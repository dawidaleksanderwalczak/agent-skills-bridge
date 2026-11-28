#!/usr/bin/env python3
"""Uninstall the agent-skills-bridge kit from a project. Standard library only.

The kit makes Claude Code load the Agent Skills that a project keeps in .agents/skills. This script
takes it out again: the bridge's hook entries in .claude/settings.json, the kit's files in
.claude/hooks, the copies that the bridge made in .claude/skills, and the bridge's records. What
is not the kit's stays: the other settings and hooks, skills of the project's own, and
.agents/skills. It never commits, never prompts, and never writes or deletes through a link.

The copies are deleted by the bridge itself, with its clean command: only the bridge can tell its
copy from a skill of someone's own that has taken the copy's place. The script that runs for this
is the one that the installing skill next to this skill holds, never the project's: the project is
input, and this script starts no program that the project holds.

Its answer is one JSON object on stdout, the report, whose "outcome" says the same as the exit
code. It writes nothing to stderr: Windows PowerShell 5.1 turns a program's stderr into errors of
its own once it is redirected, and would then report a failure where there was none.
"""
import json
import os
import re
import subprocess
import sys

NEEDS = (3, 11)  # the oldest Python that the uninstaller runs on

EXIT_OK = 0  # uninstalled, or nothing of the bridge was there, and verified
EXIT_BLOCKED = 1  # something is in the way: nothing of the kit was removed
EXIT_USAGE = 2  # wrong arguments
EXIT_INCOMPLETE = 3  # the project was changed, but a later step failed
EXIT_PYTHON = 4  # started with a Python older than 3.11, and no newer one is on PATH

EXIT_CODES = (
    "Exit codes, each with the report's 'outcome': "
    "0 = uninstalled or not installed: done and verified; or would change: what a dry run found. "
    "1 = blocked: nothing of the kit was removed; the report's 'blockers' say why. "
    "2 = wrong arguments: the report's 'message' says which. "
    "3 = incomplete: the project was changed, but a later step failed; the report's 'problems' say which. "
    "4 = python too old: started with a Python older than 3.11, and no newer one is on PATH."
)

# The removal by hand, for a machine without a Python that is new enough. The page comes with the skill.
BY_HAND = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "references", "removing-by-hand.md")

# -- a Python that is too old -------------------------------------------------------------------
#
# From here to the version check, the code also runs on a Python that is too old for the rest, so
# it keeps to what Python 3.6 knows, and the whole file keeps to syntax that such a Python reads.
# On many machines `python3` is older than 3.11 while a newer Python is there under another name,
# python3.12 for example. The uninstaller looks for that one and goes on with it, so that whoever
# started it need not know the name. The installer of the same plugin does the same, with the same
# functions: a test holds the two files to the same code.

STARTED_BY = "ASB_UNINSTALLER_STARTED_BY"  # tells the newer Python which version started the uninstaller
VERSIONED = re.compile(r"python3\.(\d{1,3})")
PROBE = "import os, sys; print('%d.%d.%d %s %s' % (tuple(sys.version_info[:4]) + (os.name,)))"
# A first start can take this long where security software checks every new program.
PROBE_TIMEOUT = 30


def named_project(arguments):
    """The folder that --project names on a command line, or None. The last one counts, as it does
    for the parser."""
    named = None
    for index, argument in enumerate(arguments):
        if argument == "--project" and index + 1 < len(arguments):
            named = arguments[index + 1]
        elif argument.startswith("--project="):
            named = argument[len("--project=") :]
    return named


def same_folder(one, other):
    """True when two paths name the same folder. The file system is asked, because a folder has
    more than one spelling: through a link, in another letter case, as a short name on Windows."""
    try:
        return os.path.samefile(one, other)
    except (OSError, ValueError):
        return os.path.normcase(os.path.abspath(one)) == os.path.normcase(os.path.abspath(other))


def pythons_on_path(avoid=()):
    """The commands on PATH that may start another Python, best first: python3.<n> from the highest
    n down, then python3, then python, then the py launcher on Windows. Each is a list to start a
    process with. Only PATH entries that are absolute folders are searched, and never a folder in
    `avoid`: the working directory and the project are input."""
    windows = os.name == "nt"
    avoided = [folder for folder in avoid if folder]
    seen = set([os.path.normcase(os.path.abspath(sys.executable or os.curdir))])  # the Python that runs this
    found = []
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        folder = folder.strip('"')
        if not os.path.isabs(folder) or any(same_folder(folder, input_folder) for input_folder in avoided):
            continue
        try:
            entries = sorted(os.listdir(folder))
        except OSError:
            continue  # PATH names folders that do not exist on most machines
        for entry in entries:
            name = entry.lower() if windows else entry
            if windows:
                if not name.endswith(".exe"):
                    continue  # a .bat or .cmd wrapper would put the arguments through cmd.exe
                name = name[:-4]
            versioned = VERSIONED.fullmatch(name)
            if versioned:
                if (3, int(versioned.group(1))) < NEEDS:
                    continue
                order = (0, -int(versioned.group(1)))
            elif name in ("python3", "python"):
                order = (1 if name == "python3" else 2, 0)
            elif windows and name == "py":
                order = (3, 0)
            else:
                continue
            path = os.path.join(folder, entry)
            key = os.path.normcase(os.path.abspath(path))
            if key in seen or os.path.isdir(path) or not (windows or os.access(path, os.X_OK)):
                continue
            seen.add(key)  # PATH often names a folder twice
            found.append((order, len(found), [path, "-3"] if order[0] == 3 else [path]))
    return [command for _, _, command in sorted(found)]


def version_of(command):
    """What a command answers when asked for its Python version and the system it is built for, as
    ((3, 12, 4), "final", "nt"). None when it does not start, does not answer in time or is no
    Python 3: PATH holds placeholders that only offer to install Python, and wrappers whose
    Python is gone."""
    try:
        process = subprocess.Popen(command + ["-I", "-S", "-c", PROBE], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except (OSError, ValueError):
        return None
    try:
        answer = process.communicate(timeout=PROBE_TIMEOUT)[0]
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError:
            pass
        return None
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+) (\w+) (\w+)", answer.decode("ascii", "replace").strip())
    if process.returncode != 0 or not match:
        return None
    return tuple(int(number) for number in match.group(1, 2, 3)), match.group(4), match.group(5)


def go_on_with_a_newer_python():
    """Start the uninstaller again with a Python on PATH that is new enough, and return its exit
    code. Where there is none, say so in a report and return EXIT_PYTHON."""
    arguments = sys.argv[1:]
    looked_at = []
    chosen = None
    commands = []
    if not os.environ.get(STARTED_BY):  # a Python that was handed the uninstaller hands it to no third one
        try:
            commands = pythons_on_path((os.getcwd(), named_project(arguments)))
        except Exception:  # whatever happens here, the answer is the report below
            pass
    for command in commands:
        found = version_of(command)
        if found is None:
            looked_at.append("%s: did not start" % " ".join(command))
            continue
        version, level, system = found
        if system != os.name:
            # On Windows, a Python of MSYS2 or Cygwin reads a path such as C:\Users differently.
            looked_at.append("%s: Python %d.%d.%d, built for another system (%s)" % ((" ".join(command),) + version + (system,)))
            continue
        looked_at.append("%s: Python %d.%d.%d" % ((" ".join(command),) + version))
        if version[:2] < NEEDS:
            continue
        if level == "final":
            chosen = command
            break
        chosen = chosen or command  # a pre-release only if no final release turns up
    if chosen is not None:
        environment = dict(os.environ)
        environment[STARTED_BY] = "%d.%d.%d" % tuple(sys.version_info[:3])
        try:
            return subprocess.call(chosen + ["-I", "-S", os.path.abspath(__file__)] + arguments, env=environment)
        except OSError as error:
            looked_at.append("%s: %s" % (" ".join(chosen), error.strerror or error))
    report = {
        "outcome": "python too old",
        "message": "The uninstaller needs Python %d.%d or newer. It was started with Python %d.%d.%d (%s) and found no newer "
        "one on PATH." % (NEEDS + tuple(sys.version_info[:3]) + (sys.executable or "path unknown",)),
        "looked_at": looked_at,
        "fix": "Install Python %d.%d or newer, or put the one that is installed on PATH, then run the uninstaller again. "
        "Without Python, the bridge can be removed by hand: %s says how." % (NEEDS + (BY_HAND,)),
    }
    if sys.stdout is not None:  # None where the caller closed it
        sys.stdout.write(json.dumps(report, indent=2) + "\n")  # in ASCII: this Python may print in any encoding
    return EXIT_PYTHON


