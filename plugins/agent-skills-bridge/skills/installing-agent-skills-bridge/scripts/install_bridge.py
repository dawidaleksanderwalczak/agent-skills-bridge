#!/usr/bin/env python3
"""Install or update the agent-skills-bridge kit in a project. Standard library only.

The kit makes Claude Code load the Agent Skills that a project keeps in .agents/skills. This script
copies the kit's files from ../assets/kit to the project's .claude folder, adds the kit's hooks to
.claude/settings.json next to the hooks that are already there, sets what git or svn needs, and
then checks its own work. It never commits, never prompts and never writes through a link.
"""
import sys

if sys.version_info < (3, 11):
    sys.stderr.write(
        "error: this installer needs Python 3.11 or newer, and this is Python %d.%d. "
        "Start it with another interpreter: python3, python or py -3.\n" % sys.version_info[:2]
    )
    sys.exit(4)

import argparse
import copy
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path

EXIT_OK = 0  # installed or already current, and verified
EXIT_BLOCKED = 1  # something is in the way: nothing in the project was changed
EXIT_USAGE = 2  # wrong arguments (argparse uses this code)
EXIT_INCOMPLETE = 3  # the project was changed, but a later step failed
EXIT_PYTHON = 4  # this interpreter is older than Python 3.11

EXIT_CODES = (
    "Exit codes: 0 = installed or already current, and verified. "
    "1 = blocked: nothing in the project was changed; the report's 'blockers' say why. "
    "2 = wrong arguments. "
    "3 = the project was changed, but a later step failed; the report's 'problems' say which. "
    "4 = this interpreter is older than Python 3.11."
)

KIT = Path(__file__).resolve().parent.parent / "assets" / "kit"

# The kit's own files: (file under assets/kit, file in the project). The installer creates them and
# replaces them when their text differs from the kit's.
OWNED = (
    ("hooks/agent-skills-bridge.sh", ".claude/hooks/agent-skills-bridge.sh"),
    ("hooks/agent-skills-bridge.ps1", ".claude/hooks/agent-skills-bridge.ps1"),
    ("hooks/agent-skills-bridge.md", ".claude/hooks/agent-skills-bridge.md"),
)
# Files that the project may already have. The installer never replaces one of them.
SETTINGS = ("settings.json", ".claude/settings.json")
GITATTRIBUTES = ("hooks/.gitattributes", ".claude/hooks/.gitattributes")
ANCHOR = ("skills/.gitignore", ".claude/skills/.gitignore")
SCRIPT = ".claude/hooks/agent-skills-bridge.sh"
SCRIPT_PS1 = ".claude/hooks/agent-skills-bridge.ps1"
SKILLS = ".claude/skills"
FOLDERS = (".claude", ".claude/hooks", SKILLS)

EOL_RULE = b"*.sh text eol=lf"  # the line that keeps the shell script LF in every git checkout
BRIDGE_MARK = "agent-skills-bridge."  # every hook command of the kit names one of its scripts
IGNORE_FLAG = "--fix-gitignore"
# The spellings of a rule that ignores the whole .claude folder, which the installer can rewrite.
WHOLE_FOLDER_RULES = (".claude", ".claude/", "/.claude", "/.claude/")

# git and svn answer a local question within a second. A minute covers a network drive and the
# security software that makes every process start slow on some Windows machines.
TOOL_TIMEOUT = 60
# The bridge's status command starts a few dozen processes. Claude Code gives the session hook the
# same 120 seconds (see "timeout" in the kit's settings.json).
STATUS_TIMEOUT = 120


def lf(data):
    """The bytes with LF line ends. The kit's files are compared and written that way."""
    return data.replace(b"\r\n", b"\n")


def is_link(path):
    """True for a symbolic link and for a Windows junction. A OneDrive placeholder is neither."""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode):
        return True
    links = (getattr(stat, "IO_REPARSE_TAG_SYMLINK", 0xA000000C), getattr(stat, "IO_REPARSE_TAG_MOUNT_POINT", 0xA0000003))
    return getattr(info, "st_reparse_tag", 0) in links


def locate(name, project=None):
    """Absolute path of a program on PATH. A copy that lies in the working directory or in the
    project's top folder is never accepted: the project is input, and on Windows a bare name is
    looked up in the working directory first."""
    found = shutil.which(name)
    if found is None:
        return None
    found = os.path.abspath(found)
    home = os.path.normcase(os.path.dirname(found))
    for folder in (os.getcwd(), project):
        if folder is not None and home == os.path.normcase(os.path.abspath(folder)):
            return None
    return found


