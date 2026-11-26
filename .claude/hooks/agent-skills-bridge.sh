#!/bin/sh
# agent-skills-bridge.sh - make the skills in .agents/skills visible to Claude Code.
#
# .agents/skills is the one place this repository keeps its Agent Skills: Codex, Copilot, Cursor,
# Junie and OpenCode read it directly. Claude Code reads project skills only from .claude/skills, so
# this script copies each .agents/skills/<name>/ to .claude/skills/<name>/ as a generated, read-only
# copy. Each copy carries its own .gitignore, so git ignores it whatever else lives in .claude/skills.
# The hooks in .claude/settings.json run it; nobody has to. Details: agent-skills-bridge.md.
#
# Usage: sh .claude/hooks/agent-skills-bridge.sh [sync|session|guard|status|clean]
#   sync     copy new and changed skills, delete copies of removed ones (the default)
#   session  sync, then answer the SessionStart hook: reload skills, watch .agents/skills
#   guard    answer the PreToolUse hook: refuse an edit inside a copy, naming the source file
#   status   show what is bridged, whether the copies are current and whether git or svn ignores them
#   clean    delete every copy this script made, and its records
# AGENT_SKILLS_BRIDGE=off makes sync, session and guard do nothing.
#
# Hooks dot-source this file with ASB_CMD set, so no second shell starts. When nothing changed it
# starts no process at all: on Windows each process can cost the better part of a second. It runs in
# POSIX sh: dash (Ubuntu), bash 3.2 (macOS), Git Bash (Windows), BusyBox ash (Alpine), and in zsh.
# agent-skills-bridge.ps1 does the same job where Claude Code runs hooks in PowerShell (Windows
# without Git Bash). Keep both in step.

# zsh, when a hook shell is one: split words and leave unmatched globs alone, as sh does, and
# expand no aliases (zsh reads ~/.zshenv, and with it any alias, even for a hook).
[ -z "${ZSH_VERSION:-}" ] || { emulate sh && unsetopt aliases; }
set -u
CDPATH= # or cd could go somewhere else, and print where

if [ -n "${ASB_CMD:-}" ]; then
  cmd=$ASB_CMD
  cd "${CLAUDE_PROJECT_DIR:-.}" 2> /dev/null || exit 0
else
  cmd=${1:-sync}
  case $0 in *[/\\]*) cd "${0%[/\\]*}/../.." || exit 1 ;; *) cd ../.. || exit 1 ;; esac
fi
case $cmd in
  sync | session | guard | status | clean) ;;
  *)
    echo "usage: sh .claude/hooks/agent-skills-bridge.sh [sync|session|guard|status|clean]" >&2
    exit 64
    ;;
esac

# Hooks send a JSON event on stdin. Read it, so Claude Code never writes into a closed pipe.
input=
if [ ! -t 0 ] && { [ -n "${ASB_CMD:-}" ] || [ "$cmd" = guard ]; }; then
  while IFS= read -r line || [ -n "$line" ]; do input=$input$line; done
fi

if [ "${AGENT_SKILLS_BRIDGE:-}" = off ]; then
  case $cmd in sync | session | guard) exit 0 ;; esac
fi

src=.agents/skills
dst=.claude/skills
state=$dst/.agent-skills-bridge # the bridge's records; like each copy, the folder ignores itself
manifest=$state/manifest
stamp=$state/stamp
lock=$state/lock
notes=
changed=0

note() { notes="${notes}${notes:+ }$*"; }

# True when $1 is safe as a folder name in paths, in the manifest and in JSON.
valid_name() {
  case $1 in '' | .* | -* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# True when the space-separated list $1 contains the word $2.
has() {
  case " $1 " in *" $2 "*) return 0 ;; esac
  return 1
}

# Sets l to $1 in lower case, in-process where the shell allows it (bash 4 and later).
lower() {
  if [ "${BASH_VERSINFO:-0}" -ge 4 ]; then eval 'l=${1,,}'; else l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); fi
}

