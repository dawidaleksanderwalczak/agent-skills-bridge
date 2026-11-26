# agent-skills-bridge

Makes Claude Code use the Agent Skills in `.agents/skills`.

Codex, GitHub Copilot, Cursor, JetBrains Junie and OpenCode read a project's skills from
`.agents/skills/<name>/SKILL.md`. Claude Code reads them only from `.claude/skills`, and the request
to change that, [anthropics/claude-code#31005](https://github.com/anthropics/claude-code/issues/31005),
is still open. This kit closes the gap: three Claude Code hooks copy every skill from `.agents/skills`
to `.claude/skills`, keep the copies current while people work, and stop Claude from editing a copy.
The copies are read-only and ignored by git and svn, so nothing generated is ever committed.

- **Nothing to install per person.** The kit is committed to the project, and Claude Code runs it.
- **Every environment.** Windows (Git Bash or PowerShell), macOS and Linux; git and svn; Claude
  desktop and the CLI.
- **Fits existing setups.** The project's own `.claude` settings, hooks and Claude-only skills stay
  as they are.
- **Tested.** The test suite passes on Windows (Git Bash, Windows PowerShell 5.1), Ubuntu (dash,
  bash, zsh) and Alpine (BusyBox). macOS, PowerShell 7 and a live run of the manual test are still to
  do; see [Testing](.claude/hooks/agent-skills-bridge.md#testing).

## What is in this repository

The kit's files sit at the paths they take in a project: `.claude/` here becomes `.claude/` there.

| File | What it is |
|---|---|
| [`.claude/settings.json`](.claude/settings.json) | The hooks: four entries for three events |
| [`.claude/hooks/agent-skills-bridge.sh`](.claude/hooks/agent-skills-bridge.sh) | The bridge in POSIX `sh`, for macOS, Linux and Windows with Git Bash |
| [`.claude/hooks/agent-skills-bridge.ps1`](.claude/hooks/agent-skills-bridge.ps1) | The same bridge in PowerShell, for Windows without Git Bash, and for running it by hand in cmd or PowerShell |
| [`.claude/hooks/agent-skills-bridge.md`](.claude/hooks/agent-skills-bridge.md) | The full documentation. It travels with the kit into every project. |
| [`.claude/hooks/agent-skills-bridge.test.sh`](.claude/hooks/agent-skills-bridge.test.sh) | Scenario tests for both scripts |
| [`.claude/hooks/.gitattributes`](.claude/hooks/.gitattributes) | Keeps the shell scripts LF in every git checkout |
| [`.claude/skills/.gitignore`](.claude/skills/.gitignore) | The anchor: it keeps `.claude/skills` in every checkout and ignores nothing |

[`docs/overview.md`](docs/overview.md) describes the design: requirements, how it works, the
alternatives that were rejected, test evidence and risks. It stays here; projects don't need it.

## Add the kit to a project

You need Claude Code 2.1.220 or newer; the desktop app updates itself. Nothing else: on Windows, the
hooks run in Git Bash when Git for Windows is installed, and in Windows PowerShell otherwise.

### git

1. Clone this repository. Open a terminal in your project's top folder, and copy the kit with the
   commands below. Set `kit` to the folder of your clone; the example assumes that it sits next to
   your project. The commands never overwrite a `settings.json`, `.gitattributes` or `.gitignore`
   that your project already has.

   Windows (PowerShell):

   ```powershell
   $kit = '..\agent-skills-bridge'
   New-Item -ItemType Directory -Force .claude\hooks, .claude\skills | Out-Null
   Copy-Item -Force "$kit\.claude\hooks\agent-skills-bridge.*" .claude\hooks
   foreach ($f in 'settings.json', 'hooks\.gitattributes', 'skills\.gitignore') {
     if (-not (Test-Path ".claude\$f")) { Copy-Item "$kit\.claude\$f" ".claude\$f" }
   }
   ```

   macOS, Linux, Git Bash:

   ```sh
   kit=../agent-skills-bridge
   mkdir -p .claude/hooks .claude/skills
   cp "$kit"/.claude/hooks/agent-skills-bridge.* .claude/hooks/
   for f in settings.json hooks/.gitattributes skills/.gitignore; do
     [ -e ".claude/$f" ] || cp "$kit/.claude/$f" ".claude/$f"
   done
   ```

2. If your project already had one of these files, finish by hand. The kit's documentation covers
   each case in
   [Adopt it next to an existing `.claude` folder](.claude/hooks/agent-skills-bridge.md#adopt-it-next-to-an-existing-claude-folder).
   - `.claude/settings.json`: add the kit's four hook entries to it, two of them under `PreToolUse`.
     Claude Code can do this: ask it to "add the four agent-skills-bridge hook entries from
     ../agent-skills-bridge/.claude/settings.json to ours".
   - `.claude/hooks/.gitattributes`: add the line `*.sh text eol=lf`.
   - `.claude/skills/.gitignore`: nothing to do. The bridge needs no line in it.
   - A root `.gitignore` that ignores `.claude/`: git can't see the kit. Change the rule as that
     section shows.
3. Commit the kit. The message names the kit's commit, so you can tell later which version the
   project has. The two lines work in PowerShell too:

   ```sh
   git add .claude/settings.json .claude/hooks/agent-skills-bridge.* .claude/hooks/.gitattributes .claude/skills/.gitignore
   git commit -m "Add agent-skills-bridge $(git -C "$kit" rev-parse --short HEAD)"
   ```

4. Put your skills in `.agents/skills/<name>/SKILL.md` if they aren't there yet, commit them, and
   [check that it works](#check-that-it-works).

Teammates get the kit with their next pull. They install nothing.

### svn

Copy the kit without its two git files, `.claude/hooks/.gitattributes` and
`.claude/skills/.gitignore`:

Windows (PowerShell):

```powershell
$kit = '..\agent-skills-bridge'
New-Item -ItemType Directory -Force .claude\hooks | Out-Null
Copy-Item -Force "$kit\.claude\hooks\agent-skills-bridge.*" .claude\hooks
if (-not (Test-Path .claude\settings.json)) { Copy-Item "$kit\.claude\settings.json" .claude }
```

macOS, Linux, Git Bash:

```sh
kit=../agent-skills-bridge
mkdir -p .claude/hooks
cp "$kit"/.claude/hooks/agent-skills-bridge.* .claude/hooks/
[ -e .claude/settings.json ] || cp "$kit/.claude/settings.json" .claude/
```

Merge the hooks into an existing `settings.json` as described for git. Then run the commands in
[Adopt it in an svn working copy](.claude/hooks/agent-skills-bridge.md#adopt-it-in-an-svn-working-copy).
They add the kit, keep the copies out of svn with `svn:ignore`, and keep the shell scripts LF.

## Check that it works

In the project's top folder:

```sh
sh .claude/hooks/agent-skills-bridge.sh status
```

In cmd or PowerShell on Windows, where `sh` is usually not on PATH:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 status
```

The `hooks` line must say `.claude/settings.json runs the bridge`. Then run the
[manual test](.claude/hooks/agent-skills-bridge.md#manual-test) once, in Claude desktop or in the
CLI. It takes about ten minutes and shows the whole chain working on your machine.

Claude desktop runs worktree sessions with the hooks of the main checkout, so there the kit works
once the main checkout has it. See
[Claude desktop worktree sessions](.claude/hooks/agent-skills-bridge.md#claude-desktop-worktree-sessions).

To try the kit before you add it anywhere, run the manual test in your clone of this repository: the
repository runs its own kit.

## Update a project to a newer kit

1. Pull your clone of this repository, and run the copy commands again. They replace the four
   `agent-skills-bridge.*` files and leave the project's other files alone.
2. Check whether the kit's other files changed since your last update. Replace `1234abc` with the kit
   commit named in your last update:

   ```sh
   git -C "$kit" log -p "1234abc..HEAD" -- .claude/settings.json .claude/hooks/.gitattributes .claude/skills/.gitignore
   ```

   If it lists a change, most likely to `settings.json`, make the same change in the project by hand.
3. Commit, as in step 3 of the git section, with `Update` in place of `Add` in the message.

## Remove it

Once Claude Code reads `.agents/skills` itself, follow
[Removing it](.claude/hooks/agent-skills-bridge.md#removing-it).

## Work on the kit

- Change the shell script and the PowerShell script together: both must behave the same, and one test
  suite checks both. Update the documentation in the same commit.
- Run the tests. They build throwaway repositories in the temp folder. The git and svn cases run
  where those tools are installed.

  ```sh
  sh .claude/hooks/agent-skills-bridge.test.sh        # the sh bridge, in any POSIX shell
  sh .claude/hooks/agent-skills-bridge.test.sh ps1    # the PowerShell bridge (Git Bash on Windows)
  ```

  The tests and the hook commands use the first `sh` on PATH. To test another shell as `sh`, such as
  dash, bash or zsh on Linux, put a link named `sh` to it first on PATH.
- Keep the scripts ASCII. Windows PowerShell 5.1 reads a `.ps1` file without a byte order mark in the
  local ANSI code page.
- Record new results in the documentation's [Testing](.claude/hooks/agent-skills-bridge.md#testing)
  section.

## Related tools

Sentry's [dotagents](https://github.com/getsentry/dotagents), in beta in November 2026, is an npm
package that manages `.agents` folders and symlinks `.agents/skills` into `.claude/skills`. This kit
needs no package manager and no Node.js. It copies instead of linking, because symbolic links need
Developer Mode or administrator rights on Windows.
[Alternatives considered](docs/overview.md#9-alternatives-considered) explains the choice.
