<#
agent-skills-bridge.ps1 - make the skills in .agents/skills visible to Claude Code.

The PowerShell twin of agent-skills-bridge.sh, for Windows machines where Claude Code runs hooks in
PowerShell because Git Bash is missing. Same commands, same files, same results; keep the two in
step. Details: agent-skills-bridge.md next to this file.

Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .claude\hooks\agent-skills-bridge.ps1 [command]
  sync     copy new and changed skills, delete copies of removed ones (the default)
  session  sync, then answer the SessionStart hook: reload skills, watch .agents/skills
  guard    answer the PreToolUse hook: refuse an edit inside a copy, naming the source file
  status   show what is bridged, whether the copies are current and whether git or svn ignores them
  clean    delete every copy this script made, and its records
AGENT_SKILLS_BRIDGE=off makes sync, session and guard do nothing.
Runs in Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII: 5.1 reads it as ANSI.
#>
param([string]$Command = 'sync')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (@('sync', 'session', 'guard', 'status', 'clean') -notcontains $Command) {
  [Console]::Error.WriteLine('usage: agent-skills-bridge.ps1 [sync|session|guard|status|clean]')
  exit 64
}
$hook = @('sync', 'session', 'guard') -contains $Command

# Hooks send a JSON event on stdin. Read it, so Claude Code never writes into a closed pipe.
$inputText = ''
if ($hook -and [Console]::IsInputRedirected) { $inputText = [Console]::In.ReadToEnd() }
if ($hook -and $env:AGENT_SKILLS_BRIDGE -eq 'off') { exit 0 }

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$src = Join-Path $root '.agents\skills'
$dst = Join-Path $root '.claude\skills'
$state = Join-Path $dst '.agent-skills-bridge' # the bridge's records; like each copy, the folder ignores itself
$manifest = Join-Path $state 'manifest'
$stamp = Join-Path $state 'stamp'
$lock = Join-Path $state 'lock'
$utf8 = New-Object System.Text.UTF8Encoding $false
$notes = New-Object System.Collections.Generic.List[string]
$script:changed = $false
$script:lockStream = $null

function Add-Note([string]$Text) { $script:notes.Add($Text) }

# True when $Name is safe as a folder name in paths, in the manifest and in JSON.
function Test-ValidName([string]$Name) { return $Name -cmatch '^[A-Za-z0-9_][A-Za-z0-9._-]*$' }

function Test-Exists([string]$Path) { return [bool](Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) }

