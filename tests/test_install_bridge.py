"""Tests for the plugin and its installer skill: the plugin and the marketplace file, the skill
folder, and the installer in throwaway projects.

Run:  python3 tests/test_install_bridge.py          (Windows: py -3.11 tests\\test_install_bridge.py)

Needs Python 3.11 or newer and git. The svn cases run where svn and svnadmin are installed, the
case for an older interpreter where one is found, the link cases where the system lets a test make
a link, and Claude Code's own check of the plugin where the claude command is installed. Every
project is built under the temp folder and deleted afterwards. git reads no configuration of the
user's while the tests run, and claude gets a configuration folder of its own.
"""
import ast
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MARKETPLACE = REPO / ".claude-plugin" / "marketplace.json"
PLUGIN = REPO / "plugins" / "agent-skills-bridge"
MANIFEST = PLUGIN / ".claude-plugin" / "plugin.json"
SKILL = PLUGIN / "skills" / "installing-agent-skills-bridge"
INSTALLER = SKILL / "scripts" / "install_bridge.py"
KIT = SKILL / "assets" / "kit"

SH = ".claude/hooks/agent-skills-bridge.sh"
PS1 = ".claude/hooks/agent-skills-bridge.ps1"
DOC = ".claude/hooks/agent-skills-bridge.md"
SETTINGS = ".claude/settings.json"
ATTRIBUTES = ".claude/hooks/.gitattributes"
ANCHOR = ".claude/skills/.gitignore"
KIT_FILES = {
    SH: "hooks/agent-skills-bridge.sh",
    PS1: "hooks/agent-skills-bridge.ps1",
    DOC: "hooks/agent-skills-bridge.md",
    SETTINGS: "settings.json",
    ATTRIBUTES: "hooks/.gitattributes",
    ANCHOR: "skills/.gitignore",
}
WINDOWS = os.name == "nt"

SCRATCH = None
ENV = None


def setUpModule():
    global SCRATCH, ENV
    SCRATCH = Path(tempfile.mkdtemp(prefix="asb-install-test-"))
    empty = SCRATCH / "gitconfig"
    empty.write_text("", encoding="utf-8")
    temp = SCRATCH / "temp"  # where the installer keeps the files it replaced: gone with the tests
    temp.mkdir()
    ENV = dict(os.environ, GIT_CONFIG_GLOBAL=str(empty), GIT_CONFIG_NOSYSTEM="1", TMPDIR=str(temp), TEMP=str(temp), TMP=str(temp))
    for name in ("ASB_CMD", "AGENT_SKILLS_BRIDGE", "CLAUDE_PROJECT_DIR"):
        ENV.pop(name, None)


def tearDownModule():
    def writable(function, path, _):
        os.chmod(path, stat.S_IWRITE | stat.S_IREAD)
        function(path)

    shutil.rmtree(SCRATCH, onerror=writable)


def kit(target):
    """The kit's file for a path in the project, with LF line ends: what the installer writes."""
    return (KIT / KIT_FILES[target]).read_bytes().replace(b"\r\n", b"\n")


KIT_HOOKS = json.loads(kit(SETTINGS))["hooks"]


def install(*flags, cwd=None, python=None):
    """Run the installer the way the skill says. Returns (exit code, report, stderr)."""
    done = subprocess.run(
        [python or sys.executable, "-I", "-S", str(INSTALLER), *flags],
        cwd=cwd,
        env=ENV,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=300,
    )
    out = done.stdout.decode("utf-8")
    return done.returncode, json.loads(out) if out.strip() else None, done.stderr.decode("utf-8", "replace")


def tool(*argv, cwd=None, check=True, feed=None):
    done = subprocess.run(argv, cwd=cwd, env=ENV, capture_output=True, input=feed, timeout=300, **({} if feed is not None else {"stdin": subprocess.DEVNULL}))
    if check and done.returncode != 0:
        raise AssertionError("%s failed: %s" % (" ".join(map(str, argv)), done.stderr.decode("utf-8", "replace")))
    return done.stdout.decode("utf-8", "replace")


def bridge_commands(settings):
    """Every hook command of the bridge in a settings object, as (event, command)."""
    found = []
    for event, groups in settings.get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                if "agent-skills-bridge." in hook.get("command", ""):
                    found.append((event, hook["command"]))
    return found


def files_of(root):
    """Every file of a project outside .git and .svn, as {path: bytes}."""
    found = {}
    for path in root.rglob("*"):
        rel = path.relative_to(root).as_posix()
        if path.is_file() and not rel.startswith((".git/", ".svn/")):
            found[rel] = path.read_bytes()
    return found


class Case(unittest.TestCase):
    def folder(self, name="project"):
        root = Path(tempfile.mkdtemp(prefix="p-", dir=SCRATCH)) / name
        root.mkdir()
        return root

    def project(self, name="project"):
        """A new git repository."""
        root = self.folder(name)
        self.git(root, "init", "-q")
        for key, value in (("user.name", "Test"), ("user.email", "test@example.invalid"), ("core.autocrlf", "false")):
            self.git(root, "config", key, value)
        return root

    def git(self, root, *arguments, check=True):
        return tool("git", "-C", str(root), *arguments, check=check)

    def write(self, root, rel, content):
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode("utf-8"))
        return path

    def run_installer(self, root, *flags, expect=0):
        code, report, err = install("--project", str(root), *flags)
        self.assertEqual(code, expect, "exit code %s, report: %s\n%s" % (code, json.dumps(report, indent=1), err))
        return report

    def actions(self, report):
        return {entry["path"]: entry["action"] for entry in report["files"]}

    def blocker(self, report, ident):
        ids = [entry["id"] for entry in report["blockers"]]
        self.assertIn(ident, ids)
        return report["blockers"][ids.index(ident)]

    def assert_kit_installed(self, root, git_files=True):
        for target in (SH, PS1, DOC):
            self.assertEqual((root / target).read_bytes(), kit(target), target)
        settings = json.loads((root / SETTINGS).read_bytes().decode("utf-8-sig"))
        for event, groups in KIT_HOOKS.items():
            for group in groups:
                self.assertIn(group, settings["hooks"][event])
        self.assertEqual(len(bridge_commands(settings)), 4)
        if git_files:
            self.assertIn(b"*.sh text eol=lf", (root / ATTRIBUTES).read_bytes())
            self.assertTrue((root / ANCHOR).is_file())


