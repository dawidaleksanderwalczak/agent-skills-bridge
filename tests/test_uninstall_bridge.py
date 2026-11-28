"""Tests for the uninstaller skill: the skill folder, and the uninstaller in throwaway projects.

Run:  python3 tests/test_uninstall_bridge.py          (Windows: py -3.11 tests\\test_uninstall_bridge.py)

Needs what tests/test_install_bridge.py needs, and that file next to this one: the projects here
get their kit from the real installer, and the helpers come from there. Most tests install the
kit, let the bridge make its copies, uninstall, and compare the project with what it was before
the installation, byte for byte. Every project is built under the temp folder and deleted
afterwards.
"""
import argparse
import ast
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # a test loads the uninstaller as a module: no __pycache__ in the skill folder
sys.path.insert(0, str(Path(__file__).resolve().parent))  # with -I, Python does not look next to the script

import test_install_bridge as base  # noqa: E402  (the path above comes first)

REPO = base.REPO
PLUGIN = base.PLUGIN
INSTALLING = base.SKILL
SKILL = PLUGIN / "skills" / "uninstalling-agent-skills-bridge"
UNINSTALLER = SKILL / "scripts" / "uninstall_bridge.py"
BY_HAND = SKILL / "references" / "removing-by-hand.md"

SH, PS1, DOC, SETTINGS, ATTRIBUTES, ANCHOR = base.SH, base.PS1, base.DOC, base.SETTINGS, base.ATTRIBUTES, base.ANCHOR
LOCAL = ".claude/settings.local.json"
OLD_TESTS = ".claude/hooks/agent-skills-bridge.test.sh"
WORKSHOP = ".claude/agent-skills-bridge-uninstall"
RECORDS = ".claude/skills/.agent-skills-bridge"
DEMO = ".agents/skills/demo/SKILL.md"
COPY = ".claude/skills/demo"
WINDOWS = base.WINDOWS
EXIT = {"uninstalled": 0, "not installed": 0, "would change": 0, "blocked": 1, "wrong arguments": 2, "incomplete": 3, "python too old": 4}

kit = base.kit
files_of = base.files_of
tool = base.tool


def setUpModule():
    base.setUpModule()


def tearDownModule():
    base.tearDownModule()


def uninstall(*flags, cwd=None, python=None, env=None, script=None):
    """Run the uninstaller the way the skill says. Returns (exit code, report, stderr)."""
    done = subprocess.run(
        [python or sys.executable, "-I", "-S", str(script or UNINSTALLER), *flags],
        cwd=cwd,
        env=env or base.ENV,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=300,
    )
    out = done.stdout.decode("utf-8")
    return done.returncode, json.loads(out) if out.strip() else None, done.stderr.decode("utf-8", "replace")


def uninstaller_module():
    """The uninstaller as a module, for the few functions that are tested by themselves."""
    spec = base.importlib.util.spec_from_file_location("uninstall_bridge", UNINSTALLER)
    module = base.importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def remove(path):
    """Delete a folder that holds read-only files, as every copy of the bridge does."""

    def writable(function, target, _):
        os.chmod(target, stat.S_IWRITE | stat.S_IREAD)
        function(target)

    shutil.rmtree(path, onerror=writable)


class Case(base.Case):
    def run_uninstaller(self, root, *flags, expect=0, **more):
        code, report, err = uninstall("--project", str(root), *flags, **more)
        self.assertEqual(code, expect, "exit code %s, report: %s\n%s" % (code, json.dumps(report, indent=1), err))
        self.assertEqual(err, "", "the uninstaller writes nothing to stderr")
        self.assertEqual(EXIT[report["outcome"]], code, "the outcome and the exit code say the same")
        self.assert_backups_are_the_tests_own(report)
        return report

    def sync(self, root, report):
        """Let the bridge make its copies, in the shell that Claude Code runs the hooks in."""
        shell = report["status_shell"]
        if "powershell" in Path(shell).name.lower():
            tool(shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(root / PS1), "sync", cwd=root)
        else:
            tool(shell, (root / SH).as_posix(), "sync", cwd=root)
        self.assertTrue((root / COPY / "SKILL.md").is_file(), "control: the bridge made the copy")
        self.assertTrue((root / RECORDS).is_dir(), "control: and put it on record")

    def skill(self, root, name="demo"):
        self.write(root, ".agents/skills/%s/SKILL.md" % name, "---\nname: %s\ndescription: Demo.\n---\n\nBody of %s.\n" % (name, name))

    def bridged(self, name="project", root=None):
        """A git repository with one skill, the kit installed and the copy made. Returns the
        project and its files as they were before the installation."""
        root = root or self.project(name)
        self.skill(root)
        before = files_of(root)
        self.sync(root, self.run_installer(root))
        return root, before

    def by_hand(self, root):
        """A project that has the kit's files and hook entries, put there without the installer."""
        for target in (SH, PS1, DOC, SETTINGS):
            self.write(root, target, kit(target))

    def assert_gone(self, root):
        """Nothing of the bridge is left: no hook entry, no file of the kit, no copy, no record."""
        for target in (SH, PS1, DOC, OLD_TESTS, WORKSHOP, RECORDS, COPY):
            self.assertFalse((root / target).exists(), target)
        for target in (SETTINGS, LOCAL):
            if (root / target).is_file():
                self.assertEqual(base.bridge_commands(json.loads((root / target).read_bytes().decode("utf-8-sig"))), [], target)

    def notes(self, report, said):
        found = [note for note in report["notes"] if said in note]
        self.assertTrue(found, "no note says %r: %s" % (said, report["notes"]))
        return found[0]

    def inside(self, root, prepare):
        """Run the uninstaller inside the test's own Python, for the few cases that must put
        something else in the place of a part of it: `prepare` gets the uninstaller before it runs.
        Returns (exit code, report)."""
        uninstaller = uninstaller_module().Uninstaller(argparse.Namespace(project=str(root), dry_run=False, restore_gitignore=False))
        prepare(uninstaller)
        saved, temp = dict(os.environ), tempfile.tempdir
        try:
            os.environ.clear()
            os.environ.update(base.ENV)
            tempfile.tempdir = None  # Python remembers the temp folder: it must ask again, or the backups land in the user's own
            code = uninstaller.uninstall()
        finally:
            os.environ.clear()
            os.environ.update(saved)
            tempfile.tempdir = temp
        self.assertEqual(EXIT[uninstaller.report["outcome"]], code, "the outcome and the exit code say the same")
        self.assert_backups_are_the_tests_own(uninstaller.report)
        return code, uninstaller.report

    def assert_backups_are_the_tests_own(self, report):
        """A test must leave nothing in the user's temp folder."""
        if report.get("backups"):
            self.assertTrue(Path(report["backups"]).is_relative_to(os.path.realpath(base.SCRATCH)), report["backups"])


def frontmatter(skill):
    """SKILL.md of a skill folder as (frontmatter fields, lines of the body)."""
    lines = (skill / "SKILL.md").read_text(encoding="utf-8").split("\n")
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


def code_of(path):
    """The functions, classes and methods of a Python file by name, each as its code without the
    documentation: what two files must have in common to do the same."""
    found = {}

    def bare(node):
        for part in ast.walk(node):
            body = getattr(part, "body", None)
            if isinstance(part, (ast.FunctionDef, ast.ClassDef)) and body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant):
                del body[0]
        return ast.dump(node)

    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.ClassDef):
            for part in node.body:
                if isinstance(part, ast.FunctionDef):
                    found["%s.%s" % (node.name, part.name)] = bare(part)
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            found[node.name] = bare(node)
    return found