def run(argv, cwd, timeout=TOOL_TIMEOUT, env=None, feed=None):
    """Run a program that cannot prompt: its input is `feed`, or nothing. Returns (exit code or
    None, stdout, stderr)."""
    try:
        source = {"stdin": subprocess.DEVNULL} if feed is None else {"input": feed}
        done = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout, **source)
    except subprocess.TimeoutExpired:
        return None, "", "no answer within %d seconds" % timeout
    except OSError as error:
        return None, "", error.strerror or str(error)
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


class Blocked(Exception):
    """Raised when writing failed and everything was put back."""


class Changes:
    """The file writes of one installation. Either all of them stay, or none does."""

    def __init__(self, root):
        self.root = root
        self.backups = None  # a folder outside the project, made when the first file is replaced
        self.written = []  # (path, had a file before)
        self.folders = []  # folders this run created

    def write(self, rel, data):
        target = self.root / rel
        for folder in reversed([p for p in target.parents if self.root in p.parents]):
            if not folder.exists():
                folder.mkdir()
                self.folders.append(folder)
        existed = target.exists()
        if existed:
            if self.backups is None:
                self.backups = Path(tempfile.mkdtemp(prefix="agent-skills-bridge-backup-"))
            copy_to = self.backups / rel
            copy_to.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, copy_to)
        # Written next to the target and moved over it, so that no reader ever sees half a file.
        draft = target.with_name(target.name + ".installing")
        try:
            draft.write_bytes(data)
            if existed:
                shutil.copymode(target, draft)
            self.written.append((rel, existed))
            os.replace(draft, target)
        finally:
            if draft.exists():  # the move failed: the draft must not stay, read-only or not
                try:
                    os.chmod(draft, stat.S_IREAD | stat.S_IWRITE)
                    draft.unlink()
                except OSError:
                    pass

    def undo(self):
        """Put every file back. Returns what could not be put back."""
        failed = []
        for rel, existed in reversed(self.written):
            target = self.root / rel
            try:
                if existed:
                    before = (self.backups / rel).read_bytes()
                    if not target.is_file() or target.read_bytes() != before:  # else the write never got there
                        shutil.copy2(self.backups / rel, target)
                elif target.exists():
                    target.unlink()
            except OSError as error:
                failed.append("%s: %s" % (rel, error.strerror or error))
        for folder in reversed(self.folders):
            try:
                folder.rmdir()
            except OSError:
                pass  # something else is in it by now: it stays
        self.written = []
        self.folders = []
        return failed


