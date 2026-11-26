# Agent Skills Bridge: sharing `.agents/skills` with Claude Code

## 1. Summary

Each repository may have one set of project-specific Agent Skills that every AI coding tool on
every developer machine can use. The tool-neutral place for them is `.agents/skills/`.
Codex, GitHub Copilot, Cursor, JetBrains Junie and OpenCode read that folder directly. **Claude Code
does not.** It loads project skills only from `.claude/skills`. That was checked in the Claude Code
2.1.330 program, and no release note up to 2.1.332 changes it. The feature request,
[anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005), is still
open.

The **Agent Skills Bridge** closes the gap from inside Claude Code. Three hooks, committed in
`.claude/settings.json`, do the work:

- they copy every skill from `.agents/skills` to `.claude/skills` as read-only copies that version
  control ignores;
- they keep those copies in sync while people work;
- they stop Claude from editing a copy by mistake.

Developers install nothing and run nothing. A POSIX shell script and a PowerShell twin cover Windows,
macOS and Linux, in git and in svn. The kit works next to an existing `.claude` folder: its own
settings, hooks and Claude-only skills stay as they are.

**Verification:**
- The automated tests pass on these platforms:
  - Windows 11: Git Bash, and Windows PowerShell 5.1.
  - Ubuntu 24.04: dash, bash and zsh, each used as `sh`.
  - Alpine: BusyBox.
- The tests include git and svn repositories that already have a `.claude` folder.
- The hooks were observed working in live Claude Code 2.1.330 sessions.
- A check from `cmd.exe` confirmed that Claude Code never runs hooks in cmd, and that the kit works for
  people who work in cmd.

---

## 2. Problem and requirements

### Which tool reads which folder (November 2026)

| Tool | Reads `.agents/skills` | Reads `.claude/skills` |
|---|---|---|
| **Claude Code** (CLI, desktop, IDE) | **no** | yes: its only project location |
| OpenAI Codex (CLI, IDE) | yes | no |
| GitHub Copilot (CLI, VS Code, cloud agent) | yes | yes; for the same name, `.agents` wins |
| Cursor (IDE, `cursor-agent`) | yes | yes; both copies are listed |
| JetBrains Junie | yes | no |
| OpenCode | yes | yes; 2.x prefers `.agents`, 1.x lists both with a warning |

### Requirements

- **One source of truth.** Skills live in the repository and are reviewed like code.
- **Every environment.** Windows, macOS and Linux; git and svn; Claude Code in the desktop app and
  in a terminal, whichever shell that terminal runs (cmd, PowerShell, Git Bash, zsh and so on).
- **Fits existing repositories.** It works next to an existing `.claude` folder with its own
  settings, hooks, ignore rules and Claude-only skills.
- **No setup per person.** Nothing to install or remember, not even after a pull or update.
- **No fragile mechanisms.** No symlinks (they need privileges on Windows and break in version
  control), and no generated files in version control.
- **Safe.** It never overwrites or deletes someone's work, and a failure never blocks a session or an
  edit.
- **Cheap.** It can run at every session start, including on Windows machines whose security software
  makes every process start slow.
- **Removable.** Easy to take out once Claude Code reads `.agents/skills` itself.

---

## 3. Solution at a glance

```mermaid
flowchart LR
    subgraph repo["Repository, git or svn"]
        SRC[".agents/skills/skill-name/<br/>source of truth, committed"]
        CFG[".claude/settings.json<br/>3 hooks, committed"]
        SCR[".claude/hooks/agent-skills-bridge.sh / .ps1"]
        DST[".claude/skills/skill-name/<br/>generated copy, read-only, ignores itself"]
    end
    OTHERS["Codex, Copilot, Cursor,<br/>Junie, OpenCode"] -->|read directly| SRC
    CC["Claude Code"] -->|runs hooks from| CFG
    CFG --> SCR
    SCR -->|copies at session start and on every change| DST
    SCR -.->|reads| SRC
    CC -->|loads skills from| DST
```

- **Source.** People edit skills only in `.agents/skills/<name>/`.
- **Copy.** `.claude/skills/<name>/` is generated, read-only and recorded in a manifest. It carries
  its own `.gitignore` (`*`), so git ignores it whatever else is in `.claude/skills`.
- **Trigger.** Claude Code's own hooks. There are no git hooks, build steps or installers. The copies
  exist only on machines where Claude Code runs.

---

## 4. How it works

### 4.1 Lifecycle

| When | Hook | What the bridge does |
|---|---|---|
| A session starts (also on resume, `/clear` and compaction) | `SessionStart` | Copies new and changed skills and deletes the copies of removed ones. Then it tells Claude Code to reload skills (`reloadSkills`) and to watch `.agents/skills` (`watchPaths`). Skills are available from the first prompt. |
| A file under `.agents/skills` changes, whether Claude, an IDE, `git pull` or `svn update` changed it | `FileChanged` | Syncs again. Claude Code's skill watcher picks up the new copy within seconds. |
| Claude tries to edit a file in `.claude/skills` | `PreToolUse` | Refuses the edit if the file belongs to a copy, and names the source file to change instead. |

