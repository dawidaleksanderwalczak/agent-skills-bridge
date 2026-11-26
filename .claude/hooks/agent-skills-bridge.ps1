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
$script:skipped = $false
$script:lockStream = $null
$reparse = [IO.FileAttributes]::ReparsePoint
$readOnly = [IO.FileAttributes]::ReadOnly
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

# The folders in .agents/skills that hold a SKILL.md. Sets $script:skipped when one of them has a
# name the bridge cannot use.
function Get-SourceNames {
  $names = @()
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { return , $names }
  foreach ($dir in @(Get-ChildItem -LiteralPath $src -Directory -Force | Sort-Object Name)) {
    if ($dir.Name.StartsWith('.')) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md') -PathType Leaf)) { continue }
    if (Test-ValidName $dir.Name) { $names += $dir.Name }
    else { $script:skipped = $true }
  }
  return , $names
}

# On a line that begins like this, a record names the copies whose folders a sync may have left
# half-done: see Get-BegunText.
$unfinishedLine = '# Unfinished:'

# What the record file $File says. Names: the skill names that it lists, one on a line. A last line
# that lacks its line end counts only with $LastLine. In the manifest an editor may have left it so.
# In a stamp it is a name that was cut short, because the sync was killed while it wrote the stamp.
# Unfinished: the names on the record's "# Unfinished:" line. Seen: whether it has that line. Lines:
# how many whole lines it has. The file is opened so that it is in nobody's way: another run may
# write, replace or delete it meanwhile.
function Read-RecordFile([string]$File, [bool]$LastLine) {
  $record = @{ Names = @(); Unfinished = @(); Seen = $false; Lines = 0 }
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $record }
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
  try { $lines = (New-Object IO.StreamReader -ArgumentList $stream, $utf8).ReadToEnd().Split("`n") }
  finally { $stream.Dispose() }
  $record.Lines = $lines.Count - 1
  $count = $lines.Count
  if (-not $LastLine) { $count-- }
  for ($i = 0; $i -lt $count; $i++) {
    $line = $lines[$i].TrimEnd("`r")
    if ($line.StartsWith($unfinishedLine, [StringComparison]::Ordinal)) {
      $record.Seen = $true
      foreach ($word in $line.Substring($unfinishedLine.Length).Split(' ')) {
        if (Test-ValidName $word) { $record.Unfinished += $word }
      }
      continue
    }
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if (Test-ValidName $line) { $record.Names += $line }
  }
  return $record
}

# What the bridge's records say. Managed: the copies that are the bridge's. The manifest lists the
# copies that a finished sync made. A sync that began and has not ended lists its copies in its
# stamp, the ones it is about to make among them: those are the bridge's too, though the manifest
# does not list them yet. Doubt: the copies whose folders a sync may have left half-done, as the
# records name them. ManifestLine: whether the manifest has a line for them. StampForm: what the
# stamp of a sync that has begun is like: 'new' (it has that line), 'old' (the scripts of before
# wrote it, without the line) or 'cut' (it ends in its first line: that sync was killed before it
# touched a folder).
function Read-Records {
  $listed = Read-RecordFile $manifest $true
  $records = @{ Managed = $listed.Names; Doubt = $listed.Unfinished; ManifestLine = $listed.Seen; StampForm = '' }
  $item = Get-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
  if ($item -and $item.Length -gt 0) {
    $begun = @{ Names = @(); Unfinished = @(); Seen = $false; Lines = 0 }
    try { $begun = Read-RecordFile $stamp $false } catch { } # the sync that wrote the stamp may delete it this moment
    foreach ($n in $begun.Names) { if ($records.Managed -notcontains $n) { $records.Managed += $n } }
    $records.Doubt += $begun.Unfinished
    if ($begun.Seen) { $records.StampForm = 'new' }
    elseif ($begun.Lines -gt 0) { $records.StampForm = 'old' }
    else { $records.StampForm = 'cut' }
  }
  return $records
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
  # A link may point to a link. After eight of them it is a loop, which leads nowhere.
  for ($hop = 0; $hop -lt 8; $hop++) {
    if (-not ($Item.Attributes -band $reparse)) { return $Item }
    $target = Get-LinkTarget $Item
    if (-not $target) { return $Item }
    $Item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if (-not $Item) { return }
  }
}