NAME = r"^[a-z0-9]+(-[a-z0-9]+)*$"


def frontmatter():
    """SKILL.md as (frontmatter fields, lines of the body)."""
    lines = (SKILL / "SKILL.md").read_text(encoding="utf-8").split("\n")
    if lines[0] != "---":
        raise AssertionError("the frontmatter must open on the first line")
    end = lines.index("---", 1)
    fields, key = {}, None
    for line in lines[1:end]:
        if line.startswith(" ") and key:
            fields[key] = (fields[key] + " " + line.strip()).strip()
        else:
            key, _, value = line.partition(":")
            fields[key] = "" if value.strip() in (">-", ">", "|") else value.strip().strip('"')
    return fields, lines[end + 1 :]


def files_in(folder):
    return sorted(path.relative_to(folder).as_posix() for path in folder.rglob("*") if path.is_file() and "__pycache__" not in path.parts)


class Plugin(unittest.TestCase):
    """The plugin and the marketplace file: what Claude Code needs to install the skill by name."""

    def setUp(self):
        self.market = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        self.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.entry = self.market["plugins"][0]

    def test_marketplace_lists_the_plugin_under_its_own_name(self):
        self.assertRegex(self.market["name"], NAME)
        self.assertTrue(self.market["owner"]["name"])
        self.assertTrue(self.market["description"])
        self.assertEqual(len(self.market["plugins"]), 1)
        self.assertEqual(self.entry["name"], self.manifest["name"], "people install by the entry's name, the skill carries the manifest's")
        self.assertEqual(PLUGIN.name, self.manifest["name"])

    def test_marketplace_finds_the_plugin_in_this_repository(self):
        source = self.entry["source"]
        self.assertTrue(source.startswith("./"), source)
        self.assertNotIn("..", source)
        self.assertNotIn("\\", source)
        self.assertEqual((REPO / source).resolve(), PLUGIN.resolve())
        self.assertTrue(MANIFEST.is_file())

    def test_manifest_has_what_users_see(self):
        name = self.manifest["name"]
        self.assertRegex(name, NAME)
        self.assertNotIn("claude", name)
        self.assertNotIn("anthropic", name)
        self.assertTrue(self.manifest["description"])
        self.assertTrue(self.manifest["author"]["name"])
        for field in ("homepage", "repository"):
            url = urllib.parse.urlsplit(self.manifest[field])
            self.assertEqual(url.scheme, "https", field)
            self.assertTrue(url.netloc and url.path.strip("/"), field)
        self.assertEqual(self.manifest["license"], frontmatter()[0]["license"])

    def test_no_version_is_pinned(self):
        """Without a version, Claude Code takes the commit as the version: every commit to the
        plugin reaches the users who update. A pinned version would hold them back until someone
        remembers to raise it."""
        self.assertNotIn("version", self.manifest)
        self.assertNotIn("version", self.entry)

    def test_manifests_name_no_mail_address(self):
        for path in (MARKETPLACE, MANIFEST):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn('"email"', text, path.name)
            self.assertNotRegex(text, r"[\w.+-]+@[\w-]+\.\w", path.name)

    def test_plugin_brings_the_one_skill_and_nothing_else(self):
        """No hooks, commands, agents, servers or programs: installing the plugin changes no session
        until the user types the skill's name."""
        expected = sorted([".claude-plugin/plugin.json", "README.md", *("skills/%s/%s" % (SKILL.name, name) for name in files_in(SKILL))])
        self.assertEqual(files_in(PLUGIN), expected)
        self.assertEqual(files_in(MARKETPLACE.parent), ["marketplace.json"])
        for key in ("skills", "commands", "agents", "hooks", "mcpServers", "lspServers", "outputStyles", "workflows", "experimental", "userConfig", "channels", "dependencies"):
            self.assertNotIn(key, self.manifest)
            self.assertNotIn(key, self.entry)

    def test_readmes_give_the_install_line_and_the_command(self):
        name = self.manifest["name"]
        repository = urllib.parse.urlsplit(self.manifest["repository"]).path.strip("/")
        for readme in (REPO / "README.md", PLUGIN / "README.md"):
            text = readme.read_text(encoding="utf-8")
            where = readme.relative_to(REPO).as_posix()
            self.assertIn("/plugin install %s --marketplace %s\n" % (name, repository), text, where)
            self.assertIn("/plugin install %s@%s\n" % (name, self.market["name"]), text, where)
            self.assertIn("/%s:%s\n" % (name, SKILL.name), text, where)

    def test_claude_code_accepts_the_plugin(self):
        claude = shutil.which("claude")
        if claude is None:
            self.skipTest("no claude command here")
        config = SCRATCH / "claude-config"
        config.mkdir(exist_ok=True)
        for folder in (REPO, PLUGIN):
            done = subprocess.run([claude, "plugin", "validate", str(folder)], env=dict(ENV, CLAUDE_CONFIG_DIR=str(config)), capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
            out = done.stdout.decode("utf-8", "replace") + done.stderr.decode("utf-8", "replace")
            self.assertEqual(done.returncode, 0, out)
            self.assertIn("Validation passed", out)
            self.assertNotIn("has no line that installs", out, "the README must hold the install line")
        if "Provides:" in out:  # Claude Code 2.1.326 and newer list what the plugin brings
            self.assertIn("skills: %s:%s" % (self.manifest["name"], SKILL.name), out)


class SkillFolder(unittest.TestCase):
    """The skill as a package: what the Agent Skills specification and Claude Code ask of it."""

    def test_frontmatter_follows_the_specification(self):
        fields, body = frontmatter()
        name = fields["name"]
        self.assertEqual(name, SKILL.name, "the name must match the folder")
        self.assertRegex(name, r"^[a-z0-9]+(-[a-z0-9]+)*$")
        self.assertLessEqual(len(name), 64)
        self.assertNotIn("claude", name)
        self.assertNotIn("anthropic", name)
        self.assertTrue(0 < len(fields["description"]) <= 1024, len(fields["description"]))
        self.assertNotRegex(fields["description"], r"[<>]")
        self.assertLessEqual(len(fields["compatibility"]), 500)
        self.assertLess(len(body), 500, "SKILL.md must stay under 500 lines")

    def test_description_says_what_and_when_and_draws_the_line(self):
        description = frontmatter()[0]["description"]
        self.assertTrue(description.startswith("Installs or updates the agent-skills-bridge"))
        self.assertIn("Use only when the user explicitly asks", description)
        self.assertIn("never commits", description)

    def test_only_the_user_starts_it(self):
        fields, body = frontmatter()
        self.assertEqual(fields["disable-model-invocation"], "true")
        self.assertIn("allow_implicit_invocation: false", (SKILL / "agents" / "openai.yaml").read_text(encoding="utf-8"))
        self.assertIn("## 0. Precondition", "\n".join(body))

    def test_skill_names_its_script_and_no_windows_paths(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn('"<skill>/scripts/install_bridge.py"', text)
        self.assertTrue(INSTALLER.is_file())
        self.assertNotIn("scripts\\", text)

    def test_folder_holds_the_skill_and_nothing_else(self):
        expected = sorted(["SKILL.md", "agents/openai.yaml", "scripts/install_bridge.py", *("assets/kit/" + asset for asset in KIT_FILES.values())])
        self.assertEqual(files_in(SKILL), expected)

    def test_scripts_of_the_kit_are_ascii(self):
        for target in (SH, PS1):
            self.assertTrue(kit(target).isascii(), target)
        self.assertNotIn(b"\r", (KIT / KIT_FILES[SH]).read_bytes(), "the shell script must be LF in the checkout")

    def test_installer_imports_the_standard_library_only(self):
        tree = ast.parse(INSTALLER.read_text(encoding="utf-8"))
        modules = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                modules.add(node.module.split(".")[0])
        self.assertLessEqual(modules, set(sys.stdlib_module_names))

    def test_help_documents_the_exit_codes(self):
        code, _, _ = install("--dry-run", "--project", str(SCRATCH / "no such folder"))
        self.assertEqual(code, 2)
        out = tool(sys.executable, "-I", "-S", str(INSTALLER), "--help")
        for number in "01234":
            self.assertIn(number + " =", out)

    def test_an_older_python_is_refused_with_its_own_exit_code(self):
        old = older_python()
        if old is None:
            self.skipTest("no Python older than 3.11 here")
        done = subprocess.run([old, "-I", "-S", str(INSTALLER), "--dry-run"], cwd=SCRATCH, env=ENV, capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        self.assertEqual(done.returncode, 4)
        self.assertEqual(done.stdout, b"")
        self.assertIn(b"needs Python 3.11 or newer", done.stderr)


def older_python():
    candidates = [shutil.which(name) for name in ("python3.10", "python3.9", "python3.8")]
    if WINDOWS and shutil.which("py"):
        listing = subprocess.run(["py", "-0p"], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
        candidates += [match.group(0).strip() for match in re.finditer(r"[A-Za-z]:\\.*python\.exe", listing)]
    for candidate in filter(None, candidates):
        probe = subprocess.run([candidate, "-c", "import sys; print(sys.version_info < (3, 11))"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if probe.stdout.strip() == "True":
            return candidate
    return None


class FreshProject(Case):
    def test_install_in_a_new_git_repository(self):
        root = self.project()
        report = self.run_installer(root)
        self.assertEqual(report["outcome"], "installed")
        self.assertEqual(report["vcs"], ["git"])
        self.assertRegex(report["kit_version"], r"^[0-9a-f]{12}$")
        self.assertEqual(self.actions(report), {target: "create" for target in KIT_FILES})
        self.assert_kit_installed(root)
        for target in KIT_FILES:
            self.assertEqual((root / target).read_bytes(), kit(target), target)
        self.assertEqual(report["blockers"] + report["problems"], [])
        self.assertNotIn("backups", report)
        self.assertTrue(any("runs the bridge" in line for line in report["status"]))
        self.assertTrue(any("git add --" in step for step in report["next_steps"]))
        self.assertTrue(any("Add agent-skills-bridge (kit %s)" % report["kit_version"] in step for step in report["next_steps"]))
        self.assertEqual(sorted(files_of(root)), sorted(KIT_FILES), "the installer leaves nothing else behind")
        self.assertEqual(self.git(root, "check-attr", "eol", "--", SH).strip(), SH + ": eol: lf")

    def test_second_run_changes_nothing(self):
        root = self.project()
        self.run_installer(root)
        before = files_of(root)
        report = self.run_installer(root)
        self.assertEqual(report["outcome"], "current")
        self.assertEqual(set(self.actions(report).values()), {"keep"})
        self.assertEqual(files_of(root), before)
        self.assertNotIn("backups", report)

    def test_dry_run_changes_nothing(self):
        root = self.project()
        report = self.run_installer(root, "--dry-run")
        self.assertEqual(report["outcome"], "would change")
        self.assertTrue(report["dry_run"])
        self.assertEqual(self.actions(report), {target: "create" for target in KIT_FILES})
        self.assertEqual(files_of(root), {})
        self.assertNotIn("status", report)

    def test_without_project_the_top_of_the_git_repository_is_taken(self):
        root = self.project()
        deep = root / "src" / "deep"
        deep.mkdir(parents=True)
        code, report, _ = install(cwd=deep)
        self.assertEqual(code, 0)
        self.assertTrue(os.path.samefile(report["project"], root))
        self.assert_kit_installed(root)
        self.assertFalse((deep / ".claude").exists())

    def test_a_named_subfolder_is_taken_as_it_is_and_noted(self):
        root = self.project()
        package = root / "packages" / "app"
        package.mkdir(parents=True)
        report = self.run_installer(package)
        self.assert_kit_installed(package)
        self.assertFalse((root / ".claude").exists())
        self.assertTrue(any("inside the git repository" in note for note in report["notes"]))

    def test_folder_without_version_control(self):
        root = self.folder()
        report = self.run_installer(root)
        self.assertEqual(report["vcs"], [])
        self.assert_kit_installed(root)
        self.assertFalse(any("git add" in step for step in report["next_steps"]))

    def test_folder_name_with_a_space_and_a_letter_outside_ascii(self):
        root = self.project("my projéct")
        report = self.run_installer(root)
        self.assert_kit_installed(root)
        self.assertTrue(any("runs the bridge" in line for line in report["status"]))

    def test_committed_kit_needs_no_commit_step(self):
        root = self.project()
        self.run_installer(root)
        self.git(root, "add", "-A")
        self.git(root, "commit", "-q", "-m", "kit")
        report = self.run_installer(root)
        self.assertFalse(any("git add" in step for step in report["next_steps"]))
        self.assertTrue(any(".claude/skills is in the repository" in line for line in report["status"]))

    def test_linked_worktree_is_noted(self):
        root = self.project()
        self.git(root, "commit", "-q", "--allow-empty", "-m", "first")
        tree = root.parent / "tree"
        self.git(root, "worktree", "add", "-q", "-b", "side", str(tree))
        report = self.run_installer(tree)
        self.assert_kit_installed(tree)
        self.assertTrue(any("linked git worktree" in note for note in report["notes"]))
        self.assertFalse(any("linked git worktree" in note for note in self.run_installer(root)["notes"]))

    def test_no_skill_yet_is_a_next_step_and_a_skill_ends_it(self):
        root = self.project()
        self.assertTrue(any("no skill in .agents/skills" in step for step in self.run_installer(root)["next_steps"]))
        self.write(root, ".agents/skills/demo/SKILL.md", "---\nname: demo\ndescription: Demo.\n---\n\nBody.\n")
        self.assertFalse(any("no skill in .agents/skills" in step for step in self.run_installer(root)["next_steps"]))


class Settings(Case):
    OWN = (
        "{\r\n"
        '    "permissions": {\r\n'
        '        "allow": [\r\n'
        '            "Bash(npm test)"\r\n'
        "        ]\r\n"
        "    },\r\n"
        '    "hooks": {\r\n'
        '        "SessionStart": [\r\n'
        "            {\r\n"
        '                "hooks": [\r\n'
        "                    {\r\n"
        '                        "type": "command",\r\n'
        '                        "command": "own-start.sh"\r\n'
        "                    }\r\n"
        "                ]\r\n"
        "            }\r\n"
        "        ],\r\n"
        '        "PreToolUse": [\r\n'
        "            {\r\n"
        '                "matcher": "Bash",\r\n'
        '                "hooks": [\r\n'
        "                    {\r\n"
        '                        "type": "command",\r\n'
        '                        "command": "own-check.sh"\r\n'
        "                    }\r\n"
        "                ]\r\n"
        "            }\r\n"
        "        ]\r\n"
        "    }\r\n"
        "}\r\n"
    )

    def settings(self, root):
        return json.loads((root / SETTINGS).read_bytes().decode("utf-8-sig"))

    def test_own_settings_stay_and_keep_their_layout(self):
        root = self.project()
        self.write(root, SETTINGS, self.OWN)
        report = self.run_installer(root)
        self.assertEqual(self.actions(report)[SETTINGS], "merge")
        self.assertNotIn("layout changed", report["files"][3]["why"])
        text = (root / SETTINGS).read_bytes().decode("utf-8")
        self.assertTrue(text.startswith(self.OWN[: self.OWN.index('        "SessionStart"')]), "the lines before the hooks are untouched")
        self.assertNotIn("\n", text.replace("\r\n", ""), "CRLF line ends are kept")
        self.assertIn('\r\n    "hooks"', text, "the indentation of four spaces is kept")
        settings = self.settings(root)
        self.assertEqual(settings["permissions"], {"allow": ["Bash(npm test)"]})
        self.assertEqual(settings["hooks"]["SessionStart"][0]["hooks"][0]["command"], "own-start.sh")
        self.assertEqual(settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "own-check.sh")
        self.assert_kit_installed(root)
        backup = Path(report["backups"]) / SETTINGS
        self.assertEqual(backup.read_bytes(), self.OWN.encode("utf-8"), "the file as it was is kept outside the project")
        shutil.rmtree(report["backups"])
        again = self.run_installer(root)
        self.assertEqual(self.actions(again)[SETTINGS], "keep")
        self.assertEqual((root / SETTINGS).read_bytes().decode("utf-8"), text)

    def test_hook_entries_of_an_older_kit_are_replaced(self):
        root = self.project()
        old = "ASB_CMD=%s . \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh\" ; exit ; #' ; & \"$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1\" %s"
        settings = {
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "set \\' ; " + old % ("session", "session")}]}],
                "FileChanged": [{"hooks": [{"type": "command", "command": "set \\' ; " + old % ("sync", "sync")}]}],
                "PreToolUse": [
                    {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "own-lint.sh"}, {"type": "command", "command": "set \\' ; " + old % ("guard", "guard")}]},
                ],
            }
        }
        self.write(root, SETTINGS, json.dumps(settings, indent=2) + "\n")
        report = self.run_installer(root)
        self.assertEqual(self.actions(report)[SETTINGS], "merge")
        merged = self.settings(root)
        self.assertEqual(len(bridge_commands(merged)), 4, "no entry of the older kit is left")
        self.assertTrue(all('test -r "$CLAUDE_PROJECT_DIR' in command for _, command in bridge_commands(merged)))
        self.assertEqual(merged["hooks"]["PreToolUse"][0], {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "own-lint.sh"}]})
        self.assert_kit_installed(root)

    def test_a_doubled_entry_is_brought_back_to_one(self):
        root = self.project()
        doubled = json.loads(kit(SETTINGS))
        doubled["hooks"]["SessionStart"] = doubled["hooks"]["SessionStart"] * 2
        self.write(root, SETTINGS, json.dumps(doubled, indent=2) + "\n")
        self.run_installer(root)
        self.assertEqual(self.settings(root), json.loads(kit(SETTINGS)))

    def test_settings_that_are_not_json_block_and_nothing_is_written(self):
        for name, content in (
            ("a comment", '{\n  // mine\n  "hooks": {}\n}\n'),
            ("a key twice", '{"hooks": {}, "model": "a", "model": "b"}\n'),
            ("hooks as a list", '{"hooks": []}\n'),
            ("an event that is no list", '{"hooks": {"PreToolUse": {}}}\n'),
            ("no object", "[1, 2]\n"),
            ("not UTF-8", b'{"model": "\xff"}\n'),
        ):
            with self.subTest(name):
                root = self.project()
                self.write(root, SETTINGS, content)
                before = files_of(root)
                report = self.run_installer(root, expect=1)
                self.assertEqual(report["outcome"], "blocked")
                self.assertIn(str(KIT / "settings.json"), self.blocker(report, "settings-unreadable")["fix"])
                self.assertEqual(files_of(root), before)
                self.assertFalse((root / ".claude" / "hooks").exists())

    def test_byte_order_mark_and_letters_outside_ascii_are_kept(self):
        root = self.project()
        self.write(root, SETTINGS, b"\xef\xbb\xbf" + '{\n\t"env": {\n\t\t"NAME": "Zoë"\n\t}\n}'.encode("utf-8"))
        self.run_installer(root)
        raw = (root / SETTINGS).read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf{\n\t\"env\": {\n\t\t\"NAME\": \"Zo\xc3\xab\"\n\t},\n\t\"hooks\": {"), raw[:60])
        self.assertFalse(raw.endswith(b"\n"), "a file without a last line end gets none")
        self.assert_kit_installed(root)

    def test_layout_that_no_writer_makes_is_said_to_change(self):
        root = self.project()
        self.write(root, SETTINGS, '{ "permissions": { "allow": ["Bash(ls)"] } }\n')
        report = self.run_installer(root)
        self.assertIn("layout changed", report["files"][3]["why"])
        self.assertEqual(self.settings(root)["permissions"], {"allow": ["Bash(ls)"]})

    def test_empty_settings_file_is_filled(self):
        root = self.project()
        self.write(root, SETTINGS, "")
        self.run_installer(root)
        self.assertEqual(self.settings(root), json.loads(kit(SETTINGS)))

    def test_hooks_that_are_turned_off_are_noted(self):
        root = self.project()
        self.write(root, SETTINGS, '{\n  "disableAllHooks": true\n}\n')
        report = self.run_installer(root)
        self.assertTrue(any("disableAllHooks" in note for note in report["notes"]))


