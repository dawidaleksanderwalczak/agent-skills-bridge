# Agent skills bridge: `.agents/skills` for Claude Code

The repository keeps its Agent Skills in one place, `.agents/skills/<name>/SKILL.md`. Codex,
Copilot, Cursor, Junie and OpenCode read that folder directly. Claude Code does not: it loads
project skills only from `.claude/skills`. That was checked in the 2.1.330 program, and no release
note up to 2.1.332 changes it. The request to change it,
[anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005), is still
open.

The bridge closes the gap on its own. Claude Code runs it from hooks in `.claude/settings.json`. It
copies every skill from `.agents/skills` to `.claude/skills`. The copies are read-only, ignored by
version control and never committed. Nobody has to install or run anything.

## How it works

1. **Session start.** A `SessionStart` hook copies new and changed skills to
   `.claude/skills/<name>/` and deletes copies of skills that were removed. It then tells Claude Code
   to reload its skills, so the first prompt already sees them, and to watch `.agents/skills`.
2. **While you work.** A `FileChanged` hook syncs again when anything under `.agents/skills` changes.
   That covers edits by Claude, by you in an IDE, and by `git pull` or `svn update`.
3. **Guard.** A `PreToolUse` hook stops Claude from editing a copy. The reason it gives names the
   source file to edit instead. Copies are read-only too, so editors warn people.
   - **Edit:** the hook's `if` filter limits it to paths in `.claude/skills`, so other edits start no
     process.
   - **Write and NotebookEdit:** Claude Code's `if` filter can't match these tools to an `Edit` rule,
     so their entry has no filter. The guard starts on every call and exits at once unless the path is
     in `.claude/skills`.
4. **Out of version control.** Each copy contains its own `.gitignore` with the single rule `*`.
   So does the bridge's record folder, `.claude/skills/.agent-skills-bridge/`.
   - **git:** it ignores the copies whatever your other `.gitignore` files say. The bridge never
     edits a `.gitignore` it did not write.
   - **svn:** it reads no `.gitignore`. There, `svn:ignore` on `.claude/skills` does the job.
5. **Anchor.** A committed `.claude/skills/.gitignore` keeps the folder in every checkout and
   worktree, so Claude Code watches it from the first second. It contains only comments, so it ignores
   nothing.

The bridge never writes through a link and never touches a skill in `.claude/skills` that it did not
create. It reports such a name as a conflict. When nothing changed, a hook run starts no process
beyond the shell Claude Code opens for it. That matters on Windows, where security software can make
each process cost most of a second.

## Files

| Path | In version control | What it is |
|---|---|---|
| `.agents/skills/<name>/` | yes | The skills: the only copy you edit |
| `.claude/settings.json` | yes | The three hooks |
| `.claude/hooks/agent-skills-bridge.sh` | yes | The bridge for macOS, Linux and Windows with Git Bash (POSIX `sh`) |
| `.claude/hooks/agent-skills-bridge.ps1` | yes | The same bridge for Windows without Git Bash, and for running it by hand in cmd or PowerShell (PowerShell 5.1 or 7) |
| `.claude/hooks/agent-skills-bridge.test.sh` | yes | Scenario tests for both |
| `.claude/hooks/agent-skills-bridge.md` | yes | This page |
| `.claude/hooks/.gitattributes` | yes (git) | Keeps the shell scripts LF in every git checkout |
| `.claude/skills/.gitignore` | yes (git) | The anchor. It keeps the folder in every checkout and ignores nothing |
| `svn:ignore` on `.claude/skills` | yes (svn) | Keeps the copies out of svn |
| `.claude/skills/<name>/` | no, ignored | Generated copies, each with its own `.gitignore` |
| `.claude/skills/.agent-skills-bridge/` | no, ignored | The bridge's records: what it copied, when, and its lock |

## Adopt it in a git repository

1. Copy `.claude/hooks/agent-skills-bridge.*`, `.claude/hooks/.gitattributes` and
   `.claude/skills/.gitignore` from this repository.