function Test-Link([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return [bool]($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
}

function Get-WriteTime([string]$Path) { return (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc }

# Runs a command-line tool for status and never throws, whatever the tool writes to stderr:
# Windows PowerShell 5.1 turns redirected stderr into errors, which 'Stop' would make fatal.
function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $out = @(& $Exe @Arguments 2> $null)
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

# The folders in .agents/skills that hold a SKILL.md.
function Get-SourceNames {
  $names = @()
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { return , $names }
  foreach ($dir in @(Get-ChildItem -LiteralPath $src -Directory -Force | Sort-Object Name)) {
    if ($dir.Name.StartsWith('.')) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md') -PathType Leaf)) { continue }
    if (Test-ValidName $dir.Name) { $names += $dir.Name }
    else { Add-Note "Skipped a folder in .agents/skills: skill folder names may only use letters, digits, '.', '_' and '-'." }
  }
  return , $names
}

# The copies the bridge made, as the manifest records them.
function Get-ManagedNames {
  $names = @()
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return , $names }
  foreach ($line in [IO.File]::ReadAllLines($manifest)) {
    $line = $line.TrimEnd("`r")
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if (Test-ValidName $line) { $names += $line }
  }
  return , $names
}

# True when $Path, or anything under it, changed at or after $Since (the start of the last sync).
function Test-ChangedSince([string]$Path, [DateTime]$Since) {
  if ((Get-WriteTime $Path) -ge $Since) { return $true }
  if (-not (Test-Path -LiteralPath $Path -PathType Container) -or (Test-Link $Path)) { return $false }
  foreach ($e in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
    if ($e.LastWriteTimeUtc -ge $Since) { return $true }
  }
  return $false
}

# True when $Path, or anything under it, changed after $After (the end of the last sync).
function Test-ChangedAfter([string]$Path, [DateTime]$After) {
  if ((Get-WriteTime $Path) -gt $After) { return $true }
  if (-not (Test-Path -LiteralPath $Path -PathType Container) -or (Test-Link $Path)) { return $false }
  foreach ($e in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
    if ($e.LastWriteTimeUtc -gt $After) { return $true }
  }
  return $false
}

# Works out what to copy (Wanted), refresh (Stale), delete (Gone) and leave alone (Conflicts).
function Get-Plan {
  $plan = @{ Source = (Get-SourceNames); Managed = (Get-ManagedNames); Wanted = @(); Stale = @(); Gone = @(); Conflicts = @() }
  $stampTime = [DateTime]::MinValue
  $manifestTime = [DateTime]::MaxValue
  $fresh = (Test-Path -LiteralPath $stamp -PathType Leaf) -and (Test-Path -LiteralPath $manifest -PathType Leaf)
  if ($fresh) {
    $stampTime = Get-WriteTime $stamp
    $manifestTime = Get-WriteTime $manifest
    if ($stampTime -gt $manifestTime) { $fresh = $false }
  }
  foreach ($n in $plan.Source) {
    $copy = Join-Path $dst $n
    if ($plan.Managed -contains $n) {
      $plan.Wanted += $n
      if (-not $fresh -or -not (Test-Path -LiteralPath $copy -PathType Container) -or (Test-Link $copy) -or
        (Test-ChangedSince (Join-Path $src $n) $stampTime) -or (Test-ChangedAfter $copy $manifestTime)) { $plan.Stale += $n }
    }
    elseif (Test-Exists $copy) { $plan.Conflicts += $n }
    else { $plan.Wanted += $n; $plan.Stale += $n }
  }
  foreach ($n in $plan.Managed) { if ($plan.Wanted -notcontains $n) { $plan.Gone += $n } }
  return $plan
}

# Deletes .claude/skills/$Name. A symlink or junction is unlinked, never followed.
function Remove-Copy([string]$Name) {
  $p = Join-Path $dst $Name
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if (-not $item) { return $true }
  try {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      if ($item.PSIsContainer) { [IO.Directory]::Delete($p) } else { [IO.File]::Delete($p) }
    }
    elseif ($item.PSIsContainer) {
      foreach ($f in @(Get-ChildItem -LiteralPath $p -Recurse -Force -File)) { $f.IsReadOnly = $false }
      [IO.Directory]::Delete($p, $true)
    }
    else { $item.IsReadOnly = $false; [IO.File]::Delete($p) }
  }
  catch { return $false }
  return -not (Test-Exists $p)
}

# Writes .claude/skills/$Name/.gitignore. It makes git ignore the whole copy, whatever the rules in
# the folders above say, so the copy needs no line in a .gitignore that someone else owns.
function Set-CopyIgnore([string]$Name) {
  $file = Join-Path (Join-Path $dst $Name) '.gitignore'
  $old = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  if ($old) { $old.IsReadOnly = $false } # a read-only .gitignore that came with the source
  $text = "# Copy of .agents/skills/$Name for Claude Code, made by .claude/hooks/agent-skills-bridge.sh.`n" +
  "# Git ignores the whole copy. Edit the original in .agents/skills.`n*`n"
  [IO.File]::WriteAllText($file, $text, $utf8)
}

# Copies .agents/skills/$Name to .claude/skills/$Name, gives the copy its .gitignore and makes it read-only.
function Copy-Skill([string]$Name) {
  $from = Join-Path $src $Name
  $to = Join-Path $dst $Name
  if (Test-Exists $to) { Add-Note "Could not replace .claude/skills/$Name; is a file in it open?"; return }
  try {
    Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
    Set-CopyIgnore $Name
    foreach ($f in @(Get-ChildItem -LiteralPath $to -Recurse -Force -File)) { $f.IsReadOnly = $true }
  }
  catch { Add-Note "Could not copy .agents/skills/$Name." }
}

# Takes the lock (a file opened for exclusive use); a lock left by a killed run goes stale after two minutes.
function Enter-Lock {
  for ($i = 0; $i -lt 75; $i++) {
    try {
      $script:lockStream = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      return $true
    }
    catch {
      if (-not (Test-Path -LiteralPath $state -PathType Container)) { # a clean deleted the records meanwhile
        try { [void][IO.Directory]::CreateDirectory($state); continue } catch { return $false }
      }
      $item = Get-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
      if ($item -and $item.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-2)) {
        try { Remove-Item -LiteralPath $lock -Recurse -Force; continue } catch { }
      }
      Start-Sleep -Milliseconds 200
    }
  }
  return $false
}