class KitFiles(Case):
    def test_a_changed_script_is_replaced_and_kept_as_backup(self):
        root = self.project()
        self.run_installer(root)
        changed = kit(SH) + b"# local change\n"
        self.write(root, SH, changed)
        report = self.run_installer(root)
        self.assertEqual(self.actions(report), {**{target: "keep" for target in KIT_FILES}, SH: "replace"})
        self.assertEqual((root / SH).read_bytes(), kit(SH))
        self.assertEqual((Path(report["backups"]) / SH).read_bytes(), changed)
        shutil.rmtree(report["backups"])

    def test_shell_script_with_crlf_is_replaced_and_others_are_not(self):
        root = self.project()
        self.run_installer(root)
        for target in (SH, PS1, DOC):
            self.write(root, target, kit(target).replace(b"\n", b"\r\n"))
        report = self.run_installer(root)
        self.assertEqual(self.actions(report)[SH], "replace")
        self.assertEqual(self.actions(report)[PS1], "keep")
        self.assertEqual(self.actions(report)[DOC], "keep")
        self.assertNotIn(b"\r", (root / SH).read_bytes())
        shutil.rmtree(report["backups"])

    def test_checkout_with_autocrlf_counts_as_current(self):
        root = self.project()
        self.git(root, "config", "core.autocrlf", "true")
        self.run_installer(root)
        self.git(root, "add", "-A")
        self.git(root, "commit", "-q", "-m", "kit")
        for target in KIT_FILES:
            (root / target).unlink()
        self.git(root, "checkout", "--", ".")
        self.assertIn(b"\r\n", (root / PS1).read_bytes(), "control: git wrote CRLF")
        self.assertNotIn(b"\r", (root / SH).read_bytes(), "the kit's .gitattributes keeps the script LF")
        report = self.run_installer(root)
        self.assertEqual(report["outcome"], "current")
        self.assertEqual(self.git(root, "status", "--porcelain").strip(), "")

    def test_own_gitattributes_gets_the_line_and_own_anchor_stays(self):
        root = self.project()
        self.write(root, ATTRIBUTES, "*.py text\r\n*.bat text eol=crlf")
        self.write(root, ANCHOR, "*.bak\n")
        report = self.run_installer(root)
        self.assertEqual(self.actions(report)[ATTRIBUTES], "append")
        self.assertEqual(self.actions(report)[ANCHOR], "keep")
        self.assertEqual((root / ATTRIBUTES).read_bytes(), b"*.py text\r\n*.bat text eol=crlf\r\n*.sh text eol=lf\r\n")
        self.assertEqual((root / ANCHOR).read_bytes(), b"*.bak\n")
        self.assertEqual(self.git(root, "check-attr", "eol", "--", SH).strip(), SH + ": eol: lf")
        shutil.rmtree(report["backups"])
        self.assertEqual(self.actions(self.run_installer(root))[ATTRIBUTES], "keep")

    def test_test_file_of_an_older_kit_is_noted_and_left(self):
        root = self.project()
        self.write(root, ".claude/hooks/agent-skills-bridge.test.sh", "#!/bin/sh\n")
        report = self.run_installer(root)
        self.assertTrue(any("agent-skills-bridge.test.sh" in note for note in report["notes"]))
        self.assertEqual((root / ".claude/hooks/agent-skills-bridge.test.sh").read_bytes(), b"#!/bin/sh\n")

    def test_other_files_in_the_folders_are_left(self):
        root = self.project()
        own = {".claude/hooks/own-hook.sh": b"#!/bin/sh\r\n", ".claude/skills/mine/SKILL.md": b"---\nname: mine\n---\n", ".claude/settings.local.json": b"{}", ".claude/commands/go.md": b"go"}
        for rel, content in own.items():
            self.write(root, rel, content)
        self.run_installer(root)
        found = files_of(root)
        for rel, content in own.items():
            self.assertEqual(found[rel], content, rel)
        self.assert_kit_installed(root)


