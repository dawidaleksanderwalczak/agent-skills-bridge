"""Tests for the plugin and its installer skill: the plugin and the marketplace file, the skill
folder, and the installer in throwaway projects. The plugin's other skill, the uninstaller, has
its tests in test_uninstall_bridge.py, which builds on this file.

Run:  python3 tests/test_install_bridge.py          (Windows: py -3.11 tests\\test_install_bridge.py)

Needs Python 3.11 or newer and git. The svn cases run where svn and svnadmin are installed, the
cases for an older interpreter where one is found, the link cases where the system lets a test make
a link, and Claude Code's own check of the plugin where the claude command is installed. Every
project is built under the temp folder and deleted afterwards. git reads no configuration of the
user's while the tests run, and claude gets a configuration folder of its own.
"""
import argparse
import ast
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse
from pathlib import Path

sys.dont_write_bytecode = True  # a test loads the installer as a module: no __pycache__ in the skill folder

REPO = Path(__file__).resolve().parent.parent
MARKETPLACE = REPO / ".claude-plugin" / "marketplace.json"
PLUGIN = REPO / "plugins" / "agent-skills-bridge"
MANIFEST = PLUGIN / ".claude-plugin" / "plugin.json"
SKILL = PLUGIN / "skills" / "installing-agent-skills-bridge"
REMOVING = PLUGIN / "skills" / "uninstalling-agent-skills-bridge"  # the plugin's other skill
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


def install(*flags, cwd=None, python=None, env=None):
    """Run the installer the way the skill says. Returns (exit code, report, stderr)."""
    done = subprocess.run(
        [python or sys.executable, "-I", "-S", str(INSTALLER), *flags],
        cwd=cwd,
        env=env or ENV,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=300,
    )
    out = done.stdout.decode("utf-8")
    return done.returncode, json.loads(out) if out.strip() else None, done.stderr.decode("utf-8", "replace")