### 4.2 Components

| Path | In version control | Role |
|---|---|---|
| `.agents/skills/<name>/` | yes | The skills, and the only copy anyone edits |
| `.claude/settings.json` | yes | The hooks: `SessionStart`, `FileChanged`, and `PreToolUse` in two entries |
| `.claude/hooks/agent-skills-bridge.sh` | yes | The bridge, in POSIX `sh`, for macOS, Linux and Windows with Git Bash |
| `.claude/hooks/agent-skills-bridge.ps1` | yes | The same bridge for Windows without Git Bash, in PowerShell 5.1 or 7, and the way to run the bridge by hand in cmd or PowerShell |
| `.claude/hooks/agent-skills-bridge.test.sh` | yes | Scenario tests for both implementations |
| `.claude/hooks/agent-skills-bridge.md` | yes | Documentation for maintainers and users |
| `.claude/hooks/.gitattributes` | yes (git) | Keeps the shell scripts LF in every git checkout |
| `.claude/skills/.gitignore` | yes (git) | The **anchor**. It keeps the folder in every checkout and contains only comments |
| `svn:ignore *` on `.claude/skills` | yes (svn) | Keeps the copies out of svn; svn reads no `.gitignore` |
| `.claude/skills/<name>/` | no, ignored | Generated copies, each with its own `.gitignore` |
| `.claude/skills/.agent-skills-bridge/` | no, ignored | The bridge's records (manifest, stamp, lock); the folder ignores itself |

### 4.3 One hook command for every shell

Claude Code runs hooks in `/bin/sh` on macOS and Linux, and in Git Bash on Windows. On Windows
without Git Bash it runs them in PowerShell. It never runs them in `cmd.exe`, and it chooses the shell
itself, so the terminal someone starts it from doesn't matter. Every hook therefore uses a single
command that is valid in both shell families:

```text
set \' ; test -r "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh" || exit 0 ; ASB_CMD=session . "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh" ; exit ; #' ; & "$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1" session ; exit $LASTEXITCODE
```

- **POSIX shell.** `\'` is a literal quote. The shell sources the script and exits, and the rest is a
  comment. Should the hook shell be zsh, the script puts it into `sh` emulation first.
- **A hook without its script does nothing.** `test -r ... || exit 0` comes first, because dash and
  BusyBox `ash` end with status 2 when `.` finds no file, and Claude Code reads status 2 from a
  `PreToolUse` hook as a refusal.
- **PowerShell.** `\'...#'` is one quoted argument to `Set-Variable`, so the POSIX half is inert.
  PowerShell runs the `.ps1` file and passes its exit code on.
- **cmd.exe.** A hook's `shell` setting accepts only `bash` and `powershell`, and
  `CLAUDE_CODE_SHELL` and `CLAUDE_CODE_GIT_BASH_PATH` accept only bash, zsh or sh. Claude Code looks
  for Git Bash in `CLAUDE_CODE_GIT_BASH_PATH`, then in the standard Git folders, then in the Git
  installation of the `git` on PATH.
- **Tested** the way Claude Code spawns each shell, including stdin, exit code 2 and paths with
  spaces. The shells: Git Bash, Windows PowerShell 5.1, dash, bash and zsh as `sh`, zsh under its own
  name, and BusyBox `ash`. The hook commands were also run from `cmd.exe` (section 8).

### 4.4 Safety properties

- **It touches only its own copies.** A manifest records what the bridge created. A skill that already
  exists in `.claude/skills` is reported as a conflict and never overwritten.
- **It never writes through a link.** If `.claude/skills` or a copy is a symlink or a Windows junction,
  the bridge leaves it alone or unlinks it without following it. This matters on Windows, where
  PowerShell 5.1's `Remove-Item -Recurse` and some Java tools delete *through* junctions.
- **Copies are read-only and self-healing.** A copy that was edited or deleted is restored at the next
  sync. That includes a copy whose `.gitignore` was deleted.
- **Links in a skill are followed.** A copy holds plain files and folders. A link to nowhere, a link
  loop or a file that cannot be read is left out and reported, and the rest of the skill is copied.
  A file that is there but could not be read keeps the sync unfinished until it can be. For a loop
  the shell script relies on `cp`: GNU `cp` leaves it out, BusyBox `cp` follows it 40 folders deep.
- **An unfinished sync never passes for current.** If a copy cannot be replaced or deleted, for
  example because a program holds one of its files open, the bridge says so and the next hook tries
  again. The same holds for a sync that was killed midway.
- **An edit during a sync is not lost.** Each sync writes its time stamp before it looks at the
  skills, and the next sync copies every skill that holds a file changed at or after that stamp. A
  file that changes while a sync is running, for example during a `git pull`, is copied by the next
  hook.
- **Edits are redirected.** The guard refuses Claude's edits to a copy and names the source file. It
  knows the usual spellings of a path: relative, with `.` and `..`, in another letter case, and the
  Git Bash and network forms.
