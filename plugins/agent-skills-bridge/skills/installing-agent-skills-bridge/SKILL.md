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
  Requires Python 3.11 or newer on PATH, under any of the names python3,
  python, py or python3.x (standard library only; no network access and no
  package installation). The installed kit needs Claude Code 2.1.220 or
  newer. Uses git and svn where the project does.
disable-model-invocation: true
argument-hint: "[project folder]"
---

# Installing the agent-skills-bridge

The bundled installer does the whole installation and checks its own work. You run it, act on the
outcome it reports and relay its report. **Run the script; do not read it, and never copy or edit
the kit's files by hand.** It is a deterministic installer, not reference material.

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

One command, on one line, flags included. It reads the same in bash, zsh and PowerShell:

```
python3 -I -S "<skill>/scripts/install_bridge.py" --project "<project>"
```

Write both paths without a slash or backslash at the end, and put nothing behind the line: no
pipe and no redirection.

The installer answers with one JSON object on stdout, the report, and writes nothing to stderr.

- **No report.** Then the installer did not run, whatever the exit code and the message say: the
  shell found no `python3`, or that name starts a placeholder that only offers to install Python,
  or a Python too old to read the script. Run the same line with `python` in place of `python3`,
  then with `py -3`. If none of the three prints a report, stop and tell the user that the
  installer needs Python 3.11 or newer on PATH. Do not install an interpreter.
- **An older Python.** The installer needs Python 3.11 or newer and nothing else. Started with an
  older one, it looks on PATH for a newer one, `python3.12` for example, and goes on with that by
  itself. A note in the report then says so, and you run nothing for it.
- **Plan first.** If the user wants to see what would happen, add `--dry-run`. It reports and
  changes nothing.

## 2. Act on the outcome

The report's `outcome` and the exit code say the same thing. If they differ, because a shell
changed the exit code, go by the `outcome`.

| `outcome` | Exit | Meaning | What you do |
|---|---|---|---|
| `installed`, `current` | 0 | Installed, or already current, and verified | Report (step 3). |
| `would change` | 0 | A dry run found something to do | Report (step 3). Nothing is installed yet. |
| `blocked` | 1 | Nothing in the project was changed | Give the user the `message` and the `fix` of each entry in `blockers`, and ask whether to apply the fix. Change nothing in the project to get past a blocker without their yes. On a yes, apply it (`rerun_with`, where an entry has it, is the installer flag that does so) and run step 1 again. Without an answer, stop here. |
| `wrong arguments` | 2 | The command line is wrong | Correct it: `message` says what is wrong. |
| `incomplete` | 3 | The project was changed, but a later step failed | Give the user every entry in `problems`, and the `backups` folder if the report names one. |
| `python too old` | 4 | No Python 3.11 or newer is on PATH | Stop. Give the user the `message` and the `fix`. Do not install an interpreter. |

Run the installer at most three times for one request; a line that printed no report does not
count. If the outcome is not `installed` or `current` by then, stop and show the user the last
report. Call the bridge installed only after one of these two outcomes.

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