class Blockers(Case):
    def test_a_file_in_the_place_of_a_folder(self):
        root = self.project()
        self.write(root, ".claude", "a file")
        report = self.run_installer(root, expect=1)
        self.assertEqual(self.blocker(report, "not-a-folder")["path"], ".claude")
        self.assertEqual(files_of(root), {".claude": b"a file"})

    def test_a_folder_in_the_place_of_a_file(self):
        root = self.project()
        (root / SETTINGS).mkdir(parents=True)
        report = self.run_installer(root, expect=1)
        self.assertEqual(self.blocker(report, "not-a-file")["path"], SETTINGS)
        self.assertFalse((root / ".claude" / "hooks").exists())

    def link(self, link, target):
        """A folder link the way people make one: a junction on Windows, a symlink elsewhere."""
        link.parent.mkdir(parents=True, exist_ok=True)
        if WINDOWS:
            tool("cmd", "/c", "mklink", "/J", str(link), str(target))
        else:
            os.symlink(target, link, target_is_directory=True)
        self.addCleanup(lambda: os.rmdir(link) if WINDOWS else os.unlink(link))

    def test_skills_folder_that_is_a_link_blocks_and_needs_the_user(self):
        root = self.project()
        skills = root / ".agents" / "skills"
        skills.mkdir(parents=True)
        self.link(root / ".claude" / "skills", skills)
        report = self.run_installer(root, expect=1)
        blocker = self.blocker(report, "skills-folder-is-link")
        self.assertIn("the user's consent", blocker["fix"])
        self.assertFalse((root / ".claude" / "hooks").exists())
        self.assertEqual(list(skills.iterdir()), [], "nothing was written through the link")

    def test_claude_folder_that_is_a_link_blocks(self):
        root = self.project()
        elsewhere = root.parent / "shared"
        elsewhere.mkdir()
        self.link(root / ".claude", elsewhere)
        report = self.run_installer(root, expect=1)
        self.blocker(report, "folder-is-link")
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_a_file_that_cannot_be_written_puts_everything_back(self):
        root = self.project()
        own = '{\n  "model": "sonnet"\n}\n'
        settings = self.write(root, SETTINGS, own)
        if WINDOWS:
            os.chmod(settings, stat.S_IREAD)
            self.addCleanup(os.chmod, settings, stat.S_IWRITE | stat.S_IREAD)
        else:
            if os.geteuid() == 0:
                self.skipTest("root may write everywhere")
            (root / ".claude" / "hooks").mkdir()
            os.chmod(root / ".claude", 0o555)
            self.addCleanup(os.chmod, root / ".claude", 0o755)
        report = self.run_installer(root, expect=1)
        self.assertIn("Everything was put back", self.blocker(report, "write-failed")["message"])
        self.assertEqual(report["problems"], [])
        found = files_of(root)
        self.assertEqual(found, {SETTINGS: own.encode()}, "the scripts written before the failure are gone again")
        if WINDOWS:
            self.assertFalse((root / ".claude" / "hooks").exists(), "and so is the folder that the run made")