if sys.version_info < NEEDS:
    sys.exit(go_on_with_a_newer_python())

# -- from here on, Python 3.11 or newer -----------------------------------------------------------

import argparse
import shutil
import stat
import tempfile
import time
from pathlib import Path
from xml.etree import ElementTree

WINDOWS = os.name == "nt"
# The endings of the programs that Windows starts by itself. PATHEXT names more, such as .VBS.
STARTABLE = (".com", ".exe", ".bat", ".cmd")

# The bridge's own scripts, as the installing skill of the same plugin holds them. One of them runs
# the clean command. They are the plugin's files, which were reviewed with it: whatever the project
# keeps under these names is never started.
BRIDGE = Path(__file__).resolve().parent.parent.parent / "installing-agent-skills-bridge" / "assets" / "kit" / "hooks"
BRIDGE_SCRIPTS = {"sh": "agent-skills-bridge.sh", "powershell": "agent-skills-bridge.ps1"}

CLAUDE = ".claude"
HOOKS = ".claude/hooks"
SKILLS = ".claude/skills"
RECORDS_NAME = ".agent-skills-bridge"
RECORDS = SKILLS + "/" + RECORDS_NAME  # the bridge's records: what it copied, when, and its lock
# The project's settings files that Claude Code reads hooks from. The installer writes only the
# first. The second is looked at too, because a hook entry that outlives the script is not
# harmless everywhere: an entry of an older kit ends with status 2 in dash once the script is gone,
# and Claude Code reads that as a refusal of every Write.
SETTINGS = (".claude/settings.json", ".claude/settings.local.json")
# The kit's own files, the one included that only an older kit brought into a project.
KIT_FILES = (
    (".claude/hooks/agent-skills-bridge.sh", "the bridge, as a shell script"),
    (".claude/hooks/agent-skills-bridge.ps1", "the bridge, as a PowerShell script"),
    (".claude/hooks/agent-skills-bridge.md", "the kit's documentation"),
    (".claude/hooks/agent-skills-bridge.test.sh", "the tests that an older kit brought along"),
)
GITATTRIBUTES = ".claude/hooks/.gitattributes"
ANCHOR = ".claude/skills/.gitignore"
# Where the bridge's script is put for the one run of its clean command. Both of the bridge's
# scripts take the folder two levels above their own for the project, so the script must lie in a
# folder of .claude. It is not .claude/hooks: there the hooks of a running session would find it.
WORKSHOP = ".claude/agent-skills-bridge-uninstall"

BRIDGE_MARK = "agent-skills-bridge."  # every hook command of the kit names one of its scripts
# The first line of the .gitignore that the bridge writes into each copy. By this line the bridge
# knows a copy that it made, and its scripts promise to go on knowing it. Here it serves to name
# such folders in the report. Nothing is ever deleted on the strength of it.
COPY_MARK = "# Copy of .agents/skills/%s for Claude Code, made by .claude/hooks/agent-skills-bridge.sh."
RESTORE_FLAG = "--restore-gitignore"
# What the installer writes into the project's .gitignore in the place of a rule that ignored the
# whole .claude folder (its --fix-gitignore option): one of the two first lines, then these three.
LET_THROUGH = (b"!/.claude/settings.json", b"!/.claude/hooks/", b"!/.claude/skills/")
EVERYTHING = {b"**/.claude/*": b".claude/", b"/.claude/*": b"/.claude/"}  # the first line, and the rule it stands for

# git and svn answer a local question within a second. A minute covers a network drive and the
# security software that makes every process start slow on some Windows machines.
TOOL_TIMEOUT = 60
# The bridge's clean command waits up to 15 seconds for a sync that is running, and then starts a
# few dozen processes. Claude Code gives the bridge's session hook the same 120 seconds.
CLEAN_TIMEOUT = 120
# How long ending a program that did not answer may take, each step of it.
STOP_TIMEOUT = 15
# The bridge's own rule (acquire_lock in its scripts): a lock in its records that is older than two
# minutes is the lock of a run that was killed. Claude Code ends a hook of the bridge after two.
LOCK_LIFE = 120


def inside(folder, parent):
    """True when a folder is the other one or lies in it, as the file system knows the two."""
    try:
        folder, parent = os.path.normcase(os.path.realpath(folder)), os.path.normcase(os.path.realpath(parent))
        return os.path.commonpath([folder, parent]) == parent
    except (OSError, ValueError):  # two drives have nothing in common
        return False


def remove_folder(path):
    """Delete a folder with all that is in it, a file that is read-only too. A link in it is
    unlinked and never followed. Returns True when the folder is gone."""
    for folder, folders, files in os.walk(path, topdown=False):
        for name in files + folders:
            entry = os.path.join(folder, name)
            try:
                if os.path.isdir(entry) and not is_link(entry):
                    os.rmdir(entry)
                    continue
                try:
                    os.unlink(entry)
                except OSError:
                    if is_link(entry):
                        os.rmdir(entry)  # a link to a folder, which Windows unlinks this way
                    else:
                        os.chmod(entry, stat.S_IREAD | stat.S_IWRITE)
                        os.unlink(entry)
            except OSError:
                pass  # what stays keeps the folder, and the caller looks
    try:
        os.rmdir(path)
    except OSError:
        pass
    return not os.path.lexists(path)


def lf(data):
    """The bytes with LF line ends. The bridge's scripts are written that way."""
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
    """Absolute path of a program on PATH. Only PATH entries that are absolute folders are
    searched, and never the working directory or the project's top folder: the project is input.
    shutil.which() does not do for this. On Windows before Python 3.12 it looks into the working
    directory first, and a file of that name in the project hides the program that PATH has."""
    avoided = [folder for folder in (os.getcwd(), project) if folder is not None]
    endings = [""]
    if WINDOWS:
        named = [ending for ending in os.environ.get("PATHEXT", "").split(os.pathsep) if ending.lower() in STARTABLE]
        endings = named or list(STARTABLE)
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        folder = folder.strip('"')
        if not os.path.isabs(folder) or any(same_folder(folder, input_folder) for input_folder in avoided):
            continue
        for ending in endings:
            found = os.path.join(folder, name + ending)
            if os.path.isfile(found) and (WINDOWS or os.access(found, os.X_OK)):
                return os.path.abspath(found)
    return None


class Job:
    """Windows: a job object for a program and everything it starts. Ending the job ends all of it.

    `taskkill /T` does less: it goes from each process to the ones that name it as their parent,
    and finds nothing behind a process that has ended. In Git Bash that is the rule: a script's
    `sleep` or `sed` is started by a copy of the shell that ends at once.

    The program must be in the job before it starts anything, so it is started suspended, put into
    the job, and only then let run. Git's bin\\bash.exe shows why: it is a small launcher, and it
    has started the real shell before a job could be made for it."""

    SUSPENDED = 0x00000004  # CREATE_SUSPENDED, which subprocess has no name for

    def __init__(self, process):
        self.kernel32 = self.handle = None
        self.let_run = False  # whether the suspended program runs now
        try:
            import ctypes
            from ctypes import wintypes

            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.CreateJobObjectW.restype = wintypes.HANDLE
            kernel32.CreateJobObjectW.argtypes = (wintypes.LPVOID, wintypes.LPCWSTR)
            kernel32.OpenProcess.restype = wintypes.HANDLE
            kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
            kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
            kernel32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
            kernel32.TerminateJobObject.restype = wintypes.BOOL
            kernel32.TerminateJobObject.argtypes = (wintypes.HANDLE, wintypes.UINT)
            kernel32.CloseHandle.restype = wintypes.BOOL
            kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
            ntdll = ctypes.WinDLL("ntdll")
            ntdll.NtResumeProcess.restype = ctypes.c_long
            ntdll.NtResumeProcess.argtypes = (wintypes.HANDLE,)
            # The rights that the assignment asks for (PROCESS_SET_QUOTA, PROCESS_TERMINATE) and the
            # right to let the program run (PROCESS_SUSPEND_RESUME).
            opened = kernel32.OpenProcess(0x0100 | 0x0001 | 0x0800, False, process.pid)
            if not opened:
                return
            try:
                job = kernel32.CreateJobObjectW(None, None)
                if job and kernel32.AssignProcessToJobObject(job, opened):
                    self.kernel32, self.handle = kernel32, job
                elif job:
                    kernel32.CloseHandle(job)  # a Windows that refuses the job: stop() uses taskkill
                self.let_run = ntdll.NtResumeProcess(opened) == 0
            finally:
                kernel32.CloseHandle(opened)
        except Exception:  # no ctypes: run() starts the program again, the plain way
            pass

    def end(self):
        """End every program in the job. False when there is no job or Windows refuses."""
        return self.handle is not None and bool(self.kernel32.TerminateJobObject(self.handle, 1))

    def close(self):
        """Let go of the job. Programs in it go on running."""
        if self.handle is not None:
            self.kernel32.CloseHandle(self.handle)
            self.handle = None