# Turns the escaped backslashes (\\) of the JSON string in $p into slashes, in-process where the
# shell allows it. Each must become one slash: two of them start a network path (\\server\share).
p_json() {
  case $p in *\\\\*) ;; *) return 0 ;; esac
  if [ -n "${BASH_VERSION:-}" ]; then eval 'p=${p//\\\\//}'; else p=$(printf '%s' "$p" | sed 's|\\\\|/|g'); fi
}

# Turns the backslashes in $p into slashes, in-process where the shell allows it.
p_slashes() {
  case $p in *\\*) ;; *) return 0 ;; esac
  if [ -n "${BASH_VERSION:-}" ]; then eval 'p=${p//\\//}'; else p=$(printf '%s' "$p" | tr '\\' '/'); fi
}

# Upper-cases a Windows drive letter in $p, so c:/x and C:/x compare equal without a subprocess.
p_drive() {
  case $p in
    [a-z]:*)
      d=${p%%:*}
      case $d in
        a) d=A ;; b) d=B ;; c) d=C ;; d) d=D ;; e) d=E ;; f) d=F ;; g) d=G ;; h) d=H ;; i) d=I ;;
        j) d=J ;; k) d=K ;; l) d=L ;; m) d=M ;; n) d=N ;; o) d=O ;; p) d=P ;; q) d=Q ;; r) d=R ;;
        s) d=S ;; t) d=T ;; u) d=U ;; v) d=V ;; w) d=W ;; x) d=X ;; y) d=Y ;; z) d=Z ;;
      esac
      p=$d${p#?}
      ;;
  esac
}

# Resolves the "." and ".." folders in the absolute path $p and drops doubled and trailing slashes,
# in-process. The two slashes that start a network path (//server/share) stay.
p_dots() {
  case $p/ in *//* | */./* | */../*) ;; *) return 0 ;; esac
  case $p in //[!/]*) unc=/ ;; *) unc= ;; esac
  todo=$p/
  p=${todo%%/*}
  todo=${todo#*/}
  while [ -n "$todo" ]; do
    seg=${todo%%/*}
    todo=${todo#*/}
    case $seg in
      '' | .) ;;
      ..) case $p in */*) p=${p%/*} ;; esac ;;
      *) p=$p/$seg ;;
    esac
  done
  [ -n "$p" ] || p=/
  p=$unc$p
}

# Spells the absolute path in $p the way Claude Code does: slashes, C:/... on Windows (also for the
# /c/... of Git Bash), no "." or ".." folders.
p_native() {
  p_slashes
  case $p in
    /[a-zA-Z] | /[a-zA-Z]/*) if [ -n "${MSYSTEM:-}" ]; then
      d=${p#/}
      d=${d%%/*}
      p=$d:${p#/"$d"}
    fi ;;
  esac
  p_drive
  p_dots
}

# Sets nroot to the repository path the way Claude Code spells it (C:/... on Windows), without a
# slash at its end: empty when the repository is the root folder.
native_root() {
  p=${CLAUDE_PROJECT_DIR:-$PWD}
  case $p in /* | [a-zA-Z]:* | \\*) ;; *) p=$PWD ;; esac # a relative one: the shell is there already
  p_native
  nroot=${p%/}
}

# Sets p to the string that the JSON event in $input gives for the key $1, escapes and all; fails
# when there is none. Allows blanks around the colon. A key quoted inside another string has a
# backslash before its closing quote, so it never matches.
json_string() {
  p=$input
  while :; do
    case $p in *"\"$1\""*) p=${p#*"\"$1\""} ;; *) return 1 ;; esac
    q=$p
    json_blanks
    case $q in :*) q=${q#:} ;; *) continue ;; esac
    json_blanks
    case $q in \"*) ;; *) continue ;; esac
    p=${q#\"}
    p=${p%%\"*}
    return 0
  done
}

json_blanks() {
  while :; do case $q in [[:space:]]*) q=${q#?} ;; *) return 0 ;; esac; done
}

# Sets src_names to the folders in .agents/skills that hold a SKILL.md.
scan_source() {
  src_names=
  for s in "$src"/*; do
    [ -f "$s/SKILL.md" ] || continue
    n=${s##*/}
    if valid_name "$n"; then
      src_names="$src_names $n"
    else
      note "Skipped a folder in .agents/skills: skill folder names may only use letters, digits, '.', '_' and '-'."
    fi
  done
}

