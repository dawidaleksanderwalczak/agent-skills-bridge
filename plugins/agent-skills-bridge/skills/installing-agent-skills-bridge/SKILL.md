---
name: installing-agent-skills-bridge
description: >-
  Installs or updates the agent-skills-bridge kit in a project, so that Claude
  Code loads the Agent Skills kept in .agents/skills. Use only when the user
  explicitly asks to install, set up, add, update or repair the
  agent-skills-bridge (the bridge from .agents/skills to .claude/skills) in a
  git or svn repository. Runs a bundled installer that copies the hook scripts
  to .claude/hooks, merges the hooks into .claude/settings.json without
  replacing existing settings, and verifies the result. Installation only:
  never commits, never creates, moves or edits skills, and does not remove the
  bridge.
license: MIT
compatibility: >-
  Requires Python 3.11 or newer on PATH (standard library only; no network
  access and no package installation). The installed kit needs Claude Code
  2.1.220 or newer. Uses git and svn where the project does.
disable-model-invocation: true
argument-hint: "[project folder]"
---

# Installing the agent-skills-bridge

The bundled installer does the whole installation and checks its own work. You run it, act on its
exit code and relay its report. **Run the script; do not read it, and never copy or edit the kit's
files by hand.** It is a deterministic installer, not reference material.

- `<skill>` is the folder that holds this file. Claude Code fills it in here:
  `${CLAUDE_SKILL_DIR}`. If that still reads as a name with a dollar sign, your tool did not fill
  it in: use the folder this file was loaded from.
- `<project>` is the top folder of the project the user means: the folder they named, otherwise
  the folder this session was started in. Never a subfolder of it.

## 0. Precondition: the user asked for it

Continue only if the user asked for this installation in this conversation, by this skill's name
or in words. If you got here any other way, stop and ask first: the installation adds hooks to the
project's `.claude/settings.json`.

## 1. Run the installer

One command, on one line, flags included. It reads the same in bash and in PowerShell:

```
python3 -I -S "<skill>/scripts/install_bridge.py" --project "<project>"
```

- **Interpreter.** The script needs Python 3.11 or newer and nothing else. If `python3` does not
  start it, or it exits with 4 (interpreter too old), run the same line with `python`, then with
  `py -3`. If none of the three works, stop and tell the user that the installer needs
  Python 3.11 or newer. Do not install an interpreter.
- **Plan first.** If the user wants to see what would happen, add `--dry-run`. It reports and
  changes nothing.

The report is one JSON object on stdout.

## 2. Act on the exit code

| Exit | Meaning | What you do |
|---|---|---|
| 0 | Installed, or already current, and verified | Report (step 3). |
| 1 | Blocked. Nothing in the project was changed | Give the user the `message` and the `fix` of each entry in `blockers`, and ask whether to apply the fix. Change nothing in the project to get past a blocker without their yes. On a yes, apply it (`rerun_with`, where an entry has it, is the installer flag that does so) and run step 1 again. Without an answer, stop here. |
| 2 | Wrong arguments | Correct the command line. |
| 3 | The project was changed, but a later step failed | Give the user every entry in `problems`, and the `backups` folder if the report names one. |

Run the installer at most three times for one request. If it has not exited with 0 by then, stop
and show the user the last report. Call the bridge installed only after an exit code of 0.

## 3. Report

Tell the user, briefly:

- the project folder, and what happened to each file in `files` whose `action` is not `keep`. If
  every file was kept, say that the kit was already current;
- every entry in `notes`;
- the `next_steps`, as steps for them to take. Commit nothing, with git or with svn, unless the
  user asks.

`status` in the report is the bridge's own answer. The installer has checked it and has put what
matters into `notes` and `next_steps`, so run no command of the bridge yourself.

## Reference

- `<project>/.claude/hooks/agent-skills-bridge.md` (the installer puts it there)
  How the bridge works, its commands, the manual test, troubleshooting and removal.
  Read it only when the user asks about one of these. It starts with a table of contents.