class SkillFolder(unittest.TestCase):
    """The skill as a package: what the Agent Skills specification and Claude Code ask of it."""

    def test_frontmatter_follows_the_specification(self):
        fields, body = frontmatter(SKILL)
        name = fields["name"]
        self.assertEqual(name, SKILL.name, "the name must match the folder")
        self.assertRegex(name, base.NAME)
        self.assertLessEqual(len(name), 64)
        self.assertNotIn("claude", name)
        self.assertNotIn("anthropic", name)
        self.assertTrue(0 < len(fields["description"]) <= 1024, len(fields["description"]))
        self.assertNotRegex(fields["description"], r"[<>]")
        self.assertLessEqual(len(fields["compatibility"]), 500)
        self.assertLess(len(body), 500, "SKILL.md must stay under 500 lines")
        self.assertEqual(fields["license"], json.loads(base.MANIFEST.read_text(encoding="utf-8"))["license"])

    def test_description_says_what_and_when_and_draws_the_line(self):
        description = frontmatter(SKILL)[0]["description"]
        self.assertTrue(description.startswith("Uninstalls the agent-skills-bridge"), "what it does comes first: a listing may be cut short")
        self.assertIn("Use only when the user explicitly asks", description)
        for word in ("uninstall", "remove", "delete", "clean up"):
            self.assertIn(word, description, "a word that a user asks with")
        self.assertIn("Removal only: never commits", description)

    def test_descriptions_of_the_two_skills_tell_them_apart(self):
        """Both skills have the same subject and the same condition, so each description must say
        which of the two jobs it does, at its start, and name the other job as not its own."""
        removing, installing = frontmatter(SKILL)[0]["description"], frontmatter(INSTALLING)[0]["description"]
        self.assertTrue(removing.startswith("Uninstalls") and installing.startswith("Installs"))
        self.assertNotEqual(removing.split(".")[0], installing.split(".")[0])
        self.assertIn("does not install the bridge", removing)
        self.assertIn("does not remove the bridge", installing)

    def test_only_the_user_starts_it(self):
        fields, body = frontmatter(SKILL)
        self.assertEqual(fields["disable-model-invocation"], "true")
        self.assertIn("allow_implicit_invocation: false", (SKILL / "agents" / "openai.yaml").read_text(encoding="utf-8"))
        self.assertIn("## 0. Precondition", "\n".join(body))
        self.assertNotIn("allowed-tools", fields, "no tool is approved ahead of the user: each run of the uninstaller asks")

    def test_skill_names_its_script_and_no_windows_paths(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn('"<skill>/scripts/uninstall_bridge.py"', text)
        self.assertTrue(UNINSTALLER.is_file())
        self.assertNotIn("scripts\\", text)
        self.assertNotIn("references\\", text)

    def test_skill_tells_every_outcome_of_the_uninstaller(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        for outcome, code in EXIT.items():
            self.assertRegex(text, r"\| `%s` \| %d \|" % (outcome, code))
        self.assertIn("at most three times", text, "the loop of runs has an end")

    def test_references_are_one_level_deep_and_come_with_their_condition(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        named = sorted(set(base.re.findall(r"references/[\w.-]+\.md", text)))
        self.assertEqual(named, sorted("references/" + path.name for path in (SKILL / "references").iterdir()), "every reference is named, and every name leads to a file")
        self.assertIn("Read it only when", text.split("## Reference")[1])
        for reference in named:
            page = (SKILL / reference).read_text(encoding="utf-8")
            self.assertNotRegex(page, r"references/|\]\((?!https?:)[^)]*\.md", "a reference leads to no second page")
            self.assertLess(len(page.split("\n")), 100, "short enough to need no table of contents")

    def test_folder_holds_the_skill_and_nothing_else(self):
        expected = sorted(["SKILL.md", "agents/openai.yaml", "references/removing-by-hand.md", "scripts/uninstall_bridge.py"])
        self.assertEqual(base.files_in(SKILL), expected)

    def test_uninstaller_imports_the_standard_library_only(self):
        tree = ast.parse(UNINSTALLER.read_text(encoding="utf-8"))
        modules = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                modules.add(node.module.split(".")[0])
        self.assertLessEqual(modules, set(sys.stdlib_module_names))

    def test_source_reads_as_python_3_7(self):
        """An older Python must get as far as the version check, so the file keeps to old syntax."""
        ast.parse(UNINSTALLER.read_text(encoding="utf-8"), feature_version=(3, 7))

    def test_help_documents_the_exit_codes(self):
        done = subprocess.run([sys.executable, "-I", "-S", str(UNINSTALLER), "--help"], env=dict(base.ENV, FORCE_COLOR="1"), capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        out = done.stdout.decode("utf-8")
        self.assertEqual((done.returncode, done.stderr), (0, b""))
        for number, outcome in enumerate(("uninstalled", "blocked", "wrong arguments", "incomplete", "python too old")):
            self.assertRegex(out, r"%d\s+=\s+%s" % (number, outcome.replace(" ", r"\s+")))
        for option in ("--project", "--dry-run", "--restore-gitignore"):
            self.assertIn(option, out)
        self.assertNotIn("\x1b", out, "no colour codes, also where Python 3.14 is told to force them")

    def test_code_shared_with_the_installer_is_the_same(self):
        """Each skill's script is one file that stands alone, so the two hold the same code for
        finding a Python, finding and running a program, and printing the report. The installer's
        tests try that code out. This test holds the uninstaller to it."""
        mine, theirs = code_of(UNINSTALLER), code_of(base.INSTALLER)
        shared = ("named_project", "same_folder", "pythons_on_path", "version_of", "lf", "is_link", "locate", "Job", "run", "stop", "render", "Arguments")
        for name in shared:
            self.assertEqual(mine[name], theirs[name], name)
        self.assertEqual(mine["Uninstaller.hook_shell"], theirs["Installer.hook_shell"], "the shell that Claude Code runs the hooks in")

    def test_the_bridge_and_the_page_by_hand_are_where_the_uninstaller_looks(self):
        module = uninstaller_module()
        self.assertTrue(os.path.samefile(module.BY_HAND, BY_HAND))
        for name in module.BRIDGE_SCRIPTS.values():
            self.assertTrue((module.BRIDGE / name).is_file(), name)
        self.assertTrue(os.path.samefile(module.BRIDGE, base.KIT / "hooks"))

    def test_the_mark_of_a_copy_is_the_one_that_both_scripts_of_the_bridge_write(self):
        mark = uninstaller_module().COPY_MARK
        self.assertIn((mark % "$1").encode(), kit(SH))
        self.assertIn((mark % "$Name").encode(), kit(PS1))


class CommandLine(Case):
    """What the caller sees of a run: one JSON object on stdout, nothing on stderr, and an exit code
    that says the same as the report's outcome."""

    def test_wrong_arguments_come_as_a_report(self):
        root = self.folder()
        for name, flags, said in (
            ("an option that does not exist", ("--project", str(root), "--nope"), "--nope"),
            ("an option cut short", ("--proj", str(root)), "--proj"),
            ("an option of the installer", ("--project", str(root), "--fix-gitignore"), "--fix-gitignore"),
            ("a project that is no folder", ("--dry-run", "--project", str(root / "no such folder")), "is not a folder"),
            ("--project without a folder", ("--project",), "expected one argument"),
        ):
            with self.subTest(name):
                code, report, err = uninstall(*flags)
                self.assertEqual((code, err), (2, ""))
                self.assertEqual(report["outcome"], "wrong arguments")
                self.assertIn(said, report["message"])
                self.assertIn("--project FOLDER", report["usage"])
                self.assertEqual(files_of(root), {})

    def test_a_quote_that_powershell_left_in_the_path_is_explained(self):
        root, _ = self.bridged("my project")
        before = files_of(root)
        code, report, err = uninstall("--project", str(root) + '" --dry-run')
        self.assertEqual((code, err), (2, ""))
        self.assertIn("quotation mark", report["message"])
        self.assertEqual(files_of(root), before)

    def test_a_slash_at_the_end_of_the_project_is_accepted(self):
        root = self.folder("my project")
        code, report, err = uninstall("--project", str(root) + "/", "--dry-run")
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(os.path.samefile(report["project"], root))

    @unittest.skipUnless(WINDOWS, "Windows PowerShell 5.1 is the shell that turns a program's stderr into errors")
    def test_windows_powershell_with_stderr_redirected_sees_a_success(self):
        root, before = self.bridged()
        quoted = ["'%s'" % str(value).replace("'", "''") for value in (sys.executable, UNINSTALLER, root)]
        command = "$ErrorActionPreference = 'Stop'; & %s -I -S %s --project %s 2>&1; exit $LASTEXITCODE" % tuple(quoted)
        done = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command], env=base.ENV, capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        out = done.stdout.decode("utf-8", "replace") + done.stderr.decode("utf-8", "replace")
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("NativeCommandError", out)
        self.assertEqual(json.loads(done.stdout.decode("utf-8", "replace"))["outcome"], "uninstalled")
        self.assertEqual(files_of(root), before)


class OlderPython(Case):
    """python3 is older than 3.11 on many machines that have a newer Python under another name. The
    uninstaller looks for that one on PATH and goes on with it, as the installer does."""

    def start_older(self, *flags, path):
        old = base.older_python()
        if old is None and WINDOWS:
            self.skipTest("no Python older than 3.11 here, and no link to play one with")
        start = [old, "-I", "-S"] if old else [sys.executable, "-I", "-S", "-c", base.OlderPython.PLAYED]
        done = subprocess.run([*start, str(UNINSTALLER), *flags], env=dict(base.ENV, PATH=path), stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
        out = done.stdout.decode("utf-8")
        return done.returncode, json.loads(out) if out.strip() else None, done.stderr.decode("utf-8", "replace")

    def test_an_older_python_goes_on_with_a_newer_one_from_path(self):
        root, before = self.bridged()
        first = self.folder("first")
        if not WINDOWS:
            os.symlink(sys.executable, first / "python3.98")  # this Python under a name that a search finds
        path = os.pathsep.join([str(first), os.path.dirname(sys.executable), base.ENV["PATH"]])
        code, report, err = self.start_older("--project", str(root), path=path)
        self.assertEqual((code, err), (0, ""), report)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertRegex(self.notes(report, "started the uninstaller"), r"^Python 3\.\d+\.\d+ started the uninstaller, which needs Python 3\.11 or newer\. It went on with Python 3\.(1[1-9]|[2-9]\d)\.\d+ \(")
        self.assertEqual(files_of(root), before)

    def test_an_older_python_without_a_newer_one_says_so_and_changes_nothing(self):
        root, _ = self.bridged()
        installed = files_of(root)
        lonely = self.folder("lonely")
        self.program(lonely, "python3.99", b"not a program")
        code, report, err = self.start_older("--project", str(root), path=str(lonely))
        self.assertEqual((code, err), (4, ""), report)
        self.assertEqual(report["outcome"], "python too old")
        self.assertIn("The uninstaller needs Python 3.11 or newer", report["message"])
        self.assertEqual(len(report["looked_at"]), 1)
        self.assertIn(str(BY_HAND), report["fix"], "the way out without Python is a page that comes with the skill")
        self.assertEqual(files_of(root), installed)


class RoundTrip(Case):
    """Install, uninstall, and the project is what it was before, byte for byte."""

    def test_new_git_repository(self):
        root = self.project()
        self.run_installer(root)
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual(report["vcs"], ["git"])
        self.assertEqual(self.actions(report), {**{target: "delete" for target in base.KIT_FILES}, ".claude/hooks": "delete", ".claude/skills": "delete", ".claude": "delete"})
        self.assertEqual(files_of(root), {})
        self.assertFalse((root / ".claude").exists(), "the folders that the installer made are gone too")
        self.assertEqual(report["blockers"] + report["problems"] + report["notes"], [])
        self.assertNotIn("clean", report, "no session ran here, so the bridge had made no copy")
        self.assertEqual(self.git(root, "status", "--porcelain").strip(), "")
        self.assertFalse(any("git add" in step for step in report["next_steps"]), "nothing of the kit was committed")
        self.assertEqual(sorted(files_of(Path(report["backups"]))), sorted(base.KIT_FILES), "every file is kept outside the project as it was")
        self.assertEqual(report["backups"], os.path.realpath(report["backups"]))

    def test_second_run_finds_nothing_and_changes_nothing(self):
        root, before = self.bridged()
        self.run_uninstaller(root)
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "not installed")
        self.assertEqual((report["files"], report["notes"], report["next_steps"]), ([], [], []))
        self.assertNotIn("backups", report)
        self.assertEqual(files_of(root), before)

    def test_copies_and_records_go_and_the_skills_stay(self):
        root, before = self.bridged()
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual(self.actions(report)[".claude/skills"], "delete")
        self.assertIn("demo", [entry for entry in report["files"] if entry["action"] == "clean"][0]["why"])
        self.assertTrue(any("deleted the copies: demo" in line for line in report["clean"]), report["clean"])
        self.assertTrue(report["clean_shell"])
        self.assert_gone(root)
        self.assertEqual(files_of(root), before, "the skill in .agents/skills is all that is left, as it was")
        self.assertFalse((root / ".claude").exists())
        self.assertTrue(any(".agents/skills stay" in step for step in report["next_steps"]))
        session = [step for step in report["next_steps"] if "new Claude Code session" in step]
        self.assertEqual(len(session), 1)
        self.assertIn("do nothing", session[0], "the hooks of the kit of today look for the script first")
        self.assertNotIn("older kit", session[0])

    def test_folder_without_version_control(self):
        root = self.folder()
        self.skill(root)
        before = files_of(root)
        self.sync(root, self.run_installer(root))
        report = self.run_uninstaller(root)
        self.assertEqual((report["outcome"], report["vcs"]), ("uninstalled", []))
        self.assertEqual(files_of(root), before)
        self.assertFalse(any("checkout" in step for step in report["next_steps"]), "no version control, so no other checkout")

    def test_folder_name_with_a_space_and_a_letter_outside_ascii(self):
        root, before = self.bridged("my projéct")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual(files_of(root), before)

    def test_what_the_project_had_before_is_what_it_has_after(self):
        root = self.project()
        own = {
            SETTINGS: base.Settings.OWN.encode("utf-8"),
            LOCAL: b'{\n  "permissions": {"allow": ["Bash(ls)"]}\n}\n',
            ".claude/hooks/own-hook.sh": b"#!/bin/sh\r\n",
            ".claude/skills/mine/SKILL.md": b"---\nname: mine\n---\n",
            ANCHOR: b"*.bak\n",
            ".claude/commands/go.md": b"go",
            DEMO: b"---\nname: demo\ndescription: Demo.\n---\n",
        }
        for rel, content in own.items():
            self.write(root, rel, content)
        self.sync(root, self.run_installer(root))
        installed = files_of(root)
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        actions = self.actions(report)
        self.assertEqual(actions[SETTINGS], "edit")
        self.assertEqual(actions[ANCHOR], "keep")
        self.assertEqual(actions[ATTRIBUTES], "keep", "own-hook.sh needs the rule that keeps shell scripts LF")
        self.assertNotIn(".claude/hooks", actions, "a folder that holds something else stays")
        self.assertNotIn("layout changed", [entry for entry in report["files"] if entry["path"] == SETTINGS][0]["why"])
        self.assertEqual(files_of(root), {**own, ATTRIBUTES: kit(ATTRIBUTES)}, "CRLF, the indentation of four spaces and every own file are as they were")
        self.assertEqual((Path(report["backups"]) / SETTINGS).read_bytes(), installed[SETTINGS], "the settings with the hooks are kept outside the project")
        self.assert_gone(root)

    def test_byte_order_mark_tabs_and_letters_outside_ascii_come_back(self):
        root = self.project()
        own = b"\xef\xbb\xbf" + '{\n\t"env": {\n\t\t"NAME": "Zoë"\n\t}\n}'.encode("utf-8")
        self.write(root, SETTINGS, own)
        self.run_installer(root)
        self.run_uninstaller(root)
        self.assertEqual((root / SETTINGS).read_bytes(), own, "also the missing line end at the end of the file")

    def test_layout_that_no_writer_makes_is_said_to_change(self):
        root = self.project()
        self.write(root, SETTINGS, '{ "permissions": { "allow": ["Bash(ls)"] } }\n')
        self.run_installer(root)
        self.write(root, SETTINGS, (root / SETTINGS).read_text(encoding="utf-8").replace('"permissions": {\n    "allow": [\n      "Bash(ls)"\n    ]\n  }', '"permissions": { "allow": ["Bash(ls)"] }'))
        report = self.run_uninstaller(root)
        self.assertIn("layout changed", report["files"][0]["why"])
        self.assertEqual(json.loads((root / SETTINGS).read_bytes()), {"permissions": {"allow": ["Bash(ls)"]}})

    def test_settings_file_that_held_nothing_else_goes(self):
        root = self.project()
        self.write(root, SETTINGS, "")
        self.run_installer(root)
        report = self.run_uninstaller(root)
        self.assertEqual(self.actions(report)[SETTINGS], "delete")
        self.assertFalse((root / ".claude").exists())

    def test_hook_entries_of_an_older_kit_go_and_own_hooks_in_the_same_group_stay(self):
        root = self.project()
        old = "ASB_CMD=%s . \"$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh\" ; exit ; #' ; & \"$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1\" %s"
        settings = {
            "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "set \\' ; " + old % ("session", "session")}]}],
                "PreToolUse": [
                    {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "own-lint.sh"}, {"type": "command", "command": "set \\' ; " + old % ("guard", "guard")}]},
                ],
                "Stop": [],
            },
            "model": "sonnet",
        }
        self.write(root, SETTINGS, json.dumps(settings, indent=2) + "\n")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertIn("2 hook entries", report["files"][0]["why"])
        self.assertEqual(
            json.loads((root / SETTINGS).read_bytes()),
            {"hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "own-lint.sh"}]}], "Stop": []}, "model": "sonnet"},
            "the group keeps its own hook, the event that held nothing else goes, and an event that was empty before stays",
        )

    def test_hook_entries_in_the_local_settings_go_too(self):
        """The installer never writes that file, but a hook entry that outlives the script is not
        harmless: one of an older kit makes dash refuse every Write."""
        root, _ = self.bridged()
        local = {"hooks": {"PreToolUse": json.loads(kit(SETTINGS))["hooks"]["PreToolUse"]}}
        self.write(root, LOCAL, json.dumps(local, indent=2) + "\n")
        report = self.run_uninstaller(root)
        self.assertEqual(self.actions(report)[LOCAL], "edit")
        self.assertEqual((root / LOCAL).read_bytes(), b"{}\n", "a file of the user's own is emptied, not deleted")
        self.assert_gone(root)

    def test_a_name_outside_the_hooks_is_left_and_noted(self):
        root, _ = self.bridged()
        settings = json.loads((root / SETTINGS).read_bytes())
        settings["permissions"] = {"allow": ["Bash(sh .claude/hooks/agent-skills-bridge.sh status)"]}
        self.write(root, SETTINGS, json.dumps(settings, indent=2) + "\n")
        report = self.run_uninstaller(root)
        self.assertEqual(json.loads((root / SETTINGS).read_bytes()), {"permissions": settings["permissions"]})
        self.notes(report, "outside its hook entries")
        again = self.run_uninstaller(root)
        self.assertEqual(again["outcome"], "not installed")
        self.notes(again, "in no hook entry")

    def test_dry_run_changes_nothing(self):
        root, _ = self.bridged()
        installed = files_of(root)
        report = self.run_uninstaller(root, "--dry-run")
        self.assertEqual((report["outcome"], report["dry_run"]), ("would change", True))
        self.assertEqual(self.actions(report), {**{target: "delete" for target in base.KIT_FILES}, ".claude/skills": "delete", ".claude/hooks": "delete", ".claude": "delete"})
        self.assertEqual([entry["action"] for entry in report["files"] if entry["path"] == ".claude/skills"], ["clean", "delete"])
        self.assertEqual(files_of(root), installed)
        self.assertFalse((root / WORKSHOP).exists())
        for key in ("clean", "backups"):
            self.assertNotIn(key, report)
        self.assertEqual((report["notes"], report["next_steps"]), ([], []))
        empty = self.project("empty")
        self.assertEqual(self.run_uninstaller(empty, "--dry-run")["outcome"], "not installed")

    def test_without_project_the_top_of_the_git_repository_is_taken(self):
        root, before = self.bridged()
        deep = root / "src" / "deep"
        deep.mkdir(parents=True)
        code, report, _ = uninstall(cwd=deep)
        self.assertEqual((code, report["outcome"]), (0, "uninstalled"))
        self.assertTrue(os.path.samefile(report["project"], root))
        shutil.rmtree(root / "src")
        self.assertEqual(files_of(root), before)

    def test_a_named_subfolder_without_the_bridge_names_the_top_folder(self):
        root, _ = self.bridged()
        installed = files_of(root)
        package = root / "packages" / "app"
        package.mkdir(parents=True)
        report = self.run_uninstaller(package)
        self.assertEqual(report["outcome"], "not installed")
        self.notes(report, "run the uninstaller there")
        self.assertEqual(files_of(root), installed)

    def test_committed_kit_leaves_a_removal_to_commit(self):
        root = self.project()
        self.skill(root)
        self.git(root, "add", "-A")
        self.git(root, "commit", "-q", "-m", "skill")
        self.sync(root, self.run_installer(root))
        self.git(root, "add", "-A")
        self.git(root, "commit", "-q", "-m", "kit")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        status = sorted(line.split() for line in self.git(root, "status", "--porcelain").splitlines())
        self.assertEqual(status, sorted(["D", target] for target in base.KIT_FILES), "the copies were never in git, so only the kit shows")
        step = [step for step in report["next_steps"] if "git add" in step]
        self.assertEqual(len(step), 1, report["next_steps"])
        command = base.re.search(r"`(git add -u -- [^`]+)`", step[0]).group(1).split()
        self.assertEqual(sorted(command[4:]), sorted(base.KIT_FILES))
        self.git(root, *command[1:])
        self.git(root, "commit", "-q", "-m", "Remove agent-skills-bridge")
        self.assertEqual(self.git(root, "status", "--porcelain").strip(), "")
        self.assertEqual(self.git(root, "ls-files").split(), [DEMO])

    def test_commit_step_names_the_paths_from_the_projects_folder(self):
        """A project in a folder below the top of the repository. git status names a path from the
        top, and the command in the report is typed in the project's folder."""
        top = self.project()
        package = top / "packages" / "app"
        package.mkdir(parents=True)
        self.run_installer(package)
        self.git(top, "add", "-A")
        self.git(top, "commit", "-q", "-m", "kit")
        report = self.run_uninstaller(package)
        self.assertEqual(report["outcome"], "uninstalled")
        step = [step for step in report["next_steps"] if "git add" in step]
        self.assertEqual(len(step), 1, report["next_steps"])
        command = base.re.search(r"`(git add -u -- [^`]+)`", step[0]).group(1).split()
        self.assertEqual(sorted(command[4:]), sorted(base.KIT_FILES))
        tool(*command, cwd=package)
        staged = self.git(top, "status", "--porcelain").splitlines()
        self.assertEqual(sorted(staged), sorted("D  packages/app/" + target for target in base.KIT_FILES), "the command staged the whole removal, from the project's folder")

    def test_linked_worktree_is_told_about_the_main_checkout(self):
        root = self.project()
        self.git(root, "commit", "-q", "--allow-empty", "-m", "first")
        tree = root.parent / "tree"
        self.git(root, "worktree", "add", "-q", "-b", "side", str(tree))
        self.run_installer(tree)
        report = self.run_uninstaller(tree)
        self.assertTrue(any("linked git worktree" in step for step in report["next_steps"]))
        self.run_installer(root)
        self.assertFalse(any("linked git worktree" in step for step in self.run_uninstaller(root)["next_steps"]))

    def test_what_an_older_kit_and_a_stopped_run_left_goes_too(self):
        root, before = self.bridged()
        self.write(root, OLD_TESTS, "#!/bin/sh\n")
        self.write(root, WORKSHOP + "/clean.sh", "#!/bin/sh\n")
        report = self.run_uninstaller(root)
        self.assertEqual(self.actions(report)[OLD_TESTS], "delete")
        self.assertEqual(self.actions(report)[WORKSHOP], "delete")
        self.assertEqual(files_of(root), before)

    def test_the_kits_gitattributes_stays_for_a_script_of_the_projects_own(self):
        for name, own, action in (("a script in the folder", ".claude/hooks/own.sh", "keep"), ("a script further down", ".claude/hooks/lib/own.sh", "keep"), ("no shell script", ".claude/hooks/own.py", "delete")):
            with self.subTest(name):
                root = self.project()
                self.run_installer(root)
                self.write(root, own, "#!/bin/sh\n")
                report = self.run_uninstaller(root)
                self.assertEqual(self.actions(report)[ATTRIBUTES], action)
                self.assertEqual(sorted(files_of(root)), sorted([own] + ([ATTRIBUTES] if action == "keep" else [])))


class Leftovers(Case):
    """What is left of a bridge that was removed by halves, or by a pull."""

    def test_copies_without_the_kit_are_deleted(self):
        """A teammate's checkout after the pull that took the kit away: the copies are in no
        repository, so they are still there, and no script of the project is left to delete them."""
        root, before = self.bridged()
        for target in base.KIT_FILES:
            (root / target).unlink()
        (root / ".claude" / "hooks").rmdir()  # git takes a folder away with the last file that it tracked there
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual([(entry["path"], entry["action"]) for entry in report["files"]], [(".claude/skills", "clean"), (".claude/skills", "delete"), (".claude", "delete")])
        self.assertTrue(any("deleted the copies: demo" in line for line in report["clean"]))
        self.assertEqual(files_of(root), before)
        self.assertFalse((root / ".claude").exists())

    def test_hooks_without_scripts_and_scripts_without_hooks(self):
        for name, left in (("hooks", (SETTINGS,)), ("scripts", (SH, PS1, DOC))):
            with self.subTest(name):
                root = self.project()
                for target in left:
                    self.write(root, target, kit(target))
                report = self.run_uninstaller(root)
                self.assertEqual(report["outcome"], "uninstalled")
                self.assertEqual(files_of(root), {})

    def test_a_skill_that_took_the_place_of_a_copy_stays_and_is_named(self):
        root, _ = self.bridged()
        remove(root / COPY)
        mine = self.write(root, COPY + "/SKILL.md", "---\nname: demo\ndescription: Mine now.\n---\n")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertIn("Mine now.", mine.read_text(encoding="utf-8"))
        note = self.notes(report, "left .claude/skills/demo alone")
        self.assertIn("The bridge's clean command says", note)
        self.assertIn("the .gitignore that the bridge wrote is not in it", note)
        self.assertEqual([entry["action"] for entry in report["files"] if entry["path"] == ".claude/skills"], ["clean"], "the folder was never planned to go: it holds a skill")
        self.assertFalse((root / RECORDS).exists())
        self.assertFalse((root / ".claude/hooks").exists())

    def test_a_copy_that_the_bridge_leaves_alone_keeps_its_folder(self):
        """The copy's skill is gone from .agents/skills and its SKILL.md was changed: that text is
        nowhere else, so the bridge deletes nothing. The folder looked like a copy when the removal
        was planned, and the report must say that it stayed after all."""
        root, _ = self.bridged()
        remove(root / ".agents" / "skills" / "demo")
        changed = root / COPY / "SKILL.md"
        os.chmod(changed, stat.S_IWRITE | stat.S_IREAD)
        changed.write_text("---\nname: demo\ndescription: Changed here, and nowhere else.\n---\n", encoding="utf-8")
        later = changed.stat().st_mtime + 5  # newer than the copy's .gitignore, whatever the clock's step is
        os.utime(changed, (later, later))
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertIn("Changed here", changed.read_text(encoding="utf-8"))
        self.assertIn("its SKILL.md is not the one that the bridge copied", self.notes(report, "left .claude/skills/demo alone"))
        folder = [entry for entry in report["files"] if entry["path"] == ".claude/skills"]
        self.assertEqual([entry["action"] for entry in folder], ["clean", "keep"])
        self.assertIn("it still holds demo", folder[1]["why"])
        self.assertEqual(self.actions(report)[".claude"], "keep")
        self.assertFalse((root / RECORDS).exists())
        self.assert_kit_gone_but(root, COPY)

    def assert_kit_gone_but(self, root, stays):
        for target in (SH, PS1, DOC, SETTINGS, ATTRIBUTES, ANCHOR, WORKSHOP, RECORDS):
            self.assertFalse((root / target).exists(), target)
        self.assertTrue((root / stays).is_dir())

    def test_a_marked_folder_that_no_record_names_stays_and_is_named(self):
        root, _ = self.bridged()
        remove(root / RECORDS)
        dry = self.run_uninstaller(root, "--dry-run")
        self.notes(dry, "holds the .gitignore of a copy")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertNotIn("clean", report, "without records the bridge's clean command has nothing to go by")
        self.assertIn("delete the folder", self.notes(report, ".claude/skills/demo holds the .gitignore of a copy"))
        self.assertTrue((root / COPY / "SKILL.md").is_file())
        again = self.run_uninstaller(root)
        self.assertEqual(again["outcome"], "not installed")
        self.notes(again, "holds the .gitignore of a copy")

    def test_skills_folder_that_is_a_link_is_left_alone(self):
        root = self.project()
        self.skill(root)
        self.by_hand(root)
        self.link(root / ".claude" / "skills", root / ".agents" / "skills")
        before = files_of(root / ".agents")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.notes(report, ".claude/skills is a link")
        self.assertTrue(base.installer_module().is_link(root / ".claude" / "skills"))
        self.assertEqual(files_of(root / ".agents"), before)
        self.assertFalse((root / ".claude/hooks").exists())


class ProjectIsInput(Case):
    """The uninstaller starts no program that the project holds."""

    def test_the_projects_own_scripts_are_never_started(self):
        root, before = self.bridged()
        marker = root.parent / "ran"
        self.write(root, SH, "#!/bin/sh\n: > '%s'\n" % marker.as_posix())
        self.write(root, PS1, "Set-Content -LiteralPath '%s' -Value ran\n" % marker)
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertFalse(marker.exists(), "a script of the project was started")
        self.assertTrue(any("deleted the copies: demo" in line for line in report["clean"]), "the copies went all the same")
        self.assertEqual(files_of(root), before)

    def test_programs_in_the_project_are_not_started_however_path_names_it(self):
        """The bridge asks git about a copy that holds a file which it did not put there. A git
        that lies in the project must not be the one that answers."""
        root, _ = self.bridged()
        self.git(root, "add", "-A")
        self.git(root, "commit", "-q", "-m", "kit")
        marker = root.parent / "ran"
        self.write(root, COPY + "/extra.txt", "not the bridge's")
        for name in ("git", "svn", "rm", "find"):
            planted = self.write(root, name, "#!/bin/sh\n: > '%s'\n" % marker.as_posix())
            os.chmod(planted, 0o755)
            self.write(root, name + ".cmd", '@echo ran> "%s"\r\n' % marker)
        path = os.pathsep.join([str(root), os.curdir, "", base.ENV["PATH"]])
        report = self.run_uninstaller(root, env=dict(base.ENV, PATH=path), cwd=root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertFalse(marker.exists(), "a program of the project was started")
        self.assertEqual(report["vcs"], ["git"], "the git that PATH has further on was found")
        self.assertFalse((root / COPY).exists())

    def test_path_for_the_bridge_names_no_folder_of_the_project(self):
        module = uninstaller_module()
        base_folder = self.folder("path")
        project, tools = base_folder / "project", base_folder / "tools"
        for folder in (project, tools):
            folder.mkdir()
        self.link(base_folder / "alias", project)
        uninstaller = module.Uninstaller(argparse.Namespace(project=str(project), dry_run=True, restore_gitignore=False))
        uninstaller.root = project
        before = dict(os.environ)
        try:
            os.environ["PATH"] = os.pathsep.join([str(project), "", os.curdir, "relative", str(base_folder / "alias"), '"%s"' % tools if WINDOWS else str(tools)])
            os.environ["ASB_CMD"] = "session"
            environment = uninstaller.environment()
        finally:
            os.environ.clear()
            os.environ.update(before)
        self.assertEqual(environment["PATH"], str(tools))
        self.assertNotIn("ASB_CMD", environment, "the run must not pass for a hook's")


class Blockers(Case):
    def test_settings_that_cannot_be_read_and_name_the_bridge_block(self):
        hooks = kit(SETTINGS).decode("utf-8")
        for name, content in (
            ("a comment", hooks.replace("{", "{\n  // mine", 1)),
            ("a key twice", hooks.replace('"hooks": {', '"model": "a", "model": "b", "hooks": {', 1)),
            ("not UTF-8", hooks.encode("utf-8").replace(b"{", b'{"model": "\xff",', 1)),
        ):
            with self.subTest(name):
                root, _ = self.bridged()
                self.write(root, SETTINGS, content)
                installed = files_of(root)
                report = self.run_uninstaller(root, expect=1)
                blocker = self.blocker(report, "settings-unreadable")
                self.assertEqual(blocker["path"], SETTINGS)
                self.assertIn("by hand", blocker["fix"])
                self.assertEqual(files_of(root), installed, "not even the copies were touched")

    def test_settings_that_cannot_be_read_and_do_not_name_the_bridge_are_left(self):
        root, _ = self.bridged()
        broken = b'{\n  // mine\n  "model": "sonnet"\n}\n'
        self.write(root, SETTINGS, broken)
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual((root / SETTINGS).read_bytes(), broken)
        self.assertNotIn(SETTINGS, self.actions(report))

    def test_claude_folder_that_is_a_link_blocks(self):
        root = self.project()
        elsewhere = root.parent / "shared"
        for target in (SH, SETTINGS):
            self.write(elsewhere, target[len(".claude/") :], kit(target))
        self.link(root / ".claude", elsewhere)
        before = files_of(elsewhere)
        report = self.run_uninstaller(root, expect=1)
        blocker = self.blocker(report, "folder-is-link")
        self.assertEqual(blocker["path"], ".claude")
        self.assertIn(str(BY_HAND), blocker["fix"])
        self.assertEqual(files_of(elsewhere), before)

    def test_a_link_without_the_bridge_behind_it_is_no_blocker(self):
        root = self.project()
        elsewhere = root.parent / "shared"
        self.write(elsewhere, "settings.json", '{\n  "model": "sonnet"\n}\n')
        self.link(root / ".claude", elsewhere)
        self.assertEqual(self.run_uninstaller(root)["outcome"], "not installed")

    def test_a_settings_file_that_is_a_link_blocks(self):
        root = self.project()
        elsewhere = self.write(root.parent, "shared-settings.json", kit(SETTINGS))
        (root / ".claude").mkdir()
        try:
            os.symlink(elsewhere, root / SETTINGS)
        except OSError:
            self.skipTest("this system lets a test make no link to a file")
        report = self.run_uninstaller(root, expect=1)
        self.assertEqual(self.blocker(report, "file-is-link")["path"], SETTINGS)
        self.assertEqual(elsewhere.read_bytes(), kit(SETTINGS))

    def test_a_script_that_is_a_link_is_unlinked_and_its_target_stays(self):
        root = self.project()
        elsewhere = self.write(root.parent, "shared.sh", kit(SH))
        (root / ".claude" / "hooks").mkdir(parents=True)
        try:
            os.symlink(elsewhere, root / SH)
        except OSError:
            self.skipTest("this system lets a test make no link to a file")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertIn("the link goes", report["files"][0]["why"])
        self.assertFalse((root / ".claude").exists())
        self.assertEqual(elsewhere.read_bytes(), kit(SH))

    def test_a_file_that_cannot_be_changed_puts_everything_back(self):
        root, _ = self.bridged()
        if WINDOWS:
            os.chmod(root / SETTINGS, stat.S_IREAD)
            self.addCleanup(os.chmod, root / SETTINGS, stat.S_IWRITE | stat.S_IREAD)
        else:
            if os.geteuid() == 0:
                self.skipTest("root may write everywhere")
            os.chmod(root / ".claude", 0o555)
            self.addCleanup(os.chmod, root / ".claude", 0o755)
        installed = files_of(root)
        report = self.run_uninstaller(root, expect=1)
        self.assertIn("Everything was put back", self.blocker(report, "write-failed")["message"])
        self.assertEqual(report["problems"], [])
        self.assertEqual(files_of(root), installed)
        self.assertNotIn("clean", report, "the bridge's clean command ran only once the files were changed")

    def test_a_clean_that_fails_puts_everything_back_and_a_second_run_succeeds(self):
        """A sync that is running holds the bridge's lock, and clean gives up after a quarter of a
        minute. The kit's files and hook entries are there again then, so the bridge still works."""
        root, before = self.bridged()
        lock = root / RECORDS / "lock"
        lock.mkdir()
        installed = files_of(root)
        report = self.run_uninstaller(root, expect=1)
        blocker = self.blocker(report, "clean-failed")
        self.assertIn("another sync is running", blocker["message"])
        self.assertIn("put back", blocker["message"])
        self.assertEqual(report["problems"], [])
        self.assertEqual(files_of(root), installed)
        self.assertFalse((root / WORKSHOP).exists(), "the script for the one run is gone again")
        self.assert_kit_installed(root)
        lock.rmdir()
        self.assertEqual(self.run_uninstaller(root)["outcome"], "uninstalled")
        self.assertEqual(files_of(root), before)

    def test_without_the_installing_skill_copies_block_and_a_project_without_copies_does_not(self):
        alone = self.folder("alone") / SKILL.name
        shutil.copytree(SKILL, alone)
        script = alone / "scripts" / "uninstall_bridge.py"
        root, _ = self.bridged()
        installed = files_of(root)
        code, report, err = uninstall("--project", str(root), script=script)
        self.assertEqual((code, err), (1, ""))
        blocker = self.blocker(report, "bridge-script-missing")
        self.assertIn("agent-skills-bridge.sh", blocker["message"])
        self.assertIn("removing-by-hand.md", blocker["fix"])
        self.assertEqual(files_of(root), installed)
        fresh = self.project("fresh")
        self.run_installer(fresh)
        code, report, err = uninstall("--project", str(fresh), script=script)
        self.assertEqual((code, err, report["outcome"]), (0, "", "uninstalled"))
        self.assertEqual(files_of(fresh), {})


class Gitignore(Case):
    """The rule that the installer rewrote in the project's .gitignore, once the user agreed: the
    uninstaller offers to put it back, and does so once the user agreed again."""

    RULES = b"node_modules/\r\n.claude/\r\n*.log\r\n"
    FIXED = b"node_modules/\r\n**/.claude/*\r\n!/.claude/settings.json\r\n!/.claude/hooks/\r\n!/.claude/skills/\r\n*.log\r\n"

    def fixed(self):
        root = self.project()
        self.write(root, ".gitignore", self.RULES)
        self.run_installer(root, "--fix-gitignore")
        self.assertEqual((root / ".gitignore").read_bytes(), self.FIXED, "control: the installer rewrote the rule")
        return root

    def test_the_rule_is_offered_and_put_back_only_with_the_flag(self):
        root = self.fixed()
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual([offer["id"] for offer in report["offers"]], ["restore-gitignore"])
        offer = report["offers"][0]
        self.assertEqual(offer["rerun_with"], "--restore-gitignore")
        self.assertIn("the user's consent", offer["message"])
        self.assertIn("line 2", offer["message"])
        self.assertEqual(files_of(root), {".gitignore": self.FIXED}, "without the flag the file is as it was")

        dry = self.run_uninstaller(root, "--dry-run")
        self.assertEqual((dry["outcome"], len(dry["offers"])), ("not installed", 1))

        report = self.run_uninstaller(root, "--restore-gitignore")
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual(self.actions(report), {".gitignore": "edit"})
        self.assertNotIn("offers", report)
        self.assertEqual(files_of(root), {".gitignore": self.RULES})
        self.assertEqual((Path(report["backups"]) / ".gitignore").read_bytes(), self.FIXED)
        again = self.run_uninstaller(root, "--restore-gitignore")
        self.assertEqual((again["outcome"], again["files"]), ("not installed", []))

    def test_removal_and_rule_in_one_run(self):
        root = self.fixed()
        report = self.run_uninstaller(root, "--restore-gitignore")
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertNotIn("offers", report)
        self.assertEqual(files_of(root), {".gitignore": self.RULES})

    def test_rule_with_a_leading_slash_and_a_block_at_the_end_of_the_file(self):
        root = self.project()
        self.write(root, ".gitignore", b"*.log\n/.claude/*\n!/.claude/settings.json\n!/.claude/hooks/\n!/.claude/skills/")
        self.run_uninstaller(root, "--restore-gitignore")
        self.assertEqual((root / ".gitignore").read_bytes(), b"*.log\n/.claude/", "the file had no last line end, and has none now")

    def test_lines_that_are_not_the_installers_are_no_offer_and_the_flag_edits_nothing(self):
        for name, rules in (
            ("the rule that the kit's page shows for doing it by hand", b".claude/*\n!.claude/settings.json\n!.claude/hooks/\n!.claude/skills/\n"),
            ("another order", b"**/.claude/*\n!/.claude/hooks/\n!/.claude/settings.json\n!/.claude/skills/\n"),
            ("one line missing", b"**/.claude/*\n!/.claude/settings.json\n!/.claude/hooks/\n"),
        ):
            with self.subTest(name):
                root = self.project()
                self.write(root, ".gitignore", rules)
                self.assertNotIn("offers", self.run_uninstaller(root))
                report = self.run_uninstaller(root, "--restore-gitignore")
                self.assertEqual(report["outcome"], "not installed")
                self.assertEqual((root / ".gitignore").read_bytes(), rules)


@unittest.skipUnless(shutil.which("svn") and shutil.which("svnadmin"), "no svn and svnadmin here")
class Subversion(Case):
    def working_copy(self):
        folder = self.folder("svn")
        tool("svnadmin", "create", str(folder / "repo"))
        tool("svn", "checkout", "-q", "--non-interactive", (folder / "repo").as_uri(), str(folder / "wc"))
        return folder / "wc"

    def svn(self, root, *arguments):
        return tool("svn", "--non-interactive", *arguments, cwd=root)

    def status(self, root):
        found = {}
        for line in self.svn(root, "status").splitlines():
            found[line[8:].strip().replace("\\", "/")] = line[:2].strip()
        return found

    def test_kit_that_was_never_committed_leaves_no_trace_in_svn(self):
        """Without a session, .claude/skills holds nothing at all in svn: git gets the anchor
        there, svn only the property. The folder is the installer's all the same, and goes."""
        for name, session in (("a session made the copies", True), ("no session ran yet", False)):
            with self.subTest(name):
                root = self.working_copy()
                self.skill(root)
                self.svn(root, "add", "-q", ".agents")
                self.svn(root, "commit", "-q", "-m", "skill")
                before = files_of(root)
                installed = self.run_installer(root)
                if session:
                    self.sync(root, installed)
                else:
                    self.assertEqual(os.listdir(root / ".claude" / "skills"), [], "control: the folder is empty")
                report = self.run_uninstaller(root)
                self.assertEqual((report["outcome"], report["vcs"]), ("uninstalled", ["svn"]))
                self.assertEqual(self.status(root), {}, "what the installer scheduled is scheduled no more")
                self.assertEqual(files_of(root), before)
                self.assertFalse((root / ".claude").exists())
                self.assertEqual(len(report["vcs_steps"]), 4, report["vcs_steps"])
                self.assertTrue(any("svn status" in step for step in report["next_steps"]))
                self.assertEqual(self.run_uninstaller(root)["outcome"], "not installed")

    def test_an_empty_skills_folder_without_the_bridges_rule_is_nobodys_and_stays(self):
        root = self.working_copy()
        self.svn(root, "mkdir", "-q", "--parents", ".claude/skills")
        self.svn(root, "commit", "-q", "-m", "folder")
        for target in (SH, SETTINGS):
            self.write(root, target, kit(target))
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertTrue((root / ".claude" / "skills").is_dir())
        self.assertEqual(self.status(root), {})

    def test_committed_kit_is_scheduled_for_deletion_and_commits(self):
        root = self.working_copy()
        self.skill(root)
        self.svn(root, "add", "-q", ".agents")
        self.sync(root, self.run_installer(root))
        self.svn(root, "commit", "-q", "-m", "kit")
        self.svn(root, "update", "-q")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertEqual(self.status(root), {".claude": "D"}, "svn names the folder that goes, and with it all that it held")
        deleted = [line.split()[-1].replace("\\", "/") for line in self.svn(root, "status", "-v").splitlines() if line.startswith("D")]
        self.assertEqual(sorted(deleted), sorted([".claude", ".claude/hooks", ".claude/skills", SETTINGS, SH, PS1, DOC]))
        self.assertFalse((root / ".claude").exists())
        self.svn(root, "commit", "-q", "-m", "Remove agent-skills-bridge")
        self.svn(root, "update", "-q")
        self.assertEqual(self.status(root), {})
        self.assertEqual(sorted(files_of(root)), [DEMO])

    def test_skills_folder_that_stays_loses_the_bridges_ignore_rule(self):
        root = self.working_copy()
        self.skill(root)
        self.write(root, ".claude/skills/mine/SKILL.md", "---\nname: mine\n---\n")
        self.svn(root, "add", "-q", "--parents", ".claude/skills/mine")
        self.sync(root, self.run_installer(root))
        self.svn(root, "commit", "-q", "-m", "kit")
        self.assertEqual(self.svn(root, "propget", "svn:ignore", ".claude/skills").split(), ["*"], "control")
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        self.assertIn("svn propdel svn:ignore .claude/skills", report["vcs_steps"])
        self.assertEqual(tool("svn", "--non-interactive", "propget", "svn:ignore", ".claude/skills", cwd=root, check=False).split(), [], "svn has no such property there any more")
        self.assertTrue((root / ".claude/skills/mine/SKILL.md").is_file())
        self.assertEqual(self.status(root).get(".claude/skills"), "M", "the folder stays, with its property changed")
        self.assertFalse((root / COPY).exists())

    def test_ignore_rules_of_the_projects_own_stay_and_the_star_is_named(self):
        root = self.working_copy()
        self.write(root, ".claude/skills/mine/SKILL.md", "---\nname: mine\n---\n")
        self.svn(root, "add", "-q", "--parents", ".claude/skills/mine")
        value = self.write(root.parent, "value.txt", "*.tmp\n")
        self.svn(root, "propset", "-q", "svn:ignore", "-F", str(value), ".claude/skills")
        self.run_installer(root)
        report = self.run_uninstaller(root)
        self.assertEqual(self.svn(root, "propget", "svn:ignore", ".claude/skills").split(), ["*.tmp", "*"])
        self.assertIn("*.tmp", self.notes(report, "svn:ignore on .claude/skills holds the rule *"))

    def test_dry_run_names_the_svn_steps_and_takes_none(self):
        root = self.working_copy()
        self.skill(root)
        self.sync(root, self.run_installer(root))
        installed, scheduled = files_of(root), self.status(root)
        report = self.run_uninstaller(root, "--dry-run")
        self.assertEqual(report["outcome"], "would change")
        self.assertEqual(len(report["vcs_steps"]), 4, report["vcs_steps"])
        self.assertTrue(all(step.startswith("svn delete --force -- ") for step in report["vcs_steps"]))
        self.assertEqual((files_of(root), self.status(root)), (installed, scheduled))

    def test_a_step_that_svn_refuses_makes_the_run_incomplete(self):
        """The files are gone by then, so the run is not blocked: the report must say that the
        project is changed, name what svn said, and claim no folder that is still there."""
        root = self.working_copy()
        self.run_installer(root)
        self.svn(root, "commit", "-q", "-m", "kit")

        def locked(uninstaller):
            ask = uninstaller.svn_ask
            uninstaller.svn_ask = lambda *arguments: (1, "", "svn: E155004: working copy locked") if arguments[0] == "delete" else ask(*arguments)

        code, report = self.inside(root, locked)
        self.assertEqual((code, report["outcome"]), (3, "incomplete"), report)
        self.assertIn("working copy locked", " ".join(report["problems"]))
        self.assertIn("svn delete --force", " ".join(report["problems"]))
        self.assertNotIn("vcs_steps", report, "no step is named that svn did not take")
        folders = {entry["path"]: entry["action"] for entry in report["files"] if entry["path"] in (".claude", ".claude/hooks", ".claude/skills")}
        self.assertEqual(folders, {".claude": "keep", ".claude/hooks": "keep", ".claude/skills": "keep"})
        self.assertTrue((root / ".claude" / "hooks").is_dir())
        self.assertEqual(self.status(root).get(SH), "!", "svn still waits to be told about the script that is gone")


class SessionThatWasRunning(Case):
    """A session that started before the removal still holds the bridge's hooks. They must do
    nothing now: a guard that failed would refuse every Write of that session."""

    def hook(self, argv, root, event):
        done = subprocess.run(argv, cwd=root, env=dict(base.ENV, CLAUDE_PROJECT_DIR=str(root)), input=json.dumps(event).encode(), capture_output=True, timeout=300)
        return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")

    def check(self, shell):
        root, before = self.bridged()
        commands = {event: [hook["command"] for group in groups for hook in group["hooks"]] for event, groups in base.KIT_HOOKS.items()}
        self.run_uninstaller(root)
        code, out, _ = self.hook([*shell, commands["SessionStart"][0]], root, {"hook_event_name": "SessionStart"})
        self.assertEqual((code, out), (0, ""))
        for command in commands["PreToolUse"]:
            code, _, _ = self.hook([*shell, command], root, {"tool_name": "Write", "tool_input": {"file_path": str(root / COPY / "SKILL.md")}})
            self.assertEqual(code, 0, "the guard of a bridge that is gone refuses nothing")
        self.assertEqual(files_of(root), before, "and no hook made the copies again")

    def test_its_hooks_do_nothing_in_the_shell_that_claude_code_uses(self):
        kind, shell = uninstaller_module().Uninstaller(argparse.Namespace(project=None, dry_run=True, restore_gitignore=False)).hook_shell()
        if kind != "sh":
            self.skipTest("no POSIX shell here: the PowerShell case covers this machine")
        self.check([shell, "-c"])

    @unittest.skipUnless(WINDOWS, "Windows PowerShell is the hook shell only on Windows without Git Bash")
    def test_its_hooks_do_nothing_in_windows_powershell(self):
        self.check(["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"])

    def test_hook_entries_of_an_older_kit_fail_without_the_script_and_the_report_says_so(self):
        """An entry of an older kit starts the script without looking for it first. Once the script
        is gone it fails, and dash ends with status 2 then, which Claude Code reads as the guard's
        refusal of every Write. The removal cannot change what a running session holds, so the
        report puts the new session first."""
        root = self.project()
        looks_first = 'test -r "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh" || exit 0 ; '
        older = json.loads(kit(SETTINGS))
        for groups in older["hooks"].values():
            for group in groups:
                for hook in group["hooks"]:
                    self.assertIn(looks_first, hook["command"], "control: the kit of today looks first")
                    hook["command"] = hook["command"].replace(looks_first, "")
        self.write(root, SETTINGS, json.dumps(older, indent=2) + "\n")
        self.write(root, SH, kit(SH))
        report = self.run_uninstaller(root)
        self.assertEqual(report["outcome"], "uninstalled")
        sessions = [step for step in report["next_steps"] if "new Claude Code session" in step]
        self.assertEqual(len(sessions), 1)
        self.assertEqual(report["next_steps"][0], sessions[0], "this step comes first")
        self.assertIn("before anything else", sessions[0])
        self.assertIn("older kit", sessions[0])
        self.assertIn("refuses every Write", sessions[0])
        kind, shell = uninstaller_module().Uninstaller(argparse.Namespace(project=None, dry_run=True, restore_gitignore=False)).hook_shell()
        if kind == "sh":
            guard = older["hooks"]["PreToolUse"][1]["hooks"][0]["command"]
            code, _, _ = self.hook([shell, "-c", guard], root, {"tool_name": "Write", "tool_input": {"file_path": str(root / "README.md")}})
            self.assertNotEqual(code, 0, "control: the older entry does fail without its script")


@unittest.skipUnless(WINDOWS, "Windows PowerShell is the hook shell only on Windows without Git Bash")
class WithoutGitBash(Case):
    def test_the_copies_are_deleted_by_the_powershell_twin(self):
        """On Windows without Git Bash, Claude Code runs the hooks in PowerShell, and so does the
        uninstaller the bridge's clean command. This machine has Git Bash, so the uninstaller is
        told here which shell it found."""
        root, before = self.bridged()
        powershell = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"

        def no_git_bash(uninstaller):
            uninstaller.hook_shell = lambda: ("powershell", str(powershell))

        code, report = self.inside(root, no_git_bash)
        self.assertEqual((code, report["outcome"]), (0, "uninstalled"), report)
        self.assertEqual(report["clean_shell"], str(powershell))
        self.assertTrue(any("deleted the copies: demo" in line for line in report["clean"]), report["clean"])
        self.assertEqual(files_of(root), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