- **Concurrent runs are safe.** A lock serialises them. A lock left by a killed run expires after two
  minutes.
- **It fails open.** A broken bridge never blocks a session or an edit, and a hook whose script is
  missing does nothing. Problems reach the user as a one-line message. One case is out of the
  bridge's hands: a shell script saved with CRLF makes the shell itself end with status 2, and
  Claude Code then refuses every Write until the line endings are repaired.
- **Kill switch.** `AGENT_SKILLS_BRIDGE=off` turns the hooks into no-ops.
- **Nothing gets committed by accident.**
  - git: each copy and the record folder carry their own `.gitignore`. Git ignores them whatever
    other ignore rules say, in fresh clones and worktrees too.
  - The bridge never edits a `.gitignore` that it didn't write.
  - svn: `svn:ignore` on `.claude/skills` does the same.
  - `status` asks git or svn directly whether the copies are really ignored.

### 4.5 Performance

- **Nothing changed** (the common case). Beyond the shell Claude Code opens for the hook, no process
  starts at all. That costs about 0.5 s on a Windows machine where security software makes each
  process start take 0.3 to 1 s, and milliseconds on Linux and macOS.
- **Something changed.** About seven processes, whatever the number of skills, because the copy runs
  as one batch. The first sync of a new checkout took 6.8 s on that slow Windows machine.
- **The guard.** For Edit, Claude Code's `if` filter skips it for every file outside `.claude/skills`.
  A hook's `if` holds one rule, and that rule matches only the Edit tool. So for Write, NotebookEdit
  and MultiEdit the guard starts on each call and exits at once, without starting a program of its
  own.

---

## 5. Support matrix

| Environment | How the bridge runs | Status |
|---|---|---|
| Windows with Git Bash | `sh` script in Git Bash | tests pass; live-checked in Claude desktop |
| Windows without Git Bash | PowerShell twin | tests pass on Windows PowerShell 5.1; PowerShell 7 not run |
| Windows, people who work in cmd | Hooks still run in Git Bash or PowerShell, never cmd. By hand: the PowerShell command in section 6 | checked from cmd.exe (section 8) |
| Linux | `sh` script | tests pass with dash (Debian, Ubuntu), bash as `sh` (Fedora, RHEL, Arch), zsh as `sh`, zsh as the hook shell, and BusyBox (Alpine, containers) |
| macOS | `sh` script (bash 3.2, or zsh if that is the hook shell) | bash 3.2's known pitfalls are handled (see section 8), and zsh is tested on Linux; not run on a Mac |
| git | each copy ignores itself; `.claude/hooks/.gitattributes` keeps the script LF | tested, including a clone with `core.autocrlf=true` |
| svn | `svn:ignore *` on `.claude/skills`, `svn:eol-style LF` on the script | tested |
| An existing `.claude` folder | settings merged by hand; everything else untouched | tested in git and svn (section 6) |
| Claude desktop, plain folder | project root is the folder | live-checked |
| Claude desktop, app worktree | project root is the **main checkout** (see section 7) | live-checked |
| Claude Code in a terminal | project root is the start folder | Same engine as the desktop app. Even the older 2.1.220 CLI has every hook feature the kit uses. Not run live, because the CLI login on the test machine had expired. |
| Claude Code on the web, cloud sessions | Linux container | not checked |

**Other tools on a machine where Claude Code also runs:**

| Effect of the local copy | Tools |
|---|---|
| None: `.claude/skills` is not read, or `.agents` wins | Codex, Junie, Copilot CLI, OpenCode 2.x |
| None: the copies are never in the repository | Copilot cloud agent |
| Each skill listed twice, with identical content | Cursor, OpenCode 1.x, VS Code's deprecated Local harness |

