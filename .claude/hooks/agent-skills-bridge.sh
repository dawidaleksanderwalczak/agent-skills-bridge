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

# zsh, when a hook shell is one: split words and leave unmatched globs alone, as sh does. zsh reads
# ~/.zshenv even for a hook, so every option goes back to its sh default (-R), and no alias is
# expanded.
[ -z "${ZSH_VERSION:-}" ] || { emulate -R sh && unsetopt aliases; }
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
nl='
'

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

# Sets src_names to the folders in .agents/skills that hold a SKILL.md, and skipped to 1 when one of
# them has a name the bridge cannot use.
scan_source() {
  src_names=
  skipped=0
  for s in "$src"/*; do
    [ -f "$s/SKILL.md" ] || continue
    n=${s##*/}
    if valid_name "$n"; then src_names="$src_names $n"; else skipped=1; fi
  done
}

# On a line that begins like this, a record names the copies whose folders a sync may have left
# half-done: see begin_sync.
unfinished_line='# Unfinished:'

# Sets names to the skill names that the record file $1 lists, one on a line. A last line that lacks
# its line end counts only when $2 is 1. In the manifest an editor may have left it so. In a stamp
# it is a name that was cut short, because the sync was killed while it wrote the stamp. Sets
# unfinished to the names on the record's "# Unfinished:" line, seen to 1 when it has that line, and
# lines to the number of lines it took in.
read_names() {
  names=
  unfinished=
  seen=0
  lines=0
  [ -f "$1" ] || return 0
  {
    while IFS= read -r line || { [ "$2" = 1 ] && [ -n "$line" ]; }; do
      lines=$((lines + 1))
      line=${line%[[:cntrl:]]} # the carriage return of a record that someone saved with CRLF
      case $line in
        "$unfinished_line"*)
          seen=1
          words=${line#"$unfinished_line"}
          words="$words "
          while [ -n "$words" ]; do
            u=${words%% *}
            words=${words#* }
            if valid_name "$u"; then unfinished="$unfinished $u"; fi
          done
          continue
          ;;
        '' | '#'*) continue ;;
      esac
      if valid_name "$line"; then names="$names $line"; fi
    done < "$1"
  } 2> /dev/null # the sync that wrote a stamp may delete it this moment
}

# Sets managed to the copies that are the bridge's. The manifest lists the copies that a finished
# sync made. A sync that began and has not ended lists its copies in its stamp, the ones it is about
# to make among them: those are the bridge's too, though the manifest does not list them yet.
# Sets doubt to the copies whose folders a sync may have left half-done, as the records name them,
# mline to 1 when the manifest has a line for them, and sform to what the stamp of a sync that has
# begun is like: new (it has that line), old (the scripts of before wrote it, without the line) or
# cut (it ends in its first line: that sync was killed before it touched a folder).
read_manifest() {
  read_names "$manifest" 1
  managed=$names
  doubt=$unfinished
  mline=$seen
  sform=
  [ -s "$stamp" ] || return 0
  read_names "$stamp" 0
  for u in $names; do has "$managed" "$u" || managed="$managed $u"; done
  doubt="$doubt $unfinished"
  if [ "$seen" = 1 ]; then sform=new; elif [ "$lines" -gt 0 ]; then sform=old; else sform=cut; fi
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

# Sets mark to the first line of the .gitignore that the bridge writes into the copy of skill $1. By
# this line the bridge knows a copy that it made. A kit that words the line anew must go on knowing
# this one, or it takes every older copy for a skill of someone's own.
mark_line() {
  mark="# Copy of .agents/skills/$1 for Claude Code, made by .claude/hooks/agent-skills-bridge.sh."
}

# True when the folder .claude/skills/$1 holds the .gitignore that the bridge wrote into it.
marked() {
  f=$dst/$1/.gitignore
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  line=
  { IFS= read -r line < "$f"; } 2> /dev/null
  line=${line%[[:cntrl:]]} # see read_names
  mark_line "$1"
  [ "$line" = "$mark" ]
}

# True when the folder $1 has no entry. A folder that cannot be read may hold anything.
bare() {
  [ -r "$1" ] || return 1
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$e" ] || [ -L "$e" ]; then return 1; fi
  done
  return 0
}

# True when the folder $1 holds something that the bridge did not put there: a file that is newer
# than $2, the copy's own .gitignore, which the bridge writes last of all, or a link, which no copy
# holds. With $3 = 1, a file that can be written is no file of the bridge's either: see sealed. A
# folder counts for nothing by itself: its time changes when a file in it goes, and that leaves
# nothing of anyone's behind. A folder that cannot be read may hold anything.
touched() {
  [ -r "$1" ] || return 0
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -L "$e" ]; then return 0; fi
    if [ -d "$e" ]; then
      if touched "$e" "$2" "$3"; then return 0; fi
    elif [ -e "$e" ]; then
      if [ "$e" -nt "$2" ]; then return 0; fi
      if [ "$3" = 1 ] && [ -w "$e" ]; then return 0; fi
    fi
  done
  return 1
}