# True when $Path is the bridge's own folder .claude/skills or lies in it. A link in a skill that
# leads up to the repository must not take the bridge into its own copies.
function Test-OwnFolder([string]$Path) {
  return $Path.Equals($dst, [StringComparison]::OrdinalIgnoreCase) -or
  $Path.StartsWith($dst + '\', [StringComparison]::OrdinalIgnoreCase)
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
    if ($Follow -and (Test-OwnFolder $item.FullName)) { continue } # reached through a link: not part of the skill
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
# folders. What cannot be copied is left out and listed in $script:leftOut by its name in the skill,
# which starts with $Inside: a link to nowhere, a link loop (a link back to a folder around it, or
# into the bridge's own .claude/skills), a file that cannot be read. The last kind is also counted
# in $script:unread: that file is there to copy, so the copy is not whole.
function Copy-Folder([string]$From, [string]$To, [string]$Inside, [string[]]$Above = @()) {
  if ($Above.Count -ge $maxDepth) {
    $script:tooDeep = $true
    throw "its folders are nested more than $maxDepth deep (a link loop?)"
  }
  [void][IO.Directory]::CreateDirectory($To)
  $here = $Above + $From
  foreach ($e in ([IO.DirectoryInfo]$From).GetFileSystemInfos()) {
    $name = $Inside + $e.Name
    $item = Resolve-Item $e
    if (-not $item) { $script:leftOut += $name; continue } # a link to nowhere
    if (($item -is [IO.DirectoryInfo]) -and (($here -contains $item.FullName) -or (Test-OwnFolder $item.FullName))) {
      $script:leftOut += $name # a link loop
      continue
    }
    try {
      if ($item -is [IO.DirectoryInfo]) { Copy-Folder $item.FullName ([IO.Path]::Combine($To, $e.Name)) ($name + '/') $here }
      else { [IO.File]::Copy($item.FullName, [IO.Path]::Combine($To, $e.Name), $true) }
    }
    catch {
      if ($script:tooDeep) { throw }
      $script:leftOut += $name
      $script:unread++
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

# Makes the copy $Folder ready for [IO.Directory]::Delete: lifts read-only from its files and
# folders (someone may have set it on the folders too), and unlinks every link to a folder that
# someone put there, because that method stumbles over one. What a link points to is never touched.
function Clear-Copy([string]$Folder) {
  foreach ($e in ([IO.DirectoryInfo]$Folder).GetFileSystemInfos()) {
    if (Test-LinkItem $e) {
      if ($e -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($e.FullName) }
      continue
    }
    if ($e.Attributes -band $readOnly) { $e.Attributes = $e.Attributes -bxor $readOnly }
    if ($e -is [IO.DirectoryInfo]) { Clear-Copy $e.FullName }
  }
}

# The first line of the .gitignore that the bridge writes into the copy of the skill $Name. By this
# line the bridge knows a copy that it made. A kit that words the line anew must go on knowing this
# one, or it takes every older copy for a skill of someone's own.
function Get-MarkLine([string]$Name) {
  return "# Copy of .agents/skills/$Name for Claude Code, made by .claude/hooks/agent-skills-bridge.sh."
}

# True when the folder .claude/skills/$Name holds the .gitignore that the bridge wrote into it. The
# name in it may differ in letter case, as everywhere in this script: a skill that was renamed in
# letter case only still has its copy, under the name of before.
function Test-Marked([string]$Name) {
  $file = Join-Path (Join-Path $dst $Name) '.gitignore'
  $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  if (-not $item -or ($item -isnot [IO.FileInfo]) -or (Test-LinkItem $item)) { return $false }
  $line = $null
  try {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { $line = (New-Object IO.StreamReader -ArgumentList $stream, $utf8).ReadLine() }
    finally { $stream.Dispose() }
  }
  catch { return $false }
  return ($null -ne $line) -and $line.Equals((Get-MarkLine $Name), [StringComparison]::OrdinalIgnoreCase)
}

# True when the folder $Folder has no entry. A folder that cannot be read may hold anything.
function Test-Bare([string]$Folder) {
  try { return (([IO.DirectoryInfo]$Folder).GetFileSystemInfos().Count -eq 0) }
  catch { return $false }
}

# True when the folder $Folder holds something that the bridge did not put there: a file that is
# newer than $Mark, the time of the copy's own .gitignore, which the bridge writes last of all, or
# a link, which no copy holds. With $Seal, a file that can be written is no file of the bridge's
# either: see Test-Sealed. A folder counts for nothing by itself: its time changes when a file in it
# goes, and that leaves nothing of anyone's behind. A folder that cannot be read may hold anything.
function Test-Touched([string]$Folder, [DateTime]$Mark, [bool]$Seal) {
  try { $entries = ([IO.DirectoryInfo]$Folder).GetFileSystemInfos() }
  catch { return $true }
  foreach ($e in $entries) {
    if (Test-LinkItem $e) { return $true }
    if ($e -is [IO.DirectoryInfo]) { if (Test-Touched $e.FullName $Mark $Seal) { return $true } }
    elseif ($e.LastWriteTimeUtc -gt $Mark -or ($Seal -and -not $e.IsReadOnly)) { return $true }
  }
  return $false
}

# True when a file that can be written tells something about the copy of the skill $Name. The
# bridge leaves every file of a copy read-only, its .gitignore among them. So a file there that can
# be written was put there by someone else, also when it is older than the copy: a file manager
# that moves a skill over its copy keeps the times. That holds only while the .gitignore itself is
# still read-only. Where it is not, someone has lifted the mark from the whole folder, and the sign
# says nothing.
function Test-Sealed([string]$Name) {
  $item = Get-Item -LiteralPath (Join-Path (Join-Path $dst $Name) '.gitignore') -Force -ErrorAction SilentlyContinue
  return [bool]($item -and ($item -is [IO.FileInfo]) -and $item.IsReadOnly)
}

# True when .claude/skills/$Name is a folder that holds nothing of anyone's: no entry at all, or a
# copy just as the bridge made it. Such a folder is in no record when the bridge took its hands off
# it for a time (see Select-Own: git has taken its files out again), or when the records were lost.
# The bridge makes the copy anew in its place.
function Test-Leftover([string]$Name) {
  $folder = Join-Path $dst $Name
  $item = Get-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
  if (-not $item -or ($item -isnot [IO.DirectoryInfo]) -or (Test-LinkItem $item)) { return $false }
  if (Test-Bare $folder) { return $true }
  if (-not (Test-Marked $Name)) { return $false }
  return -not (Test-Touched $folder (Get-WriteTime (Join-Path $folder '.gitignore')) (Test-Sealed $Name))
}

# Works out what to copy (Wanted), refresh (Stale), delete (Gone) and leave alone (Conflicts), and
# which of the skills in Stale have a folder that is a leftover in no record (Adopted). Select-Own
# fills Taken and Why.
function Get-Plan {
  $records = Read-Records
  $plan = @{
    Source = (Get-SourceNames); Managed = $records.Managed; Doubt = $records.Doubt
    Wanted = @(); Stale = @(); Gone = @(); Conflicts = @(); Adopted = @(); Taken = @(); Why = @{}; Busy = $false
  }
  $stampTime = [DateTime]::MinValue
  $manifestTime = [DateTime]::MaxValue
  $stampThere = Test-Path -LiteralPath $stamp -PathType Leaf
  $fresh = $stampThere -and (Test-Path -LiteralPath $manifest -PathType Leaf)
  if ($fresh) {
    $stampItem = Get-Item -LiteralPath $stamp -Force
    $stampTime = $stampItem.LastWriteTimeUtc
    $manifestTime = Get-WriteTime $manifest
    # The stamp of a sync that has not ended holds text, and it is newer than the manifest.
    if ($stampItem.Length -gt 0 -or $stampTime -gt $manifestTime) { $fresh = $false }
  }
  # Records of an unfinished sync that the scripts of before wrote do not name the folders it may
  # have left half-done: any of them may be.
  if (-not $fresh -and (($records.StampForm -eq 'old') -or (-not $stampThere -and -not $records.ManifestLine))) {
    $plan.Doubt = $plan.Managed
  }
  foreach ($n in $plan.Source) {
    $copy = Join-Path $dst $n
    if ($plan.Managed -contains $n) {
      $plan.Wanted += $n
      if (-not $fresh -or -not (Test-Path -LiteralPath $copy -PathType Container) -or (Test-Link $copy) -or
        (Test-SourceChanged $n $stampTime) -or (Test-CopyChanged $n $manifestTime)) { $plan.Stale += $n }
    }
    elseif (-not (Test-Exists $copy)) { $plan.Wanted += $n; $plan.Stale += $n }
    elseif (Test-Leftover $n) { $plan.Wanted += $n; $plan.Stale += $n; $plan.Adopted += $n }
    else { $plan.Conflicts += $n }
  }
  foreach ($n in $plan.Managed) { if ($plan.Wanted -notcontains $n) { $plan.Gone += $n } }
  return $plan
}

# The repository folder, or the folder above it, that holds the entry $Entry: .git or .svn, by which
# a checkout of git or svn is known. Nothing when there is none. git and svn are asked only where
# they are at home.
function Find-Above([string]$Entry) {
  $folder = $root
  while ($folder) {
    if (Test-Exists (Join-Path $folder $Entry)) { return $folder }
    $folder = [IO.Path]::GetDirectoryName($folder)
  }
}

# True while git is at work on the checkout whose .git lies in $Folder: it holds a lock on its index
# then, from the first file of a checkout to the last. The index is in .git, or in the folder that a
# .git file names (a worktree, a submodule).
function Test-GitBusy([string]$Folder) {
  $gitDir = Join-Path $Folder '.git'
  if (Test-Path -LiteralPath $gitDir -PathType Leaf) {
    $line = ''
    try { $line = [string](@([IO.File]::ReadAllLines($gitDir))[0]) } catch { }
    if ($line.StartsWith('gitdir: ', [StringComparison]::Ordinal)) {
      $gitDir = $line.Substring(8).Trim()
      if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Folder $gitDir }
    }
  }
  return (Test-Exists (Join-Path $gitDir 'index.lock'))
}

# Asks git and svn about the folders .claude/skills/<name> of $Names, with one process each for git
# and for every folder that svn is asked about. Git and Svn: the names in whose folder they track
# something. Busy: git is at work on the checkout this moment. Its index is still the one of before
# then, so its answer would be wrong. A git that fails here (it does not trust the checkout, it is
# too old) is like no git: it tracks nothing that the bridge could ask about, and the other signs
# decide.
function Get-Tracked([string[]]$Names) {
  $tracked = @{ Git = @(); Svn = @(); Busy = $false }
  $checkout = Find-Above '.git'
  if ($checkout -and (Get-Command git -ErrorAction SilentlyContinue)) {
    if (Test-GitBusy $checkout) { $tracked.Busy = $true; return $tracked }
    # Letter case counts for nothing, in the question and in the answer: Windows takes a folder in
    # another letter case for the same one.
    $answer = Invoke-Tool git (@('-C', $root, '--icase-pathspecs', 'ls-files', '--') + @($Names | ForEach-Object { ".claude/skills/$_" }))
    if ($answer.Code -eq 0) {
      $out = "`n" + $answer.Out + "`n"
      foreach ($n in $Names) {
        # A tracked file in the folder (git puts quotes around a name with unusual letters), or the
        # name itself: a tracked link, or a file where the folder was.
        $p = ".claude/skills/$n"
        foreach ($line in "`n$p/", "`n`"$p/", "`n$p`n") {
          if ($out.IndexOf($line, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $tracked.Git += $n; break }
        }
      }
    }
  }
  if ((Find-Above '.svn') -and (Get-Command svn -ErrorAction SilentlyContinue)) {
    foreach ($n in $Names) {
      if ((Invoke-Tool svn @('info', (Join-Path $dst $n))).Code -eq 0) { $tracked.Svn += $n }
    }
  }
  return $tracked
}

# One more sentence for whoever keeps the folder .claude/skills/$Name, which the bridge leaves alone:
# the copy's .gitignore stays in it, and goes on hiding what is new there from git.
function Get-Hint([string]$Name) {
  if ((Test-Marked $Name) -and (Find-Above '.git')) {
    return ' Its .gitignore still hides new files there from git: delete that file if you work in the folder.'
  }
  return ''
}

# Before the bridge deletes or replaces a folder, it makes sure that the folder still is the copy
# that it made: its records alone do not say so. Someone may have put a skill of their own in the
# copy's place, by hand or with a git checkout of a branch that keeps the skill in .claude/skills.
# Looks at the folders of Gone and Stale that are on record. A folder is still the bridge's copy
# when all of this holds:
#   - It holds the .gitignore that the bridge wrote: whoever replaces the folder replaces that file
#     too. Only a folder that a sync may have left half-done (Doubt) can be without it.
#   - Its skill is still in .agents/skills, or its SKILL.md is the one the bridge copied. A changed
#     SKILL.md whose skill is gone could be restored from nowhere.
#   - git and svn track nothing in it. They are asked only about a folder that holds a file that the
#     bridge did not put there (see Test-Touched), or lacks the .gitignore: what a checkout writes is
#     new and can be written, and git puts a tracked file over an ignored copy without a word.
# Whatever else differs in a folder with that .gitignore is an edit of a copy: the bridge restores
# it. Sets Taken to the names whose folder is no longer the bridge's copy, and takes them out of
# Gone, Stale and Wanted: the bridge leaves these folders alone, and its next manifest does not
# list them. Why says why, name by name. Sets Busy when git had to be asked and is at work this
# moment: then nothing is decided, and the caller waits for the next hook.
function Select-Own($Plan) {
  $why = @{}
  $ask = @()
  $work = @($Plan.Gone) + @($Plan.Stale)
  $Plan.Busy = $false
  foreach ($n in $work) {
    if ($Plan.Managed -notcontains $n) { continue } # a new copy: no folder is there, or a leftover
    $folder = Join-Path $dst $n
    $item = Get-Item -LiteralPath $folder -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    if (Test-LinkItem $item) { $ask += $n } # a link holds nothing; the bridge unlinks it unless git or svn tracks it
    elseif ($item -isnot [IO.DirectoryInfo]) { $why[$n] = 'it is not a folder' }
    elseif (Test-Bare $folder) { } # an empty folder is nobody's work
    elseif (-not (Test-Marked $n)) {
      if ($Plan.Doubt -contains $n) { $ask += $n }
      else { $why[$n] = 'the .gitignore that the bridge wrote is not in it' }
    }
    else {
      $mark = Get-WriteTime (Join-Path $folder '.gitignore')
      # A sync that was killed may have left its copy before it made the files read-only.
      $seal = ($Plan.Doubt -notcontains $n) -and (Test-Sealed $n)
      if (Test-Touched $folder $mark $seal) {
        $skill = Get-Item -LiteralPath (Join-Path $folder 'SKILL.md') -Force -ErrorAction SilentlyContinue
        if (($Plan.Gone -contains $n) -and ($skill -is [IO.FileInfo]) -and
          (($skill.LastWriteTimeUtc -gt $mark) -or ($seal -and -not $skill.IsReadOnly))) {
          $why[$n] = "its SKILL.md is not the one that the bridge copied, and .agents/skills/$n is gone"
        }
        else { $ask += $n }
      }
    }
  }
  if ($ask.Count) {
    $tracked = Get-Tracked $ask
    if ($tracked.Busy) { $Plan.Busy = $true; return }
    foreach ($n in $ask) {
      if ($tracked.Git -contains $n) { $why[$n] = 'git tracks it' }
      elseif ($tracked.Svn -contains $n) { $why[$n] = 'svn tracks it' }
    }
  }
  $Plan.Why = $why
  $Plan.Taken = @($work | Where-Object { $why.ContainsKey($_) })
  $Plan.Gone = @($Plan.Gone | Where-Object { -not $why.ContainsKey($_) })
  $Plan.Stale = @($Plan.Stale | Where-Object { -not $why.ContainsKey($_) })
  $Plan.Wanted = @($Plan.Wanted | Where-Object { -not $why.ContainsKey($_) })
}

# The text of the stamp of a sync that has begun: see Invoke-Sync. $Work names the copies that the
# sync is about to delete or to make, $Copies every copy of the bridge. The line with $Work comes
# first: a stamp that is cut short still has it, or names nothing at all.
function Get-BegunText([string[]]$Work, [string[]]$Copies) {
  return $unfinishedLine + ((@($Work) | ForEach-Object { " $_" }) -join '') + "`n" +
  "# A sync began here and has not ended. Above: the copies that it was about to delete or to make. Below: every copy of the bridge.`n" +
  ((@($Copies) | ForEach-Object { "$_`n" }) -join '')
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
      if ($item.Attributes -band $readOnly) { $item.Attributes = $item.Attributes -bxor $readOnly }
      Clear-Copy $p
      [IO.Directory]::Delete($p, $true)
    }
    else { $item.IsReadOnly = $false; [IO.File]::Delete($p) }
  }
  catch { return $false }
  return -not (Test-Exists $p)
}

# Writes .claude/skills/$Name/.gitignore, last of all that goes into the copy. It makes git ignore
# the whole copy, whatever the rules in the folders above say, so the copy needs no line in a
# .gitignore that someone else owns. By its first line the bridge knows the copy for its own later:
# see Test-Marked.
function Set-CopyIgnore([string]$Name) {
  $file = Join-Path (Join-Path $dst $Name) '.gitignore'
  $old = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
  if ($old) { $old.Attributes = [IO.FileAttributes]::Normal } # a read-only or hidden .gitignore that came with the source
  $text = (Get-MarkLine $Name) + "`n# Git ignores the whole copy. Edit the original in .agents/skills.`n*`n"
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
  $script:unread = 0
  $script:tooDeep = $false
  try {
    $from = Resolve-Item (Get-Item -LiteralPath (Join-Path $src $Name) -Force)
    if (-not $from) { throw 'it is a link to nowhere' }
    Copy-Folder $from.FullName $to ''
    if (-not (Test-Path -LiteralPath (Join-Path $to 'SKILL.md') -PathType Leaf)) { throw 'its SKILL.md cannot be read' }
    Set-CopyIgnore $Name
    # A file keeps the time of its original. One that lies ahead of the clock would be newer than
    # the copy's .gitignore for good, and pass for a file that someone put there: see Test-Touched.
    $mark = Get-WriteTime (Join-Path $to '.gitignore')
    foreach ($f in @(Get-CopyFiles $to)) {
      if ($f.LastWriteTimeUtc -gt $mark) {
        $f.IsReadOnly = $false
        $f.LastWriteTimeUtc = $mark
      }
      $f.IsReadOnly = $true
    }
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
  # A copy that lacks a file which is there to copy is not whole: the next sync tries again.
  return ($script:unread -eq 0)
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
    if ($script:skipped) { Add-Note "Skipped a folder in .agents/skills: skill folder names may only use letters, digits, '.', '_' and '-'." }
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
    # No folder is deleted or replaced that is not the bridge's own copy any more.
    Select-Own $plan
    if ($plan.Busy) {
      # Nothing is written yet, so the next hook finds everything as this one did.
      Add-Note 'git is at work in this checkout, so this sync waits for the next hook.'
      return
    }
    foreach ($n in $plan.Taken) {
      $text = ".claude/skills/$n is no longer the copy that the bridge made ($($plan.Why[$n])). The bridge leaves it alone"
      if ($plan.Source -contains $n) { Add-Note "$text, so .agents/skills/$n is not copied. Rename or delete one of them.$(Get-Hint $n)" }
      else { Add-Note "$text.$(Get-Hint $n)" }
    }
    # The stamp of a sync that has begun goes into the records. Unlike the stamp of a sync that has
    # ended, it holds text and is newer than the manifest: a sync that is killed midway counts as
    # unfinished, and the next one makes every copy again. The text names every copy that is the
    # bridge's, the ones this sync is about to make among them. So a copy is on record before it
    # exists: a sync that is killed after a new copy and before its manifest leaves nothing that the
    # next plan would take for someone's own skill.
    # The first line names the copies that this sync is about to delete or to make. Should it be
    # killed, their folders may be half-done, without the .gitignore by which the bridge knows its
    # copies: the next sync does not ask them for it (see Select-Own). It asks every other folder,
    # so what Select-Own found to be someone's own stays theirs after a kill too.
    $work = @($plan.Gone) + @($plan.Stale)
    $new = @($plan.Stale | Where-Object { $plan.Managed -notcontains $_ })
    $copies = @($plan.Managed | Where-Object { $plan.Taken -notcontains $_ }) + $new
    # No copy is made that is not on record.
    try { [IO.File]::WriteAllText($stamp, (Get-BegunText $work $copies), $utf8) }
    catch { Add-Note 'Could not write .claude/skills/.agent-skills-bridge/stamp, so nothing was copied.'; return }
    if ($work.Count) { $script:changed = $true }
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
      if (($plan.Managed -contains $n) -or ($plan.Adopted -contains $n)) { [void](Remove-Copy $n) }
      elseif (Test-Exists (Join-Path $dst $n)) {
        # No folder was there when the sync looked: someone made this one meanwhile, so it is theirs.
        Add-Note ".claude/skills/$n exists and was not made by the bridge, so .agents/skills/$n is not copied. Rename or delete one of them."
        $plan.Wanted = @($plan.Wanted | Where-Object { $_ -ne $n })
        continue
      }
      if (-not (Copy-Skill $n)) { $broken = $true }
    }
    $kept += @($plan.Wanted | Where-Object { Test-Path -LiteralPath (Join-Path $dst $_) -PathType Container })
    if ($kept.Count -eq 0) {
      Remove-Item -LiteralPath $manifest, $stamp -Force -ErrorAction SilentlyContinue
      return
    }
    $text = "# Copies made by .claude/hooks/agent-skills-bridge.sh from .agents/skills. Do not edit.`n"
    if ($broken) {
      # What this sync could not delete or make stays on record, and its folder may have lost the
      # bridge's .gitignore on the way. The manifest says which folders: the next sync does not ask
      # them for that file, and asks every other one.
      $left = @($work | Where-Object { ($kept -contains $_) -and -not (Test-Marked $_) })
      $text += $unfinishedLine + (($left | ForEach-Object { " $_" }) -join '') + "`n"
    }
    $text += (($kept | ForEach-Object { "$_`n" }) -join '')
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
  $match = @((Read-Records).Managed | Where-Object { $_ -eq $name }) # the list, name by name
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
  Select-Own $plan # as the next sync will: it may ask git or svn
  $plan.Managed = @($plan.Managed | Where-Object { $plan.Taken -notcontains $_ })
  "agent-skills bridge: $root"
  "  .agents/skills  $($plan.Source.Count) skill(s): $($plan.Source -join ' ')"
  "  .claude/skills  $($plan.Managed.Count) copy(ies): $($plan.Managed -join ' ')"
  if ($plan.Conflicts.Count) { "  conflicts       $($plan.Conflicts -join ' ') (in .claude/skills, not made by the bridge)" }
  foreach ($n in $plan.Taken) {
    "  left alone      ${n}: no longer the copy that the bridge made ($($plan.Why[$n])). The next sync takes it off the records"
  }
  if ($plan.Busy) { '  git             at work in this checkout: a sync waits until it is done' }
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
  $managed = (Read-Records).Managed
  if ($managed.Count -eq 0 -and -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    # No copies, but perhaps records: a sync that deleted the last copy leaves its folder behind.
    if ((Test-Path -LiteralPath $state -PathType Container) -and -not (Test-Exists $lock)) {
      Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
    }
    'agent-skills bridge: no copies to delete.'
    return
  }
  if (-not (Enter-Lock)) { Write-Line 'agent-skills bridge: another sync is running; try again.' -Stderr; exit 1 }
  try {
    $plan = Get-Plan
    # Every copy on record goes, current or not, but no folder that is not the bridge's copy any more.
    $plan.Gone = @($plan.Managed | Where-Object { $plan.Source -notcontains $_ })
    $plan.Stale = @($plan.Managed | Where-Object { $plan.Source -contains $_ })
    Select-Own $plan
    $mine = @($plan.Managed | Where-Object { $plan.Taken -notcontains $_ })
    $stuck = @()
    if (-not $plan.Busy) {
      # As a sync does, clean first puts on record which folders it is about to delete. Should it be
      # killed, or should a folder stay, the next sync knows that these may be half-deleted.
      try { [IO.File]::WriteAllText($stamp, (Get-BegunText (@($plan.Gone) + @($plan.Stale)) $mine), $utf8) } catch { }
      $stuck = @($mine | Where-Object { -not (Remove-Copy $_) })
    }
  }
  finally { Exit-Lock }
  if ($plan.Busy) { Write-Line 'agent-skills bridge: git is at work in this checkout; try again when it is done.' -Stderr; exit 1 }
  if ($stuck.Count) {
    # The records stay: without them the bridge would take what is left for someone else's skills.
    Write-Line "agent-skills bridge: could not delete: $($stuck -join ' '). Is a file in there open? Close it and run clean again." -Stderr
    exit 1
  }
  Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue # the records
  if ($mine.Count) { "agent-skills bridge: deleted the copies: $($mine -join ' ')." }
  else { 'agent-skills bridge: no copies to delete.' }
  foreach ($n in $plan.Taken) {
    "agent-skills bridge: left .claude/skills/$n alone: it is no longer the copy that the bridge made ($($plan.Why[$n])).$(Get-Hint $n)"
  }
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
    # Through Write-Line, so that a pipe gets UTF-8 from these two as well.
    'status' { Show-Status | ForEach-Object { Write-Line $_ } }
    'clean' { Invoke-Clean | ForEach-Object { Write-Line $_ } }
  }
}
catch {
  if ($Command -eq 'guard') { exit 0 } # never block an edit because the bridge broke
  Add-Note "failed: $(Get-Reason $_)"
  if ($hook) { Write-Result } else { Write-Line "agent-skills bridge: failed: $(Get-Reason $_)" -Stderr; exit 1 }
}
exit 0