class IgnoredByGit(Case):
    def ignored(self, root, *paths):
        out = tool("git", "-C", str(root), "check-ignore", *paths, check=False)
        return sorted(line.strip() for line in out.splitlines() if line.strip())

    def test_ignored_claude_folder_blocks_until_the_user_agrees(self):
        root = self.project()
        rules = b"node_modules/\r\n.claude/\r\n*.log\r\n"
        self.write(root, ".gitignore", rules)
        report = self.run_installer(root, expect=1)
        blocker = self.blocker(report, "kit-ignored-by-git")
        self.assertIn("the user's consent", blocker["fix"])
        self.assertEqual(blocker["rerun_with"], "--fix-gitignore")
        self.assertIn("line 2", blocker["message"])
        self.assertEqual(files_of(root), {".gitignore": rules})

        report = self.run_installer(root, "--fix-gitignore")
        self.assertEqual(self.actions(report)[".gitignore"], "edit")
        self.assertEqual(
            (root / ".gitignore").read_bytes(),
            b"node_modules/\r\n**/.claude/*\r\n!/.claude/settings.json\r\n!/.claude/hooks/\r\n!/.claude/skills/\r\n*.log\r\n",
        )
        self.assert_kit_installed(root)
        self.assertEqual(self.ignored(root, *KIT_FILES), [])
        self.assertTrue(any(".gitignore" in step for step in report["next_steps"] if "git add" in step))
        # What the rule hid before stays hidden, in this .claude folder and in every other one.
        self.write(root, ".claude/settings.local.json", "{}")
        self.write(root, ".claude/worktrees/w/file", "x")
        self.write(root, "packages/app/.claude/settings.json", "{}")
        hidden = [".claude/settings.local.json", ".claude/worktrees/w/file", "packages/app/.claude/settings.json"]
        self.assertEqual(self.ignored(root, *hidden), sorted(hidden))
        self.assertEqual((Path(report["backups"]) / ".gitignore").read_bytes(), rules)
        shutil.rmtree(report["backups"])
        again = self.run_installer(root, "--fix-gitignore")
        self.assertEqual(again["outcome"], "current")

    def test_rule_with_a_leading_slash_keeps_it(self):
        root = self.project()
        self.write(root, ".gitignore", "/.claude\n")
        report = self.run_installer(root, "--fix-gitignore")
        self.assertEqual((root / ".gitignore").read_bytes(), b"/.claude/*\n!/.claude/settings.json\n!/.claude/hooks/\n!/.claude/skills/\n")
        self.assertEqual(self.ignored(root, *KIT_FILES), [])
        shutil.rmtree(report["backups"])

    def test_flag_without_an_ignoring_rule_edits_nothing(self):
        root = self.project()
        self.write(root, ".gitignore", "*.log\n")
        report = self.run_installer(root, "--fix-gitignore")
        self.assertNotIn(".gitignore", self.actions(report))
        self.assertEqual((root / ".gitignore").read_bytes(), b"*.log\n")

    def test_rules_the_installer_cannot_rewrite_block_even_with_the_flag(self):
        for name, prepare in (
            ("a wider pattern", lambda root: self.write(root, ".gitignore", ".cl*\n")),
            ("a rule outside the project's .gitignore", lambda root: self.write(root, ".git/info/exclude", ".claude/\n")),
            ("a rule inside .claude", lambda root: self.write(root, ".claude/.gitignore", "*\n")),
        ):
            with self.subTest(name):
                root = self.project()
                prepare(root)
                before = files_of(root)
                report = self.run_installer(root, "--fix-gitignore", expect=1)
                blocker = self.blocker(report, "kit-ignored-by-git")
                self.assertNotIn("rerun_with", blocker)
                self.assertIn("by hand", blocker["fix"])
                self.assertEqual(files_of(root), before)

    def test_project_below_the_top_folder_edits_only_its_own_gitignore(self):
        # git names an ignore file from the top of the repository, not from the project's folder.
        root = self.project()
        package = root / "packages" / "app"
        package.mkdir(parents=True)
        self.write(root, ".gitignore", ".claude/\n")
        self.write(package, ".gitignore", "*.tmp\n")
        before = files_of(root)
        report = self.run_installer(package, "--fix-gitignore", expect=1)
        self.assertNotIn("rerun_with", self.blocker(report, "kit-ignored-by-git"), "a rule in the top folder's file is not the project's to rewrite")
        self.assertEqual(files_of(root), before)

        self.write(root, ".gitignore", "*.log\n")
        self.write(package, ".gitignore", "*.tmp\n.claude\n")
        report = self.run_installer(package, "--fix-gitignore")
        self.assertEqual((package / ".gitignore").read_bytes(), b"*.tmp\n**/.claude/*\n!/.claude/settings.json\n!/.claude/hooks/\n!/.claude/skills/\n")
        self.assertEqual((root / ".gitignore").read_bytes(), b"*.log\n")
        self.assert_kit_installed(package)
        self.assertEqual(self.ignored(root, *("packages/app/" + target for target in KIT_FILES)), [])
        shutil.rmtree(report["backups"])

    def test_second_rule_that_still_hides_the_kit_puts_everything_back(self):
        root = self.project()
        rules = b".claude/\nsettings.json\n"
        self.write(root, ".gitignore", rules)
        report = self.run_installer(root, "--fix-gitignore", expect=1)
        blocker = self.blocker(report, "check-failed")
        self.assertIn("still ignores .claude/settings.json", blocker["message"])
        self.assertIn("Everything was put back", blocker["message"])
        self.assertEqual(files_of(root), {".gitignore": rules})
        self.assertFalse((root / ".claude").exists())

    def test_tracked_kit_in_an_ignored_folder_is_no_blocker(self):
        root = self.project()
        self.run_installer(root)
        self.git(root, "add", "-A")
        self.git(root, "commit", "-q", "-m", "kit")
        self.write(root, ".gitignore", ".claude/\n")
        report = self.run_installer(root)
        self.assertEqual(report["outcome"], "current")