def run(argv, cwd, timeout=TOOL_TIMEOUT, env=None, feed=None):
    """Run a program that cannot prompt: its input is `feed`, or nothing. Returns (exit code or
    None, stdout, stderr). A program that does not answer in time is ended, and the wait is over
    soon after `timeout`, whatever the programs do that it has started."""

    def start(flags=0):
        return subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL if feed is None else subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=flags,
        )

    job = None
    try:
        if WINDOWS:
            process = start(Job.SUSPENDED)
            job = Job(process)
            if not job.let_run:  # it would stay suspended: end it, and start it without a job
                job.close()
                job = None
                process.kill()
                process.wait()
                for pipe in (process.stdin, process.stdout, process.stderr):
                    if pipe is not None:
                        pipe.close()
                process = start()
        else:
            process = start()
    except (OSError, ValueError) as error:
        return None, "", getattr(error, "strerror", None) or str(error)
    try:
        out, err = process.communicate(feed, timeout=timeout)
    except subprocess.TimeoutExpired:
        stop(process, job)
        return None, "", "no answer within %d seconds" % timeout
    except BaseException:  # Ctrl-C
        stop(process, job)
        raise
    finally:
        if job is not None:
            job.close()
    return process.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def stop(process, job=None):
    """End a program that did not answer, and wait for nothing beyond STOP_TIMEOUT.

    subprocess.run() does not do for this on Windows: it ends the program and then waits until the
    last program that holds the pipes has ended. A git or an svn that hangs behind a shell would
    hold the uninstaller for as long as it hangs. So on Windows everything that the program started
    is ended with it, through its job, and where there is no job, as far as taskkill finds it.

    Elsewhere only the program itself is ended, as subprocess.run() does it. What it started stays
    in the uninstaller's own process group: a session that is ended by its group takes all of it
    along, which a group or a session of the program's own would prevent."""
    if WINDOWS and not (job is not None and job.end()):
        taskkill = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "taskkill.exe")
        try:
            subprocess.run(
                [taskkill, "/F", "/T", "/PID", str(process.pid)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=STOP_TIMEOUT,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass
    try:
        process.kill()
    except OSError:
        pass
    try:
        process.wait(timeout=STOP_TIMEOUT)
    except (subprocess.TimeoutExpired, OSError):
        pass
    if not WINDOWS:  # on Windows a thread of subprocess may still read from them, and close() would wait for it
        for pipe in (process.stdin, process.stdout, process.stderr):
            try:
                if pipe is not None:
                    pipe.close()
            except OSError:
                pass


class Blocked(Exception):
    """Raised when a step failed and everything was put back."""


class Changes:
    """The file changes of one removal: files written anew and files deleted. Either all of them
    stay, or none does. Every file is copied to a folder outside the project before it is touched."""

    def __init__(self, root):
        self.root = root
        self.backups = None  # a folder outside the project, made when the first file is changed
        self.done = []  # (path, the target of the link that was there, or None for a file)
        self.left = []  # what undo() could not put back

    def backups_shown(self):
        """The backup folder under the name that other programs find it by, or None when this run
        changed no file. A Python from the Microsoft Store keeps what it writes below AppData,
        the temp folder included, in a place of its own, and only the real path leads there."""
        return None if self.backups is None else os.path.realpath(self.backups)

    def keep(self, rel):
        """Copy the file to the backup folder as it is now."""
        if self.backups is None:
            self.backups = Path(tempfile.mkdtemp(prefix="agent-skills-bridge-removed-"))
        copy_to = self.backups / rel
        copy_to.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.root / rel, copy_to)

    def draft(self, target):
        """A new, empty file next to the target. It is written and then moved over the target, so
        that no reader ever sees half a file. Its name is made up and the file is created in one
        step that fails where the name is taken: whatever the project holds next to the target, a
        link under a likely name included, is neither followed nor replaced."""
        handle, name = tempfile.mkstemp(prefix=target.name + ".", suffix=".uninstalling", dir=str(target.parent))
        os.close(handle)
        return name

    def drop(self, draft):
        """Take away a draft that was not moved. It is this run's own file, read-only or not."""
        if os.path.lexists(draft):
            try:
                os.chmod(draft, stat.S_IREAD | stat.S_IWRITE)
                os.unlink(draft)
            except OSError:
                pass

    def write(self, rel, data):
        target = self.root / rel
        self.keep(rel)
        draft = self.draft(target)
        try:
            with open(draft, "wb") as file:
                file.write(data)
            shutil.copymode(target, draft)
            self.done.append((rel, None))
            os.replace(draft, target)
        finally:
            self.drop(draft)

    def delete(self, rel):
        target = self.root / rel
        if is_link(target):  # the link goes, and what it leads to is not touched
            self.done.append((rel, os.readlink(target)))
            if WINDOWS and os.path.isdir(target):
                os.rmdir(target)
            else:
                os.unlink(target)
            return
        self.keep(rel)
        self.done.append((rel, None))
        # A file that Windows will not delete because it is read-only stays: the installer does not
        # write over such a file either, and whoever set the mark may have meant it.
        target.unlink()

    def undo(self):
        """Put every file back. Returns what could not be put back."""
        failed = []
        for rel, link in reversed(self.done):
            target = self.root / rel
            try:
                if link is not None:
                    if not is_link(target):
                        os.symlink(link, target)
                    continue
                kept = self.backups / rel
                if os.path.isfile(target) and not is_link(target) and target.read_bytes() == kept.read_bytes():
                    continue  # the change never got there
                # The way back is the way in: a draft, moved over the target. A copy into the
                # target would fail where the file is read-only, which the move never asked about.
                draft = self.draft(target)
                try:
                    shutil.copy2(kept, draft)
                    os.replace(draft, target)
                finally:
                    self.drop(draft)
            except OSError as error:
                failed.append("%s: %s" % (rel, error.strerror or error))
        self.done = []
        self.left += failed
        return failed


def of_bridge(hook):
    """True for a hook entry whose command names one of the bridge's scripts."""
    return isinstance(hook, dict) and isinstance(hook.get("command"), str) and BRIDGE_MARK in hook["command"]


def bridge_commands(settings):
    """The commands of the bridge's hook entries in a settings object."""
    hooks = settings.get("hooks") if isinstance(settings, dict) else None
    found = []
    for groups in (hooks.values() if isinstance(hooks, dict) else ()):
        for group in (groups if isinstance(groups, list) else ()):
            entries = group.get("hooks") if isinstance(group, dict) else None
            found += [hook["command"] for hook in (entries if isinstance(entries, list) else ()) if of_bridge(hook)]
    return found


def strip_hooks(settings):
    """The settings without the bridge's hook entries, and the number of entries that went. The
    project's own hooks stay where they are. A group that held nothing else goes with its entry,
    then an event that held nothing else, then "hooks" itself. What this run did not empty stays,
    empty or not."""
    hooks = settings.get("hooks") if isinstance(settings, dict) else None
    if not isinstance(hooks, dict):
        return settings, 0
    count = 0
    events = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            events[event] = groups
            continue
        kept = []
        went = 0
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list) and any(of_bridge(hook) for hook in group["hooks"]):
                rest = [hook for hook in group["hooks"] if not of_bridge(hook)]
                went += len(group["hooks"]) - len(rest)
                if rest:
                    kept.append({**group, "hooks": rest})
            else:
                kept.append(group)
        count += went
        if kept or not went:
            events[event] = kept
    if not count:
        return settings, 0
    stripped = {}
    for key, value in settings.items():
        if key != "hooks":
            stripped[key] = value
        elif events:
            stripped[key] = events
    return stripped, count


