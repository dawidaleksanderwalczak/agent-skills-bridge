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

# Hooks send a JSON event on stdin. Read it, so Claude Code never writes into a closed pipe. Read it
# as UTF-8, which it is: [Console]::In would apply the console code page and spoil every letter
# outside ASCII in a path.
$utf8 = New-Object System.Text.UTF8Encoding $false
$inputText = ''
if ($hook -and [Console]::IsInputRedirected) {
  $inputText = (New-Object IO.StreamReader -ArgumentList ([Console]::OpenStandardInput()), $utf8).ReadToEnd()
}
if ($hook -and $env:AGENT_SKILLS_BRIDGE -eq 'off') { exit 0 }

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$src = Join-Path $root '.agents\skills'
$dst = Join-Path $root '.claude\skills'
$state = Join-Path $dst '.agent-skills-bridge' # the bridge's records; like each copy, the folder ignores itself
$manifest = Join-Path $state 'manifest'
$stamp = Join-Path $state 'stamp'
$lock = Join-Path $state 'lock'
$notes = New-Object System.Collections.Generic.List[string]
$script:changed = $false
$script:lockStream = $null
$reparse = [IO.FileAttributes]::ReparsePoint
$maxDepth = 16 # folders nested deeper than this are taken for a link loop, as in the shell script

function Add-Note([string]$Text) { $script:notes.Add($Text) }

# Why something failed, in one line.
function Get-Reason($ErrorRecord) {
  $e = $ErrorRecord.Exception
  while ($e.InnerException) { $e = $e.InnerException }
  return $e.Message.Trim()
}

# Writes a line to stdout, or with -Stderr to stderr. Through a pipe it goes out as UTF-8, which is
# what Claude Code reads: [Console]::Out would apply the console code page.
function Write-Line([string]$Text, [switch]$Stderr) {
  if ($Stderr) { $piped = [Console]::IsErrorRedirected } else { $piped = [Console]::IsOutputRedirected }
  if (-not $piped) {
    if ($Stderr) { [Console]::Error.WriteLine($Text) } else { [Console]::Out.WriteLine($Text) }
    return
  }
  if ($Stderr) { $stream = [Console]::OpenStandardError() } else { $stream = [Console]::OpenStandardOutput() }
  $bytes = $utf8.GetBytes($Text + "`n")
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush()
}

# True when $Name is safe as a folder name in paths, in the manifest and in JSON.
function Test-ValidName([string]$Name) { return $Name -cmatch '^[A-Za-z0-9_][A-Za-z0-9._-]*$' }

function Test-Exists([string]$Path) { return [bool](Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) }

# True when $Item is a junction or a symbolic link. The reparse-point attribute alone does not say
# so: in a OneDrive folder every plain file and folder carries it too.
function Test-LinkItem($Item) {
  return [bool](($Item.Attributes -band $reparse) -and (@('Junction', 'SymbolicLink') -contains $Item.LinkType))
}