@unittest.skipUnless(shutil.which("svn") and shutil.which("svnadmin"), "no svn and svnadmin here")
class Subversion(Case):
    def working_copy(self):
        base = self.folder("svn")
        tool("svnadmin", "create", str(base / "repo"))
        tool("svn", "checkout", "-q", "--non-interactive", (base / "repo").as_uri(), str(base / "wc"))
        return base / "wc"

    def svn(self, root, *arguments):
        return tool("svn", "--non-interactive", *arguments, cwd=root)

    def status(self, root):
        found = {}
        for line in self.svn(root, "status").splitlines():
            found[line[8:].strip().replace("\\", "/")] = line[0]
        return found

    def test_install_in_an_svn_working_copy(self):
        root = self.working_copy()
        self.write(root, ".claude/settings.local.json", "{}")
        self.write(root, ".claude/skills/old-copy/SKILL.md", "---\nname: old-copy\n---\n")
        report = self.run_installer(root)
        self.assertEqual(report["vcs"], ["svn"])
        self.assertEqual(self.actions(report)[ATTRIBUTES], "skip")
        self.assertEqual(self.actions(report)[ANCHOR], "skip")
        self.assertFalse((root / ATTRIBUTES).exists())
        self.assertFalse((root / ANCHOR).exists())
        self.assert_kit_installed(root, git_files=False)
        status = self.status(root)
        for path in (".claude", ".claude/hooks", ".claude/skills", SETTINGS, SH, PS1, DOC):
            self.assertEqual(status.get(path), "A", path)
        self.assertEqual(status.get(".claude/settings.local.json"), "?", "a file of the user's is not scheduled")
        self.assertNotIn(".claude/skills/old-copy", status, "what lies in .claude/skills is ignored, not added")
        self.assertEqual(self.svn(root, "propget", "svn:ignore", ".claude/skills").split(), ["*"])
        self.assertEqual(self.svn(root, "propget", "svn:eol-style", SH).strip(), "LF")
        self.assertEqual(len(report["vcs_steps"]), 4)
        self.assertTrue(any("svn status" in step for step in report["next_steps"]))
        self.assertTrue(any("copies are ignored" in line for line in report["status"]), report["status"])

        again = self.run_installer(root)
        self.assertEqual(again["outcome"], "current")
        self.assertNotIn("vcs_steps", again)
        self.svn(root, "commit", "-q", "-m", "kit")
        self.assertEqual(self.run_installer(root)["outcome"], "current")

    def test_own_svn_ignore_rules_stay(self):
        root = self.working_copy()
        self.svn(root, "mkdir", "-q", "--parents", ".claude/skills")
        value = self.write(root.parent, "value.txt", "*.tmp\n")
        self.svn(root, "propset", "-q", "svn:ignore", "-F", str(value), ".claude/skills")
        self.run_installer(root)
        self.assertEqual(self.svn(root, "propget", "svn:ignore", ".claude/skills").split(), ["*.tmp", "*"])

    def test_dry_run_names_the_svn_steps_and_takes_none(self):
        root = self.working_copy()
        report = self.run_installer(root, "--dry-run")
        self.assertEqual(report["outcome"], "would change")
        self.assertEqual(len(report["vcs_steps"]), 4)
        self.assertEqual(self.status(root), {})
        self.assertEqual(files_of(root), {})