class Uninstaller:
    def __init__(self, args):
        self.args = args
        self.root = None
        self.above = None  # the top folder of the git repository, where the project is a folder inside it
        self.git = None  # path of git when the project is a git work tree that git answers for
        self.svn = None  # path of svn when the project is an svn working copy that svn answers for
        self.svn_silent = None  # what svn said where it is there and does not answer for the working copy
        self.held = {}  # for each of the kit's folders, whether it held anything before the removal
        self.is_git = False
        self.is_svn = False
        self.linked = False  # the project is a linked git worktree
        self.plan = []  # {"path", "action", "why", "data"}, and "folder" or "stray" for the two special kinds
        self.marked = []  # the folders in .claude/skills that hold the .gitignore of a copy
        self.unguarded = False  # a hook entry goes that fails without the script: see next_steps
        self.bridge = {}  # the bridge's scripts, by the kind of shell that runs them
        self.changes = None
        self.swept = False  # whether the run got as far as telling svn and taking folders away
        self.report = {
            "outcome": None,
            "project": None,
            "vcs": [],
            "dry_run": bool(args.dry_run),
            "files": [],
            "vcs_steps": [],
            "clean_shell": None,
            "clean": None,
            "blockers": [],
            "problems": [],
            "notes": [],
            "offers": [],
            "backups": None,
            "next_steps": [],
        }

    # -- reporting ---------------------------------------------------------------------------

    def block(self, ident, message, fix, **more):
        self.report["blockers"].append({"id": ident, "message": message, "fix": fix, **more})

    def note(self, text):
        if text not in self.report["notes"]:
            self.report["notes"].append(text)

    def problem(self, text):
        self.report["problems"].append(text)

    def step(self, rel, action, why, data=None, **kind):
        self.plan.append({"path": rel, "action": action, "why": why, "data": data, **kind})

    def planned(self, *actions):
        return [entry for entry in self.plan if entry["action"] in actions]

    def changing(self):
        """The files that this run writes anew or deletes."""
        return [entry for entry in self.planned("edit", "delete") if not entry.get("folder") and not entry.get("stray")]

    def finish(self, outcome, code):
        self.report["outcome"] = outcome
        self.report["files"] = [{key: entry[key] for key in ("path", "action", "why")} for entry in self.plan]
        if self.changes is not None and self.changes.backups is not None:
            self.report["backups"] = self.changes.backups_shown()
        for key in ("vcs_steps", "clean_shell", "clean", "offers", "backups"):  # said only where there is something to say
            if not self.report[key]:
                del self.report[key]
        return code

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
        if given and top is not None:
            try:
                if not os.path.samefile(top, self.root):
                    self.above = top
            except OSError:
                pass  # a git that is built for another system spells the folder its own way

    def detect_vcs(self):
        root = str(self.root)
        git = locate("git", self.root)
        has_git_folder = any(os.path.lexists(folder / ".git") for folder in (self.root, *self.root.parents))
        if git:
            code, out, err = run([git, "-C", root, "rev-parse", "--is-inside-work-tree", "--absolute-git-dir", "--git-common-dir"], cwd=root)
            lines = [line.strip() for line in out.split("\n")]
            if code == 0 and len(lines) > 2 and lines[0] == "true":
                self.git, self.is_git = git, True
                common = Path(lines[2])
                if not common.is_absolute():
                    common = self.root / common
                try:
                    self.linked = not os.path.samefile(lines[1], common)
                except OSError:
                    self.linked = False
            elif has_git_folder:
                self.is_git = True
                self.note("git did not answer for this folder (%s), so the uninstaller could not say what is left to commit." % (err.strip() or "no output"))
        elif has_git_folder:
            self.is_git = True
            self.note("This folder is in a git repository, but no git is on PATH, so the uninstaller could not say what is left to commit.")
        for folder in (self.root, *self.root.parents):
            if os.path.isdir(folder / ".svn"):
                self.is_svn = True
                self.svn = locate("svn", self.root)
                if self.svn:
                    # svn must be able to read this working copy, or its silence about a path would
                    # pass for "svn does not know it". One of another version cannot: the working
                    # copy's top folder, which svn always knows, tells.
                    code, _, err = self.svn_ask("info", "--", str(folder))
                    if code != 0:
                        self.svn_silent = " ".join(err.split()) or "no answer"
                        self.svn = None
                break
        self.report["vcs"] = [name for name, there in (("git", self.is_git), ("svn", self.is_svn)) if there]

    def ask_git(self, *arguments):
        # core.fsmonitor names a program that git would start: the project is input, so it stays off.
        return run([self.git, "-c", "core.fsmonitor=false", "-C", str(self.root), *arguments], cwd=str(self.root))

    def check_readable(self):
        """The kit's folders must let the uninstaller look into them. One that does not is a
        blocker: what of the bridge is in it, nobody can say."""
        for rel in (CLAUDE, HOOKS, SKILLS):
            folder = self.root / rel
            if is_link(folder) or not os.path.isdir(folder):
                continue
            try:
                os.listdir(folder)
                if not os.access(folder, os.X_OK):  # its names can be listed, and nothing in it can be looked at
                    raise PermissionError(13, "Permission denied")
            except OSError as error:
                self.unreadable(rel, error)

    def unreadable(self, rel, error):
        if not any(entry.get("path") == rel and entry["id"] == "cannot-read" for entry in self.report["blockers"]):
            self.block(
                "cannot-read",
                "%s cannot be read (%s), so the uninstaller cannot tell what of the bridge is in it." % (rel, error.strerror or error),
                "Make it readable for this user, then run the uninstaller again.",
                path=rel,
            )

    # -- the plan ------------------------------------------------------------------------------

    def read(self, rel, quiet=False):
        """The file's bytes, or None when the project has no file of that name. A file that is
        there and cannot be read is a blocker, unless the caller only looks again (`quiet`)."""
        target = self.root / rel
        if not os.path.isfile(target):
            return None
        try:
            return target.read_bytes()
        except OSError as error:
            if not quiet:
                self.unreadable(rel, error)
            return None

    def plan_settings(self, rel):
        raw = self.read(rel)
        if raw is None:
            return
        named = BRIDGE_MARK.encode("ascii") in raw
        manual = (
            "Repair the file, or delete the bridge's hook entries from it by hand: every entry whose command names "
            "agent-skills-bridge. Then run the uninstaller again."
        )
        unreadable = "%s %%s, so the uninstaller does not edit it. It names the bridge, so the bridge's hook entries may still be in it." % rel
        bom = raw.startswith(b"\xef\xbb\xbf")
        try:
            text = raw[3:].decode("utf-8") if bom else raw.decode("utf-8")
        except UnicodeDecodeError:
            if named:
                self.block("settings-unreadable", unreadable % "is not UTF-8 text", manual, path=rel)
            return
        doubles = []

        def pairs(items):
            keys = [key for key, _ in items]
            doubles.extend(key for key in set(keys) if keys.count(key) > 1)
            return dict(items)

        def no_number(name):
            # Python reads NaN and Infinity where JSON has no such words, and Claude Code reads none.
            raise ValueError("%s is no JSON" % name)

        try:
            settings = json.loads(text, object_pairs_hook=pairs, parse_constant=no_number) if text.strip() else {}
        except (ValueError, RecursionError) as error:
            if named:
                self.block("settings-unreadable", unreadable % ("is not valid JSON (%s)" % error), manual, path=rel)
            return
        stripped, count = strip_hooks(settings)
        if not count:
            if rel == SETTINGS[0] or named:
                self.step(rel, "keep", "holds no hook entry of the bridge")
            if named:
                self.note("%s names agent-skills-bridge, but in no hook entry: in a permission rule, for example. The uninstaller left that as it is." % rel)
            return
        if doubles:
            self.block(
                "settings-unreadable",
                unreadable % ("names a key twice (%s). Rewriting it would drop one of the two" % ", ".join(sorted(set(doubles)))),
                manual,
                path=rel,
            )
            return
        if is_link(self.root / rel):
            self.block(
                "file-is-link",
                "%s is a link (to %s) and holds hook entries of the bridge. The uninstaller never writes through a link." % (rel, os.path.realpath(self.root / rel)),
                manual,
                path=rel,
            )
            return
        entries = "%d hook entr%s" % (count, "y" if count == 1 else "ies")
        # The kit's command looks for the script (test -r) before it starts it. One of an older kit
        # does not, and fails once the script is gone.
        if any("test -r" not in command for command in bridge_commands(settings)):
            self.unguarded = True
        if BRIDGE_MARK in json.dumps(stripped):
            self.note("%s names agent-skills-bridge outside its hook entries too: in a permission rule, for example. The uninstaller left that as it is." % rel)
        if not stripped and rel == SETTINGS[0]:
            # The installer made this file, or filled one that was empty: without the bridge it says nothing.
            self.step(rel, "delete", "held nothing but the bridge's %s" % entries)
            return
        # The file keeps its own indentation, line ends, byte order mark and last line end.
        indent = "  "
        for line in text.splitlines()[1:]:
            lean = line.lstrip(" \t")
            if lean and lean != line:
                indent = line[: len(line) - len(lean)]
                break
        newline = "\r\n" if "\r\n" in text else "\n"
        end = newline if text.endswith("\n") else ""

        def dump(value):
            body = json.dumps(value, indent=indent, ensure_ascii=text.isascii(), allow_nan=False)
            return ("\ufeff" if bom else "") + body.replace("\n", newline) + end

        try:
            as_it_is, without = dump(settings), dump(stripped)
        except (ValueError, RecursionError) as error:
            # A number such as 1E400 is JSON, and Python reads it as infinity, which no JSON writer
            # writes: the file would come back as one that Claude Code cannot read.
            self.block("settings-unreadable", unreadable % ("holds a number that cannot be written back as it is (%s)" % error), manual, path=rel)
            return
        why = "took out the bridge's %s; the other settings stay" % entries
        if as_it_is != ("\ufeff" if bom else "") + text:
            why += "; the file's layout changed too, because it was not laid out the way a JSON writer does it"
        self.step(rel, "edit", why, without.encode("utf-8"))

    def plan_kit_files(self):
        for rel, what in KIT_FILES:
            target = self.root / rel
            if is_link(target):
                self.step(rel, "delete", "%s; here a link (to %s): the link goes, and what it leads to stays" % (what, os.path.realpath(target)))
            elif os.path.isfile(target):
                self.step(rel, "delete", what)
            elif os.path.isdir(target):
                self.note("%s is a folder, not the kit's file of that name. The uninstaller left it alone." % rel)
        workshop = self.root / WORKSHOP
        if os.path.isdir(workshop) and not is_link(workshop):
            self.step(WORKSHOP, "delete", "left behind by an uninstaller run that was stopped", stray=True)

    def own_scripts(self):
        """The shell scripts below .claude/hooks that are not the kit's. No link is followed."""
        kit = {rel for rel, _ in KIT_FILES}
        found = []
        waiting = [HOOKS]
        while waiting:
            rel = waiting.pop()
            try:
                entries = sorted(os.scandir(self.root / rel), key=lambda entry: entry.name)
            except OSError:
                continue
            for entry in entries:
                path = rel + "/" + entry.name
                if os.path.isdir(entry.path) and not is_link(entry.path):
                    waiting.append(path)
                elif entry.name.endswith(".sh") and path not in kit:
                    found.append(path)
        return sorted(found)

    def plan_git_files(self):
        """The two files that the installer adds for git: both go where they are the kit's, and
        stay where the project has made them its own."""

        def rules(raw):
            lines = [line.strip() for line in raw.decode("utf-8", "replace").splitlines()]
            return [line for line in lines if line and not line.startswith("#")]

        def keeps_lf(rule):
            return rule.split()[0] == "*.sh" and "eol=lf" in rule.split()

        raw = None if is_link(self.root / HOOKS) or is_link(self.root / GITATTRIBUTES) else self.read(GITATTRIBUTES)
        if raw is not None:
            found = rules(raw)
            if found and all(keeps_lf(rule) for rule in found):
                own = self.own_scripts()
                if own:
                    self.step(GITATTRIBUTES, "keep", "its rule keeps %s LF too, a shell script of the project's own" % own[0])
                else:
                    self.step(GITATTRIBUTES, "delete", "held only the kit's rule, which kept the bridge's shell script LF")
            elif any(keeps_lf(rule) for rule in found):
                self.step(GITATTRIBUTES, "keep", "the project's own file; the rule that keeps *.sh LF stays in it")
        raw = None if is_link(self.root / SKILLS) or is_link(self.root / ANCHOR) else self.read(ANCHOR)
        if raw is not None:
            if rules(raw):
                self.step(ANCHOR, "keep", "the project's own file: it holds rules, and the bridge wrote none of them")
            elif b"agent-skills-bridge" in raw:
                self.step(ANCHOR, "delete", "the kit's anchor: it held comments only, and kept the folder in every checkout for the bridge")

    def is_marked(self, name):
        """True when the folder .claude/skills/<name> holds the .gitignore that the bridge writes
        into a copy."""
        ignore = self.root / SKILLS / name / ".gitignore"
        if is_link(ignore) or not os.path.isfile(ignore):  # also where the folder lets nobody look
            return False
        try:
            with open(ignore, "rb") as file:
                first = file.readline(1024)
        except OSError:
            return False
        return first.decode("utf-8", "replace").rstrip("\r\n") == COPY_MARK % name

    def find_marked(self):
        skills = self.root / SKILLS
        if is_link(skills) or not os.path.isdir(skills):
            return []
        try:
            names = sorted(os.listdir(skills))
        except OSError:
            return []
        return [name for name in names if os.path.isdir(skills / name) and not is_link(skills / name) and self.is_marked(name)]

    def plan_copies(self):
        """The bridge's copies and records in .claude/skills. Its clean command deletes them, and
        it has work to do wherever the record folder is."""
        skills = self.root / SKILLS
        if is_link(skills):
            self.note(
                ".claude/skills is a link (to %s). The bridge leaves a link alone, so nothing of the bridge is behind it, "
                "and the uninstaller left it alone too." % os.path.realpath(skills)
            )
            return
        self.marked = self.find_marked()
        records = self.root / RECORDS
        if is_link(records) or not os.path.isdir(records):
            if os.path.lexists(records):
                self.note("%s is no folder of the bridge's making (a file or a link has its name). The uninstaller left it alone." % RECORDS)
            return
        why = "the bridge's own clean command deletes its copies and its records"
        if self.marked:
            count = len(self.marked)
            why += "; %d folder%s there hold%s the mark of a copy: %s" % (count, "" if count == 1 else "s", "s" if count == 1 else "", ", ".join(self.marked))
        self.step(SKILLS, "clean", why)

    def plan_gitignore(self):
        """Where the installer rewrote the rule that ignored the whole .claude folder, offer to put
        that rule back, and do it once the user agreed."""
        raw = None if is_link(self.root / ".gitignore") else self.read(".gitignore", quiet=True)
        if raw is None:
            return
        lines = raw.splitlines(keepends=True)
        bare = [line.strip() for line in lines]
        found = [index for index in range(len(bare) - 3) if bare[index] in EVERYTHING and tuple(bare[index + 1 : index + 4]) == LET_THROUGH]
        if not found:
            return
        where = "line%s %s" % ("" if len(found) == 1 else "s", ", ".join(str(index + 1) for index in found))
        if not self.args.restore_gitignore:
            self.report["offers"].append(
                {
                    "id": "restore-gitignore",
                    "message": "The project's .gitignore still lets git see .claude/settings.json, .claude/hooks/ and .claude/skills/ "
                    "(%s and the three after). The installer wrote those lines for the kit, in the place of a rule that ignored the "
                    "whole .claude folder. The uninstaller can put that rule back. Git then ignores what is new in .claude again, "
                    "files of the user's own included; what is committed stays tracked. This needs the user's consent. On a yes, "
                    "run the uninstaller again with %s." % (where, RESTORE_FLAG),
                    "rerun_with": RESTORE_FLAG,
                }
            )
            return
        for index in reversed(found):
            last = lines[index + 3]
            ending = last[len(last.rstrip(b"\r\n")) :]  # the block's own last line end, or none at the end of the file
            lines[index : index + 4] = [EVERYTHING[bare[index]] + ending]
        self.step(".gitignore", "edit", "put the rule back that ignores the whole .claude folder, in the place of the four lines that let the kit through (%s)" % where, b"".join(lines))

    def plan_folders(self):
        """The folders that this run empties go too, the innermost first. A folder that holds
        anything else stays, and so does one that was empty before: nothing says whose it is.
        One empty folder does say so. In an svn working copy the installer makes .claude/skills,
        schedules it and has svn ignore everything in it, and until a session runs it holds
        nothing: git gets the anchor there, svn does not."""
        going = {entry["path"] for entry in self.planned("delete")}
        cleaned = bool(self.planned("clean"))
        view = self.svn_view()
        for rel in (HOOKS, SKILLS, CLAUDE):
            folder = self.root / rel
            if is_link(folder) or not os.path.isdir(folder):
                continue
            try:
                names = os.listdir(folder)
            except OSError:
                continue
            self.held[rel] = bool(names)
            rest = [name for name in names if rel + "/" + name not in going]
            if rel == SKILLS and cleaned:
                rest = [name for name in rest if name != RECORDS_NAME and name not in self.marked]
            if rest or not (names or (rel == SKILLS and rel in view and self.svn_ignores() == ["*"])):
                continue
            more = self.svn_knows_more(rel, view, going)
            if more:
                self.step(rel, "keep", more, folder=True)
                continue
            why = "empty once the bridge is gone" if names else "empty, and svn ignores everything in it: the installer made it for the bridge's copies"
            self.step(rel, "delete", why, folder=True)
            going.add(rel)

    # -- what svn knows ------------------------------------------------------------------------------

    def svn_ask(self, *arguments):
        code, out, err = run([self.svn, "--non-interactive", *arguments], cwd=str(self.root))
        return code, out, err.strip()

    def svn_view(self):
        """What svn knows of .claude and of everything in it, as {path: (schedule, depth)}. The
        working copy is asked, not the repository. It names what the disk does not show: a file
        that is missing, a folder that this working copy leaves out (depth exclude) or holds in
        part, and what is scheduled to be added or deleted. Empty where svn does not know .claude.
        Where svn is there and cannot say, it counts as an svn that does not answer from then on."""
        if not self.svn:
            return {}
        code, out, err = self.svn_ask("info", "-R", "--xml", "--", CLAUDE)
        if code != 0:
            # svn names a path that it does not know by one of these numbers. Anything else is trouble.
            if os.path.lexists(self.root / CLAUDE) and not any(sign in err for sign in ("E155007", "E155010", "W155010", "E200009")):
                self.svn, self.svn_silent = None, " ".join(err.split()) or "no answer"
            return {}
        try:
            entries = list(ElementTree.fromstring(out.encode("utf-8")).iter("entry"))
        except ElementTree.ParseError as error:
            self.svn, self.svn_silent = None, "its answer could not be read: %s" % error
            return {}
        return {
            (entry.get("path") or "").replace("\\", "/"): (entry.findtext("wc-info/schedule") or "normal", entry.findtext("wc-info/depth") or "infinity")
            for entry in entries
        }

    def svn_ignores(self):
        """The rules of svn:ignore on .claude/skills, a folder that svn knows."""
        code, out, _ = self.svn_ask("propget", "svn:ignore", SKILLS)
        return [line.strip() for line in out.splitlines() if line.strip()] if code == 0 else []

    def svn_knows_more(self, rel, view, going=()):
        """Why a folder must stay although the disk shows nothing in it, or None. svn can know
        more in a folder than the disk holds: a file that is missing, a folder that this working
        copy leaves out, or one of which it holds a part only. To delete the folder in svn would
        take all of that out of the repository with the next commit."""
        if rel not in view:
            return None
        if view[rel][1] != "infinity":
            return "this working copy holds only a part of it (svn depth %s), so the repository may hold more in it" % view[rel][1]
        more = sorted(
            path
            for path, (schedule, _) in view.items()
            if path.startswith(rel + "/") and schedule != "delete" and path not in going and not any(path.startswith(gone + "/") for gone in going)
        )
        if not more:
            return None
        return "svn knows more in it than the disk holds: %s%s" % (", ".join(more[:3]), "" if len(more) <= 3 else " and %d more" % (len(more) - 3))

    def added_for_the_kit(self, rel, view):
        """True for a folder that svn has scheduled to be added and in which it knows nothing
        else that stays. The installer scheduled such a folder on the way to the kit's files (svn
        add --parents). With the kit gone, nothing is left that svn should add it for."""
        if view.get(rel, ("",))[0] != "add":
            return False
        return not any(path.startswith(rel + "/") and schedule != "delete" for path, (schedule, _) in view.items())

    def check_links(self):
        """Nothing is written or deleted through a link: a plan that would do so is a blocker."""
        touched = [entry["path"] for entry in self.planned("edit", "delete", "clean")]
        for rel in (CLAUDE, HOOKS):
            folder = self.root / rel
            if is_link(folder) and any(path.startswith(rel + "/") for path in touched):
                self.block(
                    "folder-is-link",
                    "%s is a link (to %s), and files of the bridge are behind it. The uninstaller never writes or deletes through a link."
                    % (rel, os.path.realpath(folder)),
                    "Remove the bridge by hand in the folder that the link leads to: %s says how." % BY_HAND,
                    path=rel,
                )
                return

    def load_bridge(self):
        """Read the bridge's scripts from the installing skill next to this one."""
        missing = []
        for kind, name in BRIDGE_SCRIPTS.items():
            try:
                self.bridge[kind] = lf((BRIDGE / name).read_bytes())
            except OSError:
                missing.append(name)
        if not missing and not (self.bridge["sh"].startswith(b"#!/bin/sh") and all(b"clean" in script for script in self.bridge.values())):
            missing.append("a file with the text it should have")
        if missing:
            self.block(
                "bridge-script-missing",
                "The copies in .claude/skills are deleted by the bridge's own script, which the uninstaller takes from the installing "
                "skill of the same plugin. It is not there: %s is missing in %s." % (", ".join(missing), BRIDGE),
                "Copy the whole plugin again from the agent-skills-bridge repository, both skill folders, then run the uninstaller "
                "again. Or delete the copies by hand: %s says how." % BY_HAND,
            )

    # -- changing the project ------------------------------------------------------------------------

    def apply(self):
        """Write and delete the kit's files. From here on the hooks of a session that is still
        running find no script, and do nothing."""
        for entry in self.plan:
            if entry.get("stray"):
                shutil.rmtree(self.root / entry["path"], ignore_errors=True)
        self.changes = Changes(self.root)
        try:
            for entry in self.changing():
                if entry["data"] is None:
                    self.changes.delete(entry["path"])
                else:
                    self.changes.write(entry["path"], entry["data"])
        except OSError as error:
            self.give_up(
                "write-failed",
                "Could not %s %s: %s." % ("delete" if entry["data"] is None else "write", entry["path"], error.strerror or error),
                "Free the file or the folder (is it open in a program, or read-only?), then run the uninstaller again.",
            )
        wrong = []
        for entry in self.changing():
            target = self.root / entry["path"]
            if entry["data"] is None and (target.exists() or is_link(target)):
                wrong.append("%s is still there." % entry["path"])
            elif entry["data"] is not None and self.read(entry["path"]) != entry["data"]:
                wrong.append("%s does not hold what was written." % entry["path"])
        if wrong:
            self.give_up("check-failed", "The files were changed, but a check of them failed: %s" % " ".join(wrong), "Repair what the message names, then run the uninstaller again.")

    def give_up(self, ident, message, fix, put_back=" Everything was put back as it was."):
        left = self.changes.undo()
        if left:
            kept = self.changes.backups_shown()  # None where no file was copied
            self.problem(message)
            self.problem("These files could not be put back as they were: %s.%s" % ("; ".join(left), " Their earlier versions are in %s." % kept if kept else ""))
            raise Blocked(False)
        self.block(ident, message + put_back, fix)
        raise Blocked(True)

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

    def environment(self):
        """The environment for the bridge's script: without ASB_CMD, which would make the run a
        hook's, and with a PATH that names absolute folders only and neither the project nor the
        working directory. The script finds git and svn by PATH, and the project is input."""
        environment = {key: value for key, value in os.environ.items() if key != "ASB_CMD"}
        avoided = (os.getcwd(), str(self.root))
        folders = [folder.strip('"') for folder in os.environ.get("PATH", "").split(os.pathsep)]
        environment["PATH"] = os.pathsep.join(
            folder for folder in folders if os.path.isabs(folder) and not any(same_folder(folder, input_folder) for input_folder in avoided)
        )
        return environment

    def clean(self):
        """Run the bridge's clean command, which deletes its copies and its records. The script
        lies in a folder of the project for this one run, because it takes the project from its
        own place."""
        kind, program = self.hook_shell()
        if not program:
            self.give_up(
                "no-shell",
                "No shell was found to run the bridge's clean command in, so its copies in .claude/skills were not deleted.",
                "Delete the copies by hand: %s says how. Then run the uninstaller again." % BY_HAND,
            )
        workshop = self.root / WORKSHOP
        script = workshop / ("clean.sh" if kind == "sh" else "clean.ps1")
        try:
            workshop.mkdir()
            script.write_bytes(self.bridge[kind])
            if kind == "sh":
                argv = [program, script.as_posix(), "clean"]
            else:
                argv = [program, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(script), "clean"]
            code, out, err = run(argv, cwd=str(self.root), timeout=CLEAN_TIMEOUT, env=self.environment())
        except OSError as error:
            code, out, err = None, "", "the bridge's script could not be put into %s: %s" % (WORKSHOP, error.strerror or error)
        finally:
            shutil.rmtree(workshop, ignore_errors=True)
        self.report["clean_shell"] = program
        self.report["clean"] = [line.rstrip() for line in out.splitlines() if line.strip()]
        if code != 0:
            self.give_up(
                "clean-failed",
                "The bridge's clean command did not delete its copies: %s." % (" ".join(err.split()).rstrip(".") or "exit code %s" % code),
                "Where the message names a file that is open, close it. Where it says that a sync is running or that git is at work, "
                "wait until that is done. Then run the uninstaller again.",
                " Everything else was put back as it was. Where the bridge is installed, the copies that the command had deleted by then "
                "come back with the next session.",
            )
        # What the bridge left alone because it is no longer its copy is for the user to know.
        for line in self.report["clean"]:
            said = line.partition("agent-skills bridge: ")[2]
            if said.startswith("left "):
                self.note("The bridge's clean command says: " + " ".join(said.split()))

    # -- svn, and the folders that are empty now -------------------------------------------------------

    def svn_ask(self, *arguments):
        code, out, err = run([self.svn, "--non-interactive", *arguments], cwd=str(self.root))
        return code, out, err.strip()

    def versioned(self, rel):
        """True when svn knows the path, also where the file is gone from the disk."""
        return self.svn is not None and self.svn_ask("info", rel)[0] == 0

    def svn_do(self, *arguments):
        """Take a step in svn, or name it in a dry run. False when svn refused."""
        line = "svn " + " ".join(arguments)
        if not self.args.dry_run:
            code, _, err = self.svn_ask(*arguments)
            if code != 0:
                self.problem("'%s' failed: %s" % (line, err or "no message"))
                return False
        self.report["vcs_steps"].append(line)
        return True

    def sweep(self):
        """Tell svn about the files that went, take away the folders that are empty now, and take
        the bridge's rule out of svn:ignore. Nothing is committed. A dry run names the steps."""
        self.swept = True
        dry = self.args.dry_run
        files = [entry["path"] for entry in self.changing() if entry["data"] is None]
        folders = [entry for entry in self.plan if entry.get("folder")]
        if self.is_svn and not self.svn:
            if files or folders:
                missing = (
                    "This is an svn working copy, but no svn is on PATH. Tell svn about the removal yourself: `svn delete` for each "
                    "file of the kit that svn knows, and `svn propdel svn:ignore .claude/skills`. The folders stay until then."
                )
                if dry:
                    self.note(missing)
                else:
                    self.problem(missing)
            for entry in folders:
                entry.update(action="keep", why="svn could not be asked whether it knows the folder")
            return
        refused = False  # svn refused a step: the report names it as a problem, and no further step is taken
        if self.svn:
            known = [rel for rel in files if self.versioned(rel)]
            refused = bool(known) and not self.svn_do("delete", "--force", "--", *known)
        for entry in folders:
            rel = entry["path"]
            folder = self.root / rel
            if refused:
                entry.update(action="keep", why="svn refused a step before it, so the folder is as it was")
                continue
            if not dry:
                try:
                    left = sorted(os.listdir(folder))
                except OSError:
                    continue  # gone already
                if left:
                    more = "" if len(left) <= 4 else " and %d more" % (len(left) - 4)
                    entry.update(action="keep", why="it still holds %s%s" % (", ".join(left[:4]), more))
                    continue
            if self.versioned(rel):
                refused = not self.svn_do("delete", "--force", "--", rel)
                if refused:
                    entry.update(action="keep", why="svn refused to delete it")
            elif not dry:
                try:
                    folder.rmdir()
                except OSError as error:
                    entry.update(action="keep", why="could not be deleted: %s" % (error.strerror or error))
        if self.svn and not refused:
            self.svn_ignore(folders)

    def svn_ignore(self, folders):
        """Where .claude/skills stays in svn, its svn:ignore loses the rule that the bridge needed.
        A value with rules of the project's own next to it is left as it is, and named."""
        if any(entry["path"] == SKILLS and entry["action"] == "delete" for entry in folders):
            return  # the folder goes, and its properties with it
        if is_link(self.root / SKILLS) or not (self.root / SKILLS).is_dir():
            return
        rules = self.svn_ignores() or []
        if rules == ["*"]:
            self.svn_do("propdel", "svn:ignore", SKILLS)
        elif "*" in rules:
            self.note(
                "svn:ignore on .claude/skills holds the rule * next to rules of the project's own (%s). The installer adds that rule for the "
                "bridge's copies where it is missing, so it may be the bridge's. The uninstaller left it: take it out with "
                "`svn propedit svn:ignore .claude/skills` if nothing else needs it." % ", ".join(rule for rule in rules if rule != "*")
            )

    # -- checking, and what is left to do -------------------------------------------------------------

    def verify(self):
        """What is still there of the bridge after the removal, as a list of findings."""
        wrong = []
        for rel in SETTINGS:
            raw = self.read(rel)
            try:
                if raw is not None and strip_hooks(json.loads(raw.decode("utf-8-sig")))[1]:
                    wrong.append("%s still holds a hook entry of the bridge." % rel)
            except ValueError:
                pass  # a file that cannot be read was a blocker, or does not name the bridge
        for rel in [rel for rel, _ in KIT_FILES] + [WORKSHOP]:
            if (self.root / rel).exists() or is_link(self.root / rel):
                wrong.append("%s is still there." % rel)
        if self.planned("clean") and (self.root / RECORDS).exists():
            wrong.append(
                "The bridge's records in %s are there again: a hook of a session that was running may have made the copies anew "
                "while the bridge was removed. Run the uninstaller again." % RECORDS
            )
        return wrong

    def name_leftovers(self):
        """Name the folders that still hold the mark of a copy. The bridge's clean command has
        named the ones it left alone; the others are in no record of the bridge."""
        said = " ".join(self.report["notes"])
        for name in self.find_marked():
            if ".claude/skills/%s alone" % name in said:
                continue
            self.note(
                ".claude/skills/%s holds the .gitignore of a copy that the bridge made, but the bridge's records do not name the folder, "
                "so it stays. If it is no skill of the user's, delete the folder. If it is, delete the .gitignore in it: that file hides "
                "the folder from git." % name
            )

    def next_steps(self):
        steps = self.report["next_steps"]
        message = "Remove agent-skills-bridge"
        if self.git:
            paths = [entry["path"] for entry in self.changing()]
            # ls-files names a path as it was asked for, from the project's folder. status would
            # name it from the top of the repository, which a project in a folder below is not.
            code, out, _ = self.ask_git("ls-files", "-z", "--modified", "--deleted", "--", *paths) if paths else (1, "", "")
            changed = set(out.split("\0")) if code == 0 else set()
            tracked = [path for path in paths if path in changed]
            if tracked:
                steps.append(
                    "The removal is not committed yet. Teammates lose the bridge with their next pull once it is: "
                    "`git add -u -- %s`, then `git commit -m \"%s\"`. The uninstaller commits nothing." % (" ".join(tracked), message)
                )
        if self.is_svn and self.report["vcs_steps"]:
            steps.append(
                "The removal is scheduled in svn, not committed. Review it with `svn status`, then commit, for example with the "
                "message \"%s\". The uninstaller commits nothing." % message
            )
        if self.linked:
            steps.append(
                "This folder is a linked git worktree. Claude desktop runs a worktree session with the hooks of the main checkout, so "
                "the bridge goes on working there until the main checkout has the removal: commit it on this branch and merge it."
            )
        if self.is_git or self.is_svn:
            steps.append(
                "Copies of the skills exist in every checkout of this project where a Claude Code session ran: on a teammate's machine, "
                "in another worktree. A pull or an update takes the kit away there, and the copies in .claude/skills stay, so Claude Code "
                "goes on loading them. Run this uninstaller in each such checkout too: it deletes the copies also where the kit is "
                "already gone."
            )
        if self.unguarded:
            # dash and BusyBox end with status 2 where `.` finds no file, and Claude Code reads
            # status 2 from the guard as its refusal. bash ends with 1 and zsh with 127, which
            # Claude Code only shows. So this step comes first, and says what is at stake.
            steps.insert(
                0,
                "Start a new Claude Code session in this project before anything else. The hook entries came from an older kit, whose "
                "commands start the script without looking for it first, and a session that was running still holds them. Without the "
                "script they fail, and where hooks run in dash or BusyBox, as on Debian, Ubuntu and Alpine, the guard then refuses "
                "every Write and Edit of that session.",
            )
        else:
            steps.append(
                "Start a new Claude Code session in this project. A session that was running still holds the bridge's hooks: they find "
                "no script now and do nothing, and where hooks run in PowerShell each of them prints an error first."
            )
        skills = self.root / ".agents" / "skills"
        try:
            there = skills.is_dir() and any((entry / "SKILL.md").is_file() for entry in skills.iterdir())
        except OSError:
            there = False
        if there:
            steps.append(
                "The skills in .agents/skills stay where they are, for the tools that read that folder. Claude Code no longer loads "
                "them: a skill that Claude Code should keep needs a copy of its own in .claude/skills/<name>."
            )

    # -- the whole run -------------------------------------------------------------------------------

    def uninstall(self):
        self.find_project()
        self.detect_vcs()
        for rel in SETTINGS:
            self.plan_settings(rel)
        self.plan_kit_files()
        self.plan_git_files()
        self.plan_copies()
        self.plan_gitignore()
        self.plan_folders()
        self.check_links()
        if self.planned("clean") and not self.report["blockers"]:
            self.load_bridge()
        if self.report["blockers"]:
            return self.finish("blocked", EXIT_BLOCKED)
        changed = bool(self.planned("edit", "delete", "clean"))
        if self.args.dry_run or not changed:
            if changed:
                self.sweep()  # names the steps that svn would be asked to take
            elif self.above is not None:
                self.note(
                    "%s is a folder inside the git repository %s, and nothing of the bridge is in it. If the bridge is installed in "
                    "the top folder, run the uninstaller there." % (self.root, self.above)
                )
            if not self.planned("clean"):  # else the clean command is still to decide what stays
                self.name_leftovers()
            return self.finish("would change" if changed else "not installed", EXIT_OK)
        try:
            self.apply()
            if self.planned("clean"):
                self.clean()
        except Blocked as blocked:
            put_back = blocked.args[0]
            return self.finish("blocked" if put_back else "incomplete", EXIT_BLOCKED if put_back else EXIT_INCOMPLETE)
        self.sweep()
        for finding in self.verify():
            self.problem(finding)
        self.name_leftovers()
        self.next_steps()
        if self.report["problems"]:
            return self.finish("incomplete", EXIT_INCOMPLETE)
        return self.finish("uninstalled", EXIT_OK)


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


