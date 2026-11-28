# Removing the agent-skills-bridge by hand

The uninstaller of this skill does all of this, and checks more than a person would. Use this page
on a machine without Python 3.11 or newer, or where the uninstaller's report names it.

An agent takes these steps only when the user asked for the removal by hand, and edits nothing
beyond what they name.

All paths count from the project's top folder. The skills in `.agents/skills` are not touched.

## 1. Take the hooks out of the settings

In `.claude/settings.json`, delete every hook entry whose `command` names `agent-skills-bridge`:
one under `SessionStart`, one under `FileChanged` and two under `PreToolUse`. Do the same in
`.claude/settings.local.json`, if that file has such entries.

- Hooks of the project's own stay. Where a group holds one of them next to the bridge's entry,
  delete the bridge's entry only.
- Delete a group, an event and then `hooks` itself where nothing else is left in it.
- If `.claude/settings.json` then holds nothing but `{}`, delete the file.

## 2. Delete the copies

Run the bridge's `clean` command while its script is still there. It deletes every copy that the
bridge made in `.claude/skills`, and the bridge's records in `.claude/skills/.agent-skills-bridge`.
A skill of the project's own stays, also one that has taken the place of a copy: the command names
it.

macOS, Linux, Git Bash:

```sh
sh .claude/hooks/agent-skills-bridge.sh clean
```

cmd or PowerShell on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 clean
```

The script is a program that the project holds: run it only in a project that the user trusts.

If the script is gone already, because a pull took the kit away, the copies are still there. Each
copy is a folder in `.claude/skills` with a `.gitignore` whose first line begins with
`# Copy of .agents/skills/`. Delete those folders and `.claude/skills/.agent-skills-bridge`. Leave
every folder without that file alone.

## 3. Delete the kit's files

- `.claude/hooks/agent-skills-bridge.sh`, `agent-skills-bridge.ps1` and `agent-skills-bridge.md`,
  and `agent-skills-bridge.test.sh` where an older kit left it.
- `.claude/hooks/.gitattributes`, unless it holds rules of the project's own, or another shell
  script in `.claude/hooks` needs its rule `*.sh text eol=lf`.
- `.claude/skills/.gitignore`, unless it holds rules: the kit's file holds comments only.
- The folders `.claude/hooks`, `.claude/skills` and `.claude`, where they are empty now.

## 4. Tell version control

Commit nothing unless the user asks.

**git.** The removal shows in `git status` as deleted and changed files: stage and commit them.

If the installer once rewrote a rule in the project's `.gitignore` (its `--fix-gitignore` option),
the file holds these four lines in a row, the first also as `/.claude/*`:

```gitignore
**/.claude/*
!/.claude/settings.json
!/.claude/hooks/
!/.claude/skills/
```

They let git see the kit. To have git ignore the whole folder again, replace them with the one
line `.claude/`. That is the user's decision: git then ignores what is new in `.claude`, their own
files included.

**svn.** Delete the kit's files with `svn delete` in place of a plain delete, and the folders that
are empty with it too. Where `.claude/skills` stays, because skills of the project's own live in
it, take the bridge's rule out of its ignore list: `svn propdel svn:ignore .claude/skills` if the
value is `*` alone, `svn propedit svn:ignore .claude/skills` if it holds other rules too.

## 5. Other checkouts

The copies are in no repository, so a pull or an update removes none of them. In every other
checkout where a Claude Code session ran, on a teammate's machine or in another worktree, do step
2 before the kit goes, or delete the copies by hand afterwards as step 2 describes.