For the tools that list skills twice, switches exist. In the Cursor IDE, turn off the third-party
skills setting. In OpenCode 1.x, set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`.

---

## 6. Adoption

### git

1. Copy `.claude/hooks/agent-skills-bridge.*`, `.claude/hooks/.gitattributes` and
   `.claude/skills/.gitignore` into the repository.
2. Add the hooks from `.claude/settings.json` to the repository's settings, or copy the file if it has
   none.
3. Put the skills in `.agents/skills/<name>/SKILL.md` and commit.

### svn

Copy the same files, except the two git files. Then run:

```sh
svn add --parents .claude/settings.json .claude/hooks/agent-skills-bridge.* .agents
svn mkdir --parents .claude/skills
printf '*\n' > svn-ignore.txt && svn propset svn:ignore -F svn-ignore.txt .claude/skills && rm svn-ignore.txt
svn propset svn:eol-style LF .claude/hooks/agent-skills-bridge.sh .claude/hooks/agent-skills-bridge.test.sh
svn commit -m "Share .agents/skills with Claude Code"
```

On Windows, `svn.exe` expands a `*` on its own command line, even inside quotes. The ignore value
must therefore come from a file (`-F`), or be set in TortoiseSVN's Properties dialog.

### Next to an existing `.claude` folder

| Already there | What to do |
|---|---|
| `.claude/settings.json` | Add the bridge's four hook entries next to your own: one for `SessionStart`, one for `FileChanged` and two for `PreToolUse`. Claude Code runs all matching hooks. Claude Code itself can do the merge. |
| Other hooks in `.claude/hooks` | Nothing. The kit's file names start with `agent-skills-bridge`. |
| Claude-only skills in `.claude/skills` | git: nothing; the copies ignore only themselves. svn: add a new skill folder by name, since `svn:ignore` hides the folder's direct entries. |
| A `.claude/skills/.gitignore` with your own rules | Keep it. The bridge never edits it and needs no line in it. |
| A skill with the same name in both folders | Reported as a conflict, and both are left alone. |
| `.claude/skills` as a link (the usual hand-made workaround) | Left alone and reported. Delete the link to switch to the bridge. |
| A root `.gitignore` that ignores `.claude/` | Replace the rule with `.claude/*`, `!.claude/settings.json`, `!.claude/hooks/` and `!.claude/skills/`. `settings.local.json` stays ignored. |

The kit's documentation has a merged `settings.json` example.

### Check a repository

```sh
sh .claude/hooks/agent-skills-bridge.sh status
```

In cmd or PowerShell on Windows, `sh` is usually not on PATH: Git for Windows adds only its `cmd`
folder by default. There, use the PowerShell twin, with or without Git Bash:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status
```

`status` reports:
- the skills, the copies and whether they are current;
- any conflicts;
- skill names that break the Agent Skills spec;
- whether git or svn really ignores the copies, and whether `.claude/skills` is in the repository;
- whether the hooks are in place.

Both scripts take the same commands: `status`, `sync` and `clean`.

### Check it by hand

The kit's documentation has a step-by-step manual test, "Manual test", for Claude desktop and for the
terminal CLI. It takes about ten minutes and assumes no knowledge of the kit. A throwaway skill,
`bridge-check`, shows that:

1. a new session copies the skill to `.claude/skills`;
2. Claude Code knows it: typing `/bridge-check` gets the answer `BRIDGE CHECK OK - version 1`;
3. a change to the skill reaches the running session (`version 2`);
4. Claude can't edit the copy: the guard's message appears instead;
5. git or svn never sees the copy;
6. deleting the skill deletes the copy.

Each step gives the exact commands for Windows and for macOS, Linux and Git Bash, and says what you
should see. A closing table names the likely cause and the fix for each failed check.

---

## 7. Claude desktop worktree sessions

The Claude desktop app starts sessions in its own worktrees (`.claude/worktrees/<name>`) with
`--project-config-root` set to the **main checkout**. Hooks, project settings, project skills and
`CLAUDE_PROJECT_DIR` therefore all come from the main checkout. The live check confirmed that the
bridge follows the same rule.

- **Where the kit must be.** Merge it to the branch that the main checkout has checked out. A kit
  that exists only on a worktree branch does nothing in worktree sessions.
- **Which skills a worktree session sees.** It sees the main checkout's skills. A skill changed only
  on the worktree branch appears once the main checkout has that change. Skill authors can also test
  from a terminal `claude` started inside the worktree, where the worktree is the project root.
- **Which guard answers.** The desktop app refuses the model's edits to the main checkout from a
  worktree session, so the app's guard answers before the bridge's.
- **This is not specific to the bridge.** Plain `.claude/settings.json` and `.claude/skills` content
  behaves the same way in these sessions.

---

## 8. Verification evidence

### Automated tests

The tests run the exact hook commands from `.claude/settings.json`, the way Claude Code runs them.
They cover:

- the first sync, edits, removals (including a sync that only deletes) and conflicts;
- a sync with nothing to do, which must start no program;
- read-only copies, and repair after tampering or deletion;
- the guard, for Edit, Write, NotebookEdit and MultiEdit: one copy and two, relative paths, `.` and
  `..`, other letter cases, the Git Bash and network spellings, and events with blanks in their JSON;
- symlinks, junctions and link loops in a skill, links to nowhere, a junction up to the repository, a
  junction to a junction, and a junction or a read-only folder inside a copy;
- a copy that cannot be replaced or deleted, and a file that cannot be copied at first and can later;
- hooks whose script is missing, and a skill folder with a name the bridge cannot use;
- an edit that lands while a sync is running, and a sync that is killed midway;
- a stale lock, the kill switch, and paths with spaces, with a letter outside ASCII, and on a network
  share;
- files saved with CRLF, read-only folders, `CDPATH`, and zsh with an alias and an option from
  `.zshenv`;
- `status` and `clean`;
- git: an existing `.claude/skills` with its own skill and `.gitignore`. Git sees the native skill's
  files but no copy and no record. `status` spots a copy that lost its `.gitignore`, and `sync`
  repairs it.
- git: a clone with `core.autocrlf=true` keeps the script LF thanks to `.claude/hooks/.gitattributes`,
  with a control clone that proves the conversion happens without it;
- svn: `status` names what svn would add, `svn:ignore` hides the copies, and a native skill can still
  be added and keeps showing new files.

| Platform | Result |
|---|---|
| Windows 11, Git Bash | 174 / 174 passed (Windows has no symlinks for the link cases) |
| Windows 11, Windows PowerShell 5.1 | 169 / 169 passed |
| Ubuntu 24.04 (WSL2), dash | 157 / 157 passed |
| Ubuntu 24.04 (WSL2), bash 5.2 as `sh` | 157 / 157 passed |
| Ubuntu 24.04 (WSL2), zsh 5.9 as `sh` | 157 / 157 passed |
| Ubuntu 24.04 (WSL2), zsh 5.9 as the hook shell | 159 / 159 passed |
| Alpine 3.24 container, BusyBox 1.37 | 137 / 137 passed (no git, svn or node in the image) |

A case that needs something the system lacks is skipped: symlinks and file modes on Windows, junctions
and network paths elsewhere.

### Code review (25 November 2026)

A reviewer went through the kit platform by platform. A second, adversarial review of the fixes
followed, with every finding reproduced before it was accepted. All of the findings below are fixed.
Each but the OneDrive one has a test that failed on the kit as it was: 39 checks failed there in
dash, 66 with zsh as the hook shell and 27 in Windows PowerShell. For OneDrive, the link test was
checked against the entries of a OneDrive folder, but no sync has run inside one.

| Finding | Fix |
|---|---|
| zsh as the hook shell splits no words and fails on a pattern without a match, so nothing was copied. | The script puts zsh into `sh` emulation and turns alias expansion off. |
| dash misread a manifest or a `SKILL.md` saved with CRLF, and took the bridge's own copies for someone else's. | Carriage returns are dropped in every shell, without a process. |
| `CDPATH` could send `cd` to another folder. | The script clears it. |
| Linux: a read-only folder in a skill made its copy impossible to replace. | The bridge makes such a copy writable before it deletes it. |
| The guard missed paths with `.` or `..`, relative paths, Git Bash's `/c/...`, network paths, another letter case in the skill's name, and events with blanks in their JSON. | Both guards bring the path into one form first. A relative path counts from the folder the event names. |
| MultiEdit sat behind an `if` filter that matches only Edit. | It moved to the guard entry without a filter. |
| PowerShell: a junction loop in a skill sent `-Recurse` down to the path limit and left a nested copy. An edit behind a junction went unnoticed. | The twin walks folders itself. It follows the links in a skill and leaves a loop out. |
| PowerShell: in a OneDrive folder every file and folder counted as a link, so the bridge did nothing there. | Only junctions and symbolic links count as links. |
| PowerShell: stdin and stdout went through the console code page, so a letter outside ASCII in the repository path broke the guard and the watch path. | The twin reads and writes UTF-8. |
| Both: a copy that could not be replaced, because a file in it was open, stayed half deleted and passed for current. A skill whose `SKILL.md` could not be read left a half copy. | Such a sync counts as unfinished and the next hook repeats it. Half copies are deleted. `clean` keeps its records until every copy is gone. |
| dash and BusyBox: a link to nowhere in a skill made every hook copy that skill again. | Such a link counts for nothing, and is reported once when the skill is copied. |

Two limits remain, both outside what Claude Code sends:

- The guard compares spellings. A `\\?\` path, a short 8.3 name or a link that leads into a copy gets
  past it; the next sync then replaces the edited copy.
- The shell guard finds the path with string operations. Claude Code puts the path first in an
  event. If it came after a very large value, the guard would need seconds per 100 KB to find it.

### Portability review (25 November 2026)

A review against the question "Windows and Linux, git and svn, CLI and desktop, existing `.claude`
folders" found these problems. All of them are fixed and covered by the tests above.

| Finding | Fix |
|---|---|
| The old anchor (`*` in `.claude/skills/.gitignore`) hid new files of Claude-only skills in `.claude/skills` from git. | Each copy ignores itself. The anchor now ignores nothing. |
| With an existing `.claude/skills/.gitignore`, the bridge kept that file. The copies were then visible to git and could be committed, while `status` reported the anchor as present. | Copies no longer depend on that file. `status` asks `git check-ignore` and `svn status` directly. |
| macOS `sh` is bash 3.2. Under `set -u` it rejects an empty `"$@"`, which a sync that only deletes copies produced. | `${1+"$@"}`. A test now checks that a delete-only sync succeeds; bash 3.2 itself was not run. |
| LF line endings depended on a manual edit of the root `.gitattributes`. A CRLF script fails in dash (checked); Git Bash copes. | The kit ships `.claude/hooks/.gitattributes`. |
| The PowerShell `status` crashed in a non-svn repository on machines with svn installed: Windows PowerShell 5.1 turns redirected stderr into a fatal error under `Stop` (checked). | A helper runs git and svn without that effect. A test now checks that `status` runs to the end. |
| Test harness: BusyBox compares file times in whole seconds, and zsh keeps an assignment made in front of a function call. | The tests now allow for both. The bridge itself was unaffected. |

### An edit during a sync (26 November 2026)

The code review had noticed one more problem and left it for a change of its own, because the fix
changes how a sync writes its records.

| Finding | Fix |
|---|---|
| Both: a sync wrote its time stamp after it had looked at every skill. A file that was edited in between, for example by a `git pull` that was still running, was older than the stamp. No later sync copied it, and the copy stayed out of date until the skill changed again. | The stamp is written before the look, under another name, so that the look still compares with the stamp of the sync before. It goes into the records together with the manifest when the sync ends. |

- **No extra process.** A shell cannot set a file's time without starting a program. So the shell
  script writes the new stamp into its lock folder and moves it with the `mv` that already moved the
  manifest. A sync with work to do starts as many programs as before, and one with nothing to do
  still starts none.
- **The file system's clock.** PowerShell could set the stamp's time from its own clock, but the
  twin writes a file too. On the test machine, in 2,016 of 3,000 writes the file's time was behind
  the precise system clock, by up to 14 ms. That is the clock PowerShell 7 reads for
  `[DateTime]::UtcNow`, so a stamp set from it could be later than an edit that came after it. On a
  network share, the server stamps the files.
- **An unfinished sync.** While a sync works, the stamp in the records is still newer than the
  manifest, as before, so a sync that is killed counts as unfinished. So does a sync whose stamp or
  manifest does not arrive at the end: the shell script then deletes the stamp, and the PowerShell
  twin stops before the manifest is in place. The next sync makes every copy again.
- **The test** runs a sync whose script carries one more line: after the look at the skills, it
  edits a skill that the look found unchanged. No file time set by hand can stand in for that,
  because the moment lies inside one run. The test fails on the scripts of the code review, in dash,
  BusyBox and Windows PowerShell 5.1, and passes now. A second test kills a sync between its last
  copy and its manifest and checks that the next plan calls every copy out of date.
- **With real processes.** In dash on Ubuntu, one process edited 600 skills, about one edit a
  millisecond, while two others ran sync after sync. When the edits stopped, one more sync had to
  bring every copy up to date. With the scripts of the code review, 36, 78 and 30 copies stayed out
  of date in three rounds. With the scripts as they are now, none did.
- **Old records.** Both scripts read the records that the earlier scripts wrote, and the earlier
  scripts read the new ones (checked by hand on Windows, in both directions).

### Second review (26 November 2026)

An independent review of the code review's commit followed, from four angles: the shell script's
sync, both guards, the PowerShell twin's sync, and the tests and documents. The findings below are
fixed, and each has a test. Of the new checks, 8 fail on the kit as it was before this review in
dash, 10 with zsh as the hook shell and 17 in Windows PowerShell.

| Finding | Fix |
|---|---|
| PowerShell: with two or more copies, the guard's refusal named all of them at once (`.agents/skills/alpha beta/SKILL.md`). | The list of copies is read name by name. |
| PowerShell: a junction in a skill that leads up to the repository took the bridge into its own `.claude/skills`. It copied its copy until the depth limit, and the skill lost its copy. | The bridge's own folder is no part of a skill: it is left out of the copy and of the search for changes. |
| PowerShell: a junction to a junction was followed one step only, so a file deleted at the end of the chain stayed in the copy. | Links are followed to their end. |
| PowerShell: a folder with the read-only attribute inside a copy could not be replaced. | The attribute is lifted from folders too. |
| PowerShell: `status` and `clean` went through a pipe in the console code page. | They write UTF-8, like the hook answers. |
| The hook command: where `sh` is dash or BusyBox `ash`, a missing script ended the shell with status 2, and Claude Code refused every Write. | The command tests for the script first and does nothing without it. |
| A file that could not be read was left out of a copy for good, also once it could be read. | Such a sync counts as unfinished, and the next hook tries again. |
| zsh as the hook shell kept the options set in `~/.zshenv`; `markdirs` stopped every copy. | Every option goes back to its `sh` default. |
| The note about a skill folder with an unusable name came with every file event, and twice in a hook that copied. | It comes once per session. |
| `clean` left the record folder behind when the last sync had deleted the last copy. | It deletes that folder too. |
| The shell guard named the source file in lower case when the event and the repository differed in letter case. | The message keeps the event's spelling. |
| Tests and documents: some checks could not fail, the suite left files behind when it was interrupted, and the documents said that a link loop is always left out. | `settings.json` is read entry by entry, a link loop must leave no runaway copy where `cp` sees it, and the file holder ends by itself. The documents now say what BusyBox `cp` does. |

These findings are open. They are older than both reviews, and each needs a decision before a fix:

- **Who owns a copy.** The manifest alone says which folders in `.claude/skills` are the bridge's.
  If a skill of your own takes a copy's place, the bridge deletes or overwrites it. That happens
  when a branch that tracks `.claude/skills/foo` is checked out after a sync on a branch that has
  moved the skill to `.agents/skills/foo`.
- **A sync killed during its first copy.** The names of new copies reach the manifest only when the
  sync ends. After a kill they count as someone else's and are never updated. A second session
  that starts while the first sync still copies reports the same false conflicts.
- **A file replaced by an older one.** The bridge compares file times with its stamp, not with the
  copy. A file put in place with an older time (`cp -p`, a Windows copy, `tar`, `rsync -a`) is not
  copied until something else in the skill changes.
- **A skill renamed in letter case only**, where the file system ignores case: the shell script
  reports a conflict and deletes the copy first; the PowerShell twin keeps the old name.
- **Waiting for a lock.** Each try starts three programs. On a slow Windows machine the wait takes
  about 115 s, close to the hook's timeout of 120 s.
- **The Edit filter on Windows.** Read from the Claude Code 2.1.330 program, not confirmed in a live
  session: after a `cd` in the session, the rule `Edit(**/.claude/skills/**)` no longer matches a
  Windows path, so the guard does not start for Edit. The copies stay read-only, and the next sync
  repairs an edited one.
- **A link from a skill up to the repository, in the shell script.** The PowerShell twin copies the
  repository once, without its own folder. The shell script leaves the link to `cp`, and GNU `cp`
  may refuse the whole skill, which then has no copy until the link is gone.
- **Smaller ones.** A repository path with a control character or, outside Windows, a backslash
  breaks the watch path. A deleted target of a junction leaves its files in the copy until the
  skill changes. In Git Bash the guard needs about four seconds to read an event of 1 MB.

### Adoption flows

| Flow | Result |
|---|---|
| git, existing `.claude/skills` with its own skill and ignore rules | The copies and records stay invisible, and the native skill stays visible (automated). |
| git, root `.gitignore` with `.claude/*` and re-include rules | The kit is visible to git, and `settings.local.json` stays ignored. |
| git, fresh clone with `core.autocrlf=true` | The script arrives with LF (automated). |
| git worktree | The copy is made, and the status is clean. |
| svn checkout | `svn status` is clean, and the copies are ignored (automated). |
| `sh` and PowerShell on the same checkout | They share the manifest and stamp, and neither redoes the other's work. |

### cmd.exe check (25 November 2026)

A follow-up question was whether the kit also works for people who use cmd. The Claude Code program
shows that hooks never run in `cmd.exe`, so the terminal doesn't matter (section 4.3). A manual check
from `cmd.exe` on Windows 11, in a repository whose path has a space, covered the rest:

| Check | Result |
|---|---|
| Claude Code's Git Bash lookup rule, applied in cmd | Found a per-user Git install through PATH. |
| PowerShell twin: `sync`, `status`, `clean` | All succeeded, from the repository and from another folder. |
| `status` through Git's `sh.exe`, by its full path | Succeeded. |
| SessionStart and guard hook commands, in Git Bash and in PowerShell, with cmd's environment | SessionStart exited 0 with `reloadSkills` and `watchPaths`, and made the copy. The guard refused an edit of a copy with exit code 2. |
| `git status` afterwards | No copies listed. |
| The hook command typed into cmd itself | Fails ("The filename, directory name, or volume label syntax is incorrect"). Claude Code never does this. |

The check found one documentation gap, now fixed. The docs offered the PowerShell command only for
Windows without Git Bash, but `sh` is usually missing from cmd and PowerShell even where Git is
installed.

### Live checks in Claude Code 2.1.330 (Claude desktop on Windows 11)

These ran before the reviews, with the earlier layout, which kept the ignore rule in
`.claude/skills/.gitignore`. The hook commands are the same today; the scripts behind them have
changed as the two review sections and "An edit during a sync" above describe. Claude Code's skill
loader skips a folder without `SKILL.md` silently, so the new record folder is never taken for a
skill.

| Check | Result |
|---|---|
| Session start, plain folder | The skill was in Claude's list from the first prompt. The SessionStart hook took 6.8 s, including the first copy. It returned `watchPaths` and `reloadSkills`. |
| Skill use | The skill loaded from `.claude/skills/bridge-selftest`. |
| Edit guard | The Edit was refused within 0.23 s with the bridge's message, and the copy was unchanged. |
| Live sync | A source edit reached the copy in 1.3 s, and the same session then used the new version. |
| Removal | A deleted skill's copy and manifest entry were gone in 1.5 s. |
| Desktop worktree | Hooks, `CLAUDE_PROJECT_DIR`, the copy and the watch all came from the main checkout, as described in section 7. |
| Ignored copy | Claude Code loads skills from a `.claude/skills` folder that git ignores. |

The live check also found one defect. Claude Code's `if` filter on the guard never matches the Write
tool, so Write could create a file inside a copy. That is now fixed with a second guard entry for
Write and NotebookEdit, without a filter.

### Not yet verified

- A live session with the new layout, with the Write, NotebookEdit and MultiEdit guard entry, and
  with the scripts as they are after the code review. The tests cover all three.
- The manual test as written, end to end in a live session. Its commands and expected `status`
  outputs were dry-run on Windows, with the hooks run the way Claude Code runs them. The steps on
  the Claude side rest on the earlier live checks and on the Claude Code program.
- A run on macOS, and bash 3.2 itself. The official `bash:3.2` container image would allow the latter.
- PowerShell 7. The test machine has none; `ASB_TEST_POWERSHELL=pwsh.exe` runs the suite with one.
- A sync inside a OneDrive folder. The link test of the PowerShell twin was checked against the
  entries of a OneDrive folder, but nothing was copied there.
- The terminal Claude Code CLI on the test machine (its login had expired), and cloud sessions.

---

## 9. Alternatives considered

| Option | Decision | Reason |
|---|---|---|
| Commit `.claude/skills` as symlinks to `.agents/skills` | rejected | Windows needs Developer Mode for symlinks. Without it, git and svn check them out as plain text files. |
| Create symlinks or junctions locally with a script | rejected | Junctions hold absolute paths, and some recursive deletes follow them into the real skills. Each OS also needs its own code and privileges. |
| Commit a mirrored copy of `.claude/skills` | rejected | Every change shows up twice in reviews, the two drift apart, and Cursor and similar tools list duplicates for everyone. |
| Claude Code's `/import cursor` | rejected | It works only interactively, never refreshes a copy, and drops frontmatter such as `allowed-tools`. |
| A Claude Code plugin | rejected | Plugins are copied into a cache and their skills get prefixed names. Every user must approve the install. |
| Make `.claude/skills` the canonical folder | rejected | Codex and Junie don't read it, and `.agents/skills` is the emerging standard. |
| One `.gitignore` in `.claude/skills` for all copies | replaced | It hid Claude-only skills from git, and it did nothing where a team already had its own file there. |
| **A local copy driven by Claude Code hooks, each copy ignoring itself** | **chosen** | It needs no setup, no symlinks and no generated files in version control. It works on every OS, in both VCSs and next to existing `.claude` content. Python's `venv` and pytest's cache use the same self-ignoring pattern. |

---

## 10. Limitations and risks

| Item | Impact | Mitigation |
|---|---|---|
| Duplicate listings in Cursor, OpenCode 1.x and the VS Code Local harness | Identical skills are listed twice on machines that also run Claude Code. Behaviour is unchanged, but some context is wasted. | Per-tool switches (section 5). The duplicates go away once Claude Code reads `.agents/skills` itself. |
| Desktop worktree sessions use the main checkout | A skill edited only on a worktree branch isn't served there. | Documented, and native `.claude/skills` behaves the same. Test from the main checkout or the terminal CLI. |
| The organisation turns off project hooks (`disableAllHooks`, `allowManagedHooksOnly`) | The bridge doesn't run. | Run `sh .claude/hooks/agent-skills-bridge.sh sync` (in cmd or PowerShell, the `.ps1`), then `/reload-skills`. |
| A Group Policy enforces `AllSigned` for PowerShell | On Windows without Git Bash, the `.ps1` doesn't run. | Install Git for Windows (hooks then run in Git Bash), or sign the script. |
| svn: `svn:ignore *` also hides a new Claude-only skill folder | Someone must add it by name. | Documented. Files inside an added skill folder behave normally. |
| Merging the hooks into an existing `settings.json` is manual | A wrong merge leaves the bridge off. | `status` reports missing hooks. Claude Code can do the merge on request. |
| Each Write or NotebookEdit call starts the guard | A small delay per call. It is noticeable only on machines with slow process starts. | The guard exits at once outside `.claude/skills`. Claude Code's `if` filter can't help for these tools. |
| The file watcher can't see changes, for example in WSL on `/mnt/c` | Changes made outside Claude arrive at the next session start. | Start a new session, or run `sync` and `/reload-skills`. |
| Claude Code adds native `.agents/skills` support | Claude Code may list each skill twice until the bridge is removed. | Follow the exit plan in section 11 and watch #31005. |
| The two implementations drift apart | One platform starts behaving differently from the others. | One test suite runs both implementations against the same scenarios. |

---

## 11. Exit plan

When Claude Code reads `.agents/skills` itself:

1. Delete the three hooks from `.claude/settings.json`.
2. Run `sh .claude/hooks/agent-skills-bridge.sh clean` (in cmd or PowerShell, the `.ps1` with
   `clean`) to delete the copies and the bridge's records.
3. Delete `.claude/hooks/agent-skills-bridge.*`. Delete `.claude/hooks/.gitattributes` unless other
   scripts need it, and the anchor unless Claude-only skills live in `.claude/skills`.

The skills themselves stay where they are, in `.agents/skills`.

---

## 12. References

- Claude Code feature request for `.agents/skills`:
  [anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005)
- Agent Skills specification: <https://agentskills.io/specification>
- Claude Code skills documentation: <https://code.claude.com/docs/en/skills>
- Kit documentation: [`.claude/hooks/agent-skills-bridge.md`](../.claude/hooks/agent-skills-bridge.md),
  which travels with the kit into every project
- The tool behaviour described here was checked against each tool's documentation in November 2026.
  Cursor's duplicate listing is documented only on its forum.
