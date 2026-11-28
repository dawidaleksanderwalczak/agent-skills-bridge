# agent-skills-bridge

A Claude Code plugin that makes Claude Code load the Agent Skills in `.agents/skills`.

## The Problem: Claude Code Ignores .agents/skills

Codex, GitHub Copilot, Cursor, JetBrains Junie and OpenCode load project skills from 
`.agents/skills`. **Claude Code does not.** It only reads from `.claude/skills`
([anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005) is still
open).

Without a bridge, teams must manage synchronization themselves, whether through manual copying, maintaining fragile symlinks (which often break across Windows and Git/SVN) or custom scripts.

The plugin automatically synchronizes skills from `.agents/skills` into `.claude/skills`, keeping the generated copies up to date, read-only and excluded from version control. The `.agents/skills` directory remains the single source of truth.

Under the hood, the plugin installs three Claude Code hooks that handle initial synchronization, keep skill copies current throughout a session, and prevent Claude Code from modifying the generated copies.

| | Source, committed | Copy, generated | In Claude Code |
|---|---|---|---|
| Generic | `.agents/skills/<name>/SKILL.md` | `.claude/skills/<name>/SKILL.md` | `/<name>` |
| Example | `.agents/skills/deploying-to-staging/SKILL.md` | `.claude/skills/deploying-to-staging/SKILL.md` | `/deploying-to-staging` |

## Technical Requirements for Plugin Usage

- Claude Code 2.1.220 or newer, desktop app or CLI
- Python 3.11 or newer on PATH, for the installer only. Any name will do: `python3`, `python`, `py`
  or a versioned one such as `python3.12`
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

3. **Commit** the files that the report lists, and start a new session.

Teammates get the bridge with their next pull. They don't need the plugin or Python.

## How to Use Skills After Installation

Keep your skills in `.agents/skills/<name>/SKILL.md` and edit them only there. Claude Code picks up
new, changed and deleted skills by itself.

To check a project, in its top folder:

```sh
sh .claude/hooks/agent-skills-bridge.sh status
```

In cmd or PowerShell on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status
```

The `hooks` line must say `.claude/settings.json runs the bridge`.

## How to Update the Bridge

```sh
claude plugin update agent-skills-bridge@agent-skills-bridge
```

Then run the install command in the project again, and commit. The plugin has no version number:
Claude Code takes the commit as its version, so an update always brings the newest commit.

## How to Uninstall the Bridge

**From a project.** In its top folder:

1. Delete the four hook entries that name `agent-skills-bridge` from `.claude/settings.json`.
2. Delete the copies. Your skills in `.agents/skills` stay.

   ```sh
   sh .claude/hooks/agent-skills-bridge.sh clean
   ```

   In cmd or PowerShell on Windows:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 clean
   ```

3. Delete `.claude/hooks/agent-skills-bridge.*`. Delete `.claude/hooks/.gitattributes` and
   `.claude/skills/.gitignore` too, unless other scripts or Claude-only skills of your own need them.
4. Commit.

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
| [docs/testing.md](docs/testing.md) | What the tests cover, where they passed, and how to run them |
| `.claude/hooks/agent-skills-bridge.md`, in an installed project | Everyday use, svn, worktrees, manual test, troubleshooting |