# Sets names to the skill names that the record file $1 lists, one on a line. A last line that lacks
# its line end counts only when $2 is 1. In the manifest an editor may have left it so. In a stamp
# it is a name that was cut short, because the sync was killed while it wrote the stamp.
read_names() {
  names=
  [ -f "$1" ] || return 0
  {
    while IFS= read -r line || { [ "$2" = 1 ] && [ -n "$line" ]; }; do
      line=${line%[[:cntrl:]]} # the carriage return of a record that someone saved with CRLF
      case $line in '' | '#'*) continue ;; esac
      if valid_name "$line"; then names="$names $line"; fi
    done < "$1"
  } 2> /dev/null # the sync that wrote a stamp may delete it this moment
}

# Sets managed to the copies that are the bridge's. The manifest lists the copies that a finished
# sync made. A sync that began and has not ended lists its copies in its stamp, the ones it is about
# to make among them: those are the bridge's too, though the manifest does not list them yet.
read_manifest() {
  read_names "$manifest" 1
  managed=$names
  [ -s "$stamp" ] || return 0
  read_names "$stamp" 0
  for u in $names; do has "$managed" "$u" || managed="$managed $u"; done
}

# True when $1, or anything under it, changed at or after the stamp (taken when the last sync began).
# Follows links, as the copy does; past 16 levels (a link loop?) it answers "changed". A link to
# nowhere has nothing to copy and counts for nothing: [ -nt ] would answer differently per shell.
depth=0
src_changed() {
  [ "$stamp" -nt "$1" ] || return 0
  [ -d "$1" ] || return 1
  depth=$((depth + 1))
  if [ "$depth" -gt 16 ]; then
    depth=$((depth - 1))
    return 0
  fi
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$e" ] && src_changed "$e"; then
      depth=$((depth - 1))
      return 0
    fi
  done
  depth=$((depth - 1))
  return 1
}

# True when $1, or anything under it, changed after the manifest (written when the last sync ended).
copy_changed() {
  [ "$1" -nt "$manifest" ] && return 0
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$e" ] || [ -L "$e" ]; then copy_changed "$e" && return 0; fi
  done
  return 1
}

