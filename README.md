# agent-skills-bridge

Makes Claude Code use the Agent Skills in `.agents/skills`.

Codex, GitHub Copilot, Cursor, JetBrains Junie and OpenCode read a project's skills from
`.agents/skills/<name>/SKILL.md`. Claude Code reads them only from `.claude/skills`, and the request
to change that, [anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005),
is still open. This kit closes the gap: three Claude Code hooks copy every skill from `.agents/skills`
to `.claude/skills`, keep the copies current while people work, and stop Claude from editing a copy.
The copies are read-only and ignored by git and svn, so nothing generated is ever committed.

- **A plugin installs it.** Add the plugin to Claude Code once. In a project, type one command: an
  installer puts the kit into the project and checks the result.
- **Nothing to install per person.** The kit is committed to the project, and Claude Code runs it.
- **Every environment.** Windows (Git Bash or PowerShell), macOS and Linux; git and svn; Claude
  desktop and the CLI.
- **Fits existing setups.** The project's own `.claude` settings, hooks and Claude-only skills stay
  as they are.
- **Tested.** The bridge's test suite passes on Windows (Git Bash, Windows PowerShell 5.1), Ubuntu
  (dash, bash, zsh) and Alpine (BusyBox), and the installer's on Windows and Ubuntu. macOS,
  PowerShell 7 and a live run of the manual test are still to do; see
  [docs/testing.md](docs/testing.md).

## What is in this repository

| Path | What it is |
|---|---|
| [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) | The marketplace file. With it, Claude Code installs the plugin from this repository by name. |
| [`plugins/agent-skills-bridge/`](plugins/agent-skills-bridge/) | The Claude Code plugin. It holds one skill, the installer, and with it everything that a project gets. |
| [`tests/`](tests/) | The tests for the bridge, the installer and the plugin |
| [`docs/overview.md`](docs/overview.md) | The design: requirements, how it works, the alternatives that were rejected, test evidence and risks |
| [`docs/testing.md`](docs/testing.md) | What the tests cover, and where they passed |
| [`docs/manual-installation.md`](docs/manual-installation.md) | The installation by hand, for a machine without Python |

The plugin folder holds only what Claude Code copies to a user's machine:

| In `plugins/agent-skills-bridge/` | What it is |
|---|---|
| [`.claude-plugin/plugin.json`](plugins/agent-skills-bridge/.claude-plugin/plugin.json) | The plugin's manifest: name, description, author, licence |
| [`README.md`](plugins/agent-skills-bridge/README.md) | The short guide that travels with the plugin |
| [`skills/installing-agent-skills-bridge/`](plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/) | The installer skill, the plugin's only component |

The skill folder holds only what the skill needs:

| In `skills/installing-agent-skills-bridge/` | What it is |
|---|---|
| [`SKILL.md`](plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/SKILL.md) | What the agent does: run the installer, act on its exit code, report |
| [`scripts/install_bridge.py`](plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/scripts/install_bridge.py) | The installer: Python 3.11 or newer, standard library only |
| [`agents/openai.yaml`](plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/agents/openai.yaml) | Tells Codex and ChatGPT to run the skill only when the user names it |
| [`assets/kit/`](plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit/) | The kit: the files that the installer puts into a project. The folder stands for the project's `.claude` folder. |

The kit:

| In `assets/kit/` | In the project | What it is |
|---|---|---|
| `settings.json` | `.claude/settings.json` | The hooks: four entries for three events |
| `hooks/agent-skills-bridge.sh` | `.claude/hooks/` | The bridge in POSIX `sh`, for macOS, Linux and Windows with Git Bash |
| `hooks/agent-skills-bridge.ps1` | `.claude/hooks/` | The same bridge in PowerShell, for Windows without Git Bash, and for running it by hand in cmd or PowerShell |
| [`hooks/agent-skills-bridge.md`](plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit/hooks/agent-skills-bridge.md) | `.claude/hooks/` | The bridge's documentation. It travels with the kit into every project. |
| `hooks/.gitattributes` | `.claude/hooks/` | Keeps the shell script LF in every git checkout |
| `skills/.gitignore` | `.claude/skills/` | The anchor: it keeps `.claude/skills` in every checkout and ignores nothing |

