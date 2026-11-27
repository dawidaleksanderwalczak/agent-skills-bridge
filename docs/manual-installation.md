# Installing the kit by hand

The [installer skill](../README.md#install) does all of this, and checks more than
a person would. Use this page on a machine without Python 3.11.

The kit's files are in `plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit` of this repository. That
folder stands for the project's `.claude` folder. The kit's documentation,
[`agent-skills-bridge.md`](../plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit/hooks/agent-skills-bridge.md),
describes every case in its sections "Adopt it in a git repository", "Adopt it next to an existing
`.claude` folder" and "Adopt it in an svn working copy".

## git

1. Clone this repository. Open a terminal in your project's top folder, and copy the kit with the
   commands below. Set `kit` to the kit folder of your clone; the example assumes that the clone
   sits next to your project. The commands never overwrite a `settings.json`, `.gitattributes` or
   `.gitignore` that your project already has.

   Windows (PowerShell):

   ```powershell
   $kit = '..\agent-skills-bridge\plugins\agent-skills-bridge\skills\installing-agent-skills-bridge\assets\kit'
   New-Item -ItemType Directory -Force .claude\hooks, .claude\skills | Out-Null
   Copy-Item -Force "$kit\hooks\agent-skills-bridge.*" .claude\hooks
   foreach ($f in 'settings.json', 'hooks\.gitattributes', 'skills\.gitignore') {
     if (-not (Test-Path ".claude\$f")) { Copy-Item "$kit\$f" ".claude\$f" }
   }
   ```

   macOS, Linux, Git Bash:

   ```sh
   kit=../agent-skills-bridge/plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit
   mkdir -p .claude/hooks .claude/skills
   cp "$kit"/hooks/agent-skills-bridge.* .claude/hooks/
   for f in settings.json hooks/.gitattributes skills/.gitignore; do
     [ -e ".claude/$f" ] || cp "$kit/$f" ".claude/$f"
   done
   ```

2. If your project already had one of these files, finish by hand:
   - `.claude/settings.json`: add the kit's four hook entries to it, two of them under `PreToolUse`.
     Copy the command strings in full from the kit's `settings.json`.
   - `.claude/hooks/.gitattributes`: add the line `*.sh text eol=lf`.
   - `.claude/skills/.gitignore`: nothing to do. The bridge needs no line in it.
   - A root `.gitignore` that ignores `.claude/`: git can't see the kit. Change the rule as the
     kit's documentation shows.
3. Commit the kit. The message names the kit's commit, so you can tell later which version the
   project has. The two lines work in PowerShell too:

   ```sh
   git add .claude/settings.json .claude/hooks/agent-skills-bridge.* .claude/hooks/.gitattributes .claude/skills/.gitignore
   git commit -m "Add agent-skills-bridge $(git -C "$kit" rev-parse --short HEAD)"
   ```

4. Put your skills in `.agents/skills/<name>/SKILL.md` if they aren't there yet, commit them, and
   [check that it works](../README.md#use).

## svn

Copy the kit without its two git files, `hooks/.gitattributes` and `skills/.gitignore`.

Windows (PowerShell):

```powershell
$kit = '..\agent-skills-bridge\plugins\agent-skills-bridge\skills\installing-agent-skills-bridge\assets\kit'
New-Item -ItemType Directory -Force .claude\hooks | Out-Null
Copy-Item -Force "$kit\hooks\agent-skills-bridge.*" .claude\hooks
if (-not (Test-Path .claude\settings.json)) { Copy-Item "$kit\settings.json" .claude }
```

macOS, Linux, Git Bash:

```sh
kit=../agent-skills-bridge/plugins/agent-skills-bridge/skills/installing-agent-skills-bridge/assets/kit
mkdir -p .claude/hooks
cp "$kit"/hooks/agent-skills-bridge.* .claude/hooks/
[ -e .claude/settings.json ] || cp "$kit/settings.json" .claude/
```

Merge the hooks into an existing `settings.json` as described for git. Then run the commands under
"Adopt it in an svn working copy" in the kit's documentation. They add the kit, keep the copies out
of svn with `svn:ignore`, and keep the shell script LF.

## Update by hand

Pull your clone, and run the copy commands again. They replace the three `agent-skills-bridge.*`
files and leave the project's other files alone. Then compare the kit's `settings.json` with the
bridge's entries in yours, and copy any command string that changed.