class Arguments(argparse.ArgumentParser):
    """A parser that reports wrong arguments the way the uninstaller reports everything else: as a
    JSON object on stdout."""

    def error(self, message):
        print(render({"outcome": "wrong arguments", "message": message, "usage": " ".join(self.format_usage().split()[1:])}))
        sys.exit(EXIT_USAGE)


def main():
    for stream in (sys.stdout, sys.stderr):  # a pipe on Windows is not UTF-8 before Python 3.15
        if stream is not None:  # a stream that the caller closed
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = Arguments(
        description="Uninstall the agent-skills-bridge kit from a project: the bridge's hook entries, its scripts, the copies it "
        "made in .claude/skills and its records. Everything else in the project stays. Prints a JSON report on stdout and nothing "
        "on stderr. Never commits and never prompts. Started with a Python older than 3.11, it goes on with a newer one from PATH.",
        epilog=EXIT_CODES,
        allow_abbrev=False,
    )
    parser.color = False  # Python 3.14 and newer colour the help, even in a pipe where FORCE_COLOR is set
    parser.add_argument("--project", metavar="FOLDER", help="the project's top folder (default: the top folder of the git repository around the working directory, or the working directory itself)")
    parser.add_argument("--dry-run", action="store_true", help="report what would be removed, and change nothing")
    parser.add_argument(RESTORE_FLAG, action="store_true", help="where the installer rewrote the rule in the project's .gitignore that ignored the whole .claude folder, put that rule back; only after the user agreed")
    args = parser.parse_args()
    if args.project is not None and not Path(args.project).is_dir():
        hint = ""
        git_bash = re.fullmatch(r"/([A-Za-z])(/.*)?", args.project) if WINDOWS else None
        if '"' in args.project:
            # Windows PowerShell 5.1 hands over "C:\my project\" with the closing quote, and the
            # arguments after it, as part of the path.
            hint = " The value holds a quotation mark: write the path without a backslash at its end."
        elif git_bash:
            # Git Bash turns /c/Users/... into C:/Users/... before it starts a Windows program.
            # PowerShell and cmd hand the path over as it is.
            hint = " That is Git Bash's spelling of a path: outside Git Bash, write %s:%s." % (git_bash.group(1).upper(), git_bash.group(2) or "/")
        parser.error("--project: %s is not a folder.%s" % (args.project, hint))
    os.environ["NoDefaultCurrentDirectoryInExePath"] = "1"  # Windows: do not look for programs in "."
    started_by = os.environ.pop(STARTED_BY, "")

    uninstaller = Uninstaller(args)
    if re.fullmatch(r"\d+\.\d+\.\d+", started_by):
        uninstaller.note(
            "Python %s started the uninstaller, which needs Python %d.%d or newer. It went on with Python %d.%d.%d (%s)."
            % ((started_by,) + NEEDS + tuple(sys.version_info[:3]) + (sys.executable,))
        )
    try:
        code = uninstaller.uninstall()
    except Exception as error:  # the report must say what state the project is in, whatever happened
        changes = uninstaller.changes
        if changes is not None and changes.done and not uninstaller.swept:
            changes.undo()
        left = changes.left if changes is not None else []  # also from an undo before the failure
        message = "The uninstaller failed: %s: %s." % (type(error).__name__, error)
        if left or uninstaller.swept:
            uninstaller.problem(message + " The project may be changed in part.")
            code = uninstaller.finish("incomplete", EXIT_INCOMPLETE)
        else:
            uninstaller.block("uninstaller-failed", message + " Nothing of the kit was removed.", "Report this to the kit's maintainer.")
            code = uninstaller.finish("blocked", EXIT_BLOCKED)
    print(render(uninstaller.report))
    return code


if __name__ == "__main__":
    sys.exit(main())