# Sets seal to 1 when a file that can be written tells something about the copy of skill $1. The
# bridge leaves every file of a copy read-only, its .gitignore among them. So a file there that can
# be written was put there by someone else, also when it is older than the copy: a file manager
# that moves a skill over its copy keeps the times. That holds only while the .gitignore itself is
# still read-only. Where it can be written, the user may write anything (root), or the file system
# keeps no such mark, and the sign says nothing.
sealed() {
  seal=0
  [ -w "$dst/$1/.gitignore" ] || seal=1
}

# True when .claude/skills/$1 is a folder that holds nothing of anyone's: no entry at all, or a copy
# just as the bridge made it. Such a folder is in no record when the bridge took its hands off it
# for a time (see own: git has taken its files out again), or when the records were lost. The
# bridge makes the copy anew in its place.
leftover() {
  [ -d "$dst/$1" ] && [ ! -L "$dst/$1" ] || return 1
  bare "$dst/$1" && return 0
  marked "$1" || return 1
  sealed "$1"
  ! touched "$dst/$1" "$dst/$1/.gitignore" "$seal"
}

# Sets wanted (skills to copy), stale (copies to refresh), gone (copies to delete), conflicts, and
# adopted (the skills among stale whose folder is a leftover in no record).
plan() {
  scan_source
  read_manifest
  wanted=
  stale=
  gone=
  conflicts=
  adopted=
  fresh=1 # the last sync finished, so the stamp can be trusted
  # The stamp of a sync that has not ended holds text, and it is newer than the manifest.
  if [ ! -f "$stamp" ] || [ ! -f "$manifest" ] || [ -s "$stamp" ] || [ "$stamp" -nt "$manifest" ]; then fresh=0; fi
  # Records of an unfinished sync that the scripts of before wrote do not name the folders it may
  # have left half-done: any of them may be.
  if [ "$fresh" = 0 ] && { [ "$sform" = old ] || { [ ! -f "$stamp" ] && [ "$mline" = 0 ]; }; }; then
    doubt=$managed
  fi
  for n in $src_names; do
    if has "$managed" "$n"; then
      wanted="$wanted $n"
      if [ "$fresh" = 0 ] || [ ! -d "$dst/$n" ] || [ -L "$dst/$n" ] ||
        src_changed "$src/$n" || copy_changed "$dst/$n"; then stale="$stale $n"; fi
    elif [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then
      if leftover "$n"; then
        wanted="$wanted $n"
        stale="$stale $n"
        adopted="$adopted $n"
      else
        conflicts="$conflicts $n"
      fi
    else
      wanted="$wanted $n"
      stale="$stale $n"
    fi
  done
  for n in $managed; do has "$wanted" "$n" || gone="$gone $n"; done
}

# Sets others to the words of the list $1 that the list $2 does not hold.
without() {
  others=
  for w in $1; do has "$2" "$w" || others="$others $w"; done
}

# True when the folder the shell is in, or a folder above it, holds the entry $1: .git or .svn, by
# which a checkout of git or svn is known. Sets d to that folder. git and svn are asked only where
# they are at home. The folder is taken as the system knows it (pwd -P), as git does: the way the
# shell came there may lead through a link.
above() {
  d=$(pwd -P 2> /dev/null) || d=$PWD
  while :; do
    [ ! -e "${d%/}/$1" ] || return 0
    case $d in
      //*/*/*) d=${d%/*} ;; # a network path: not above its share, where a look can take long
      //*) return 1 ;;
      */*) d=${d%/*} ;;
      *) return 1 ;;
    esac
  done
}

# True while git is at work on the checkout whose .git lies in the folder $d: it holds a lock on its
# index then, from the first file of a checkout to the last. The index is in .git, or in the folder
# that a .git file names (a worktree, a submodule).
git_busy() {
  gitdir=${d%/}/.git
  if [ -f "$gitdir" ]; then
    line=
    { IFS= read -r line < "$gitdir"; } 2> /dev/null
    line=${line%[[:cntrl:]]}
    case $line in
      'gitdir: '/* | 'gitdir: '[A-Za-z]:*) gitdir=${line#gitdir: } ;;
      'gitdir: '*) gitdir=${d%/}/${line#gitdir: } ;;
    esac
  fi
  [ -e "$gitdir/index.lock" ]
}

# Asks git and svn about the folders .claude/skills/<name> of the names in the arguments, with one
# process each for git and for every folder that svn is asked about. Sets in_git and in_svn to the
# names in whose folder they track something. Sets busy to 1 when git is at work on the checkout
# this moment: its index is still the one of before then, so its answer would be wrong. A git that
# fails here (it does not trust the checkout, it is too old) is like no git: it tracks nothing that
# the bridge could ask about, and the other signs decide.
ask_vcs() {
  in_git=
  in_svn=
  if above .git && command -v git > /dev/null 2>&1; then
    if git_busy; then
      busy=1
      return 0
    fi
    paths=
    for m in "$@"; do paths="$paths $dst/$m"; done
    # Letter case counts for nothing, in the question and in the answer: Windows and macOS take a
    # folder in another letter case for the same one, and the bridge cannot tell what the file
    # system here does (see do_guard).
    # shellcheck disable=SC2086 # relative paths built from validated names
    if out=$(git --icase-pathspecs ls-files -- $paths 2> /dev/null) && [ -n "$out" ]; then
      lower "$out"
      out="$nl$l$nl"
      lower "$*"
      lows=$l
      for m in "$@"; do
        low=${lows%% *}
        lows=${lows#* }
        # A tracked file in the folder (git puts quotes around a name with unusual letters), or the
        # name itself: a tracked link, or a file where the folder was.
        case $out in *"$nl$dst/$low/"* | *"$nl\"$dst/$low/"* | *"$nl$dst/$low$nl"*) in_git="$in_git $m" ;; esac
      done
    fi
  fi
  if above .svn && command -v svn > /dev/null 2>&1; then
    for m in "$@"; do
      if svn info "$dst/$m" > /dev/null 2>&1; then in_svn="$in_svn $m"; fi
    done
  fi
}

# Before the bridge deletes or replaces a folder, it makes sure that the folder still is the copy
# that it made: its records alone do not say so. Someone may have put a skill of their own in the
# copy's place, by hand or with a git checkout of a branch that keeps the skill in .claude/skills.
# Looks at the folders of $gone and $stale that are on record. A folder is still the bridge's copy
# when all of this holds:
#   - It holds the .gitignore that the bridge wrote: whoever replaces the folder replaces that file
#     too. Only a folder that a sync may have left half-done ($doubt) can be without it.
#   - Its skill is still in .agents/skills, or its SKILL.md is the one the bridge copied. A changed
#     SKILL.md whose skill is gone could be restored from nowhere.
#   - git and svn track nothing in it. They are asked only about a folder that holds a file that the
#     bridge did not put there (see touched), or lacks the .gitignore: what a checkout writes is new
#     and can be written, and git puts a tracked file over an ignored copy without a word.
# Whatever else differs in a folder with that .gitignore is an edit of a copy: the bridge restores
# it. Sets taken to the names whose folder is no longer the bridge's copy, and takes them out of
# $gone, $stale and $wanted: the bridge leaves these folders alone, and its next manifest does not
# list them. reason says why. Sets busy to 1 when git had to be asked and is at work this moment:
# then nothing is decided, and the caller waits for the next hook.
own() {
  taken=
  why_file=
  why_mark=
  why_skill=
  why_git=
  why_svn=
  ask=
  busy=0
  for n in $gone $stale; do
    has "$managed" "$n" || continue # a new copy: no folder is there, or a leftover
    c=$dst/$n
    if [ -L "$c" ]; then
      ask="$ask $n" # a link holds nothing; the bridge unlinks it unless git or svn tracks it
    elif [ ! -e "$c" ]; then
      :
    elif [ ! -d "$c" ]; then
      why_file="$why_file $n"
    elif bare "$c"; then
      : # an empty folder is nobody's work
    elif ! marked "$n"; then
      if has "$doubt" "$n"; then ask="$ask $n"; else why_mark="$why_mark $n"; fi
    else
      # A sync that was killed may have left its copy before it made the files read-only.
      seal=0
      has "$doubt" "$n" || sealed "$n"
      if touched "$c" "$c/.gitignore" "$seal"; then
        if has "$gone" "$n" && [ -f "$c/SKILL.md" ] &&
          { [ "$c/SKILL.md" -nt "$c/.gitignore" ] || { [ "$seal" = 1 ] && [ -w "$c/SKILL.md" ]; }; }; then
          why_skill="$why_skill $n"
        else
          ask="$ask $n"
        fi
      fi
    fi
  done
  if [ -n "$ask" ]; then
    # shellcheck disable=SC2086 # validated names
    ask_vcs $ask
    [ "$busy" = 0 ] || return 0
    for n in $ask; do
      if has "$in_git" "$n"; then
        why_git="$why_git $n"
      elif has "$in_svn" "$n"; then
        why_svn="$why_svn $n"
      fi
    done
  fi
  whys="$why_file$why_mark$why_skill$why_git$why_svn"
  [ -n "$whys" ] || return 0
  for n in $gone $stale; do
    if has "$whys" "$n"; then taken="$taken $n"; fi
  done
  without "$gone" "$taken"
  gone=$others
  without "$stale" "$taken"
  stale=$others
  without "$wanted" "$taken"
  wanted=$others
}

# Sets why to the reason for which own took .claude/skills/$1 for a folder that is not the bridge's,
# and hint to one more sentence for whoever keeps that folder.
reason() {
  hint=
  if has "$why_file" "$1"; then
    why='it is not a folder'
  elif has "$why_mark" "$1"; then
    why='the .gitignore that the bridge wrote is not in it'
  elif has "$why_skill" "$1"; then
    why="its SKILL.md is not the one that the bridge copied, and .agents/skills/$1 is gone"
  elif has "$why_git" "$1"; then
    why='git tracks it'
  else
    why='svn tracks it'
  fi
  # The copy's .gitignore stays in a folder that the bridge leaves alone, and goes on hiding what is
  # new there from git.
  if marked "$1" && above .git; then
    hint=' Its .gitignore still hides new files there from git: delete that file if you work in the folder.'
  fi
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
# in the folders above say, so the copy needs no line in a .gitignore that someone else owns. By its
# first line the bridge knows the copy for its own later: see marked.
copy_ignore_text() {
  mark_line "$1"
  printf '%s\n' "$mark" '# Git ignores the whole copy. Edit the original in .agents/skills.' '*'
}

# Writes that file, last of all that goes into the copy of skill $1. Fails when it cannot.
ignore_copy() {
  f=$dst/$1/.gitignore
  { copy_ignore_text "$1" > "$f"; } 2> /dev/null && return 0
  chmod u+w "$dst/$1" 2> /dev/null # a skill folder that is read-only in the source
  rm -f "$f"                       # a read-only .gitignore that came with the source
  { copy_ignore_text "$1" > "$f"; } 2> /dev/null
}

# True when every file and folder in the folder $1 has its counterpart in the copy $2. A link to
# nowhere has none and needs none. A link to a folder is not looked at: cp leaves a link loop out,
# and that is how it should be.
copy_whole() {
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$e" ] || continue
    if [ -d "$e" ] && [ -L "$e" ]; then continue; fi
    [ -e "$2/${e##*/}" ] || return 1
    [ ! -d "$e" ] || copy_whole "$e" "$2/${e##*/}" || return 1
  done
  return 0
}