# Sets wanted (skills to copy), stale (copies to refresh), gone (copies to delete) and conflicts.
plan() {
  scan_source
  read_manifest
  wanted=
  stale=
  gone=
  conflicts=
  fresh=1 # the last sync finished, so the stamp can be trusted
  # The stamp of a sync that has not ended holds text, and it is newer than the manifest.
  if [ ! -f "$stamp" ] || [ ! -f "$manifest" ] || [ -s "$stamp" ] || [ "$stamp" -nt "$manifest" ]; then fresh=0; fi
  for n in $src_names; do
    if has "$managed" "$n"; then
      wanted="$wanted $n"
      if [ "$fresh" = 0 ] || [ ! -d "$dst/$n" ] || [ -L "$dst/$n" ] ||
        src_changed "$src/$n" || copy_changed "$dst/$n"; then stale="$stale $n"; fi
    elif [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then
      conflicts="$conflicts $n"
    else
      wanted="$wanted $n"
      stale="$stale $n"
    fi
  done
  for n in $managed; do has "$wanted" "$n" || gone="$gone $n"; done
}

# Deletes the copies .claude/skills/<name> for every name in the arguments, with one process for all
# of them. A symlink or junction is unlinked, never followed. Prints nothing; check with [ -e ].
# ${1+"$@"} instead of "$@" everywhere: bash 3.2 (macOS) calls "$@" unbound when it is empty.
remove_copies() {
  links=
  dirs=
  for n in ${1+"$@"}; do
    if [ -L "$dst/$n" ]; then links="$links $dst/$n"; elif [ -e "$dst/$n" ]; then dirs="$dirs $dst/$n"; fi
  done
  # shellcheck disable=SC2086 # relative paths built from validated names
  [ -z "$links" ] || rm -f $links
  [ -n "$dirs" ] || return 0
  # shellcheck disable=SC2086
  rm -rf $dirs 2> /dev/null
  again=
  for n in $dirs; do [ ! -e "$n" ] || again="$again $n"; done
  [ -n "$again" ] || return 0
  # A folder that is read-only in the source is read-only in the copy, and holds on to its files.
  # shellcheck disable=SC2086
  chmod -R u+w $again 2> /dev/null
  # shellcheck disable=SC2086
  rm -rf $again 2> /dev/null
}

# The .gitignore of the copy of skill $1: it makes git ignore the whole copy, whatever the rules
# in the folders above say, so the copy needs no line in a .gitignore that someone else owns.
copy_ignore_text() {
  printf '%s\n' "# Copy of .agents/skills/$1 for Claude Code, made by .claude/hooks/agent-skills-bridge.sh." \
    '# Git ignores the whole copy. Edit the original in .agents/skills.' '*'
}

ignore_copy() {
  f=$dst/$1/.gitignore
  { copy_ignore_text "$1" > "$f"; } 2> /dev/null && return 0
  chmod u+w "$dst/$1" 2> /dev/null # a skill folder that is read-only in the source
  rm -f "$f"                       # a read-only .gitignore that came with the source
  { copy_ignore_text "$1" > "$f"; } 2> /dev/null || note "Could not write $f, so git may list that copy."
}

# Copies .agents/skills/<name> to .claude/skills/<name> for every name in the arguments whose old
# copy is gone, gives each copy its .gitignore, then makes the copies read-only. Three processes,
# however many skills. Sets broken=1 when it leaves a copy behind that is not whole.
copy_skills() {
  from=
  for n in ${1+"$@"}; do
    if [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then
      note "Could not replace .claude/skills/$n; is a file in it open?"
      broken=1
    else
      from="$from $src/$n"
    fi
  done
  # shellcheck disable=SC2086
  [ -z "$from" ] || cp -R -L $from "$dst/" 2> /dev/null ||
    note "Not everything in .agents/skills could be copied: look for a broken link, a link loop or a file that cannot be read."
  made=
  halves=
  for n in ${1+"$@"}; do
    case " $from " in *" $src/$n "*) ;; *) continue ;; esac
    if [ -f "$dst/$n/SKILL.md" ]; then
      ignore_copy "$n"
      made="$made $dst/$n"
    else
      note "Could not copy .agents/skills/$n."
      halves="$halves $n"
    fi
  done
  # shellcheck disable=SC2086
  [ -z "$made" ] || find $made -type f -exec chmod a-w {} + 2> /dev/null
  [ -n "$halves" ] || return 0
  # No half copy: Claude Code would list it, and the next sync would take it for current.
  # shellcheck disable=SC2086
  remove_copies $halves
  for n in $halves; do [ ! -e "$dst/$n" ] || broken=1; done
}

# Takes the lock folder; a lock left by a killed run goes stale after two minutes.
acquire_lock() {
  tries=0
  while ! mkdir "$lock" 2> /dev/null; do
    if [ ! -d "$state" ]; then # a clean deleted the records meanwhile
      mkdir -p "$state" 2> /dev/null || return 1
      continue
    fi
    if [ -n "$(find "$lock" -prune -mmin +2 2> /dev/null)" ]; then
      rm -rf "$lock" || return 1
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 75 ] || return 1
    sleep 0.2 2> /dev/null || sleep 1
  done
  trap 'rm -rf "$lock"' EXIT
  trap 'exit 130' HUP INT TERM
  return 0
}

# Writes the stamp of a sync that has begun into the records. Unlike the stamp of a sync that has
# ended, it holds text and is newer than the manifest: a sync that is killed midway counts as
# unfinished, and the next one makes every copy again. The text names every copy that is the
# bridge's, the ones this sync is about to make among them. So a copy is on record before it exists:
# a sync that is killed after a new copy and before its manifest leaves nothing that the next plan
# would take for someone's own skill.
begin_sync() {
  new=
  for n in $stale; do has "$managed" "$n" || new="$new $n"; done
  # shellcheck disable=SC2086 # validated names
  {
    printf '%s\n' '# A sync began here and has not ended. Its copies, the ones it was about to make among them:' \
      $managed $new > "$stamp"
  } 2> /dev/null
}