function Exit-Lock {
  if ($script:lockStream) {
    $script:lockStream.Dispose()
    $script:lockStream = $null
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Sync {
  # Problems that persist are reported once per session, not on every file event.
  $loud = ($Command -eq 'session') -or -not [Console]::IsOutputRedirected
  if (Test-Link $dst) {
    if ($loud) { Add-Note '.claude/skills is a link, so the bridge leaves it alone.' }
    return
  }
  $plan = Get-Plan
  if ($loud) {
    foreach ($n in $plan.Conflicts) {
      Add-Note ".claude/skills/$n exists and was not made by the bridge, so .agents/skills/$n is not copied. Rename or delete one of them."
    }
  }
  if (($plan.Stale.Count + $plan.Gone.Count) -eq 0) { return }
  if (-not (Test-Path -LiteralPath $dst -PathType Container)) {
    try { [void][IO.Directory]::CreateDirectory($state) } catch { Add-Note 'Could not create .claude/skills.'; return }
    # The bridge made the folder, so it leaves a file to commit: every checkout then has the
    # folder, and Claude Code watches it from the first session. It ignores nothing.
    $text = "# Keeps .claude/skills in every checkout, so Claude Code watches it from the first session.`n" +
    "# .claude/hooks/agent-skills-bridge.sh copies .agents/skills here. Each copy has its own`n" +
    "# .gitignore, so git never sees the copies. Commit this file; edit skills in .agents/skills.`n"
    try { [IO.File]::WriteAllText((Join-Path $dst '.gitignore'), $text, $utf8) } catch { }
  }
  elseif (-not (Test-Path -LiteralPath $state -PathType Container)) {
    try { [void][IO.Directory]::CreateDirectory($state) } catch { Add-Note 'Could not create .claude/skills/.agent-skills-bridge.'; return }
  }
  $stateIgnore = Join-Path $state '.gitignore'
  if (-not (Test-Path -LiteralPath $stateIgnore -PathType Leaf)) {
    try { [IO.File]::WriteAllText($stateIgnore, "# Records of .claude/hooks/agent-skills-bridge.sh. Git ignores this folder.`n*`n", $utf8) } catch { }
  }
  if (-not (Enter-Lock)) { Add-Note 'Another sync was still running, so this one was skipped.'; return }
  try {
    $plan = Get-Plan # again: a sync that held the lock may have done the work
    if (($plan.Stale.Count + $plan.Gone.Count) -eq 0) { return }
    [IO.File]::WriteAllText($stamp, '', $utf8)
    $script:changed = $true
    foreach ($n in $plan.Gone) {
      if (-not (Remove-Copy $n)) { Add-Note "Could not delete the old copy .claude/skills/$n." }
    }
    foreach ($n in $plan.Stale) {
      [void](Remove-Copy $n)
      Copy-Skill $n
    }
    $kept = @($plan.Wanted | Where-Object { Test-Path -LiteralPath (Join-Path $dst $_) -PathType Container })
    if ($kept.Count -eq 0) {
      Remove-Item -LiteralPath $manifest, $stamp -Force -ErrorAction SilentlyContinue
      return
    }
    $text = "# Copies made by .claude/hooks/agent-skills-bridge.sh from .agents/skills. Do not edit.`n" + (($kept | ForEach-Object { "$_`n" }) -join '')
    $tmp = "$manifest.tmp"
    [IO.File]::WriteAllText($tmp, $text, $utf8)
    Move-Item -LiteralPath $tmp -Destination $manifest -Force
  }
  finally { Exit-Lock }
}

# The repository path the way Claude Code spells it, with forward slashes.
function Get-NativeRoot {
  $p = $env:CLAUDE_PROJECT_DIR
  if (-not $p) { $p = $root }
  return ($p -replace '\\', '/').TrimEnd('/')
}

# Tells Claude Code (JSON on stdout) or the person at a console what happened.
function Write-Result {
  if (-not [Console]::IsOutputRedirected) {
    if ($notes.Count) { [Console]::Error.WriteLine('agent-skills bridge: ' + ($notes -join ' ')) }
    if ($script:changed) { [Console]::Out.WriteLine('agent-skills bridge: updated the copies in .claude/skills.') }
    return
  }
  $out = [ordered]@{}
  if ($Command -eq 'session' -and (Test-Path -LiteralPath $src -PathType Container)) {
    $answer = [ordered]@{ hookEventName = 'SessionStart'; watchPaths = @((Get-NativeRoot) + '/.agents/skills') }
    if ($script:changed) { $answer.reloadSkills = $true }
    $out.hookSpecificOutput = $answer
  }
  if ($notes.Count) { $out.systemMessage = 'agent-skills bridge: ' + ($notes -join ' ') }
  if ($out.Count) { [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 5)) }
}

# PreToolUse: exit 2 (refuse, with the reason on stderr) when Write, Edit, MultiEdit or
# NotebookEdit targets a file inside a copy; exit 0 for anything else.
function Invoke-Guard {
  if ($inputText -notmatch 'skills') { return }
  $m = [regex]::Match($inputText, '"(?:file_path|notebook_path)"\s*:\s*"((?:[^"\\]|\\.)*)"')
  if (-not $m.Success) { return }
  try {
    $path = ('{"p":"' + $m.Groups[1].Value + '"}' | ConvertFrom-Json).p
    $full = [IO.Path]::GetFullPath($path)
    $base = [IO.Path]::GetFullPath((Get-NativeRoot) + '/.claude/skills') + '\'
  }
  catch { return }
  if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return }
  $rest = $full.Substring($base.Length)
  $name = ($rest -split '\\', 2)[0]
  $match = @(Get-ManagedNames | Where-Object { $_ -eq $name })
  if ($match.Count -eq 0) { return }
  $sub = ''
  if ($rest.Contains('\')) { $sub = ($rest -split '\\', 2)[1] -replace '\\', '/' }
  [Console]::Error.WriteLine("Blocked by the agent-skills bridge: .claude/skills/$($match[0])/ is a generated copy of .agents/skills/$($match[0])/ and the next sync overwrites it. Make this change in .agents/skills/$($match[0])/$sub instead; Claude Code picks it up automatically.")
  exit 2
}

# Status: does git ignore the copies and the records, and is .claude/skills in the repository?
function Show-GitStatus($Plan) {
  $seen = @()
  foreach ($n in $Plan.Managed) {
    $probe = Join-Path (Join-Path $dst $n) 'SKILL.md'
    if ((Test-Path -LiteralPath $probe -PathType Leaf) -and (Invoke-Tool git @('-C', $root, 'check-ignore', '-q', $probe)).Code -eq 1) { $seen += $n }
  }
  if ((Test-Path -LiteralPath $manifest -PathType Leaf) -and (Invoke-Tool git @('-C', $root, 'check-ignore', '-q', $manifest)).Code -eq 1) {
    $seen += '(records in .claude/skills/.agent-skills-bridge)'
  }
  if ($seen.Count) { "  git             not ignored: $($seen -join ' '). Run sync; if git tracks them, remove them with git rm -r --cached" }
  elseif ($Plan.Managed.Count) { '  git             copies are ignored' }
  if ((Invoke-Tool git @('-C', $root, 'ls-files', '--error-unmatch', '.claude/skills')).Code -eq 0) { '  git             .claude/skills is in the repository' }
  else { '  git             nothing in .claude/skills is committed: commit .claude/skills/.gitignore, so new clones have the folder' }
}

# Status: does svn ignore the copies and the records? svn reads no .gitignore, only svn:ignore.
function Show-SvnStatus($Plan) {
  if ((Invoke-Tool svn @('info', $dst)).Code -ne 0) {
    '  svn             .claude/skills is not in svn: see "Adopt it in an svn working copy" in .claude/hooks/agent-skills-bridge.md'
    return
  }
  $seen = @()
  foreach ($n in @($Plan.Managed) + '.agent-skills-bridge') {
    $p = Join-Path $dst $n
    if (-not (Test-Exists $p)) { continue }
    if ((Invoke-Tool svn @('info', $p)).Code -eq 0) { $seen += $n; continue } # versioned: it should never be
    if ((Invoke-Tool svn @('status', '--depth=empty', $p)).Out.StartsWith('?')) { $seen += $n }
  }
  if ($seen.Count) { "  svn             not ignored: $($seen -join ' '). Set svn:ignore on .claude/skills: see ""Adopt it in an svn working copy"" in .claude/hooks/agent-skills-bridge.md" }
  else { '  svn             copies are ignored' }
}

function Show-Status {
  $plan = Get-Plan
  "agent-skills bridge: $root"
  "  .agents/skills  $($plan.Source.Count) skill(s): $($plan.Source -join ' ')"
  "  .claude/skills  $($plan.Managed.Count) copy(ies): $($plan.Managed -join ' ')"
  if ($plan.Conflicts.Count) { "  conflicts       $($plan.Conflicts -join ' ') (in .claude/skills, not made by the bridge)" }
  if (($plan.Stale.Count + $plan.Gone.Count) -eq 0) { '  state           copies are current' }
  else {
    $gone = ''
    if ($plan.Gone.Count) { $gone = " (removed: $($plan.Gone -join ' '))" }
    "  state           out of date: $($plan.Stale -join ' ')$gone. The next hook syncs, or run this script with sync"
  }
  foreach ($n in $plan.Source) {
    if ($n -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { "  note            ${n}: the Agent Skills spec wants lowercase letters, digits and single hyphens" }
    $lines = [IO.File]::ReadAllLines((Join-Path (Join-Path $src $n) 'SKILL.md'))
    if ($lines.Count -gt 0 -and $lines[0].TrimEnd() -eq '---') {
      for ($i = 1; $i -lt $lines.Count -and $lines[$i].TrimEnd() -ne '---'; $i++) {
        if ($lines[$i] -match '^name:\s*(.*)$') {
          $fm = $Matches[1].Trim().Trim('"', "'")
          if ($fm -and $fm -ne $n) { "  note            ${n}: SKILL.md says name: $fm; VS Code, Cursor and the spec want it to match the folder" }
          break
        }
      }
    }
  }
  if ((Get-Command git -ErrorAction SilentlyContinue) -and (Invoke-Tool git @('-C', $root, 'rev-parse', '--is-inside-work-tree')).Code -eq 0) { Show-GitStatus $plan }
  if ((Get-Command svn -ErrorAction SilentlyContinue) -and (Invoke-Tool svn @('info', $root)).Code -eq 0) { Show-SvnStatus $plan }
  $settings = Join-Path $root '.claude\settings.json'
  if ((Test-Path -LiteralPath $settings) -and (Select-String -LiteralPath $settings -SimpleMatch 'agent-skills-bridge' -Quiet)) {
    '  hooks           .claude/settings.json runs the bridge'
  }
  else { '  hooks           missing from .claude/settings.json' }
  if ($env:AGENT_SKILLS_BRIDGE -eq 'off') { '  switch          AGENT_SKILLS_BRIDGE=off: the hooks do nothing' }
}

function Invoke-Clean {
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { 'agent-skills bridge: no copies to delete.'; return }
  if (-not (Enter-Lock)) { [Console]::Error.WriteLine('agent-skills bridge: another sync is running; try again.'); exit 1 }
  try {
    $managed = Get-ManagedNames
    foreach ($n in $managed) {
      if (-not (Remove-Copy $n)) { [Console]::Error.WriteLine("agent-skills bridge: could not delete .claude/skills/$n") }
    }
  }
  finally { Exit-Lock }
  Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue # the records
  "agent-skills bridge: deleted the copies: $($managed -join ' ')."
}

try {
  switch ($Command) {
    { $_ -in 'sync', 'session' } {
      # A FileChanged event outside .agents is someone else's watch: nothing to do.
      if ($inputText -match '"FileChanged"' -and $inputText -notmatch '\.agents') { exit 0 }
      Invoke-Sync
      Write-Result
    }
    'guard' { Invoke-Guard }
    'status' { Show-Status }
    'clean' { Invoke-Clean }
  }
}
catch {
  if ($Command -eq 'guard') { exit 0 } # never block an edit because the bridge broke
  Add-Note "failed: $($_.Exception.Message)"
  if ($hook) { Write-Result } else { [Console]::Error.WriteLine("agent-skills bridge: failed: $($_.Exception.Message)"); exit 1 }
}
exit 0