# Copies .agents/skills/<name> to .claude/skills/<name> for every name in the arguments whose old
# copy is gone, gives each copy its .gitignore, then makes the copies read-only. Three processes,
# however many skills. Sets broken=1 when it leaves a copy behind that is not whole.
copy_skills() {
  from=
  for n in ${1+"$@"}; do
    if [ ! -e "$dst/$n" ] && [ ! -L "$dst/$n" ]; then
      from="$from $src/$n"
    elif has "$managed" "$n" || has "$adopted" "$n"; then
      note "Could not replace .claude/skills/$n; is a file in it open?"
      broken=1
    else
      # No folder was there when the sync looked: someone made this one meanwhile, so it is theirs.
      note ".claude/skills/$n exists and was not made by the bridge, so .agents/skills/$n is not copied. Rename or delete one of them."
      without "$wanted" "$n"
      wanted=$others
    fi
  done
  partial=0
  # shellcheck disable=SC2086
  [ -z "$from" ] || cp -R -L $from "$dst/" 2> /dev/null || partial=1
  [ "$partial" = 0 ] ||
    note "Not everything in .agents/skills could be copied: look for a broken link, a link loop or a file that cannot be read."
  made=
  halves=
  for n in ${1+"$@"}; do
    case " $from " in *" $src/$n "*) ;; *) continue ;; esac
    if [ ! -f "$dst/$n/SKILL.md" ]; then
      note "Could not copy .agents/skills/$n."
      halves="$halves $n"
    elif ! ignore_copy "$n"; then
      # No copy without the bridge's .gitignore: git would list it, and the next sync would take it
      # for a skill of someone's own.
      note "Could not write .claude/skills/$n/.gitignore, so .agents/skills/$n is not copied."
      halves="$halves $n"
    else
      # A copy that lacks a file which is there to copy is not whole: the next sync tries again.
      [ "$partial" = 0 ] || copy_whole "$src/$n" "$dst/$n" || broken=1
      made="$made $dst/$n"
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
  # With the lock goes what a killed sync of the PowerShell twin left in the records: its waiting
  # stamp, and the manifest that was on its way. While this run holds the lock they are nobody's,
  # so the lock goes last.
  trap 'rm -rf "$stamp.tmp" "$manifest.tmp" "$lock"' EXIT
  trap 'exit 130' HUP INT TERM
  return 0
}