class Installer:
    def __init__(self, args):
        self.args = args
        self.root = None
        self.kit = {}
        self.kit_hooks = {}
        self.git = None  # path of git when the project is a git work tree that git answers for
        self.top = None  # the top folder of that work tree; git names its ignore files from there
        self.svn = None  # path of svn when the project is an svn working copy
        self.is_git = False
        self.is_svn = False
        self.plan = []  # {"path", "action", "why", "data"}
        self.changes = None
        self.report = {
            "outcome": None,
            "project": None,
            "vcs": [],
            "kit_version": None,
            "dry_run": bool(args.dry_run),
            "files": [],
            "vcs_steps": [],
            "blockers": [],
            "problems": [],
            "notes": [],
            "status_shell": None,
            "status": None,
            "backups": None,
            "next_steps": [],
        }

    # -- reporting ---------------------------------------------------------------------------

    def block(self, ident, message, fix, **more):
        self.report["blockers"].append({"id": ident, "message": message, "fix": fix, **more})

    def note(self, text):
        self.report["notes"].append(text)

    def problem(self, text):
        self.report["problems"].append(text)

    def step(self, rel, action, why, data=None):
        self.plan.append({"path": rel, "action": action, "why": why, "data": data})

    def changing(self):
        return [entry for entry in self.plan if entry["data"] is not None]

    def finish(self, outcome, code):
        self.report["outcome"] = outcome
        self.report["files"] = [{key: entry[key] for key in ("path", "action", "why")} for entry in self.plan]
        if self.changes is not None and self.changes.backups is not None:
            self.report["backups"] = str(self.changes.backups)
        for key in ("vcs_steps", "status_shell", "status", "backups"):  # said only where there is something to say
            if not self.report[key]:
                del self.report[key]
        return code

    # -- the kit -----------------------------------------------------------------------------

    def load_kit(self):
        missing = []
        for asset, _ in (*OWNED, SETTINGS, GITATTRIBUTES, ANCHOR):
            try:
                self.kit[asset] = lf((KIT / asset).read_bytes())
            except OSError:
                missing.append(asset)
        if not missing:
            try:
                self.kit_hooks = json.loads(self.kit[SETTINGS[0]].decode("utf-8"))["hooks"]
                sound = isinstance(self.kit_hooks, dict) and all(isinstance(groups, list) for groups in self.kit_hooks.values())
            except (ValueError, KeyError, TypeError):
                sound = False
            if not sound or not self.kit[OWNED[0][0]].startswith(b"#!/bin/sh") or EOL_RULE not in self.kit[GITATTRIBUTES[0]]:
                missing.append("a file with the text it should have")
        if missing:
            self.block(
                "kit-incomplete",
                "The kit next to this installer is not complete: %s is missing in %s." % (", ".join(missing), KIT),
                "Copy the whole skill folder again from the agent-skills-bridge repository, then run the installer again.",
            )
            return
        digest = hashlib.sha256()
        for asset in sorted(self.kit):
            digest.update(asset.encode("utf-8") + b"\0" + self.kit[asset] + b"\0")
        self.report["kit_version"] = digest.hexdigest()[:12]

    # -- the project and its version control ---------------------------------------------------

    def find_project(self):
        given = self.args.project
        start = Path(os.path.abspath(given)) if given else Path.cwd()
        git = locate("git", start)
        top = None
        if git:
            code, out, _ = run([git, "-C", str(start), "rev-parse", "--show-toplevel"], cwd=str(start))
            if code == 0 and out.strip():
                top = Path(os.path.abspath(out.strip()))
        # Without --project, the project is the top folder of the git repository around the
        # working directory. A folder that was named is taken as it is.
        self.root = start if given or top is None else top
        self.report["project"] = str(self.root)
        if given and top is not None and not os.path.samefile(top, self.root):
            self.note(
                "%s is a folder inside the git repository %s. The kit works for Claude Code sessions that start in "
                "the folder it is installed in. If sessions start in the top folder, install it there." % (self.root, top)
            )

    def detect_vcs(self):
        root = str(self.root)
        git = locate("git", self.root)
        has_git_folder = any((folder / ".git").exists() for folder in (self.root, *self.root.parents))
        if git:
            code, out, err = run(
                [git, "-C", root, "rev-parse", "--is-inside-work-tree", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
                cwd=root,
            )
            lines = [line.strip() for line in out.split("\n")]
            if code == 0 and len(lines) > 3 and lines[0] == "true":
                self.git, self.is_git = git, True
                self.top = Path(os.path.abspath(lines[1]))
                common = Path(lines[3])
                if not common.is_absolute():
                    common = self.root / common
                try:
                    linked = not os.path.samefile(lines[2], common)
                except OSError:
                    linked = False
                if linked:
                    self.note(
                        "This folder is a linked git worktree. Claude desktop runs a worktree session with the hooks of "
                        "the main checkout, so the bridge works there once the main checkout has the kit: commit the "
                        "kit on this branch and merge it."
                    )
            elif has_git_folder:
                self.is_git = True
                self.note(
                    "git did not answer for this folder (%s), so the installer could not check whether git ignores the "
                    "kit or keeps the shell script LF. Check both with the bridge's status command." % (err.strip() or "no output")
                )
        elif has_git_folder:
            self.is_git = True
            self.note(
                "This folder is in a git repository, but no git is on PATH, so the installer could not check whether "
                "git ignores the kit or keeps the shell script LF."
            )
        if any((folder / ".svn").is_dir() for folder in (self.root, *self.root.parents)):
            self.is_svn = True
            self.svn = locate("svn", self.root)
        self.report["vcs"] = [name for name, there in (("git", self.is_git), ("svn", self.is_svn)) if there]

    def ask_git(self, *arguments, feed=None):
        # core.fsmonitor names a program that git would start: the project is input, so it stays off.
        return run([self.git, "-c", "core.fsmonitor=false", "-C", str(self.root), *arguments], cwd=str(self.root), feed=feed)

    def git_files_wanted(self):
        """The two files that only git needs. An svn working copy without git gets neither."""
        return self.is_git or not self.is_svn

    # -- checks before anything is written -----------------------------------------------------

    def check_folders(self):
        for rel in FOLDERS:
            folder = self.root / rel
            if is_link(folder):
                if rel == SKILLS:
                    self.block(
                        "skills-folder-is-link",
                        ".claude/skills is a link (to %s). The bridge leaves a link alone, so it would copy nothing."
                        % os.path.realpath(folder),
                        "This needs the user's consent. To let the bridge take over, delete the link .claude/skills (the "
                        "link only, not the folder it leads to), then run the installer again.",
                        path=rel,
                    )
                else:
                    self.block(
                        "folder-is-link",
                        "%s is a link (to %s). The installer never writes through a link." % (rel, os.path.realpath(folder)),
                        "Install the kit in a project whose %s is a plain folder, or replace the link with a folder." % rel,
                        path=rel,
                    )
            elif folder.exists() and not folder.is_dir():
                self.block("not-a-folder", "%s is a file, and the kit needs a folder of that name." % rel, "Move the file away.", path=rel)
        if self.report["blockers"]:
            return
        wanted = [target for _, target in (*OWNED, SETTINGS)]
        if self.git_files_wanted():
            wanted += [GITATTRIBUTES[1], ANCHOR[1]]
        for rel in wanted:
            target = self.root / rel
            if is_link(target):
                self.block("file-is-link", "%s is a link. The installer never writes through a link." % rel, "Replace the link with a file, or delete it.", path=rel)
            elif target.exists() and not target.is_file():
                self.block("not-a-file", "%s is a folder, and the kit needs a file of that name." % rel, "Move the folder away.", path=rel)

    # -- the plan ------------------------------------------------------------------------------

    def read(self, rel):
        """The file's bytes, or None when the project has no such file."""
        try:
            return (self.root / rel).read_bytes()
        except FileNotFoundError:
            return None

    def plan_owned(self):
        for asset, rel in OWNED:
            now = self.read(rel)
            if now is None:
                self.step(rel, "create", "new", self.kit[asset])
            elif lf(now) != self.kit[asset]:
                self.step(rel, "replace", "differs from the kit's file", self.kit[asset])
            elif rel == SCRIPT and b"\r" in now:
                self.step(rel, "replace", "had CRLF line ends, which sh on Linux and macOS cannot read", self.kit[asset])
            else:
                self.step(rel, "keep", "same as the kit's file")
        if self.read(".claude/hooks/agent-skills-bridge.test.sh") is not None:
            self.note(
                ".claude/hooks/agent-skills-bridge.test.sh is from an older kit, which carried its tests into every "
                "project. The kit no longer does, and the installer left the file alone: delete it if nobody uses it."
            )

    def plan_settings(self):
        asset, rel = SETTINGS
        raw = self.read(rel)
        if raw is None:
            self.step(rel, "create", "new", self.kit[asset])
            return
        manual = "Repair the file, or add the kit's four hook entries to it by hand from %s. Then run the installer again." % (KIT / asset)
        bom = raw.startswith(b"\xef\xbb\xbf")
        try:
            text = raw[3:].decode("utf-8") if bom else raw.decode("utf-8")
        except UnicodeDecodeError:
            self.block("settings-unreadable", ".claude/settings.json is not UTF-8 text, so the installer does not edit it.", manual, path=rel)
            return
        doubles = []

        def pairs(items):
            keys = [key for key, _ in items]
            doubles.extend(key for key in set(keys) if keys.count(key) > 1)
            return dict(items)

        try:
            settings = json.loads(text, object_pairs_hook=pairs) if text.strip() else {}
        except ValueError as error:
            self.block(
                "settings-unreadable",
                ".claude/settings.json is not valid JSON (%s), so the installer does not edit it." % error,
                manual,
                path=rel,
            )
            return
        if doubles:
            self.block(
                "settings-unreadable",
                ".claude/settings.json names a key twice (%s). Rewriting it would drop one of the two, so the installer "
                "does not edit it." % ", ".join(sorted(set(doubles))),
                manual,
                path=rel,
            )
            return
        hooks = settings.get("hooks", {}) if isinstance(settings, dict) else None
        if not isinstance(hooks, dict) or not all(isinstance(hooks.get(event, []), list) for event in self.kit_hooks):
            self.block(
                "settings-unreadable",
                ".claude/settings.json does not have the shape of Claude Code settings: 'hooks' must be an object, and "
                "each event in it a list.",
                manual,
                path=rel,
            )
            return
        merged = merge_hooks(settings, self.kit_hooks)
        if settings.get("disableAllHooks") is True:
            self.note(".claude/settings.json sets disableAllHooks, so Claude Code runs no hook of this project, the bridge's included.")
        if merged == settings:
            self.step(rel, "keep", "already holds the kit's four hook entries")
            return
        # The file keeps its own indentation, line ends, byte order mark and last line end.
        indent = "  "
        for line in text.splitlines()[1:]:
            stripped = line.lstrip(" \t")
            if stripped and stripped != line:
                indent = line[: len(line) - len(stripped)]
                break
        newline = "\r\n" if "\r\n" in text else "\n"
        end = newline if text.endswith("\n") or not text.strip() else ""

        def dump(value):
            body = json.dumps(value, indent=indent, ensure_ascii=text.isascii())
            return ("\ufeff" if bom else "") + body.replace("\n", newline) + end

        why = "added the kit's hook entries next to the settings that were there"
        if text.strip() and dump(settings) != ("\ufeff" if bom else "") + text:
            why += "; the file's layout changed too, because it was not laid out the way a JSON writer does it"
        self.step(rel, "merge", why, dump(merged).encode("utf-8"))

    def plan_git_files(self):
        for asset, rel in (GITATTRIBUTES, ANCHOR):
            if not self.git_files_wanted():
                self.step(rel, "skip", "only git needs it, and this is an svn working copy")
                continue
            now = self.read(rel)
            if now is None:
                self.step(rel, "create", "new", self.kit[asset])
            elif rel == ANCHOR[1]:
                self.step(rel, "keep", "the project has its own; the bridge needs no line in it")
            elif any(line.split() and line.split()[0] == b"*.sh" and b"eol=lf" in line.split() for line in now.splitlines()):
                self.step(rel, "keep", "already keeps *.sh LF")
            else:
                newline = b"\r\n" if b"\r\n" in now else b"\n"
                gap = b"" if not now or now.endswith(b"\n") else newline
                self.step(rel, "append", "added the line '%s'" % EOL_RULE.decode(), now + gap + EOL_RULE + newline)

    def ignored(self):
        """What git ignores of the kit's files: a list of (source file, line number, rule, path)."""
        paths = [entry["path"] for entry in self.plan if entry["action"] != "skip"]
        code, out, err = self.ask_git("check-ignore", "-v", "-z", "--stdin", feed="".join(path + "\0" for path in paths).encode("utf-8"))
        if code not in (0, 1):
            self.note("git could not say whether it ignores the kit (%s). Check with the bridge's status command." % (err.strip() or "no answer"))
            return []
        fields = out.split("\0")
        matches = [tuple(fields[i : i + 4]) for i in range(0, len(fields) - 3, 4)]
        # git names the rule that decides. One that starts with "!" lets the path through.
        return [match for match in matches if not match[2].startswith("!")]

    def check_ignored(self):
        if not self.git:
            return
        found = self.ignored()
        if not found:
            return
        rules = sorted({(source, int(line), rule) for source, line, rule, _ in found})
        where = "; ".join("'%s' in %s, line %d" % (rule, source, line) for source, line, rule in rules)
        hidden = ", ".join(sorted({path for *_, path in found}))
        message = "git ignores files of the kit (%s), so they could not be committed. The rule: %s." % (hidden, where)
        edit = self.gitignore_edit(rules)
        if edit is None:
            self.block(
                "kit-ignored-by-git",
                message,
                "Change the rule by hand so that git sees .claude/settings.json, .claude/hooks/ and .claude/skills/. "
                "'A root .gitignore that ignores .claude/' in %s shows how. Then run the installer again." % (KIT / OWNED[2][0]),
            )
        elif not self.args.fix_gitignore:
            self.block(
                "kit-ignored-by-git",
                message,
                "This needs the user's consent. The installer can rewrite that rule in the project's .gitignore, so "
                "that git ignores everything in .claude except settings.json, hooks/ and skills/. The user's own files "
                "in those places then show up in git too. On a yes, run the installer again with %s." % IGNORE_FLAG,
                rerun_with=IGNORE_FLAG,
            )
        else:
            self.step(".gitignore", "edit", "rewrote the rule that ignored the whole .claude folder (%s)" % where, edit)

    def gitignore_edit(self, rules):
        """The project's .gitignore with its whole-folder rules rewritten, or None when the rules
        are not that simple: a rule in another file, or a wider pattern."""
        target = self.root / ".gitignore"
        if is_link(target) or not target.is_file():
            return None
        lines = target.read_bytes().splitlines(keepends=True)
        for source, number, rule in rules:
            try:
                same = not os.path.isabs(source) and os.path.samefile(self.top / source, target)
            except OSError:
                same = False
            if not same or rule not in WHOLE_FOLDER_RULES or number > len(lines) or lines[number - 1].strip() != rule.encode():
                return None
        for _, number, rule in rules:
            line = lines[number - 1]
            newline = b"\r\n" if line.endswith(b"\r\n") else b"\n"
            # A rule without a leading slash holds for every .claude folder in the tree. The new
            # rule keeps that, and lets git into the top one only.
            every = b"/.claude/*" if rule.startswith("/") else b"**/.claude/*"
            lines[number - 1] = newline.join((every, b"!/.claude/settings.json", b"!/.claude/hooks/", b"!/.claude/skills/")) + newline
        return b"".join(lines)

    # -- writing and checking --------------------------------------------------------------------

    def apply(self):
        self.changes = Changes(self.root)
        try:
            for entry in self.changing():
                self.changes.write(entry["path"], entry["data"])
        except OSError as error:
            self.give_up("write-failed", "Could not write %s: %s." % (entry["path"], error.strerror or error), "Free the file or the folder (is it open in a program, or read-only?), then run the installer again.")
        wrong = self.check_written()
        if wrong:
            self.give_up("check-failed", "The files were written, but a check of them failed: %s" % " ".join(wrong), "Repair what the message names, then run the installer again.")

    def give_up(self, ident, message, fix):
        left = self.changes.undo()
        if left:
            self.problem(message)
            self.problem("These files could not be put back as they were: %s. Their earlier versions are in %s." % ("; ".join(left), self.changes.backups))
            raise Blocked(False)
        self.block(ident, message + " Everything was put back as it was.", fix)
        raise Blocked(True)

    def check_written(self):
        wrong = []
        for entry in self.changing():
            if self.read(entry["path"]) != entry["data"]:
                wrong.append("%s does not hold what was written." % entry["path"])
        try:
            settings = json.loads((self.read(SETTINGS[1]) or b"").decode("utf-8-sig"))
            hooks = settings["hooks"]
            if not all(group in hooks[event] for event, groups in self.kit_hooks.items() for group in groups):
                wrong.append(".claude/settings.json does not hold the kit's four hook entries.")
        except (ValueError, KeyError, TypeError):
            wrong.append(".claude/settings.json cannot be read back.")
        if self.git:
            if self.git_files_wanted():
                code, out, _ = self.ask_git("check-attr", "-z", "eol", "--", SCRIPT)
                fields = out.split("\0")
                if code == 0 and len(fields) > 2 and fields[2] != "lf":
                    wrong.append(
                        "git does not keep %s LF (eol is '%s'), although .claude/hooks/.gitattributes says so: another "
                        "rule, such as one in .git/info/attributes, overrides it." % (SCRIPT, fields[2])
                    )
            if any(entry["path"] == ".gitignore" for entry in self.changing()):
                still = self.ignored()
                if still:
                    wrong.append(
                        "git still ignores %s after the rule was rewritten: '%s' in %s, line %s."
                        % (", ".join(sorted({path for *_, path in still})), still[0][2], still[0][0], still[0][1])
                    )
        return wrong

    # -- svn ---------------------------------------------------------------------------------------

    def svn_steps(self):
        """Schedule the kit for svn and set the two properties it needs. Nothing is committed."""
        steps = self.report["vcs_steps"]
        files = [target for _, target in (SETTINGS, *OWNED)]
        if not self.svn:
            missing = (
                "This is an svn working copy, but no svn is on PATH. Run the commands under 'Adopt it in an svn working "
                "copy' in .claude/hooks/agent-skills-bridge.md yourself."
            )
            if self.args.dry_run:
                self.note(missing)
            else:
                self.problem(missing)
            return

        def svn(*arguments):
            code, out, err = run([self.svn, "--non-interactive", *arguments], cwd=str(self.root))
            return code, out, err.strip()

        def versioned(rel):
            return svn("info", rel)[0] == 0

        def do(*arguments):
            line = "svn " + " ".join(arguments)
            if self.args.dry_run:
                steps.append(line)
                return True
            code, _, err = svn(*arguments)
            if code != 0:
                self.problem("'%s' failed: %s" % (line, err or "no message"))
                return False
            steps.append(line)
            return True

        new = [rel for rel in files if not versioned(rel)]
        if new and not do("add", "--parents", *new):
            return
        if not versioned(SKILLS):
            if not self.args.dry_run:
                (self.root / SKILLS).mkdir(parents=True, exist_ok=True)
            # --depth=empty: copies that the bridge made earlier must never be added.
            if not do("add", "--parents", "--depth=empty", SKILLS):
                return
        code, out, _ = svn("propget", "svn:ignore", SKILLS)
        rules = [line.strip() for line in out.splitlines() if line.strip()] if code == 0 else []
        if "*" not in rules:
            # Through a file: svn.exe on Windows turns a * on its command line into file names.
            with tempfile.TemporaryDirectory(prefix="agent-skills-bridge-") as folder:
                value = Path(folder) / "svn-ignore.txt"
                value.write_text("\n".join((*rules, "*")) + "\n", encoding="utf-8", newline="\n")
                if self.args.dry_run:
                    steps.append("svn propset svn:ignore <%s> %s" % (", ".join((*rules, "*")), SKILLS))
                elif do("propset", "svn:ignore", "-F", str(value), SKILLS):
                    steps[-1] = "svn propset svn:ignore <%s> %s" % (", ".join((*rules, "*")), SKILLS)
                else:
                    return
        if svn("propget", "svn:eol-style", SCRIPT)[1].strip() != "LF":
            do("propset", "svn:eol-style", "LF", SCRIPT)

    # -- the bridge's own check ----------------------------------------------------------------------

    def hook_shell(self):
        """The shell that Claude Code runs this project's hooks in, as (kind, program): Git Bash
        on Windows where there is one, PowerShell otherwise, /bin/sh everywhere else."""
        if os.name != "nt":
            return ("sh", "/bin/sh") if os.path.exists("/bin/sh") else ("sh", locate("sh", self.root))
        candidates = []
        if os.environ.get("CLAUDE_CODE_GIT_BASH_PATH"):
            candidates.append(Path(os.environ["CLAUDE_CODE_GIT_BASH_PATH"]))
        for variable in ("ProgramFiles", "ProgramFiles(x86)"):
            if os.environ.get(variable):
                candidates.append(Path(os.environ[variable]) / "Git" / "bin" / "bash.exe")
        git = locate("git", self.root)
        if git:  # <Git>/cmd/git.exe, or <Git>/mingw64/bin/git.exe
            candidates += [folder / "bin" / "bash.exe" for folder in Path(git).parents[1:3]]
        for candidate in candidates:
            if candidate.is_file():
                return "sh", str(candidate)
        system = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        if system.is_file():
            return "powershell", str(system)
        return "powershell", locate("powershell", self.root) or locate("pwsh", self.root)

    def run_status(self):
        kind, program = self.hook_shell()
        if not program:
            self.problem("No shell was found to run the bridge's status command in, so the installed script was not started once.")
            return
        if kind == "sh":
            argv = [program, (self.root / SCRIPT).as_posix(), "status"]
        else:
            argv = [program, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(self.root / SCRIPT_PS1), "status"]
        env = {key: value for key, value in os.environ.items() if key != "ASB_CMD"}  # ASB_CMD would make it a hook run
        code, out, err = run(argv, cwd=str(self.root), timeout=STATUS_TIMEOUT, env=env)
        lines = [line.rstrip() for line in out.splitlines() if line.strip()]
        self.report["status_shell"] = program
        self.report["status"] = lines
        if code != 0:
            self.problem("The bridge's status command did not run in %s: %s" % (program, err.strip() or "exit code %s" % code))
        elif not any(line.split()[:1] == ["hooks"] and "runs the bridge" in line for line in lines):
            self.problem("The bridge's status command does not report its hooks in .claude/settings.json.")
        # What the bridge itself finds wrong in the project is for the user to know. Copies that
        # are out of date are not among it: the first session makes them.
        for line in lines:
            if line.split()[:1] in (["conflicts"], ["note"], ["left"], ["switch"]) or "not ignored" in line or "is not in svn" in line:
                self.note("The bridge's status command says: " + " ".join(line.split()))

    def next_steps(self):
        steps = self.report["next_steps"]
        added = any(entry["path"] == SCRIPT and entry["action"] == "create" for entry in self.plan)
        message = "%s agent-skills-bridge (kit %s)" % ("Add" if added else "Update", self.report["kit_version"])
        if self.git:
            paths = [entry["path"] for entry in self.plan if entry["action"] != "skip"]
            code, out, _ = self.ask_git("status", "--porcelain", "--untracked-files=all", "--", *paths)
            if code == 0 and out.strip():
                steps.append(
                    "The kit is not committed yet. Teammates get the bridge with their next pull once it is: "
                    "`git add -- %s`, then `git commit -m \"%s\"`. The installer commits nothing." % (" ".join(paths), message)
                )
        if self.is_svn and self.report["vcs_steps"]:
            steps.append(
                "The kit and its svn properties are scheduled, not committed. Review them with `svn status`, then commit, "
                "for example with the message \"%s\". The installer commits nothing." % message
            )
        skills = self.root / ".agents" / "skills"
        if not (skills.is_dir() and any((entry / "SKILL.md").is_file() for entry in skills.iterdir())):
            steps.append("The project has no skill in .agents/skills yet. Put each skill in .agents/skills/<name>/SKILL.md; the bridge copies it to .claude/skills.")
        steps.append(
            "Start a new Claude Code session in this project, and trust the folder if Claude Code asks: hooks are read "
            "when a session starts, and that session copies the skills to .claude/skills. Until then the bridge's "
            "status calls the copies out of date, which is as it should be. The kit needs Claude Code 2.1.220 or newer."
        )
        steps.append("Optional: 'Manual test' in .claude/hooks/agent-skills-bridge.md shows the whole chain working in about ten minutes.")

    # -- the whole run -------------------------------------------------------------------------------

    def install(self):
        self.load_kit()
        if self.report["blockers"]:
            return self.finish("blocked", EXIT_BLOCKED)
        self.find_project()
        self.detect_vcs()
        self.check_folders()
        if not self.report["blockers"]:
            self.plan_owned()
            self.plan_settings()
            self.plan_git_files()
            self.check_ignored()
        if self.report["blockers"]:
            return self.finish("blocked", EXIT_BLOCKED)
        changed = bool(self.changing())
        if self.args.dry_run:
            if self.is_svn:
                self.svn_steps()
            return self.finish("would change" if changed or self.report["vcs_steps"] else "current", EXIT_OK)
        try:
            self.apply()
        except Blocked as blocked:
            put_back = blocked.args[0]
            return self.finish("blocked" if put_back else "incomplete", EXIT_BLOCKED if put_back else EXIT_INCOMPLETE)
        if self.is_svn:
            self.svn_steps()
        self.run_status()
        self.next_steps()
        if self.report["problems"]:
            return self.finish("incomplete", EXIT_INCOMPLETE)
        return self.finish("installed" if changed or self.report["vcs_steps"] else "current", EXIT_OK)


def merge_hooks(settings, kit_hooks):
    """The settings with the kit's hook entries in them. The project's own hooks stay where they
    are. Hook entries of an older kit are replaced, wherever they sit under the kit's events."""
    merged = copy.deepcopy(settings)
    hooks = merged.setdefault("hooks", {})

    def of_bridge(hook):
        return isinstance(hook, dict) and isinstance(hook.get("command"), str) and BRIDGE_MARK in hook["command"]

    def count(groups):
        return sum(1 for group in groups if isinstance(group, dict) for hook in group.get("hooks") or [] if of_bridge(hook))

    for event, wanted in kit_hooks.items():
        current = hooks.get(event, [])
        if all(group in current for group in wanted) and count(current) == count(wanted):
            continue
        kept = []
        for group in current:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list) and any(of_bridge(hook) for hook in group["hooks"]):
                rest = [hook for hook in group["hooks"] if not of_bridge(hook)]
                if rest:
                    kept.append({**group, "hooks": rest})
            else:
                kept.append(group)
        hooks[event] = kept + copy.deepcopy(wanted)
    return merged