2. Add the three hooks from `.claude/settings.json` to yours. If you have no `.claude/settings.json`,
   copy the file as it is. If you already have a `.claude` folder, also read
   [the next section](#adopt-it-next-to-an-existing-claude-folder).
3. Put your skills in `.agents/skills/<name>/SKILL.md`, commit, and check the result:

   ```sh
   sh .claude/hooks/agent-skills-bridge.sh status
   ```

   In cmd or PowerShell on Windows, run the PowerShell twin instead (see [Everyday use](#everyday-use)):

   ```text
   powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status
   ```

4. Run the [manual test](#manual-test) once, in Claude desktop or in the CLI.

If you forget the anchor, the bridge writes `.claude/skills/.gitignore` itself when it has to create
the folder. `git status` then lists it, so you can commit it.

## Adopt it next to an existing `.claude` folder

Apart from the anchor and `.claude/hooks/.gitattributes`, every kit file name starts with
`agent-skills-bridge`. The bridge writes only inside `.claude/skills`, and only to its copies and its
record folder. Here is what to do about what you already have:

| You already have | What to do |
|---|---|
| `.claude/settings.json` | Add the bridge's three hook entries to your `hooks` arrays (see below). Claude Code runs every matching hook, so your own hooks keep working. `status` reports missing bridge hooks. |
| Other files in `.claude/hooks` | Nothing. If you already have a `.claude/hooks/.gitattributes`, add the kit's line to it. |
| Your own skills in `.claude/skills` | Nothing in git: the copies ignore only themselves, so git still sees every file of your own skills. In svn, add a new skill folder by name (see the svn section). |
| A `.claude/skills/.gitignore` with your own rules | Keep it, and don't copy the anchor. The bridge never edits that file and needs no line in it. |
| A skill in `.claude/skills` with the same name as one in `.agents/skills` | The bridge reports a conflict and leaves both alone. Delete the old one once `.agents/skills` has it, or rename one. |
| `.claude/skills` as a link to `.agents/skills` (the usual hand-made workaround) | The bridge leaves a link alone and says so in each new session. Delete the link to let the bridge take over. |
| `settings.local.json`, `.claude/worktrees`, `.claude/commands` and so on | Nothing: the bridge doesn't touch them. |
| A root `.gitignore` that ignores `.claude/` | Git can't see the kit. Change the rule as shown below. |

**Merging the hooks.** Copy the bridge's entries from the kit's `.claude/settings.json` verbatim, and
add them next to your own entries under the same event names. The result has this shape:

```json
{
  "permissions": { "allow": ["Bash(npm test)"] },
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "your-own-hook.sh" }] },
      { "hooks": [{ "type": "command", "command": "set \\' ; ASB_CMD=session ...", "timeout": 120 }] }
    ],
    "FileChanged": [
      { "hooks": [{ "type": "command", "command": "set \\' ; ASB_CMD=sync ...", "timeout": 120 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "your-bash-check.sh" }] },
      { "matcher": "Edit|MultiEdit", "hooks": [{ "type": "command", "if": "Edit(**/.claude/skills/**)", "command": "set \\' ; ASB_CMD=guard ...", "timeout": 30 }] },
      { "matcher": "Write|NotebookEdit", "hooks": [{ "type": "command", "command": "set \\' ; ASB_CMD=guard ...", "timeout": 30 }] }
    ]
  }
}
```

The `...` stands for the rest of each command: copy the full strings. Claude Code can do the merge
for you. Ask it to "add the three agent-skills-bridge hooks from the kit's settings.json to ours".

**A root `.gitignore` that ignores `.claude/`.** Git cannot re-include files inside an ignored
folder, so ignore the folder's contents instead and let the kit through:

```gitignore
.claude/*
!.claude/settings.json
!.claude/hooks/
!.claude/skills/
```

`settings.local.json` and everything else in `.claude` stay ignored. The copies stay ignored as well,
through their own `.gitignore`.

## Adopt it in an svn working copy

Copy the same files as for git (step 1), except the two git files: `.claude/hooks/.gitattributes` and
`.claude/skills/.gitignore`. Then run:

```sh
svn add --parents .claude/settings.json .claude/hooks/agent-skills-bridge.* .agents
svn mkdir --parents .claude/skills
printf '*\n' > svn-ignore.txt
svn propset svn:ignore -F svn-ignore.txt .claude/skills
rm svn-ignore.txt
svn propset svn:eol-style LF .claude/hooks/agent-skills-bridge.sh .claude/hooks/agent-skills-bridge.test.sh
svn commit -m "Share .agents/skills with Claude Code"
```

- **Pass `*` through a file.** On Windows, `svn.exe` turns a `*` on its command line into file
  names, even inside quotes. In PowerShell, write the file with `Set-Content svn-ignore.txt '*'`. In
  TortoiseSVN, open the Properties of `.claude/skills` and add `svn:ignore` with the value `*`.
- **Existing value.** `svn propset` replaces any value that is already there. If `.claude/skills`
  already has an `svn:ignore`, use `svn propedit` instead.
- **Your own skills in `.claude/skills`.** `svn:ignore` hides only the folder's direct entries. So add
  a new skill folder by name, `svn add .claude/skills/<name>`. New files inside a versioned skill
  folder show up as usual.
- **Line endings.** `svn:eol-style LF` stores and checks out the script with LF. Without it, a
  Windows editor that saves CRLF would break the script for everyone on Linux and macOS: `sh` fails
  on CRLF. Git Bash on Windows copes with CRLF either way.

## Claude desktop worktree sessions

The Claude desktop app runs a session in one of its worktrees (`.claude/worktrees/<name>`) with the
main checkout as the project config root. Hooks, project settings and project skills then come from
the main checkout, and so does the bridge:

- **Where the kit must be.** It has to be in the main checkout's working tree. A kit that exists only
  on a worktree branch does nothing.
- **Which skills the session sees.** It sees the main checkout's `.agents/skills`, copied to the main
  checkout's `.claude/skills`. A skill you change only on the worktree branch doesn't show up there.
  To try such a change, check the branch out in the main checkout, or start `claude` in a terminal
  inside the worktree: there the worktree is the project root.
- **Which guard answers.** The app refuses Claude's edits to the main checkout from a worktree session.
  Its own guard therefore answers before the bridge's.

The same rules apply to anything in `.claude/settings.json` and `.claude/skills`, with or without
the bridge.

## Everyday use

- Write and change skills only in `.agents/skills`. Claude Code picks up the change within seconds.
- `sh .claude/hooks/agent-skills-bridge.sh status` shows what is bridged and whether it is current.
  It also checks:
  - folder names and `name:` fields against the Agent Skills spec;
  - whether git or svn really ignores the copies;
  - whether `.claude/skills` is in the repository;
  - whether the hooks are in place.

  The `sh` form works in Git Bash, macOS and Linux. In cmd or PowerShell on Windows, `sh` is usually
  not on PATH: Git for Windows adds only its `cmd` folder by default. There, use the PowerShell twin,
  with or without Git Bash:
  `powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status`.
  It takes the same commands, and given the script's full path it works from any folder.
- `sync` copies right away. After a manual sync, type `/reload-skills` in Claude Code.
- `clean` deletes every copy and the record folder. The anchor stays.
- `AGENT_SKILLS_BRIDGE=off` in the environment turns the hooks into no-ops.

## Manual test

This test takes about ten minutes. It shows that the bridge works on your machine, in Claude desktop
or in Claude Code in a terminal (the CLI). It uses a throwaway skill called `bridge-check` and makes
six checks:

| Check | It proves that |
|---|---|
| 1 | a new Claude Code session copies the skill to `.claude/skills` |
| 2 | Claude Code knows the skill |
| 3 | a change to the skill reaches Claude while the session runs |
| 4 | Claude can't edit the copy |
| 5 | git or svn never sees the copy |
| 6 | deleting the skill deletes its copy |

Do the steps in order. Each check says what you should see. If you see something else, stop and look
the check up in [If a check fails](#if-a-check-fails).

### What you need

- **The repository, with the kit in it.** "Repository folder" below means its top folder: the one
  that contains `.claude` and `.agents`.
- **Claude Code.** Either the Claude desktop app, which updates itself, or the `claude` command in a
  terminal, version 2.1.220 or newer. `claude --version` shows the version.
- **A terminal that is open in the repository folder.** You type the test commands there, so Claude
  desktop users need one too. This page calls it the *command terminal*.
  - **Windows 11:** open the repository folder in File Explorer, right-click an empty spot in it, and
    choose **Open in Terminal**. That opens PowerShell, whose prompt starts with `PS`. If the prompt
    doesn't start with `PS`, type `powershell` and press Enter.
  - **macOS:** open Terminal, type `cd ` (with a space after it), drag the repository folder onto the
    Terminal window, and press Return.
  - **Linux:** right-click inside the repository folder in your file manager, and choose
    **Open in Terminal**.

Every command below comes in two forms. Use the **Windows** form in PowerShell, and the
**macOS, Linux, Git Bash** form in the other terminals.

### Step 1: Prepare

1. Close every Claude Code session for this repository: type `/exit` in each terminal that runs
   `claude`, and close the repository's sessions in Claude desktop. A session that is still open
   would copy the test skill at once, and check 1 would prove less.
2. In the command terminal, run `status`:

   Windows:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status
   ```

   macOS, Linux, Git Bash:

   ```sh
   sh .claude/hooks/agent-skills-bridge.sh status
   ```

   You see a short report like this one. Your path, skill names and numbers differ:

   ```text
   agent-skills bridge: C:\work\my-repo
     .agents/skills  1 skill(s): team-skill
     .claude/skills  1 copy(ies): team-skill
     state           copies are current
     git             copies are ignored
     git             .claude/skills is in the repository
     hooks           .claude/settings.json runs the bridge
   ```

   The `hooks` line must say `.claude/settings.json runs the bridge`. In an svn working copy, the
   `git` lines are `svn` lines. If you get "cannot find the path" or "No such file", the terminal is
   not in the repository folder, or the kit is missing.
3. The folder `.agents/skills/bridge-check` must not exist yet. If it does, an earlier test was left
   behind: clean it up as described under [Finish](#finish) first.

### Step 2: Create the test skill

In the command terminal, run these two lines. They create the file
`.agents/skills/bridge-check/SKILL.md`.

Windows:

```powershell
New-Item -ItemType Directory -Force .agents\skills\bridge-check | Out-Null
Set-Content -Encoding ascii .agents\skills\bridge-check\SKILL.md '---', 'name: bridge-check', 'description: Test skill for the agent-skills bridge. Use only when the user types /bridge-check.', '---', '', 'Reply with exactly this line, and nothing else:', '', 'BRIDGE CHECK OK - version 1'
```

macOS, Linux, Git Bash:

```sh
mkdir -p .agents/skills/bridge-check
printf '%s\n' '---' 'name: bridge-check' 'description: Test skill for the agent-skills bridge. Use only when the user types /bridge-check.' '---' '' 'Reply with exactly this line, and nothing else:' '' 'BRIDGE CHECK OK - version 1' > .agents/skills/bridge-check/SKILL.md
```

You can create the file in an editor instead. It must contain exactly these lines. In Notepad, set
**Save as type** to **All files**, or Notepad saves it as `SKILL.md.txt`.

```markdown
---
name: bridge-check
description: Test skill for the agent-skills bridge. Use only when the user types /bridge-check.
---

Reply with exactly this line, and nothing else:

BRIDGE CHECK OK - version 1
```

Run `status` again. The `state` line now says `out of date: bridge-check`. That is right: the bridge
sees the new skill, and the next Claude Code session copies it.

### Step 3: Start Claude Code

**Claude desktop:**

1. Open the Claude desktop app and switch to the **Code** tab.
2. Start a new session, and choose the repository folder for it.
3. If the app asks whether you trust the folder, confirm that you trust it. Hooks don't run in a
   folder that you haven't trusted.
4. Wait until you can type in the message box.

The app may run the session in one of its own worktrees, a folder under `.claude\worktrees\`. To find
out, ask Claude: `Which folder are you working in?` A worktree session is fine: the bridge then works
from the repository folder, as described in
[Claude desktop worktree sessions](#claude-desktop-worktree-sessions). Keep typing every command in
the command terminal, in the repository folder, and read the note in check 4.

**Claude Code in a terminal (CLI):**

1. Open a second terminal in the repository folder, the same way as the first. The first one stays
   free for the test commands.
2. Type `claude` and press Enter.
3. If Claude Code asks you to log in, follow its instructions.
4. If it shows a **Quick safety check** that asks whether you trust this folder:
   - Use the arrow keys to select **Yes, I trust this folder**, then press Enter. Don't just press
     Enter: newer versions preselect **No, exit**.
   - Never choose **No, continue without these permissions**. The bridge's hooks don't run then.
   - The check may say that the folder configures hooks. Those are the bridge's hooks.
5. Wait until you see the input prompt.

### Check 1: The session copied the skill

Run `status` in the command terminal. You should see:

- `bridge-check` in the `.claude/skills` line;
- `copies are current` in the `state` line.

The first sync can take several seconds on Windows. If `bridge-check` is missing, wait 15 seconds and
run `status` again before you call the check failed.

You can also look for yourself. The folder `.claude/skills/bridge-check` now exists and holds
`SKILL.md` and `.gitignore`. Both files are read-only:
- **Windows:** the Properties of `SKILL.md` show **Read-only** ticked.
- **macOS and Linux:** `ls -l .claude/skills/bridge-check` shows `-r--r--r--`.

macOS Finder and most Linux file managers hide names that start with a dot. To show them, press
Cmd+Shift+. in Finder, or Ctrl+H in the file manager.

### Check 2: Claude Code knows the skill

In Claude Code's message box, type `/bridge-check` and press Enter. If a list of commands opens while
you type, choose `bridge-check` in it.

- **Pass:** Claude's answer contains `BRIDGE CHECK OK - version 1`.
- **Fail:** Claude Code says `Unknown command: /bridge-check`, or Claude says it has no such skill.

### Check 3: A change reaches the running session

1. Leave the session open. In the command terminal, change the skill to version 2:

   Windows:

   ```powershell
   Set-Content -Encoding ascii .agents\skills\bridge-check\SKILL.md '---', 'name: bridge-check', 'description: Test skill for the agent-skills bridge. Use only when the user types /bridge-check.', '---', '', 'Reply with exactly this line, and nothing else:', '', 'BRIDGE CHECK OK - version 2'
   ```

   macOS, Linux, Git Bash:

   ```sh
   printf '%s\n' '---' 'name: bridge-check' 'description: Test skill for the agent-skills bridge. Use only when the user types /bridge-check.' '---' '' 'Reply with exactly this line, and nothing else:' '' 'BRIDGE CHECK OK - version 2' > .agents/skills/bridge-check/SKILL.md
   ```

   Or open `.agents/skills/bridge-check/SKILL.md` in an editor, change the `1` in the last line to
   `2`, and save.
2. Wait 10 seconds.
3. Run `status`. The `state` line says `copies are current`, and the copy
   `.claude/skills/bridge-check/SKILL.md` now ends with `version 2`.
4. In the same Claude Code session, type `/bridge-check` again and press Enter.

- **Pass:** Claude's answer contains `BRIDGE CHECK OK - version 2`.
- **Fail:** the copy still ends with `version 1`, or Claude still answers `version 1`.

### Check 4: Claude can't edit the copy

Type this into the session exactly, and press Enter:

```text
Use your Edit tool to change "version 2" to "version 3" in .claude/skills/bridge-check/SKILL.md. Do not edit any other file.
```

If Claude asks for permission to edit the file, allow it. The bridge blocks the edit anyway.

- **Pass:** Claude reports that the edit was blocked, with a message that starts with
  `Blocked by the agent-skills bridge`. The message names `.agents/skills/bridge-check/SKILL.md` as
  the file to change instead. The copy still ends with `version 2`.
- **Fail:** Claude edited the copy, and no such message appeared.

In a Claude desktop worktree session, the app's own guard refuses the edit first, with its own
message, or Claude doesn't find the file. The copy is safe either way. To see the bridge's message,
repeat this check in the CLI.

### Check 5: Version control doesn't see the copy

In the command terminal, run `git status --short` in a git repository, or `svn status` in an svn
working copy.

- **Pass:** no line contains `.claude/skills` (svn on Windows prints `.claude\skills`). The test skill
  itself is listed, and that is expected: `?? .agents/skills/bridge-check/` in git, or
  `?       .agents/skills/bridge-check` in svn (with backslashes on Windows). If the repository had
  no skills before, git shows `?? .agents/` instead. Any other lines are your own changes.
- **Fail:** a line contains `.claude/skills`.

### Check 6: Deleting the skill deletes the copy

1. Leave the session open. In the command terminal, delete the test skill:

   Windows:

   ```powershell
   Remove-Item -Recurse -Force .agents\skills\bridge-check
   ```

   macOS, Linux, Git Bash:

   ```sh
   rm -rf .agents/skills/bridge-check
   ```

2. Wait 10 seconds.
3. Run `status`.

- **Pass:** `bridge-check` is gone from both the `.agents/skills` and the `.claude/skills` line, and
  the folder `.claude/skills/bridge-check` no longer exists.
- **Fail:** the folder `.claude/skills/bridge-check` is still there.

### Finish

Close the session: type `/exit` in the CLI, or close the session in Claude desktop. Nothing is left
behind. The test skill and its copy are gone, and `git status` or `svn status` lists nothing from the
test.

If you stopped before check 6, delete the test skill with the commands from check 6. Then run `sync`,
so that the copy goes too:

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 sync
```

macOS, Linux, Git Bash:

```sh
sh .claude/hooks/agent-skills-bridge.sh sync
```

### If a check fails

| What failed | Likely cause | What to do |
|---|---|---|
| Step 1: the `hooks` line doesn't say `.claude/settings.json runs the bridge` | The bridge's hooks aren't in `.claude/settings.json`. | Add them; see the adoption sections above. |
| Check 1: no copy | The hooks didn't run. The folder isn't trusted, your organization blocks project hooks, or Claude Code is older than 2.1.220. In a desktop worktree session, the kit may be missing from the repository folder. | Trust the folder, and start a new session. If your organization blocks hooks, see [Troubleshooting](#troubleshooting). |
| Check 2 fails, but check 1 passed | Claude Code hasn't loaded the copy. | Type `/reload-skills`, then `/bridge-check`. If that fails too, check that the folder name and the `name:` line both say `bridge-check`. |
| Check 3: the copy didn't change | The file watcher can't see the folder, for example in WSL on `/mnt/c` or on a network drive. | Run `sync`, then type `/reload-skills`. On such a drive, start a new session after each change. |
| Check 3: the copy changed, but Claude answered `version 1` | Claude Code missed the change. | Type `/reload-skills`, then `/bridge-check`. |
| Check 4: Claude edited the copy | The guard hooks are missing, or were added after the session started. | Check the `hooks` line in `status`, then start a new session. |
| Check 5: a line contains `.claude/skills` | The copy isn't ignored. | Run `status`: it says why. Run `sync`. In svn, set `svn:ignore` as described in the svn section. |
| Check 6: the copy stays | As for check 3. | Run `sync`. |

## What the other tools see

The copies exist only on machines where Claude Code ran, and never in the repository. Tools that read
both folders find each skill twice, with identical content.

| Tool | Reads `.agents/skills` | Effect of the local copy in `.claude/skills` |
|---|---|---|
| Codex (CLI, IDE) | yes | none: it does not read `.claude/skills` |
| Junie | yes | none. The Junie CLI may offer to import `.claude/skills`: decline. |
| Copilot CLI | yes | none: `.agents` wins over `.claude` for the same name |
| VS Code (Copilot harness) | yes | probably none: it runs the Copilot CLI engine (not documented) |
| Copilot cloud agent | yes | none: the copies are not in the repository |
| OpenCode 2.x | yes | none: `.agents` wins |
| OpenCode 1.x | yes | listed twice, with a warning; set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` |
| Cursor (IDE, `cursor-agent`) | yes | listed twice; in the IDE, turn off Settings > Rules, Skills and Subagents > "Include Third-Party Plugins, Skills, and Other Configs". `cursor-agent` has no switch. |
| VS Code "Local" harness (deprecated) | yes | listed twice; `chat.agentSkillsLocations` |

Checked in November 2026 against each tool's documentation. Cursor's duplicate listing comes from
Cursor staff on its forum. The record folder has no `SKILL.md`, so no tool loads it as a skill.

## Writing skills that work everywhere

- The folder name and the `name:` field match: lowercase letters, digits and single hyphens, at most
  64 characters. VS Code silently skips a skill whose `name` differs from its folder.
- `description:` is required, at most 1024 characters. Say what the skill does and when to use it.
- Claude-only frontmatter is fine: `allowed-tools`, `disable-model-invocation`, `argument-hint`,
  `context`, `model`. The other tools ignore keys they don't know.
- The bridge copies files byte for byte and adds one file, the copy's `.gitignore`. Claude Code's own
  `/import` is different: it drops keys such as `allowed-tools` and escapes `` !`command` `` lines.
- Keep the body portable if other tools must follow it. `` !`command` `` lines and `$ARGUMENTS` work
  only in Claude Code.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| A skill is missing in Claude Code | Run `status`. For a brand-new checkout, accept the folder trust prompt: hooks run only in trusted folders. |
| "Blocked by the agent-skills bridge" | Claude tried to edit a copy. It edits the named source file instead. |
| "`.claude/skills/<name>` exists and was not made by the bridge" | A skill of the same name lives in `.claude/skills`. Move it to `.agents/skills`, or rename one of them. |
| `status`: "git not ignored: `<name>`" | The copy lost its `.gitignore`, or someone committed it. Run `sync`. If git tracks the copy, run `git rm -r --cached .claude/skills/<name>`. |
| `status`: "svn not ignored", or `svn status` lists copies | Set `svn:ignore` to `*` on `.claude/skills` (see the svn section). |
| Linux or macOS: the hook fails with `$'\r'`, `: not found` or "Illegal option -" | The script has CRLF line endings. Commit `.claude/hooks/.gitattributes` (git) or set `svn:eol-style LF` (svn), then check the file out again. |
| Windows: `sh` "is not recognized" in cmd or PowerShell | `sh` is usually on PATH only inside Git Bash. Use the PowerShell twin (see "Everyday use"), or open Git Bash. The hooks are not affected: Claude Code finds Git Bash itself. |
| Hooks never run | Your organization may block project hooks (`disableAllHooks`, `allowManagedHooksOnly`). Run `sync` after each pull, then `/reload-skills`. |
| A skill changed on a desktop worktree branch doesn't arrive | Desktop worktree sessions use the main checkout's skills. See "Claude desktop worktree sessions". |
| Changes made outside Claude Code don't arrive | The file watcher may not work, for example in WSL on `/mnt/c`. Start a new session, or run `sync` and `/reload-skills`. |
| Windows: hook errors about running scripts being disabled | Claude Code starts PowerShell hooks with `-ExecutionPolicy Bypass`, unless `CLAUDE_CODE_POWERSHELL_RESPECT_EXECUTION_POLICY` is set. Unset it, or install Git for Windows so the hooks run in Git Bash. A Group Policy that enforces `AllSigned` overrides Bypass: then the `.ps1` must be signed, or Git Bash installed. |

## The hook command

Claude Code runs hooks in `/bin/sh` on macOS and Linux, and in Git Bash on Windows. On Windows without
Git Bash, it runs them in PowerShell. It never runs them in cmd.exe: a hook's `shell` setting accepts
only `bash` and `powershell`, and `CLAUDE_CODE_SHELL` and `CLAUDE_CODE_GIT_BASH_PATH` accept only bash,
zsh or sh. Claude Code chooses the shell itself, so it makes no difference whether someone starts
`claude` from cmd, PowerShell, Windows Terminal or an IDE, or uses the desktop app.

To find Git Bash, Claude Code tries `CLAUDE_CODE_GIT_BASH_PATH`, then `C:\Program Files\Git` and
`C:\Program Files (x86)\Git`, then the Git installation that the `git` on PATH belongs to. So a
per-user Git install is found too. Only when all three fail does it use PowerShell. This was read in
the 2.1.330 program; 2.1.220 accepts the same two hook shells.

Each hook in `.claude/settings.json` therefore uses one command that is valid in both shells:

```text
set \' ; ASB_CMD=session . "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh" ; exit ; #' ; & "$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1" session ; exit $LASTEXITCODE
```

- **POSIX shell.** `\'` is a quote character. The shell runs `set`, sources the shell script, and
  exits. Everything after `#` is a comment.
- **PowerShell.** `\'...#'` is one quoted argument to `set` (`Set-Variable`), so the POSIX half is
  inert. PowerShell then runs the `.ps1` file and passes its exit code on.
- **Not for cmd.** Typed into cmd, the command fails with "The filename, directory name, or volume
  label syntax is incorrect". To run the bridge by hand, use the commands under
  [Everyday use](#everyday-use).

Sourcing (`.`) instead of starting `sh` saves one process per hook run.

## Testing

These are the automated tests. To check a real Claude Code session by hand, follow the
[manual test](#manual-test).

```sh
sh .claude/hooks/agent-skills-bridge.test.sh        # the sh bridge, in any POSIX shell
sh .claude/hooks/agent-skills-bridge.test.sh ps1    # the PowerShell bridge (Git Bash on Windows)
```

The tests run the exact commands from `.claude/settings.json`, the way Claude Code runs them. They
cover:

- the first sync, a sync with nothing to do, source edits, removals, conflicts and repairs;
- the guard;
- links and junctions, a stale lock and the off switch;
- `status` and `clean`, and paths with spaces;
- in git: an existing `.claude/skills` with its own skill and `.gitignore`, and a clone with
  `core.autocrlf=true`;
- in svn: `svn:ignore` and a skill of your own.

Results on 25 November 2026:

| System | Shell | Result |
|---|---|---|
| Windows 11 | Git Bash (bash 5.2 as `sh`) | 77/77; Windows has no symlinks for the link cases |
| Windows 11 | Windows PowerShell 5.1 | 77/77 |
| Ubuntu 24.04 (WSL) | dash 0.5.12 | 78/78 |
| Ubuntu 24.04 (WSL) | bash 5.2 as `sh` | 78/78 |
| Ubuntu 24.04 (WSL) | zsh 5.9 as `sh` | 78/78 |
| Alpine 3.24 (container) | BusyBox 1.37 `ash` and tools | 59/59; no git or svn there |

A manual check from cmd.exe on Windows 11 also passed, in a repository whose path has a space:

- the PowerShell twin's `sync`, `status` and `clean`, from the repository and from another folder;
- `status` through Git's `sh.exe`, called by its full path;
- the SessionStart and guard hook commands in Git Bash and in PowerShell, with cmd's environment;
- the rule Claude Code uses to find Git Bash, applied in cmd: it found a per-user Git install
  through PATH.

Not run yet:

- **macOS.** The shell script avoids what the macOS `sh` (bash 3.2) lacks or does differently. It
  never expands an empty `"$@"`, which bash 3.2 rejects under `set -u`. It also copes with file times
  in whole seconds, as the BusyBox run shows. It has not run on a Mac.
- **PowerShell 7.** The `.ps1` is written for it, but this machine has no `pwsh`.
- **The manual test, end to end in a live session.** Its commands and expected `status` outputs
  were dry-run on Windows, with the hooks run the way Claude Code runs them.

The hooks were also checked live in Claude Code 2.1.330 (Claude desktop on Windows 11), in throwaway
repositories, with the previous layout. That layout kept the ignore rule in `.claude/skills/.gitignore`;
the hooks and the sync logic are unchanged.

- **Session start.** The skill was in Claude's list from the first prompt. The first sync took 6.8 s
  on a machine where security software makes each process start cost most of a second. A sync with
  nothing to do takes about half a second.
- **Live sync.** A source edit reached the copy in 1.3 s, and the same session then used the new
  version. A deleted skill's copy was gone in 1.5 s.
- **Guard.** An Edit of a copy was refused with the bridge's message.
- **Desktop worktree.** The hooks, the copy and the watch all came from the main checkout, as
  described above.

The guard's separate Write entry was added after the live check found the gap. It is covered by the
tests here, but has not yet been run live. Claude Code's skill loader skips a folder without
`SKILL.md` silently, so the record folder is never mistaken for a skill (read in the 2.1.330 program).

## Removing it

When Claude Code reads `.agents/skills` itself (watch #31005):

1. Delete the three hooks.
2. Run `sh .claude/hooks/agent-skills-bridge.sh clean`. In cmd or PowerShell on Windows, run
   `powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 clean`.
3. Delete the `agent-skills-bridge.*` files. Delete `.claude/hooks/.gitattributes` unless other
   scripts need it, and the anchor unless your own skills live in `.claude/skills`.

Until then, a Claude Code that loads both folders would just see each skill twice.