function Test-Link([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return [bool]($item -and (Test-LinkItem $item))
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

# The skill names that the record file $File lists, one on a line. A last line that lacks its line
# end counts only with $LastLine. In the manifest an editor may have left it so. In a stamp it is a
# name that was cut short, because the sync was killed while it wrote the stamp. The file is opened
# so that it is in nobody's way: another run may write, replace or delete it meanwhile.
function Get-RecordNames([string]$File, [bool]$LastLine) {
  $names = @()
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return , $names }
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
  try { $lines = (New-Object IO.StreamReader -ArgumentList $stream, $utf8).ReadToEnd().Split("`n") }
  finally { $stream.Dispose() }
  $count = $lines.Count
  if (-not $LastLine) { $count-- }
  for ($i = 0; $i -lt $count; $i++) {
    $line = $lines[$i].TrimEnd("`r")
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if (Test-ValidName $line) { $names += $line }
  }
  return , $names
}

# The copies that are the bridge's. The manifest lists the copies that a finished sync made. A sync
# that began and has not ended lists its copies in its stamp, the ones it is about to make among
# them: those are the bridge's too, though the manifest does not list them yet.
function Get-ManagedNames {
  $names = Get-RecordNames $manifest $true
  $item = Get-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
  if ($item -and $item.Length -gt 0) {
    $more = @()
    try { $more = Get-RecordNames $stamp $false } catch { } # the sync that wrote the stamp may delete it this moment
    foreach ($n in $more) { if ($names -notcontains $n) { $names += $n } }
  }
  return , $names
}

# The bridge walks folders itself, never with -Recurse: in Windows PowerShell 5.1 -Recurse follows
# junctions and symlinks, in a link loop until the path is too long, and in PowerShell 7 it follows
# none. The bridge follows the links in a skill, as the copy does, and no link in a copy.

# Where the link $Item points to, as a full path; '' when $Item is no link or does not say.
function Get-LinkTarget($Item) {
  if (-not (Test-LinkItem $Item)) { return '' }
  try {
    $target = [string](@($Item.Target)[0])
    if ($target.StartsWith('\??\UNC\')) { $target = '\\' + $target.Substring(8) }
    elseif ($target.StartsWith('\??\')) { $target = $target.Substring(4) }
    if (-not $target) { return '' }
    if (-not [IO.Path]::IsPathRooted($target)) { $target = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Item.FullName), $target) }
    $target = [IO.Path]::GetFullPath($target)
    if ($target.Length -gt 3) { $target = $target.TrimEnd('\') }
    return $target
  }
  catch { return '' }
}

# What the folder entry $Item stands for: for a link the file or folder it points to, or nothing when
# that is gone; for anything else $Item itself.
function Resolve-Item($Item) {
  if (-not ($Item.Attributes -band $reparse)) { return $Item }
  $target = Get-LinkTarget $Item
  if (-not $target) { return $Item }
  return (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue)
}

# The entries of the folder $Folder; none when it cannot be read.
function Get-Entries([string]$Folder) {
  try { return , ([IO.DirectoryInfo]$Folder).GetFileSystemInfos() }
  catch { return , @() }
}

# True when something in the folder $Folder changed since the last sync. In a skill ($Follow): written
# at or after $Time, when that sync began, with links followed as the copy follows them. In a copy:
# written after $Time, when that sync ended, with no link followed. $Above lists the folders around
# $Folder: a link back to one of them is a loop, which the copy leaves out. Past $maxDepth levels
# the answer for a skill is "changed", as in the shell script.
function Test-FolderChanged([string]$Folder, [DateTime]$Time, [bool]$Follow, [string[]]$Above = @()) {
  if ($Follow -and $Above.Count -ge $maxDepth) { return $true }
  $here = $Above + $Folder
  foreach ($e in (Get-Entries $Folder)) {
    $item = $e
    if ($e.Attributes -band $reparse) {
      if ($Follow) {
        $item = Resolve-Item $e
        if (-not $item) { continue } # a link to nowhere: nothing to copy
      }
      elseif (Test-LinkItem $e) {
        if ($e.LastWriteTimeUtc -gt $Time) { return $true }
        continue
      }
    }
    $written = $item.LastWriteTimeUtc
    if ($written -gt $Time -or ($Follow -and $written -eq $Time)) { return $true }
    if (($item -is [IO.DirectoryInfo]) -and ($here -notcontains $item.FullName) -and
      (Test-FolderChanged $item.FullName $Time $Follow $here)) { return $true }
  }
  return $false
}

# True when the skill $Name, or anything in it, changed at or after $Since (the start of the last sync).
function Test-SourceChanged([string]$Name, [DateTime]$Since) {
  $item = Resolve-Item (Get-Item -LiteralPath (Join-Path $src $Name) -Force)
  if (-not $item) { return $false }
  return ($item.LastWriteTimeUtc -ge $Since) -or (Test-FolderChanged $item.FullName $Since $true)
}

# True when the copy of the skill $Name, or anything in it, changed after $After (the end of the last sync).
function Test-CopyChanged([string]$Name, [DateTime]$After) {
  $copy = Join-Path $dst $Name
  return ((Get-WriteTime $copy) -gt $After) -or (Test-FolderChanged $copy $After $false)
}

# Copies the folder $From to the new folder $To. Links are followed, so the copy holds plain files and
# folders. What cannot be copied (a link to nowhere, a link loop, a file that cannot be read) is left
# out, as cp leaves it out for the shell script, and listed in $script:leftOut by its name in the
# skill, which starts with $Inside.
function Copy-Folder([string]$From, [string]$To, [string]$Inside, [string[]]$Above = @()) {
  if ($Above.Count -ge $maxDepth) {
    $script:tooDeep = $true
    throw "its folders are nested more than $maxDepth deep (a link loop?)"
  }
  [void][IO.Directory]::CreateDirectory($To)
  $here = $Above + $From
  foreach ($e in ([IO.DirectoryInfo]$From).GetFileSystemInfos()) {
    $name = $Inside + $e.Name
    try {
      $item = Resolve-Item $e
      if (-not $item) { throw 'a link to nowhere' }
      if ($item -isnot [IO.DirectoryInfo]) { [IO.File]::Copy($item.FullName, [IO.Path]::Combine($To, $e.Name), $true) }
      elseif ($here -contains $item.FullName) { throw 'a link loop' }
      else { Copy-Folder $item.FullName ([IO.Path]::Combine($To, $e.Name)) ($name + '/') $here }
    }
    catch {
      if ($script:tooDeep) { throw }
      $script:leftOut += $name
    }
  }
}

# The files in the copy $Folder. A copy holds no links; one that someone put there is not followed.
function Get-CopyFiles([string]$Folder) {
  foreach ($e in ([IO.DirectoryInfo]$Folder).GetFileSystemInfos()) {
    if ($e -is [IO.FileInfo]) { $e }
    elseif (-not (Test-LinkItem $e)) { Get-CopyFiles $e.FullName }
  }
}

# Makes the copy $Folder ready for [IO.Directory]::Delete: lifts read-only from its files, and unlinks
# every link to a folder that someone put there, because that method stumbles over one. What a link
# points to is never touched.
function Clear-Copy([string]$Folder) {
  foreach ($e in ([IO.DirectoryInfo]$Folder).GetFileSystemInfos()) {
    if (Test-LinkItem $e) { if ($e -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($e.FullName) } }
    elseif ($e -is [IO.DirectoryInfo]) { Clear-Copy $e.FullName }
    elseif ($e.IsReadOnly) { $e.IsReadOnly = $false }
  }
}

# Works out what to copy (Wanted), refresh (Stale), delete (Gone) and leave alone (Conflicts).
function Get-Plan {
  $plan = @{ Source = (Get-SourceNames); Managed = (Get-ManagedNames); Wanted = @(); Stale = @(); Gone = @(); Conflicts = @() }
  $stampTime = [DateTime]::MinValue
  $manifestTime = [DateTime]::MaxValue
  $fresh = (Test-Path -LiteralPath $stamp -PathType Leaf) -and (Test-Path -LiteralPath $manifest -PathType Leaf)
  if ($fresh) {
    $stampItem = Get-Item -LiteralPath $stamp -Force
    $stampTime = $stampItem.LastWriteTimeUtc
    $manifestTime = Get-WriteTime $manifest
    # The stamp of a sync that has not ended holds text, and it is newer than the manifest.
    if ($stampItem.Length -gt 0 -or $stampTime -gt $manifestTime) { $fresh = $false }
  }
  foreach ($n in $plan.Source) {
    $copy = Join-Path $dst $n
    if ($plan.Managed -contains $n) {
      $plan.Wanted += $n
      if (-not $fresh -or -not (Test-Path -LiteralPath $copy -PathType Container) -or (Test-Link $copy) -or
        (Test-SourceChanged $n $stampTime) -or (Test-CopyChanged $n $manifestTime)) { $plan.Stale += $n }
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
    if (Test-LinkItem $item) {
      if ($item -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($p) } else { [IO.File]::Delete($p) }
    }
    elseif ($item -is [IO.DirectoryInfo]) {
      Clear-Copy $p
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
  if ($old) { $old.Attributes = [IO.FileAttributes]::Normal } # a read-only or hidden .gitignore that came with the source
  $text = "# Copy of .agents/skills/$Name for Claude Code, made by .claude/hooks/agent-skills-bridge.sh.`n" +
  "# Git ignores the whole copy. Edit the original in .agents/skills.`n*`n"
  [IO.File]::WriteAllText($file, $text, $utf8)
}

# Copies .agents/skills/$Name to .claude/skills/$Name, gives the copy its .gitignore and makes it
# read-only. False when it leaves a copy behind that is not whole.
function Copy-Skill([string]$Name) {
  $to = Join-Path $dst $Name
  if (Test-Exists $to) {
    Add-Note "Could not replace .claude/skills/$Name; is a file in it open?"
    return $false
  }
  $script:leftOut = @()
  $script:tooDeep = $false
  try {
    $from = Resolve-Item (Get-Item -LiteralPath (Join-Path $src $Name) -Force)
    if (-not $from) { throw 'it is a link to nowhere' }
    Copy-Folder $from.FullName $to ''
    if (-not (Test-Path -LiteralPath (Join-Path $to 'SKILL.md') -PathType Leaf)) { throw 'its SKILL.md cannot be read' }
    Set-CopyIgnore $Name
    foreach ($f in @(Get-CopyFiles $to)) { $f.IsReadOnly = $true }
  }
  catch {
    Add-Note "Could not copy .agents/skills/${Name}: $(Get-Reason $_)"
    # No half copy: Claude Code would list it, and the next sync would take it for current.
    return (Remove-Copy $Name)
  }
  if ($script:leftOut.Count) {
    $names = @($script:leftOut | Select-Object -First 3) -join ', '
    if ($script:leftOut.Count -gt 3) { $names += ' and more' }
    Add-Note "Not everything in .agents/skills/$Name could be copied ($names): look for a broken link, a link loop or a file that cannot be read."
  }
  return $true
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
  $newStamp = "$stamp.tmp"
  $newManifest = "$manifest.tmp"
  try {
    # The stamp of this sync is written now, before the plan looks at the skills: a file that
    # changes while the plan runs is then no older than the stamp, and the next sync copies it. The
    # stamp waits under another name, because the plan still compares with the stamp of the last
    # sync. It is a file, as in the shell script, so its time comes from the clock that also stamps
    # the skills' files. [DateTime]::UtcNow is another clock: in PowerShell 7 it runs up to a clock
    # tick ahead of the file times, and on a network share the server stamps the files.
    [IO.File]::WriteAllText($newStamp, '', $utf8)
    $plan = Get-Plan # again: a sync that held the lock may have done the work
    if (($plan.Stale.Count + $plan.Gone.Count) -eq 0) { return }
    # The stamp of a sync that has begun goes into the records. Unlike the stamp of a sync that has
    # ended, it holds text and is newer than the manifest: a sync that is killed midway counts as
    # unfinished, and the next one makes every copy again. The text names every copy that is the
    # bridge's, the ones this sync is about to make among them. So a copy is on record before it
    # exists: a sync that is killed after a new copy and before its manifest leaves nothing that the
    # next plan would take for someone's own skill.
    $new = @($plan.Stale | Where-Object { $plan.Managed -notcontains $_ })
    $begun = "# A sync began here and has not ended. Its copies, the ones it was about to make among them:`n" +
    ((@($plan.Managed) + $new | ForEach-Object { "$_`n" }) -join '')
    # No copy is made that is not on record.
    try { [IO.File]::WriteAllText($stamp, $begun, $utf8) }
    catch { Add-Note 'Could not write .claude/skills/.agent-skills-bridge/stamp, so nothing was copied.'; return }
    $script:changed = $true
    $broken = $false
    $kept = @()
    foreach ($n in $plan.Gone) {
      if (-not (Remove-Copy $n)) {
        Add-Note "Could not delete the old copy .claude/skills/$n; is a file in it open?"
        $kept += $n # still the bridge's: the next sync tries again
        $broken = $true
      }
    }
    foreach ($n in $plan.Stale) {
      [void](Remove-Copy $n)
      if (-not (Copy-Skill $n)) { $broken = $true }
    }
    $kept += @($plan.Wanted | Where-Object { Test-Path -LiteralPath (Join-Path $dst $_) -PathType Container })
    if ($kept.Count -eq 0) {
      Remove-Item -LiteralPath $manifest, $stamp -Force -ErrorAction SilentlyContinue
      return
    }
    $text = "# Copies made by .claude/hooks/agent-skills-bridge.sh from .agents/skills. Do not edit.`n" + (($kept | ForEach-Object { "$_`n" }) -join '')
    [IO.File]::WriteAllText($newManifest, $text, $utf8)
    # The manifest and the stamp from before the plan go into the records, the manifest first. Until
    # the manifest is there, the stamp of the sync that has begun stays, and with it the names of the
    # new copies. Should the sync stop between the two, that stamp still marks it as unfinished.
    Move-Item -LiteralPath $newManifest -Destination $manifest -Force
    if (-not $broken) { Move-Item -LiteralPath $newStamp -Destination $stamp -Force }
    else {
      # What could not be deleted or made whole must not pass for current. So the empty stamp stays
      # out of the records, and the stamp of the sync that has begun still marks this sync as
      # unfinished. The scripts of before cannot read that: they go by the times of the two files.
      # For them the stamp is deleted, now that the manifest is in place: without a stamp a sync
      # counts as unfinished, and the next one makes every copy again.
      Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
    }
  }
  finally {
    # The waiting stamp and the manifest that was on its way, where the sync did not use them.
    Remove-Item -LiteralPath $newStamp, $newManifest -Force -ErrorAction SilentlyContinue
    Exit-Lock
  }
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
    if ($notes.Count) { Write-Line ('agent-skills bridge: ' + ($notes -join ' ')) -Stderr }
    if ($script:changed) { Write-Line 'agent-skills bridge: updated the copies in .claude/skills.' }
    return
  }
  $out = [ordered]@{}
  if ($Command -eq 'session' -and (Test-Path -LiteralPath $src -PathType Container)) {
    $answer = [ordered]@{ hookEventName = 'SessionStart'; watchPaths = @((Get-NativeRoot) + '/.agents/skills') }
    if ($script:changed) { $answer.reloadSkills = $true }
    $out.hookSpecificOutput = $answer
  }
  if ($notes.Count) { $out.systemMessage = 'agent-skills bridge: ' + ($notes -join ' ') }
  if ($out.Count) { Write-Line ($out | ConvertTo-Json -Compress -Depth 5) }
}

# The string that the JSON event on stdin gives for a key (a regex), or '' when there is none.
# A regex, not ConvertFrom-Json: Windows PowerShell 5.1 refuses an event over 2 MB, such as a big Write.
function Get-JsonString([string]$Key) {
  $m = [regex]::Match($inputText, '"' + $Key + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
  if (-not $m.Success) { return '' }
  try { return [string]('{"p":"' + $m.Groups[1].Value + '"}' | ConvertFrom-Json).p } catch { return '' }
}

# PreToolUse: exit 2 (refuse, with the reason on stderr) when Write, Edit, MultiEdit or
# NotebookEdit targets a file inside a copy; exit 0 for anything else.
function Invoke-Guard {
  if ($inputText -notmatch 'skills') { return }
  $path = Get-JsonString '(?:file_path|notebook_path)'
  if (-not $path) { return }
  try {
    $path = $path -replace '^/([A-Za-z])(?=/|$)', '$1:' # /c/... as Git Bash spells C:/...
    if (-not [IO.Path]::IsPathRooted($path)) {
      # A relative path counts from the folder the event names, or else from the repository.
      $from = Get-JsonString 'cwd'
      if (-not $from) { $from = Get-NativeRoot }
      $path = [IO.Path]::Combine($from, $path)
    }
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
  Write-Line "Blocked by the agent-skills bridge: .claude/skills/$($match[0])/ is a generated copy of .agents/skills/$($match[0])/ and the next sync overwrites it. Make this change in .agents/skills/$($match[0])/$sub instead; Claude Code picks it up automatically." -Stderr
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
    $lines = @()
    try { $lines = [IO.File]::ReadAllLines((Join-Path (Join-Path $src $n) 'SKILL.md')) } catch { }
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
  # After a first sync that was killed there is no manifest, and still there are copies.
  $managed = Get-ManagedNames
  if ($managed.Count -eq 0 -and -not (Test-Path -LiteralPath $manifest -PathType Leaf)) { 'agent-skills bridge: no copies to delete.'; return }
  if (-not (Enter-Lock)) { [Console]::Error.WriteLine('agent-skills bridge: another sync is running; try again.'); exit 1 }
  try {
    $managed = Get-ManagedNames
    $stuck = @($managed | Where-Object { -not (Remove-Copy $_) })
  }
  finally { Exit-Lock }
  if ($stuck.Count) {
    # The records stay: without them the bridge would take what is left for someone else's skills.
    [Console]::Error.WriteLine("agent-skills bridge: could not delete: $($stuck -join ' '). Is a file in there open? Close it and run clean again.")
    exit 1
  }
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
  Add-Note "failed: $(Get-Reason $_)"
  if ($hook) { Write-Result } else { [Console]::Error.WriteLine("agent-skills bridge: failed: $(Get-Reason $_)"); exit 1 }
}
exit 0