## Add the kit to a project

You need Claude Code 2.1.220 or newer (the desktop app updates itself) and Python 3.11 or newer.
On Windows, the hooks run in Git Bash when Git for Windows is installed, and in Windows PowerShell
otherwise.

1. **Add the plugin, once per machine.** In a Claude Code session, 2.1.275 or newer:

   ```text
   /plugin install agent-skills-bridge --marketplace dawidaleksanderwalczak/agent-skills-bridge
   ```

   Claude Code shows where the plugin comes from and asks for the scope. Choose "for you", so that
   every project on the machine has it. On an older Claude Code, take two steps:

   ```text
   /plugin marketplace add dawidaleksanderwalczak/agent-skills-bridge
   /plugin install agent-skills-bridge@agent-skills-bridge
   ```

   From a terminal, write `claude plugin` in place of `/plugin`. In the desktop app, the plugin
   browser lists the plugin once the marketplace is added: click **+** next to the prompt box.

   The plugin holds one skill and nothing else. It adds no hook, no server and no program to your
   sessions.
2. **Install the bridge.** Open the project in Claude Code and type:

   ```text
   /agent-skills-bridge:installing-agent-skills-bridge
   ```

   Claude runs the installer and reports what it did. Only you can start this skill: Claude never
   starts it by itself, because it adds hooks to the project.
3. **Commit** the files that the report lists. The installer commits nothing.
4. Put your skills in `.agents/skills/<name>/SKILL.md` if they aren't there yet, and start a new
   Claude Code session. Hooks are read when a session starts.

Teammates get the kit with their next pull. They install nothing, and they don't need the plugin.

### What the installer does

| It finds | It does |
|---|---|
| No `.claude` folder, or one without the kit | Creates the kit's files |
| An older kit | Replaces the three `agent-skills-bridge.*` files, and the hook entries of the older kit |
| A `.claude/settings.json` | Adds the four hook entries next to your settings and hooks. The file keeps its indentation, line endings and the order of its keys. |
| A `.claude/hooks/.gitattributes` | Adds the line `*.sh text eol=lf`, unless a line already says so |
| A `.claude/skills/.gitignore` | Nothing: the bridge needs no line in it |
| An svn working copy | Schedules the kit's files, sets `svn:ignore` on `.claude/skills` and `svn:eol-style` on the shell script, and keeps an `svn:ignore` value that is already there. It leaves out the two files that only git needs. |
| A `.claude/settings.json` that is not valid JSON, for example with comments | Stops. Nothing is changed. |
| A link in the place of `.claude`, `.claude/hooks`, `.claude/skills` or a kit file | Stops. Nothing is changed: it never writes through a link. |
| A `.gitignore` that ignores the whole `.claude` folder | Stops, and Claude asks you. If you agree, it rewrites that one rule so that git sees `settings.json`, `hooks/` and `skills/`. |
| A file that it cannot write, or a check that fails after writing | Puts every file back as it was |

It then runs the bridge's `status` command in the shell that Claude Code runs the hooks in, and
checks the answer. A file that it replaces is kept as it was in a folder outside the project, and
the report names that folder. The installer never commits, never prompts, and installs nothing on
the machine.

### Without the plugin

The installer is a plain script. Clone this repository next to the project, and run the script from
any terminal, in the project's top folder:

```sh
python3 -I -S ../agent-skills-bridge/plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/scripts/install_bridge.py
```

On Windows, where the command is usually `py`:

```powershell
py -3 -I -S ..\agent-skills-bridge\plugins\agent-skills-bridge\skills\installing-agent-skills-bridge\scripts\install_bridge.py
```

- `--dry-run` reports what would be done, and changes nothing.
- `--project <folder>` names the project instead of the working directory.
- `--help` lists the options and the exit codes.

It prints a JSON report. Its exit code is 0 when the kit is installed and verified, 1 when
something was in the way and nothing was changed, and 3 when the project was changed but a later
step failed.

The skill folder is also a complete Agent Skill by itself. Copied to `~/.claude/skills`, it runs as
`/installing-agent-skills-bridge` without the plugin.

