---
name: uninstalling-agent-skills-bridge
description: >-
  Uninstalls the agent-skills-bridge kit from a project: takes the bridge's
  hook entries out of .claude/settings.json and deletes its scripts, the
  copies it made in .claude/skills and its records. Use only when the user
  explicitly asks to uninstall, remove, delete or get rid of the
  agent-skills-bridge (the bridge from .agents/skills to .claude/skills) in a
  git or svn repository, or to clean up what it left behind. Runs a bundled
  uninstaller that keeps every other setting, hook and skill, and verifies
  the result. Removal only: never commits, never touches .agents/skills, and
  does not install the bridge or uninstall the plugin.
license: MIT
compatibility: >-
  Requires Python 3.11 or newer on PATH, under any of the names python3,
  python, py or python3.x (standard library only; no network access and no
  package installation). Needs the installing-agent-skills-bridge skill of
  the same plugin next to it: the bridge's script from there deletes the
  copies. Uses git and svn where the project does.
disable-model-invocation: true
argument-hint: "[project folder]"
---

# Uninstalling the agent-skills-bridge

The bundled uninstaller does the whole removal and checks its own work. You run it, act on the
outcome it reports and relay its report. **Run the script; do not read it, and never delete or edit
the bridge's files by hand.** It is a deterministic uninstaller, not reference material.

- `<skill>` is the folder that holds this file. Claude Code fills it in here:
  `${CLAUDE_SKILL_DIR}`. If that still reads as a name with a dollar sign, your tool did not fill
  it in: use the folder this file was loaded from.
- `<project>` is the top folder of the project the user means: the folder they named, otherwise
  the folder this session was started in. Never a subfolder of it.

## 0. Precondition: the user asked for it

Continue only if the user asked for this removal in this conversation, by this skill's name or in
words. If you got here any other way, stop and ask first: the removal deletes hooks and files from
the project.

## 1. Run the uninstaller

One command, on one line, flags included. It reads the same in bash, zsh and PowerShell:

```
python3 -I -S "<skill>/scripts/uninstall_bridge.py" --project "<project>"
```

Write both paths without a slash or backslash at the end, and put nothing behind the line: no
pipe and no redirection.

The uninstaller answers with one JSON object on stdout, the report, and writes nothing to stderr.

- **No report.** Then the uninstaller did not run, whatever the exit code and the message say: the
  shell found no `python3`, or that name starts a placeholder that only offers to install Python,
  or a Python too old to read the script. Run the same line with `python` in place of `python3`,
  then with `py -3`. If none of the three prints a report, stop and tell the user that the
  uninstaller needs Python 3.11 or newer on PATH, and that the bridge can be removed by hand
  instead (see Reference). Do not install an interpreter.
- **An older Python.** The uninstaller needs Python 3.11 or newer and nothing else. Started with
  an older one, it looks on PATH for a newer one, `python3.12` for example, and goes on with that
  by itself. A note in the report then says so, and you run nothing for it.
- **Plan first.** If the user wants to see what would happen, add `--dry-run`. It reports and
  changes nothing.

## 2. Act on the outcome

The report's `outcome` and the exit code say the same thing. If they differ, because a shell
changed the exit code, go by the `outcome`.

| `outcome` | Exit | Meaning | What you do |
|---|---|---|---|
| `uninstalled` | 0 | The bridge is gone from the project, and that was verified | Report (step 3). |
| `not installed` | 0 | Nothing of the bridge was found, and nothing was changed | Report (step 3). |
| `would change` | 0 | A dry run found something to remove | Report (step 3). Nothing is removed yet. |
| `blocked` | 1 | Nothing of the kit was removed | Give the user the `message` and the `fix` of each entry in `blockers`, and ask whether to apply the fix. Change nothing in the project to get past a blocker without their yes. On a yes, apply it and run step 1 again. Without an answer, stop here. |
| `wrong arguments` | 2 | The command line is wrong | Correct it: `message` says what is wrong. |
| `incomplete` | 3 | The project was changed, but a later step failed | Give the user every entry in `problems`, and the `backups` folder if the report names one. |
| `python too old` | 4 | No Python 3.11 or newer is on PATH | Stop. Give the user the `message` and the `fix`. Do not install an interpreter. |

**Offers.** A report of any outcome can hold `offers`: steps that the uninstaller left out because
they need the user's yes. Ask the user each `message`. Only on a yes, run step 1 again with that
entry's `rerun_with` flag added. Never pass such a flag by yourself.

Run the uninstaller at most three times for one request; a line that printed no report does not
count. If the outcome is not `uninstalled` or `not installed` by then, stop and show the user the
last report. Call the bridge uninstalled only after one of these two outcomes.

## 3. Report

Tell the user, briefly:

- the project folder, and what happened to each entry in `files` whose `action` is not `keep`.
  After `not installed`, say that nothing of the bridge was found and nothing was changed;
- every entry in `notes`;
- the `backups` folder, if the report names one: the files as they were before the removal;
- the `next_steps`, as steps for them to take. Commit nothing, with git or with svn, unless the
  user asks.

`clean` in the report is the answer of the bridge's own clean command, which deleted the copies.
The uninstaller has checked it and has put what matters into `notes`, so run no command of the
bridge yourself.

The plugin stays on the machine: it serves the user's other projects. Only if the user wants that
gone too, they type `/plugin uninstall agent-skills-bridge@agent-skills-bridge` themselves.

## Reference

- `references/removing-by-hand.md`
  The same removal, step by step, without the uninstaller.
  Read it only when the uninstaller cannot run (no Python 3.11 or newer, or a blocker's `fix`
  names the page), or when the user asks how to remove the bridge by hand.