do_sync() {
  # Problems that persist are reported once per session, not on every file event.
  loud=0
  if [ "$cmd" = session ] || [ -t 1 ]; then loud=1; fi
  # Never write through a link: someone set this up by hand (perhaps to .agents/skills itself).
  if [ -L "$dst" ]; then
    [ "$loud" = 0 ] || note ".claude/skills is a link, so the bridge leaves it alone."
    return 0
  fi
  plan
  if [ "$loud" = 1 ]; then
    for n in $conflicts; do
      note ".claude/skills/$n exists and was not made by the bridge, so .agents/skills/$n is not copied. Rename or delete one of them."
    done
  fi
  [ -n "$stale$gone" ] || return 0
  if [ ! -d "$dst" ]; then
    if ! mkdir -p "$state" 2> /dev/null; then
      note "Could not create .claude/skills."
      return 0
    fi
    # The bridge made the folder, so it leaves a file to commit: every checkout then has the
    # folder, and Claude Code watches it from the first session. It ignores nothing.
    printf '%s\n' \
      '# Keeps .claude/skills in every checkout, so Claude Code watches it from the first session.' \
      '# .claude/hooks/agent-skills-bridge.sh copies .agents/skills here. Each copy has its own' \
      '# .gitignore, so git never sees the copies. Commit this file; edit skills in .agents/skills.' \
      > "$dst/.gitignore" 2> /dev/null
  elif [ ! -d "$state" ] && ! mkdir "$state" 2> /dev/null; then
    note "Could not create $state."
    return 0
  fi
  [ -f "$state/.gitignore" ] || printf '%s\n' \
    '# Records of .claude/hooks/agent-skills-bridge.sh. Git ignores this folder.' '*' \
    > "$state/.gitignore" 2> /dev/null
  acquire_lock || {
    note "Another sync was still running, so this one was skipped."
    return 0
  }
  # The stamp of this sync is written now, before the plan looks at the skills: a file that changes
  # while the plan runs is then no older than the stamp, and the next sync copies it. The stamp
  # waits in the lock folder, because the plan still compares with the stamp of the last sync, and
  # a shell cannot set a file's time later without starting a program.
  : > "$lock/stamp"
  plan # again: a sync that held the lock may have done the work
  [ -n "$stale$gone" ] || return 0
  # No copy is made that is not on record.
  begin_sync || {
    note "Could not write $stamp, so nothing was copied."
    return 0
  }
  changed=1
  broken=0
  # shellcheck disable=SC2086 # validated names
  remove_copies $gone $stale
  kept=
  for n in $gone; do
    if [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then
      note "Could not delete the old copy .claude/skills/$n; is a file in it open?"
      kept="$kept $n" # still the bridge's: the next sync tries again
      broken=1
    fi
  done
  # shellcheck disable=SC2086
  copy_skills $stale
  for n in $wanted; do [ -d "$dst/$n" ] && kept="$kept $n"; done
  if [ -z "$kept" ]; then
    rm -f "$manifest" "$stamp"
    return 0
  fi
  # The manifest and the stamp from before the plan go into the records with one mv, the manifest
  # first. Until the manifest is there, the stamp of the sync that has begun stays, and with it the
  # names of the new copies. Should mv stop between the two, that stamp still marks the sync as
  # unfinished.
  if {
    echo '# Copies made by .claude/hooks/agent-skills-bridge.sh from .agents/skills. Do not edit.'
    for n in $kept; do echo "$n"; done
  } > "$lock/manifest" && mv -f "$lock/manifest" "$lock/stamp" "$state/"; then
    # What could not be deleted or made whole must not pass for current. Without the stamp this sync
    # counts as unfinished, and the next one makes every copy again.
    [ "$broken" = 0 ] || rm -f "$stamp"
  else
    # The records did not arrive, so this sync must not pass for finished either. mv may have moved
    # the empty stamp all the same, so the stamp of a sync that has begun is written once more.
    begin_sync
  fi
}

# Tells Claude Code (JSON on stdout) or the person at a terminal what happened.
emit() {
  if [ -t 1 ]; then
    [ -z "$notes" ] || echo "agent-skills bridge: $notes" >&2
    [ "$changed" = 0 ] || echo "agent-skills bridge: updated the copies in .claude/skills."
    return 0
  fi
  out=
  if [ "$cmd" = session ] && [ -d "$src" ]; then
    native_root
    case $nroot in *\"*) nroot=$(printf '%s' "$nroot" | sed 's/"/\\"/g') ;; esac
    out='"hookSpecificOutput":{"hookEventName":"SessionStart","watchPaths":["'$nroot/$src'"]'
    [ "$changed" = 0 ] || out="$out"',"reloadSkills":true'
    out="$out}"
  fi
  [ -z "$notes" ] || out="$out${out:+,}"'"systemMessage":"agent-skills bridge: '$notes'"'
  [ -z "$out" ] || printf '{%s}\n' "$out"
}

# PreToolUse: exit 2 (refuse, with the reason on stderr) when Write, Edit, MultiEdit or
# NotebookEdit targets a file inside a copy; exit 0 for anything else.
do_guard() {
  case $input in *[Ss][Kk][Ii][Ll][Ll][Ss]*) ;; *) return 0 ;; esac
  json_string file_path || json_string notebook_path || return 0
  p_json
  p_slashes
  fp=$p
  native_root
  case $fp in
    /* | [A-Za-z]:/*) p=$fp ;;
    *)
      # A relative path counts from the folder the event names, or else from the repository.
      if json_string cwd && [ -n "$p" ]; then
        p_json
        p=$p/$fp
      else
        p=$nroot/$fp
      fi
      ;;
  esac
  p_native
  fp=$p
  case $fp in */.[Cc][Ll][Aa][Uu][Dd][Ee]/[Ss][Kk][Ii][Ll][Ll][Ss]/*) ;; *) return 0 ;; esac
  base=$nroot/$dst
  case $fp in
    "$base"/*) rest=${fp#"$base"/} ;;
    *)
      # The same folder in another letter case. Windows and macOS take that for the same folder.
      # The bridge cannot tell what the file system here does, so it refuses everywhere.
      lower "$fp"
      lfp=$l
      lower "$base"
      case $lfp in "$l"/*) ;; *) return 0 ;; esac
      rest=${lfp#"$l"/}
      ;;
  esac
  n=${rest%%/*}
  valid_name "$n" || return 0
  read_manifest
  match=
  if has "$managed" "$n"; then
    match=$n
  else
    lower "$n"
    ln=$l
    lower "$managed"
    if has "$l" "$ln"; then
      for m in $managed; do
        lower "$m"
        [ "$l" != "$ln" ] || match=$m
      done
    fi
  fi
  [ -n "$match" ] || return 0
  sub=
  case $rest in */*) sub=${rest#*/} ;; esac
  echo "Blocked by the agent-skills bridge: .claude/skills/$match/ is a generated copy of .agents/skills/$match/ and the next sync overwrites it. Make this change in .agents/skills/$match/$sub instead; Claude Code picks it up automatically." >&2
  exit 2
}