Without Python, follow [docs/manual-installation.md](docs/manual-installation.md).

## Check that it works

The installer has already run the bridge's `status` command. To run it again, in the project's top
folder:

```sh
sh .claude/hooks/agent-skills-bridge.sh status
```

In cmd or PowerShell on Windows, where `sh` is usually not on PATH:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status
```

The `hooks` line must say `.claude/settings.json runs the bridge`. Then run the manual test once,
in Claude desktop or in the CLI: "Manual test" in the project's
`.claude/hooks/agent-skills-bridge.md`. It takes about ten minutes and shows the whole chain
working on your machine.

Claude desktop runs worktree sessions with the hooks of the main checkout, so there the kit works
once the main checkout has it. See "Claude desktop worktree sessions" in the same file.

## Update a project to a newer kit

1. Update the plugin. Claude Code does not update it by itself, unless you turn on auto-update for
   the marketplace. In a terminal:

   ```sh
   claude plugin update agent-skills-bridge@agent-skills-bridge
   ```

   In a session, `/plugin` lists the plugin under **Installed**, with **Update now**. Then start a
   new session, or run `/reload-plugins`.
2. Type `/agent-skills-bridge:installing-agent-skills-bridge` in the project again. The installer
   replaces what changed, the hook entries included, and leaves the rest.
3. Commit.

To see whether a project is current without changing it, ask for a dry run: type the command and
add "dry run". The installer then reports and changes nothing. The report's `kit_version` names the
kit; the installer suggests it for the commit message.

## Remove it

Once Claude Code reads `.agents/skills` itself, follow "Removing it" in the project's
`.claude/hooks/agent-skills-bridge.md`.

The plugin is separate from the projects: removing it changes no project. To take the plugin and its
marketplace off your machine, in a terminal:

```sh
claude plugin marketplace remove agent-skills-bridge
```

## Work on the kit

- Change the shell script and the PowerShell script together: both must behave the same, and one test
  suite checks both. Update the documentation in the same commit.
- Run the tests. They build throwaway projects in the temp folder. The git and svn cases run where
  those tools are installed.

  ```sh
  sh tests/agent-skills-bridge.test.sh        # the sh bridge, in any POSIX shell
  sh tests/agent-skills-bridge.test.sh ps1    # the PowerShell bridge (Git Bash on Windows)
  python3 tests/test_install_bridge.py        # the plugin and its installer (py -3.11 on Windows)
  claude plugin validate .                    # Claude Code's own check of marketplace and plugin
  ```

  `claude plugin validate` reports one warning, "No version specified". That is intended: see
  "Versions" below.

  The bridge tests and the hook commands use the first `sh` on PATH. To test another shell as `sh`,
  such as dash, bash or zsh on Linux, put a link named `sh` to it first on PATH.
- Keep the scripts ASCII. Windows PowerShell 5.1 reads a `.ps1` file without a byte order mark in the
  local ANSI code page.
- Keep the plugin folder lean. The skill folder holds the skill, the installer and the kit, and no
  other document. The plugin folder holds its manifest, its README and the skill, and no hook,
  command, agent or server. A test fails when another file turns up in either. The installer
  imports the standard library only, and a test checks that too.
- Try a change of the plugin in a session without installing it:
  `claude --plugin-dir plugins/agent-skills-bridge`.
- Record new results in [docs/testing.md](docs/testing.md).

### Versions

Neither `plugin.json` nor the marketplace file names a version. Claude Code then takes the commit
as the plugin's version, so every commit on the default branch reaches the users who update. With a
version in the manifest, users would stay on their copy until someone raises the number. If you
ever want numbered releases, put the version in `plugin.json` only, and raise it with every change
to the plugin.

## Related tools

Sentry's [dotagents](https://github.com/getsentry/dotagents), in beta in November 2026, is an npm
package that manages `.agents` folders and symlinks `.agents/skills` into `.claude/skills`. This kit
needs no package manager and no Node.js. It copies instead of linking, because symbolic links need
Developer Mode or administrator rights on Windows.
[Alternatives considered](docs/overview.md#9-alternatives-considered) explains the choice.