class InstalledBridge(Case):
    """The installed kit at work: the hook commands from the installed settings.json, run the way
    Claude Code runs them."""

    def prepared(self):
        root = self.project()
        self.write(root, ".agents/skills/demo/SKILL.md", "---\nname: demo\ndescription: Demo.\n---\n\nBody.\n")
        report = self.run_installer(root)
        settings = json.loads((root / SETTINGS).read_bytes())
        commands = {event: [hook["command"] for group in groups for hook in group["hooks"]] for event, groups in settings["hooks"].items()}
        return root, report, commands

    def hook(self, argv, root, event):
        done = subprocess.run(argv, cwd=root, env=dict(ENV, CLAUDE_PROJECT_DIR=str(root)), input=json.dumps(event).encode(), capture_output=True, timeout=300)
        return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")

    def check_hooks(self, root, shell, commands):
        code, out, err = self.hook([*shell, commands["SessionStart"][0]], root, {"hook_event_name": "SessionStart"})
        self.assertEqual(code, 0, err)
        self.assertIn('"reloadSkills":true', out)
        copy = root / ".claude" / "skills" / "demo" / "SKILL.md"
        self.assertEqual(copy.read_bytes(), (root / ".agents/skills/demo/SKILL.md").read_bytes())
        self.assertNotIn(".claude/skills/demo", self.git(root, "status", "--porcelain", "--untracked-files=all"))
        for command in commands["PreToolUse"]:
            code, _, err = self.hook([*shell, command], root, {"tool_name": "Write", "tool_input": {"file_path": str(copy)}})
            self.assertEqual(code, 2, err)
            self.assertIn("Blocked by the agent-skills bridge", err)
        code, _, _ = self.hook([*shell, commands["PreToolUse"][0]], root, {"tool_name": "Edit", "tool_input": {"file_path": str(root / "README.md")}})
        self.assertEqual(code, 0)

    def test_hooks_work_in_the_shell_that_claude_code_uses(self):
        root, report, commands = self.prepared()
        self.assertTrue(any("out of date: demo" in line for line in report["status"]), report["status"])
        shell = report["status_shell"]
        if "powershell" in Path(shell).name.lower():
            self.skipTest("no POSIX shell here: the PowerShell case covers this machine")
        self.check_hooks(root, [shell, "-c"], commands)
        report = self.run_installer(root)
        self.assertEqual(report["outcome"], "current")
        self.assertTrue(any("copies are current" in line for line in report["status"]), report["status"])

    def test_what_the_bridge_finds_wrong_becomes_a_note(self):
        root = self.project()
        for folder in (".agents", ".claude"):
            self.write(root, folder + "/skills/demo/SKILL.md", "---\nname: demo\ndescription: Demo.\n---\n\nBody.\n")
        report = self.run_installer(root)
        self.assertTrue(any("status command says: conflicts demo" in note for note in report["notes"]), report["notes"])
        self.assertFalse(any("out of date" in note for note in report["notes"]), "copies that the first session makes are no finding")
        self.assertTrue(any("out of date, which is as it should be" in step for step in report["next_steps"]))

    @unittest.skipUnless(WINDOWS, "Windows PowerShell is the hook shell only on Windows without Git Bash")
    def test_hooks_work_in_windows_powershell(self):
        root, _, commands = self.prepared()
        self.check_hooks(root, ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"], commands)


if __name__ == "__main__":
    unittest.main(verbosity=2)