# Status: does git ignore the copies and the records, and is .claude/skills in the repository?
git_status() {
  seen=
  for n in $managed; do
    [ -f "$dst/$n/SKILL.md" ] || continue
    git check-ignore -q "$dst/$n/SKILL.md" 2> /dev/null
    [ $? != 1 ] || seen="$seen $n"
  done
  if [ -f "$manifest" ]; then
    git check-ignore -q "$manifest" 2> /dev/null
    [ $? != 1 ] || seen="$seen (records in $state)"
  fi
  if [ -n "$seen" ]; then
    echo "  git             not ignored:$seen. Run sync; if git tracks them, remove them with git rm -r --cached"
  elif [ -n "$managed" ]; then
    echo "  git             copies are ignored"
  fi
  if git ls-files --error-unmatch "$dst" > /dev/null 2>&1; then
    echo "  git             .claude/skills is in the repository"
  else
    echo "  git             nothing in .claude/skills is committed: commit .claude/skills/.gitignore, so new clones have the folder"
  fi
}

# Status: does svn ignore the copies and the records? svn reads no .gitignore, only svn:ignore.
svn_status() {
  if ! svn info "$dst" > /dev/null 2>&1; then
    echo "  svn             .claude/skills is not in svn: see \"Adopt it in an svn working copy\" in .claude/hooks/agent-skills-bridge.md"
    return 0
  fi
  seen=
  for n in $managed .agent-skills-bridge; do
    [ -e "$dst/$n" ] || continue
    if svn info "$dst/$n" > /dev/null 2>&1; then
      seen="$seen $n" # versioned: it should never be
      continue
    fi
    case $(svn status --depth=empty "$dst/$n" 2> /dev/null) in '?'*) seen="$seen $n" ;; esac
  done
  if [ -n "$seen" ]; then
    echo "  svn             not ignored:$seen. Set svn:ignore on .claude/skills: see \"Adopt it in an svn working copy\" in .claude/hooks/agent-skills-bridge.md"
  else
    echo "  svn             copies are ignored"
  fi
}