# Writes the stamp of a sync that has begun into the records. Unlike the stamp of a sync that has
# ended, it holds text and is newer than the manifest: a sync that is killed midway counts as
# unfinished, and the next one makes every copy again. The text names every copy that is the
# bridge's, the ones this sync is about to make among them. So a copy is on record before it exists:
# a sync that is killed after a new copy and before its manifest leaves nothing that the next plan
# would take for someone's own skill.
# The first line names the copies that this sync is about to delete or to make. Should it be killed,
# their folders may be half-done, without the .gitignore by which the bridge knows its copies: the
# next sync does not ask them for it (see own). It asks every other folder, so what own found to be
# someone's own stays theirs after a kill too. The line comes first: a stamp that is cut short
# still has it, or names nothing at all.
begin_sync() {
  new=
  for n in $stale; do has "$managed" "$n" || new="$new $n"; done
  without "$managed" "$taken"
  # shellcheck disable=SC2086 # validated names
  {
    printf '%s\n' "$unfinished_line$gone$stale" \
      '# A sync began here and has not ended. Above: the copies that it was about to delete or to make. Below: every copy of the bridge.' \
      $others $new > "$stamp"
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
    [ "$skipped" = 0 ] ||
      note "Skipped a folder in .agents/skills: skill folder names may only use letters, digits, '.', '_' and '-'."
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
  # No folder is deleted or replaced that is not the bridge's own copy any more.
  own
  if [ "$busy" = 1 ]; then
    # Nothing is written yet, so the next hook finds everything as this one did.
    note "git is at work in this checkout, so this sync waits for the next hook."
    return 0
  fi
  for n in $taken; do
    reason "$n"
    if has "$src_names" "$n"; then
      note ".claude/skills/$n is no longer the copy that the bridge made ($why). The bridge leaves it alone, so .agents/skills/$n is not copied. Rename or delete one of them.$hint"
    else
      note ".claude/skills/$n is no longer the copy that the bridge made ($why). The bridge leaves it alone.$hint"
    fi
  done
  # No copy is made that is not on record.
  begin_sync || {
    note "Could not write $stamp, so nothing was copied."
    return 0
  }
  [ -z "$stale$gone" ] || changed=1
  broken=0
  # Only what was a copy or a leftover when the sync looked is deleted. A folder that turns up under
  # the name of a new copy meanwhile is someone's own: copy_skills finds it there and leaves it.
  redo=
  for n in $stale; do
    if has "$managed" "$n" || has "$adopted" "$n"; then redo="$redo $n"; fi
  done
  # shellcheck disable=SC2086 # validated names
  remove_copies $gone $redo
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
  # What this sync could not delete or make stays on record, and its folder may have lost the
  # bridge's .gitignore on the way. The manifest says which folders: the next sync does not ask
  # them for that file, and asks every other one.
  left=
  if [ "$broken" = 1 ]; then
    for n in $gone $stale; do
      if has "$kept" "$n" && ! marked "$n"; then left="$left $n"; fi
    done
  fi
  {
    echo '# Copies made by .claude/hooks/agent-skills-bridge.sh from .agents/skills. Do not edit.'
    [ "$broken" = 0 ] || echo "$unfinished_line$left"
    for n in $kept; do echo "$n"; done
  } > "$lock/manifest" || return 0 # nothing arrives, and the stamp of the sync that has begun stays
  if [ "$broken" = 0 ]; then
    # The manifest and the stamp from before the plan go into the records with one mv, the manifest
    # first. Until the manifest is there, the stamp of the sync that has begun stays, and with it the
    # names of the new copies. Should mv stop between the two, that stamp still marks the sync as
    # unfinished. Should mv fail, it may have moved the empty stamp all the same, so the stamp of a
    # sync that has begun is written once more.
    mv -f "$lock/manifest" "$lock/stamp" "$state/" || begin_sync
  elif mv -f "$lock/manifest" "$state/"; then
    # What could not be deleted or made whole must not pass for current. So the empty stamp stays
    # out of the records, and the stamp of the sync that has begun still marks this sync as
    # unfinished. The scripts of before cannot read that: they go by the times of the two files.
    # For them the stamp is deleted, now that the manifest is in place: without a stamp a sync
    # counts as unfinished, and the next one makes every copy again.
    rm -f "$stamp"
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
      # The rest in the event's own spelling, for the message: the path without as many characters
      # as the repository's folder for copies has.
      q=$base/
      rest=$fp
      while [ -n "$q" ]; do
        q=${q#?}
        rest=${rest#?}
      done
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
  own # as the next sync will: it may ask git or svn
  without "$managed" "$taken"
  managed=$others
  echo "agent-skills bridge: $PWD"
  # shellcheck disable=SC2086 # names are validated words
  set -- $src_names
  echo "  .agents/skills  $# skill(s):$src_names"
  # shellcheck disable=SC2086
  set -- $managed
  echo "  .claude/skills  $# copy(ies):$managed"
  [ -z "$conflicts" ] || echo "  conflicts      $conflicts (in .claude/skills, not made by the bridge)"
  for n in $taken; do
    reason "$n"
    echo "  left alone      $n: no longer the copy that the bridge made ($why). The next sync takes it off the records"
  done
  [ "$busy" = 0 ] || echo "  git             at work in this checkout: a sync waits until it is done"
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
    # No copies, but perhaps records: a sync that deleted the last copy leaves its folder behind.
    [ ! -d "$state" ] || [ -e "$lock" ] || rm -rf "$state"
    echo "agent-skills bridge: no copies to delete."
    return 0
  }
  acquire_lock || {
    echo "agent-skills bridge: another sync is running; try again." >&2
    exit 1
  }
  plan
  # Every copy on record goes, current or not, but no folder that is not the bridge's copy any more.
  gone=
  stale=
  for n in $managed; do
    if has "$src_names" "$n"; then stale="$stale $n"; else gone="$gone $n"; fi
  done
  own
  if [ "$busy" = 1 ]; then
    echo "agent-skills bridge: git is at work in this checkout; try again when it is done." >&2
    exit 1
  fi
  # As a sync does, clean first puts on record which folders it is about to delete. Should it be
  # killed, or should a folder stay, the next sync knows that these may be half-deleted.
  begin_sync
  # shellcheck disable=SC2086 # validated names
  remove_copies $gone $stale
  mine=
  stuck=
  for n in $managed; do
    has "$taken" "$n" && continue
    mine="$mine $n"
    if [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then stuck="$stuck $n"; fi
  done
  if [ -n "$stuck" ]; then
    # The records stay: without them the bridge would take what is left for someone else's skills.
    echo "agent-skills bridge: could not delete:$stuck. Is a file in there open? Close it and run clean again." >&2
    exit 1
  fi
  rm -rf "$state" # the records, the lock included
  if [ -n "$mine" ]; then
    echo "agent-skills bridge: deleted the copies:$mine."
  else
    echo "agent-skills bridge: no copies to delete."
  fi
  for n in $taken; do
    reason "$n"
    echo "agent-skills bridge: left .claude/skills/$n alone: it is no longer the copy that the bridge made ($why).$hint"
  done
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