def installer_module():
    """The installer as a module, for the few functions that are tested by themselves."""
    spec = importlib.util.spec_from_file_location("install_bridge", INSTALLER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def running(pid):
    """True while a process with this id runs. One that has ended and waits to be collected, as it
    does in a container that has nothing to collect it, does not count."""
    if WINDOWS:
        listing = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return '"%d"' % pid in listing.stdout
    try:
        with open("/proc/%d/stat" % pid) as record:  # Linux: the state follows the name in brackets
            return record.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        pass  # no /proc here, or the process is gone
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def gone(pid, tries=100):
    """True once a process has ended; waits up to ten seconds for that."""
    for _ in range(tries):
        if not running(pid):
            return True
        time.sleep(0.1)
    return False


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

    def link(self, link, target):
        """A folder link the way people make one: a junction on Windows, a symlink elsewhere."""
        link.parent.mkdir(parents=True, exist_ok=True)
        if WINDOWS:
            tool("cmd", "/c", "mklink", "/J", str(link), str(target))
        else:
            os.symlink(target, link, target_is_directory=True)
        self.addCleanup(lambda: os.rmdir(link) if WINDOWS else os.unlink(link))

    def program(self, folder, name, content=b"", ending=".exe"):
        """A file that PATH would find under this name: with an ending on Windows, executable elsewhere."""
        path = self.write(folder, name + (ending if WINDOWS else ""), content)
        os.chmod(path, 0o755)
        if not WINDOWS and not os.access(path, os.X_OK):
            self.skipTest("the temp folder lets no file be a program")
        return str(path)

    def run_installer(self, root, *flags, expect=0):
        code, report, err = install("--project", str(root), *flags)
        self.assertEqual(code, expect, "exit code %s, report: %s\n%s" % (code, json.dumps(report, indent=1), err))
        self.assertEqual(err, "", "the installer writes nothing to stderr")
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

    def test_plugin_brings_its_two_skills_and_nothing_else(self):
        """No hooks, commands, agents, servers or programs: installing the plugin changes no session
        until the user types the name of one of its skills."""
        self.assertEqual(sorted(path.name for path in (PLUGIN / "skills").iterdir()), [SKILL.name, REMOVING.name])
        expected = sorted([".claude-plugin/plugin.json", "README.md", *("skills/%s/%s" % (skill.name, name) for skill in (SKILL, REMOVING) for name in files_in(skill))])
        self.assertEqual(files_in(PLUGIN), expected)
        self.assertEqual(files_in(MARKETPLACE.parent), ["marketplace.json"])
        for key in ("skills", "commands", "agents", "hooks", "mcpServers", "lspServers", "outputStyles", "workflows", "experimental", "userConfig", "channels", "dependencies"):
            self.assertNotIn(key, self.manifest)
            self.assertNotIn(key, self.entry)

    def test_readmes_give_the_install_line_and_the_commands(self):
        name = self.manifest["name"]
        repository = urllib.parse.urlsplit(self.manifest["repository"]).path.strip("/")
        for readme in (REPO / "README.md", PLUGIN / "README.md"):
            text = readme.read_text(encoding="utf-8")
            where = readme.relative_to(REPO).as_posix()
            self.assertIn("/plugin install %s --marketplace %s\n" % (name, repository), text, where)
            self.assertIn("/plugin install %s@%s\n" % (name, self.market["name"]), text, where)
            for skill in (SKILL, REMOVING):
                self.assertIn("/%s:%s\n" % (name, skill.name), text, where)

    def test_readme_names_the_page_for_a_removal_by_hand(self):
        """The uninstaller needs Python. The README leads to the page that needs none."""
        page = REMOVING / "references" / "removing-by-hand.md"
        self.assertIn("](%s)" % page.relative_to(REPO).as_posix(), (REPO / "README.md").read_text(encoding="utf-8"))
        self.assertTrue(page.is_file())

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
            for skill in (SKILL, REMOVING):
                self.assertIn("skills: %s:%s" % (self.manifest["name"], skill.name), out)


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
        done = subprocess.run([sys.executable, "-I", "-S", str(INSTALLER), "--help"], env=dict(ENV, FORCE_COLOR="1"), capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        out = done.stdout.decode("utf-8")
        self.assertEqual((done.returncode, done.stderr), (0, b""))
        for number, outcome in enumerate(("installed", "blocked", "wrong arguments", "incomplete", "python too old")):
            self.assertRegex(out, r"%d\s+=\s+%s" % (number, outcome.replace(" ", r"\s+")))
        self.assertNotIn("\x1b", out, "no colour codes, also where Python 3.14 is told to force them")


OLDER = []  # what older_python() found, looked for once


def older_python():
    """The oldest Python on this machine that the installer hands over from (3.6 to 3.10), or None.
    The oldest one, because it differs most from the Python that the tests run on."""
    if not OLDER:
        candidates = [shutil.which(name) for name in ("python3.6", "python3.7", "python3.8", "python3.9", "python3.10", "python3", "python")]
        if WINDOWS and shutil.which("py"):
            listing = subprocess.run(["py", "-0p"], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
            candidates += [match.group(0).strip() for match in re.finditer(r"[A-Za-z]:\\.*python\.exe", listing)]
        found = []
        for candidate in filter(None, candidates):
            try:
                probe = subprocess.run([candidate, "-c", "import sys; print('%d %d' % sys.version_info[:2])"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
                version = tuple(int(number) for number in probe.stdout.split())
            except (OSError, ValueError, subprocess.TimeoutExpired):
                continue  # a name on PATH that starts nothing
            if len(version) == 2 and (3, 6) <= version < (3, 11):
                found.append((version, candidate))
        OLDER.append(min(found)[1] if found else None)
    return OLDER[0]


class CommandLine(Case):
    """What the caller sees of a run: one JSON object on stdout, nothing on stderr, and an exit code
    that says the same as the report's outcome."""

    def test_wrong_arguments_come_as_a_report(self):
        root = self.folder()
        for name, flags, said in (
            ("an option that does not exist", ("--project", str(root), "--nope"), "--nope"),
            ("an option cut short", ("--proj", str(root)), "--proj"),
            ("a project that is no folder", ("--dry-run", "--project", str(root / "no such folder")), "is not a folder"),
            ("--project without a folder", ("--project",), "expected one argument"),
        ):
            with self.subTest(name):
                code, report, err = install(*flags)
                self.assertEqual((code, err), (2, ""))
                self.assertEqual(report["outcome"], "wrong arguments")
                self.assertIn(said, report["message"])
                self.assertIn("--project FOLDER", report["usage"])
                self.assertEqual(files_of(root), {})

    def test_a_quote_that_powershell_left_in_the_path_is_explained(self):
        # Windows PowerShell 5.1 hands "C:\my project\" over as: C:\my project" and the rest of the line.
        root = self.folder("my project")
        code, report, err = install("--project", str(root) + '" --dry-run')
        self.assertEqual((code, err), (2, ""))
        self.assertIn("quotation mark", report["message"])
        self.assertIn("without a backslash at its end", report["message"])
        self.assertEqual(files_of(root), {}, "the --dry-run that the path swallowed must not turn into an installation")

    @unittest.skipUnless(WINDOWS, "only Windows has a second spelling for a path")
    def test_git_bash_spelling_of_the_project_outside_git_bash_is_explained(self):
        # Git Bash rewrites /c/Users/... before it starts a Windows program; PowerShell and cmd do not.
        root = self.folder()
        windows = root.as_posix()
        if windows[1] != ":":
            self.skipTest("the temp folder is not on a drive with a letter")
        spelled = "/%s%s" % (windows[0].lower(), windows[2:])
        code, report, err = install("--project", spelled, "--dry-run")
        self.assertEqual((code, err), (2, ""))
        self.assertIn("outside Git Bash, write %s:%s." % (windows[0].upper(), windows[2:]), report["message"])

    def test_a_slash_at_the_end_of_the_project_is_accepted(self):
        root = self.folder("my project")
        code, report, err = install("--project", str(root) + "/", "--dry-run")
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(os.path.samefile(report["project"], root))

    @unittest.skipUnless(WINDOWS, "Windows PowerShell 5.1 is the shell that turns a program's stderr into errors")
    def test_windows_powershell_with_stderr_redirected_sees_a_success(self):
        """With 2>&1, Windows PowerShell 5.1 makes an error of every line on stderr, and with
        $ErrorActionPreference = 'Stop' it ends the command there with exit code 1. An installer
        that wrote its closing line to stderr was reported as failed when it had succeeded."""
        root = self.folder()
        quoted = ["'%s'" % str(value).replace("'", "''") for value in (sys.executable, INSTALLER, root)]
        command = "$ErrorActionPreference = 'Stop'; & %s -I -S %s --project %s --dry-run 2>&1; exit $LASTEXITCODE" % tuple(quoted)
        done = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command], env=ENV, capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        out = done.stdout.decode("utf-8", "replace") + done.stderr.decode("utf-8", "replace")
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("NativeCommandError", out)
        self.assertEqual(json.loads(done.stdout.decode("utf-8", "replace"))["outcome"], "would change")


class OlderPython(Case):
    """python3 is older than 3.11 on many machines that have a newer Python under another name. The
    installer looks for that one on PATH and goes on with it."""

    def test_source_reads_as_python_3_7(self):
        """An older Python must get as far as the version check, so the file keeps to old syntax."""
        ast.parse(INSTALLER.read_text(encoding="utf-8"), feature_version=(3, 7))

    def test_pythons_on_path_come_best_first_and_input_folders_are_left_out(self):
        module = installer_module()
        base = self.folder("path")
        first, second, project, missing = base / "first", base / "second", base / "project", base / "missing"
        expected = [
            [self.program(second, "python3.13")],
            [self.program(first, "python3.12")],
            [self.program(second, "python3.12")],
            [self.program(first, "python3")],
            [self.program(second, "python3")],
            [self.program(second, "python")],
        ]
        if WINDOWS:
            expected.append([self.program(second, "py"), "-3"])
        for name in ("python3.10", "python3.9", "python3.12-config", "python3.12m", "pythonw", "pip3"):
            self.program(first, name)  # too old by their names, or no Python
        self.write(first, "python3.16.bat", b"")  # a wrapper: its arguments would go through cmd.exe
        (first / "python3.14").mkdir()  # folders with the name of a program
        (first / "python3.14.exe").mkdir()
        self.program(project, "python3.99")  # in the project, which is input
        self.link(base / "alias", project)  # the project again, by another name
        if not WINDOWS:
            self.write(first, "python3.15", b"")  # not executable
        search = os.pathsep.join(
            [str(missing), "", ".", "relative", str(project), str(base / "alias"), str(first), '"%s"' % second if WINDOWS else str(second), str(first)]
        )
        before = os.environ["PATH"]
        os.environ["PATH"] = search
        try:
            found = module.pythons_on_path((str(project), None))
        finally:
            os.environ["PATH"] = before
        self.assertEqual([[os.path.normcase(part) for part in command] for command in found], [[os.path.normcase(part) for part in command] for command in expected])

    def test_the_project_is_read_from_the_command_line(self):
        module = installer_module()
        self.assertEqual(module.named_project(["--dry-run", "--project", "a b"]), "a b")
        self.assertEqual(module.named_project(["--project=a b", "--dry-run"]), "a b")
        self.assertEqual(module.named_project(["--project", "first", "--project=second"]), "second", "the last one counts, as for the parser")
        self.assertIsNone(module.named_project(["--dry-run"]))
        self.assertIsNone(module.named_project(["--project"]))

    def test_a_command_is_asked_for_its_version(self):
        module = installer_module()
        self.assertEqual(module.version_of([sys.executable]), (tuple(sys.version_info[:3]), sys.version_info.releaselevel, os.name))
        broken = self.program(self.folder(), "python3.99", b"not a program")
        self.assertIsNone(module.version_of([broken]), "a file that does not start")
        self.assertIsNone(module.version_of([str(SCRATCH / "no such program")]))
        self.assertIsNone(module.version_of([sys.executable, "-c", "print('3.12')"]), "an answer that is no version")
        self.assertIsNone(module.version_of([sys.executable, "-c", "print('3.12.1 final nt'); raise SystemExit(1)"]), "a program that fails")

    def test_a_python_for_another_system_is_passed_over(self):
        """On Windows, PATH can hold a Python of MSYS2 or Cygwin. It reads C:\\Users as a relative
        path, so the installer must not go on with it."""
        module = installer_module()
        other = "posix" if WINDOWS else "nt"
        module.pythons_on_path = lambda avoid=(): [[sys.executable, "-c", "print('3.99.0 final %s')" % other]]
        answer = io.StringIO()
        with contextlib.redirect_stdout(answer):
            code = module.go_on_with_a_newer_python()
        report = json.loads(answer.getvalue())
        self.assertEqual((code, report["outcome"]), (4, "python too old"))
        self.assertEqual(len(report["looked_at"]), 1)
        self.assertTrue(report["looked_at"][0].endswith("Python 3.99.0, built for another system (%s)" % other), report["looked_at"])

    # Where the machine has no older Python, this one plays it: it is told that it is Python 3.9
    # before the installer starts. What it then finds on PATH and starts is real.
    PLAYED = "import runpy, sys; sys.version_info = (3, 9, 6, 'final', 0); sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name='__main__')"

    def start_older(self, *flags, path, cwd=None):
        """Start the installer with a Python that is too old for it. Returns (exit code, report,
        stderr, whether that Python was a real one)."""
        old = older_python()
        if old is None and WINDOWS:
            self.skipTest("no Python older than 3.11 here, and no link to play one with")
        start = [old, "-I", "-S"] if old else [sys.executable, "-I", "-S", "-c", self.PLAYED]
        done = subprocess.run([*start, str(INSTALLER), *flags], cwd=cwd, env=dict(ENV, PATH=path), stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
        out = done.stdout.decode("utf-8")
        return done.returncode, json.loads(out) if out.strip() else None, done.stderr.decode("utf-8", "replace"), old is not None

    def test_an_older_python_goes_on_with_a_newer_one_from_path(self):
        root = self.project()
        first = self.folder("first")
        self.program(first, "python3.99", b"not a program")  # the first that is tried, and it does not start
        if not WINDOWS:
            os.symlink(sys.executable, first / "python3.98")  # this Python under a name that a search finds
        path = os.pathsep.join([str(first), os.path.dirname(sys.executable), ENV["PATH"]])
        code, report, err, real = self.start_older("--project", str(root), path=path)
        self.assertEqual((code, err), (0, ""), report)
        self.assertEqual(report["outcome"], "installed")
        self.assert_kit_installed(root)
        notes = [note for note in report["notes"] if "started the installer" in note]
        self.assertEqual(len(notes), 1, report["notes"])
        self.assertRegex(notes[0], r"^Python 3\.\d+\.\d+ started the installer, which needs Python 3\.11 or newer\. It went on with Python 3\.(1[1-9]|[2-9]\d)\.\d+ \(")
        if not real:
            self.assertTrue(notes[0].startswith("Python 3.9.6 started"), notes[0])
        again = self.run_installer(root)
        self.assertFalse(any("started the installer" in note for note in again["notes"]), "a new enough Python says nothing about it")

    def test_an_older_python_without_a_newer_one_says_so_and_changes_nothing(self):
        root = self.project()
        lonely = self.folder("lonely")
        broken = self.program(lonely, "python3.99", b"not a program")
        code, report, err, _ = self.start_older("--project", str(root), path=str(lonely))
        self.assertEqual((code, err), (4, ""), report)
        self.assertEqual(report["outcome"], "python too old")
        self.assertIn("needs Python 3.11 or newer", report["message"])
        self.assertEqual(len(report["looked_at"]), 1)
        self.assertTrue(report["looked_at"][0].endswith(": did not start"), report["looked_at"])
        self.assertTrue(os.path.samefile(report["looked_at"][0].rsplit(": ", 1)[0], broken))
        self.assertIn("manual-installation.md", report["fix"])
        self.assertEqual(files_of(root), {})

    def test_an_older_python_never_takes_one_from_the_project_or_the_working_directory(self):
        root = self.project()
        elsewhere = self.folder("elsewhere")
        for folder in (root, elsewhere):
            self.program(folder, "python3.98", b"not a program")
        for name, folder in (("project again", root), ("elsewhere again", elsewhere)):
            self.link(elsewhere.parent / name, folder)  # each of the two once more, by another name
        path = os.pathsep.join([str(root), str(elsewhere), str(elsewhere.parent / "project again"), str(elsewhere.parent / "elsewhere again"), "."])
        code, report, err, _ = self.start_older("--project", str(root), "--dry-run", path=path, cwd=elsewhere)
        self.assertEqual((code, err), (4, ""), report)
        self.assertEqual(report["looked_at"], [], "none of them was even asked for its version")


HANGS = '''\
"""A program that does not answer. Started with "start" or "leave", it starts a second one first,
which holds the same pipes, and puts that one's process id on record. With "leave" it then ends,
and only the second one is left."""
import subprocess
import sys
import time

if sys.argv[1] in ("start", "leave"):
    second = subprocess.Popen([sys.executable, "-I", "-S", __file__, "wait"])
    with open(sys.argv[2], "w") as record:
        record.write(str(second.pid))
if sys.argv[1] != "leave":
    time.sleep(120)
'''


class Programs(Case):
    """How the installer runs git, svn and the bridge's status command."""

    def test_output_exit_code_and_input_come_back(self):
        module = installer_module()
        echo = "import sys; data = sys.stdin.buffer.read(); sys.stdout.write('out:' + data.decode()); sys.stderr.write('err'); sys.exit(7)"
        self.assertEqual(module.run([sys.executable, "-I", "-S", "-c", echo], cwd=str(SCRATCH), feed=b"fed"), (7, "out:fed", "err"))
        self.assertEqual(module.run([sys.executable, "-I", "-S", "-c", echo], cwd=str(SCRATCH)), (7, "out:", "err"), "without input, the program reads nothing")
        code, out, err = module.run([str(SCRATCH / "no such program")], cwd=str(SCRATCH))
        self.assertEqual((code, out), (None, ""))
        self.assertTrue(err)

    LIMIT = 10  # seconds; enough for two programs to start on a slow machine

    def out_of_time(self, argv, record, module=None):
        """Run a program that will not answer within LIMIT and that puts the process id of a second
        program on record. Checks that the wait ends with the limit, and returns that id."""
        module = module or installer_module()
        started = time.monotonic()
        answer = module.run(argv, cwd=str(record.parent), timeout=self.LIMIT)
        took = time.monotonic() - started
        self.assertTrue(record.is_file(), "the program did not get as far as starting the second one within the limit")
        second = int(record.read_text())
        if not WINDOWS:
            self.addCleanup(lambda: running(second) and os.kill(second, signal.SIGKILL))
        self.assertEqual(answer, (None, "", "no answer within %d seconds" % self.LIMIT))
        self.assertLess(took, self.LIMIT + 5, "the wait must end with the time limit, not with the programs")
        return second

    def hangs(self, how, module=None):
        folder = self.folder("hangs")
        script = self.write(folder, "hangs.py", HANGS)
        return self.out_of_time([sys.executable, "-I", "-S", str(script), how, str(folder / "second.pid")], folder / "second.pid", module)

    def test_a_program_that_hangs_does_not_hold_the_installer(self):
        """A shell that waits for a git that hangs. The second program holds the pipes as long as
        it lives, and the installer must not wait for it. On Windows it is ended with the first.
        Elsewhere it stays in the installer's process group, for whoever ends that."""
        second = self.hangs("start")
        if WINDOWS:
            self.assertTrue(gone(second), "the program that the first one started is still there")

    def test_a_program_that_is_gone_and_left_another_one_does_not_hold_the_installer(self):
        """The first program has ended, so nothing leads from it to the second one any more."""
        second = self.hangs("leave")
        if WINDOWS:
            self.assertTrue(gone(second), "the program that was left behind is still there")

    @unittest.skipUnless(WINDOWS, "only Windows has jobs")
    def test_a_windows_that_gives_no_job_still_runs_and_ends_the_program(self):
        echo = "import sys; sys.stdout.write('out'); sys.exit(7)"
        with self.subTest("the program cannot be let run from the job: it is started again without one"):
            module = installer_module()

            class Stuck:
                SUSPENDED = module.Job.SUSPENDED
                handle, let_run = None, False

                def __init__(self, process):
                    pass  # the program stays as it was started: suspended

                def close(self):
                    pass

            module.Job = Stuck
            self.assertEqual(module.run([sys.executable, "-I", "-S", "-c", echo], cwd=str(SCRATCH)), (7, "out", ""))
        with self.subTest("the job is refused: what the program started is ended as far as taskkill finds it"):
            module = installer_module()

            class Refused(module.Job):
                def __init__(self, process):
                    super().__init__(process)
                    self.close()

            module.Job = Refused
            self.assertTrue(gone(self.hangs("start", module)), "the program that the first one started is still there")

    @unittest.skipUnless(WINDOWS, "Git Bash is a Windows program")
    def test_what_a_git_bash_script_started_is_ended_too(self):
        """Git's bin\\bash.exe is a launcher for the real shell, and a script's `sleep` is started
        by a copy of the shell that ends at once. Neither is found by going from parent to child."""
        module = installer_module()
        installer = module.Installer(argparse.Namespace(project=None, dry_run=True, fix_gitignore=False))
        installer.root = SCRATCH
        kind, bash = installer.hook_shell()
        if kind != "sh":
            self.skipTest("no Git Bash here")
        record = self.folder("bash") / "second.pid"
        script = 'sleep 120 & sleep 2; cat /proc/$!/winpid > "%s"; wait' % record.as_posix()
        second = self.out_of_time([bash, "-c", script], record)
        self.assertTrue(gone(second), "the sleep that the script started is still there")


class Lookup(Case):
    """Where the installer looks for git, svn and the shells: in the absolute folders of PATH, and
    never in the project or the working directory, however PATH spells them."""

    def test_a_program_of_that_name_in_the_project_is_not_taken_and_hides_nothing(self):
        module = installer_module()
        base = self.folder("lookup")
        project, tools = base / "project", base / "tools"
        wanted = self.program(tools, "sometool")
        self.program(project, "sometool", ending=".cmd")  # what Python 3.11 found first on Windows, and stopped at
        self.program(project / "sub", "sometool")
        self.link(base / "alias", project)
        before, here = os.environ["PATH"], os.getcwd()
        try:
            os.chdir(project)
            for name, entries in (
                ("the project comes first on PATH", [str(project), str(tools)]),
                ("the project under another name", [str(base / "alias"), str(tools)]),
                ("an entry that counts from the working directory", ["sub", os.curdir, "", str(tools)]),
                ("the working directory, and the project is not named", [str(project), str(tools)]),
            ):
                with self.subTest(name):
                    os.environ["PATH"] = os.pathsep.join(entries)
                    found = module.locate("sometool", None if "not named" in name else str(project))
                    self.assertIsNotNone(found, "the one in the tools folder was not found")
                    self.assertTrue(os.path.samefile(found, wanted), found)
            os.environ["PATH"] = os.pathsep.join([str(project), str(base / "alias")])
            self.assertIsNone(module.locate("sometool", str(project)), "there is none outside the project")
        finally:
            os.environ["PATH"] = before
            os.chdir(here)


class PuttingBack(Case):
    def test_files_that_cannot_be_put_back_make_the_run_incomplete(self):
        """A write fails, and a file that this run made cannot be removed again. The report must
        say that the project is changed, also where no earlier version of a file was kept."""
        module = installer_module()
        for name, replaced in (("every file was new", False), ("a file was replaced", True)):
            with self.subTest(name):
                root = self.folder()
                installer = module.Installer(argparse.Namespace(project=str(root), dry_run=False, fix_gitignore=False))
                installer.changes = module.Changes(root)
                if replaced:
                    installer.changes.backups = self.folder("backups")
                installer.changes.undo = lambda: ["x.sh: Access is denied"]
                with self.assertRaises(module.Blocked) as raised:
                    installer.give_up("write-failed", "Could not write y.", "Free the file.")
                self.assertEqual(raised.exception.args, (False,), "not put back: the run is incomplete, not blocked")
                self.assertEqual(installer.report["blockers"], [])
                said = " ".join(installer.report["problems"])
                self.assertIn("x.sh: Access is denied", said)
                self.assertNotIn("None", said)
                self.assertEqual("earlier versions are in" in said, replaced)


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
        self.assertEqual(report["backups"], os.path.realpath(report["backups"]), "under the name that other programs find it by")
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