do_status() {
  plan
  echo "agent-skills bridge: $PWD"
  # shellcheck disable=SC2086 # names are validated words
  set -- $src_names
  echo "  .agents/skills  $# skill(s):$src_names"
  # shellcheck disable=SC2086
  set -- $managed
  echo "  .claude/skills  $# copy(ies):$managed"
  [ -z "$conflicts" ] || echo "  conflicts      $conflicts (in .claude/skills, not made by the bridge)"
  if [ -z "$stale$gone" ]; then
    echo "  state           copies are current"
  else
    echo "  state           out of date:$stale${gone:+ (removed:$gone)}. The next hook syncs, or run: sh .claude/hooks/agent-skills-bridge.sh sync"
  fi
  for n in $src_names; do
    case $n in *[!a-z0-9-]* | -* | *- | *--*) echo "  note            $n: the Agent Skills spec wants lowercase letters, digits and single hyphens" ;; esac
    fm=$(sed -n -e '1{/^---/!q;}' -e '2,/^---/s/^name:[[:space:]]*//p' "$src/$n/SKILL.md" 2> /dev/null | tr -d "\"'\r" | head -n 1)
    [ -z "$fm" ] || [ "$fm" = "$n" ] || echo "  note            $n: SKILL.md says name: $fm; VS Code, Cursor and the spec want it to match the folder"
  done
  if command -v git > /dev/null 2>&1 && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then git_status; fi
  if command -v svn > /dev/null 2>&1 && svn info . > /dev/null 2>&1; then svn_status; fi
  if grep -q 'agent-skills-bridge' .claude/settings.json 2> /dev/null; then
    echo "  hooks           .claude/settings.json runs the bridge"
  else
    echo "  hooks           missing from .claude/settings.json"
  fi
  [ "${AGENT_SKILLS_BRIDGE:-}" != off ] || echo "  switch          AGENT_SKILLS_BRIDGE=off: the hooks do nothing"
}

do_clean() {
  read_manifest
  # After a first sync that was killed there is no manifest, and still there are copies.
  [ -f "$manifest" ] || [ -n "$managed" ] || {
    echo "agent-skills bridge: no copies to delete."
    return 0
  }
  acquire_lock || {
    echo "agent-skills bridge: another sync is running; try again." >&2
    exit 1
  }
  read_manifest
  # shellcheck disable=SC2086 # validated names
  remove_copies $managed
  stuck=
  for n in $managed; do
    if [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then stuck="$stuck $n"; fi
  done
  if [ -n "$stuck" ]; then
    # The records stay: without them the bridge would take what is left for someone else's skills.
    echo "agent-skills bridge: could not delete:$stuck. Is a file in there open? Close it and run clean again." >&2
    exit 1
  fi
  rm -rf "$state" # the records, the lock included
  echo "agent-skills bridge: deleted the copies:$managed."
}

case $cmd in
  sync | session)
    # A FileChanged event outside .agents is someone else's watch: nothing to do.
    case $input in *'"FileChanged"'*) case $input in *.agents*) ;; *) exit 0 ;; esac ;; esac
    do_sync
    emit
    ;;
  guard) do_guard ;;
  status) do_status ;;
  clean) do_clean ;;
esac
exit 0