def render(report):
    """The report as JSON with one line for each file, step and message: short enough to read."""
    parts = []
    for key, value in report.items():
        if isinstance(value, list) and value and key != "vcs":
            items = ",\n".join("    " + json.dumps(item, ensure_ascii=False) for item in value)
            parts.append("  %s: [\n%s\n  ]" % (json.dumps(key), items))
        else:
            parts.append("  %s: %s" % (json.dumps(key), json.dumps(value, ensure_ascii=False)))
    return "{\n" + ",\n".join(parts) + "\n}"


def main():
    for stream in (sys.stdout, sys.stderr):  # a pipe on Windows is not UTF-8 before Python 3.15
        stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(
        description="Install or update the agent-skills-bridge kit in a project: the hooks that make Claude Code load "
        "the Agent Skills in .agents/skills. Prints a JSON report on stdout. Never commits and never prompts.",
        epilog=EXIT_CODES,
    )
    parser.add_argument("--project", metavar="FOLDER", help="the project's top folder (default: the top folder of the git repository around the working directory, or the working directory itself)")
    parser.add_argument("--dry-run", action="store_true", help="report what would be done, and change nothing")
    parser.add_argument(IGNORE_FLAG, action="store_true", help="when the project's .gitignore ignores the whole .claude folder, rewrite that rule so that git sees the kit; only after the user agreed")
    args = parser.parse_args()
    if args.project is not None and not Path(args.project).is_dir():
        parser.error("--project: %s is not a folder" % args.project)
    os.environ["NoDefaultCurrentDirectoryInExePath"] = "1"  # Windows: do not look for programs in "."

    installer = Installer(args)
    try:
        code = installer.install()
    except Exception as error:  # the report must say what state the project is in, whatever happened
        left = installer.changes.undo() if installer.changes is not None and installer.changes.written else []
        message = "The installer failed: %s: %s." % (type(error).__name__, error)
        if installer.changes is not None and (left or installer.report["vcs_steps"]):
            installer.problem(message + " The project may be changed in part.")
            code = installer.finish("incomplete", EXIT_INCOMPLETE)
        else:
            installer.block("installer-failed", message + " Nothing in the project was changed.", "Report this to the kit's maintainer.")
            code = installer.finish("blocked", EXIT_BLOCKED)
    print(render(installer.report))
    summary = {EXIT_OK: "done", EXIT_BLOCKED: "blocked, nothing was changed", EXIT_INCOMPLETE: "INCOMPLETE, see 'problems'"}[code]
    print("agent-skills-bridge installer: %s (%s)" % (summary, installer.report["outcome"]), file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
