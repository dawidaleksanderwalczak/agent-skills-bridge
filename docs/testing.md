# Testing

Two test files cover this repository. Both build throwaway projects in the temp folder and delete
them again.

| File | What it tests | Run it with |
|---|---|---|
| [`tests/agent-skills-bridge.test.sh`](../tests/agent-skills-bridge.test.sh) | The bridge: both scripts, through the hook commands of the kit's `settings.json` | `sh tests/agent-skills-bridge.test.sh`, and the same with `ps1` |
| [`tests/test_install_bridge.py`](../tests/test_install_bridge.py) | The plugin and its installer skill: the manifests, the skill folder, and the installer in git, svn and plain projects | `python3 tests/test_install_bridge.py` |

To check a real Claude Code session by hand, follow the
[manual test](../plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit/hooks/agent-skills-bridge.md#manual-test)
in the kit's documentation.

## The bridge

```sh
sh tests/agent-skills-bridge.test.sh        # the sh bridge, in any POSIX shell
sh tests/agent-skills-bridge.test.sh ps1    # the PowerShell bridge (Git Bash on Windows)
ASB_TEST_SHELL=zsh sh tests/agent-skills-bridge.test.sh   # the sh bridge, hooks run in zsh
```

- `ASB_TEST_SHELL` names the shell that runs the hook commands (default: `sh`).
- `ASB_TEST_POWERSHELL` names the PowerShell for `ps1` (default: `powershell.exe`), for example
  `pwsh.exe`.
- `ASB_TEST_KIT` names the kit under test (default: the skill's `assets/kit` folder). With it, the
  tests of today run against the scripts of another commit.

The tests run the exact commands from the kit's `settings.json`, the way Claude Code runs them.
They cover:

- the first sync, source edits, removals, conflicts and repairs;
- a sync with nothing to do, which must start no program;
- the guard: the four editing tools, one copy and two, relative paths, `.` and `..`, other letter
  cases, the Git Bash and network spellings, and events with blanks in their JSON;
- links, junctions and link loops in a skill, links to nowhere, a junction up to the repository, a
  junction to a junction, and a junction or a read-only folder that someone put into a copy;
- a copy that cannot be replaced or deleted, and a file that cannot be copied at first and can
  later;
- hooks whose script is missing, and a skill folder with a name the bridge cannot use;
- an edit that lands while a sync is running;
- a sync that is killed: midway, after it made a new copy, before a copy has its `.gitignore`, and
  after it could not replace a copy;
- a sync that cannot write its stamp, and one whose manifest does not arrive;
- a session that starts while another sync makes a new copy;
- what a killed sync of the PowerShell twin leaves in the records;
- `clean` after a first sync that left no manifest, because it was killed or because its manifest
  did not arrive;
- a skill of your own that takes the place of a copy: put there by git, when you check out a branch
  that tracks it in `.claude/skills`, or moved there by hand, each with `sync` and with `clean`;
- the cases next to it: a branch that has the skill in both places, a git that is at work, a git
  that fails, a folder that git tracks under a name in another letter case, a skill that a file
  manager moves over its copy, a copy whose `SKILL.md` was changed before its skill went, a copy
  that only gained a file, and a file or an empty folder in the place of a copy;
- the way back to the branch that has the skill in `.agents/skills`, where the copy is made again;
- a sync that finds a skill of your own and is killed, records that the scripts of before left
  unfinished, and records that were lost;
- a skill with a file and a folder dated ahead of the clock: copied once, and again when something
  next to them changes or one of them comes with a later time;
- a stale lock and the off switch;
- `status` and `clean`;
- paths with spaces, with a letter outside ASCII, and network paths;
- files saved with CRLF, read-only folders, `CDPATH`, and zsh with an alias and an option from
  `.zshenv`;
- in git: an existing `.claude/skills` with its own skill and `.gitignore`, a copy that someone
  added to git, a copy that lost its `.gitignore`, and a clone with `core.autocrlf=true`;
- in svn: `svn:ignore`, a skill of your own, and a changed copy that someone added to svn.

A case that needs something the system lacks is skipped, and the test says so: symlinks and file
modes on Windows, junctions and network paths elsewhere, git, svn or node where they are missing.

Results on 26 November 2026:

| System | Shell | Result |
|---|---|---|
| Windows 11 | Git Bash (bash 5.3 as `sh`) | 313/313; Windows has no symlinks for the link cases |
| Windows 11 | Windows PowerShell 5.1 | 310/310 |
| Ubuntu 24.04 (WSL) | dash 0.5.12 | 296/296 |
| Ubuntu 24.04 (WSL) | bash 5.2 as `sh` | 296/296 |
| Ubuntu 24.04 (WSL) | zsh 5.9 as `sh` | 296/296 |
| Ubuntu 24.04 (WSL) | zsh 5.9 as the hook shell | 298/298 |
| Alpine 3.24 (container) | BusyBox 1.37 `ash` and tools | 242/242; no git, svn or node there |

The same day the kit moved into the installer skill's `assets/kit` folder, and this test file into
`tests/`. The scripts did not change. Run again from the new places, the suite gave the same
counts in Git Bash, Windows PowerShell 5.1, dash and BusyBox.

On 27 November 2026 the skill folder moved into the plugin folder, `plugins/agent-skills-bridge`.
The scripts did not change this time either, and the suite again gave the same counts in those
four shells: 313, 310, 296 and 242.

Run against the scripts as they were before the review of 25 November 2026, the tests of that review
failed in 39 places in dash, 66 with zsh as the hook shell and 27 in Windows PowerShell. The test
for an edit that lands while a sync is running came a day later. It fails against the scripts of
that review, in dash, BusyBox and Windows PowerShell, and passes now. The tests for a copy that is
not yet in the manifest came the same day: a sync that is killed after it made a new copy, and a
session that starts while another sync is copying. Against the scripts as they were until then, 19
checks fail in dash, 21 in BusyBox and 14 in Windows PowerShell. Two more tests followed: a sync
that could not replace a copy and is killed before it deletes its stamp, and the files that a killed
sync of the PowerShell twin leaves in the records. Against the scripts of the step before, 3 checks
fail in dash and in BusyBox, and 2 in Windows PowerShell.

The same was checked with real processes, in dash on Ubuntu: one process edited 600 skills, about
one edit a millisecond, while two others ran sync after sync. When the edits stopped, one more sync
had to bring every copy up to date. With the scripts of that review, 36, 78 and 30 copies stayed out
of date in three rounds. With the scripts as they are now, none did.

The two scripts share their records, so they were also checked by hand on one checkout, on Windows.
A sync of the shell script was killed after it had made a new copy, and the PowerShell twin took
over; then the other way round. Each finished the other's work and reported no conflict. Both read
the records that the scripts of before wrote, and those scripts read the new records.

A second review on 26 November 2026 added more checks. Run against the kit as it was before that
review, 8 of them fail in dash, 10 with zsh as the hook shell and 17 in Windows PowerShell.
[overview.md](overview.md) lists what that review found, and what it left open.

That review and the work on the records were done side by side, and both changed how `clean`
begins. When the two were brought together, one more test came: `clean` after a first sync that
left no manifest. Against the scripts of the second review alone, 5 of its 12 checks fail, and 6
against the scripts from before both. The numbers are the same in all seven environments above.

The tests for a skill of your own in the place of a copy came the same day: a branch that tracks
the skill in `.claude/skills`, a move by hand, `clean` in both states, and a sync that is killed
when it has just found such a skill. Against the scripts as they were until then, 40 checks fail in
dash, with zsh as the hook shell and in Windows PowerShell, and 20 in BusyBox, which has no git and
no svn. The two scripts were checked again on one checkout, and against each other's records of
before, with checks of their own. A sync and a `clean` of the shell script were also killed after
every line that they pass through, 548 times in all: each time the next sync left your own skills
where they were and finished the work. A sync still starts 7 programs to copy and 4 to
delete, and a hook with nothing to do starts none. [overview.md](overview.md) says where the line runs
between an edited copy and a skill of your own, and why.

One more test followed: a skill that holds a file dated ahead of the clock. Such a skill was copied
again at every hook, with 7 programs each time. Now a sync that copies it starts 8, and the hooks
after it start none. Against the scripts of before, 4 of the 9 checks fail in dash, with zsh as the
hook shell, in BusyBox and in Windows PowerShell.

A manual check from cmd.exe on Windows 11 also passed, in a repository whose path has a space:

- the PowerShell twin's `sync`, `status` and `clean`, from the repository and from another folder;
- `status` through Git's `sh.exe`, called by its full path;
- the SessionStart and guard hook commands in Git Bash and in PowerShell, with cmd's environment;
- the rule Claude Code uses to find Git Bash, applied in cmd: it found a per-user Git install
  through PATH.

Not run yet:

- **macOS.** The shell script avoids what the macOS `sh` (bash 3.2) lacks or does differently. It
  never expands an empty `"$@"`, which bash 3.2 rejects under `set -u`. It also copes with file times
  in whole seconds, as the BusyBox run shows, and with zsh as the hook shell, as the Ubuntu run shows.
  It has not run on a Mac.
- **PowerShell 7.** The `.ps1` is written for it, but this machine has no `pwsh`. Where there is one,
  run `ASB_TEST_POWERSHELL=pwsh.exe sh tests/agent-skills-bridge.test.sh ps1`.
- **A repository inside a OneDrive folder.** There Windows marks plain files and folders the way it
  marks links. The PowerShell twin tells them apart by the link type, which was checked against a
  OneDrive folder, but no sync has run inside one.
- **The manual test, end to end in a live session.** Its commands and expected `status` outputs
  were dry-run on Windows, with the hooks run the way Claude Code runs them.

The hooks were also checked live in Claude Code 2.1.330 (Claude desktop on Windows 11), in throwaway
repositories, with the previous layout. That layout kept the ignore rule in `.claude/skills/.gitignore`.
The hook commands are the same today. The scripts have changed since, in the review of 25 November
2026: how they walk folders, read the guard's event and report a sync that could not finish. A day
later the time stamp of a sync moved to before its look at the skills, a sync began to put its
copies on record before it makes them, and the bridge began to make sure that a folder is still its
copy before it deletes or replaces it.

- **Session start.** The skill was in Claude's list from the first prompt. The first sync took 6.8 s
  on a machine where security software makes each process start cost most of a second. A sync with
  nothing to do takes about half a second.
- **Live sync.** A source edit reached the copy in 1.3 s, and the same session then used the new
  version. A deleted skill's copy was gone in 1.5 s.
- **Guard.** An Edit of a copy was refused with the bridge's message.
- **Desktop worktree.** The hooks, the copy and the watch all came from the main checkout, as the
  kit's documentation describes under "Claude desktop worktree sessions".

The guard's separate Write entry was added after the live check found the gap, and MultiEdit joined
it after the review of 25 November 2026. Both are covered by the tests here, but have not yet been
run live. Claude Code's skill loader skips a folder without
`SKILL.md` silently, so the record folder is never mistaken for a skill (read in the 2.1.330 program).

## The plugin and the installer skill

```sh
python3 tests/test_install_bridge.py        # Windows: py -3.11 tests\test_install_bridge.py
```

The tests need Python 3.11 or newer and git. They start the installer the way the skill does, as a
program of its own, and look at its exit code, its report and what it left on disk. Every run
must leave stderr empty. A few of its functions are also loaded and called by themselves: the
search for another Python on PATH, and the runner for git, svn and the bridge's `status`. git
reads no configuration of the user's while the tests run, and the installer's backups go to the
tests' own temp folder. They cover:

- **the plugin:** the marketplace file and the plugin's manifest (the same name in both, a source
  path that leads to the plugin folder, what users see, no version, no mail address), the files
  that the plugin folder may hold, so that it brings the one skill and no hook, command, agent or
  server, and the install line and the command in both READMEs. Where the `claude` command is
  installed, one test runs `claude plugin validate` on the repository and on the plugin folder,
  with a configuration folder of its own;
- **the skill folder:** the frontmatter against the Agent Skills specification (the name, the
  lengths, no reserved word), the two switches that leave the start to the user, the files that
  the folder may hold, the kit's scripts being ASCII, and the installer importing the standard
  library only;
- **a first installation:** a new git repository, a second run that changes nothing, a dry run, a
  run from a subfolder, a named subfolder, a folder without version control, a folder name with a
  space and a letter outside ASCII, and a linked worktree;
- **`settings.json`:** own settings and hooks that stay, with their indentation, CRLF, byte order
  mark and letters outside ASCII; hook entries of an older kit; a doubled entry; an empty file; and
  the files that the installer must not touch: comments, a key twice, a wrong shape, bytes that are
  not UTF-8;
- **the kit's files:** a changed script, a shell script with CRLF, a checkout made with
  `core.autocrlf=true`, an own `.gitattributes` and anchor, and other files in the same folders;
- **what stops it with nothing changed:** a file in the place of a folder and the other way round,
  `.claude/skills` and `.claude` as a link (a junction on Windows), and a file that cannot be
  written, after which every file written before it is gone again;
- **a `.gitignore` that hides `.claude`:** the stop, the rewrite once the flag is given, what
  stays ignored afterwards, the rules that it must not rewrite, a project below the top folder of
  its repository, and a second rule that still hides the kit, after which everything is put back;
- **svn:** the scheduled files, the two properties, an `svn:ignore` value that was there, files of
  the user's that must not be scheduled, and a dry run;
- **the installed kit at work:** the session hook and both guard entries from the installed
  `settings.json`, run in the shell that Claude Code uses and in Windows PowerShell, and what the
  bridge's `status` finds wrong turning up in the report's notes;
- **the command line:** wrong arguments, which come as a report like everything else; the
  quotation mark that Windows PowerShell 5.1 leaves in a path that ends with a backslash; a
  project in Git Bash's spelling, `/c/Users/...`, outside Git Bash; a slash at the end of the
  project's path; the help, which must hold no colour codes where Python 3.14 is told to force
  them; and a run in Windows PowerShell 5.1 with `2>&1` and `$ErrorActionPreference = 'Stop'`,
  which must see the success;
- **a Python older than 3.11:** the file must read as Python 3.7; the Pythons on PATH come best
  first, and a folder that is input is never searched; a name that starts nothing is passed over,
  and so is a Python that is built for another system; the installer goes on with a newer Python
  and says so in a note; without a newer one it says so, with exit code 4, and changes nothing;
  and it takes no Python from the project or the working directory, also where PATH names them
  through a link. Where the machine has an older Python, the oldest one starts the installer.
  Where it has none, outside Windows, the Python that runs the tests plays it: it is told that it
  is Python 3.9 before the installer starts, and what it then finds on PATH and starts is real;
- **a program that hangs:** one that does not answer and has started a second one, which holds
  the same pipes, and one that has ended and left such a second one behind. The wait must end
  with the time limit. On Windows the second one must be gone too, also where it is the `sleep`
  of a script in Git Bash, which no parent leads to, and the program must still run and be ended
  on a Windows that gives the installer no job;
- **where git, svn and the shells are looked for:** a program of that name in the project is not
  taken and hides nothing, whether PATH names the project as it is, through a link, or by an
  entry that counts from the working directory;
- **a run that cannot put its files back:** it ends as incomplete, also where every file was new
  and no earlier version was kept.

Results on 27 November 2026, after the portability review of the installer
([overview.md](overview.md), section 8):

| System | Python | Result |
|---|---|---|
| Windows 11, git 2.54, svn from TortoiseSVN, Claude Code 2.1.332, Windows PowerShell 5.1, Git Bash | 3.11.9 | 78/78; the older Python is 3.10.20 |
| The same | 3.14.5 | 78/78 |
| Ubuntu 24.04 (WSL), git 2.43, svn 1.14 | 3.12.3 | 72 passed, 6 skipped: the five cases that are about Windows, and no `claude` command there. Python 3.12 plays the older Python |
| The same, as root | 3.12.3 | 71 passed, 7 skipped: those six, and the file that cannot be written, which root can write |

Before that review, the same day, the counts were 59/59 on Windows with both Pythons, and 56
passed with 3 skipped in WSL. The day before, without the eight plugin tests, they were 51/51 and
49 passed with 2 skipped.

The review added 20 tests, which take the place of one older test, and changed one more. Run
against the installer as it was before the review, 19 of these 21 fail on Windows. In WSL 13
fail: four cases that are about Windows are skipped there, and the two about a program that
hangs pass, because outside Windows that installer came back in time. The older tests fail
against it as well, for one reason: every run now has to leave stderr empty, and that installer
closed each run with a line on stderr. On Windows each of the three tests for a program that
hangs takes two minutes against that installer, which is the wait that the review had to end:
the installer came back after 120 seconds from a program with a time limit of 10.

### The plugin in Claude Code

`claude plugin validate .` is Claude Code's own check of the marketplace file, the plugin's manifest
and the skill. It reports one warning here, "No version specified". That is intended: without a
version, Claude Code takes the commit as the plugin's version (see "Update" in the README).

On 27 November 2026 the plugin was also installed with Claude Code 2.1.332 on Windows 11. Every
command ran with `CLAUDE_CONFIG_DIR` set to a scratch folder, so the machine's own Claude settings
and plugins stayed as they were.

| Check | Result |
|---|---|
| `claude plugin validate` on the repository and on the plugin folder | Passed, with the one warning above. It names the skill as `agent-skills-bridge:installing-agent-skills-bridge`. |
| `claude plugin marketplace add` with the local folder, `claude plugin install agent-skills-bridge@agent-skills-bridge`, `claude plugin details` | Installed. One skill, no agent, no hook, no MCP or LSP server. |
| The same from a git address: a copy of the repository as a bare clone, served through `git http-backend` on the same machine | Claude Code cloned the marketplace and copied the plugin folder into its cache: 11 files, the kit's `.gitattributes` and `.gitignore` among them. The plugin's version was the commit. |
| The installer, started from that cache copy in a new git repository | Exit code 0, the kit installed and verified. The clone had CRLF in the kit's `.ps1`, `.md` and `.json` files (`core.autocrlf=true`); the project got LF. |
| A headless session (`claude -p`) with the plugin installed, and one with `--plugin-dir` | Both list the plugin and the command `agent-skills-bridge:installing-agent-skills-bridge`. |
| `claude plugin marketplace remove agent-skills-bridge` | Removed the marketplace and the plugin. |

### Trial runs with fresh agents

The skill's text was tried on two agents that had nothing but `SKILL.md` and a throwaway git
project. Each was told that the user had typed `/installing-agent-skills-bridge`, and nothing else.

| Model | Project | What the agent did |
|---|---|---|
| Claude Haiku 5.5 | One skill in `.agents/skills`, an own `.claude/settings.json` | Ran the installer once, got exit code 0, and reported each file, the backup folder and the next steps. It committed nothing. |
| Claude Sonnet 5.5 | A `.gitignore` that ignores `.claude/` | Ran the installer once, got exit code 1, stopped, and asked whether the rule may be rewritten. It did not add the flag by itself. |

In both runs `${CLAUDE_SKILL_DIR}` was not filled in, as in a tool other than Claude Code. Both
agents then used the folder of `SKILL.md`, as the skill says. Both asked what to do with the
`status` lines of the report. Since then the installer turns what matters in them into notes, and
the skill says so.

The portability review of 27 November 2026 rewrote steps 1 and 2 of the skill, so both trials were
repeated that day with the new text, one in each shell, in projects like the two above.

| Model | Shell | What the agent did |
|---|---|---|
| Claude Haiku | Windows PowerShell 5.1; the project's path has two spaces | Ran the installer once. Its shell tool shows no exit code for a success, so the agent went by the report's outcome, `installed`. It reported each file and the next steps, and committed nothing. |
| Claude Sonnet | Git Bash | Ran the installer once, got exit code 1 with the outcome `blocked`, stopped, and asked whether the rule may be rewritten. It did not add the flag by itself. |

Each agent ran the one command line as the skill writes it, with nothing behind it. What they left
on disk was looked at afterwards: in the first project the kit is installed, the own settings are
kept and nothing is committed, and the second project is untouched.

Not run yet:

- **The skill in a live Claude Code session.** The headless sessions above list the plugin's
  command, so Claude Code 2.1.332 reads the plugin and the frontmatter. They could go no further,
  because the CLI's login had expired. Add the plugin and type
  `/agent-skills-bridge:installing-agent-skills-bridge` once in a real session.
- **The plugin from GitHub.** The git address in the table is a copy on the test machine. The
  install from `dawidaleksanderwalczak/agent-skills-bridge` works once the plugin is on the default
  branch there.
- **The plugin browser of the desktop app.** The plugin was installed with the `claude` command only.
- **The installer on macOS.** It uses nothing that Linux does not have. Apple's command line tools
  install Python 3.9.6 as `python3`. On a Mac with a newer Python on PATH as well, from Homebrew
  for example, the installer has to go on with that one, which the tests check on Linux and
  Windows. On a Mac without one, it has to answer `python too old`.
- **A Python from 3.6 to 3.9 as the one that starts the installer.** The part of the script that
  such a Python runs keeps to what Python 3.6 knows. It ran with Python 3.10 on Windows, and on
  Linux with a Python 3.12 that was told it is 3.9. No interpreter that old was at hand.
- **Python 3.13, and Python 3.12 on Windows.** The installer ran with 3.11 and 3.14 on Windows and
  with 3.12 on Linux.
- **A Python from the Microsoft Store.** It keeps what it writes below `AppData`, the temp folder
  included, in a place of its own. For that reason the report names the backup folder by its real
  path, as the Python documentation recommends. No such Python was at hand to try it.
- **PowerShell 7 as the shell that starts the installer.** This machine has no `pwsh`, so the two
  cases that came from Windows PowerShell 5.1, the redirected stderr and the path that ends with
  a backslash, were not tried there.
- **Codex and ChatGPT** with `agents/openai.yaml`.
