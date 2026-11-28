# agent-skills-bridge

A Claude Code plugin that makes Claude Code load the Agent Skills in `.agents/skills`.

## The Problem: Claude Code Ignores .agents/skills

Codex, GitHub Copilot, Cursor, JetBrains Junie and OpenCode load project skills from 
`.agents/skills`. **Claude Code does not.** It only reads from `.claude/skills`
([anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005) is still
open).

Without a bridge, teams must manage synchronization themselves, whether through manual copying, maintaining fragile symlinks (which often break across Windows and Git/SVN) or custom scripts.

The plugin automatically synchronizes skills from `.agents/skills` into `.claude/skills`, keeping the generated copies up to date, read-only and excluded from version control. The `.agents/skills` directory remains the single source of truth.

Technically, the plugin installs three Claude Code hooks that copy skills into `.claude/skills`, synchronize changes made to the source skills, and prevent Claude Code from modifying the generated copies.

The table below shows how a skill path in `.agents/skills` maps to its generated mirror and slash command in Claude Code.

| | Source directory (committed) | Generated directory | Claude Code command |
|---|---|---|---|
| Generic | `.agents/skills/<name>/SKILL.md` | `.claude/skills/<name>/SKILL.md` | `/<name>` |
| Example | `.agents/skills/deploying-to-staging/SKILL.md` | `.claude/skills/deploying-to-staging/SKILL.md` | `/deploying-to-staging` |

## Technical Requirements for Plugin Usage

- Claude Code 2.1.220 or newer, desktop app or CLI
- Python 3.11 or newer on PATH, for the installer and the uninstaller only. Any name will do:
  `python3`, `python`, `py` or a versioned one such as `python3.12`
- Windows (Git Bash or PowerShell), macOS or Linux; git or svn

## How to Install the Bridge

1. **Add the plugin, once per machine.** In a Claude Code session, 2.1.275 or newer:

   ```text
   /plugin install agent-skills-bridge --marketplace dawidaleksanderwalczak/agent-skills-bridge
   ```

   On an older Claude Code:

   ```text
   /plugin marketplace add dawidaleksanderwalczak/agent-skills-bridge
   /plugin install agent-skills-bridge@agent-skills-bridge
   ```

   From a terminal, write `claude plugin` in place of `/plugin`.

2. **Install the bridge, once per project.** Open the project in Claude Code and type:

   ```text
   /agent-skills-bridge:installing-agent-skills-bridge
   ```

   The installer adds the hooks to `.claude/settings.json` and the scripts to `.claude/hooks`, keeps
   your existing settings, and verifies the result. It commits nothing.

3. **Optional — commit to share with teammates.** If you want others on the project to get the bridge automatically on their next pull, commit the files listed in the report. Start a new session afterward—teammates won't need the plugin or Python.

## How to Use Skills After Installation

Keep your skills in `.agents/skills/<name>/SKILL.md` and edit them only there. Claude Code picks up
new, changed and deleted skills by itself.

## How to Update the Bridge

```sh
claude plugin update agent-skills-bridge@agent-skills-bridge
```

Then run the install command in the project again, and commit. The plugin has no version number:
Claude Code takes the commit as its version, so an update always brings the newest commit.

## How to Uninstall the Bridge

**From a project.**

1. Open the project in Claude Code and type:

   ```text
   /agent-skills-bridge:uninstalling-agent-skills-bridge
   ```

   The uninstaller takes the bridge's hooks out of `.claude/settings.json`, and deletes the scripts
   in `.claude/hooks`, the copies in `.claude/skills` and the bridge's records. Your other settings
   and hooks, your own skills and `.agents/skills` stay. It verifies the result and commits nothing.

2. **Commit** the removal that the report lists, and start a new session.

3. Type the command in every other checkout where a Claude Code session ran, a teammate's
   included. The copies are in no repository, so a pull removes none of them. The uninstaller
   deletes them also where the kit is already gone.

On a machine without Python, remove the bridge by hand:
[removing-by-hand.md](plugins/agent-skills-bridge/skills/uninstalling-agent-skills-bridge/references/removing-by-hand.md).

**From your machine.** This changes no project.

```text
/plugin uninstall agent-skills-bridge@agent-skills-bridge
/plugin marketplace remove agent-skills-bridge
```

## Additional Documentation

| Document | Content |
|---|---|
| [docs/overview.md](docs/overview.md) | Design, safety properties, support matrix, alternatives, risks |
| [docs/manual-installation.md](docs/manual-installation.md) | Installation by hand, for a machine without Python |
<<<<<<< HEAD
| [removing-by-hand.md](plugins/agent-skills-bridge/skills/uninstalling-agent-skills-bridge/references/removing-by-hand.md) | Removal by hand, for a machine without Python |
| [docs/testing.md](docs/testing.md) | What the tests cover, where they passed, and how to run them |
=======
>>>>>>> main
| `.claude/hooks/agent-skills-bridge.md`, in an installed project | Everyday use, svn, worktrees, manual test, troubleshooting |
