#!/bin/sh
# agent-skills-bridge.test.sh - scenario tests for the agent-skills bridge.
#
# Usage: sh .claude/hooks/agent-skills-bridge.test.sh [sh|ps1]
#   sh   test agent-skills-bridge.sh (default; any POSIX sh, Git Bash included)
#   ps1  test agent-skills-bridge.ps1 through Windows PowerShell (run from Git Bash on Windows)
# ASB_TEST_SHELL names the shell that runs the hook commands of the sh bridge (default: sh), for
# example ASB_TEST_SHELL=zsh. ASB_TEST_POWERSHELL names the PowerShell for ps1 (default:
# powershell.exe), for example ASB_TEST_POWERSHELL=pwsh.exe.
# Builds throwaway repositories under $TMPDIR and checks what the bridge leaves on disk. The git
# cases run where git is installed, the svn cases where svn and svnadmin are.

set -u
impl=${1:-sh}
hook_shell=${ASB_TEST_SHELL:-sh}
powershell=${ASB_TEST_POWERSHELL:-powershell.exe}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/agent-skills-bridge-test.XXXXXX")
blocker=
# After a signal too: dash and BusyBox ash run an EXIT trap only when the shell exits by itself.
cleanup() {
  rm -f "$base/blocking" # lets a file holder go; see block
  [ -z "$blocker" ] || wait "$blocker" 2> /dev/null
  chmod -R u+w "$base" 2> /dev/null
  rm -rf "$base"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
bad() {
  fail=$((fail + 1))
  echo "  FAIL $1"
}
check() { # check <description> <command...>
  d=$1
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
contains() { case $1 in *"$2"*) return 0 ;; esac; return 1; }
lacks() { ! contains "$1" "$2"; }
# True when the owner may write the file $1. The mode says so, and for Git Bash the Windows
# read-only attribute; [ -w ] would call everything writable for root.
writable() {
  case $(ls -ld "$1") in ??w*) return 0 ;; esac
  return 1
}
crs() { tr -cd '\r' < "$1" | wc -c | tr -d ' '; }

# The hook command from .claude/settings.json, for one bridge command. The same string runs in
# POSIX sh and in PowerShell; see agent-skills-bridge.md.
hook_command() {
  printf '%s' "set \\' ; test -r \"\$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh\" || exit 0 ; ASB_CMD=$1 . \"\$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh\" ; exit ; #' ; & \"\$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1\" $1 ; exit \$LASTEXITCODE"
}

# bridge <repo> <command> [stdin]: run the implementation under test the way Claude Code does:
# hook commands through sh -c or powershell -Command with CLAUDE_PROJECT_DIR set, others by hand.
bridge() {
  case $2 in
    sync | session | guard)
      if [ "$impl" = ps1 ]; then
        printf '%s' "${3:-}" | CLAUDE_PROJECT_DIR=$(cygpath -w "$1") "$powershell" -NoProfile -NonInteractive \
          -ExecutionPolicy Bypass -Command "$(hook_command "$2")"
      else
        dir=$1
        command -v cygpath > /dev/null 2>&1 && dir=$(cygpath -w "$1")
        printf '%s' "${3:-}" | CLAUDE_PROJECT_DIR=$dir "$hook_shell" -c "$(hook_command "$2")"
      fi
      ;;
    *)
      if [ "$impl" = ps1 ]; then
        "$powershell" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
          -File "$(cygpath -w "$1/.claude/hooks/agent-skills-bridge.ps1")" "$2" < /dev/null
      else
        sh "$1/.claude/hooks/agent-skills-bridge.sh" "$2" < /dev/null
      fi
      ;;
  esac
}

skill() { # skill <repo> <name> [body]
  mkdir -p "$1/.agents/skills/$2"
  printf -- '---\nname: %s\ndescription: Test skill %s.\n---\n\n%s\n' "$2" "$2" "${3:-Body of $2.}" > "$1/.agents/skills/$2/SKILL.md"
}

new_repo() {
  r=$base/$1
  mkdir -p "$r/.claude/hooks"
  cp "$here/agent-skills-bridge.sh" "$here/agent-skills-bridge.ps1" "$r/.claude/hooks/" 2> /dev/null
  printf '%s' "$r"
}

# Path of a file as the Claude Code tools send it in hook JSON (Windows paths escaped).
tool_path() {
  if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1" | sed 's/\\/\\\\/g'; else printf '%s' "$1"; fi
}

# guarded <description> <event> [expected exit code]: run the guard for the repository $R.
# $js is a path separator the way JSON escapes it.
if command -v cygpath > /dev/null 2>&1; then js='\\'; else js=/; fi
guarded() {
  bridge "$R" guard "$2" > /dev/null 2>&1
  check "$1" test $? = "${3:-2}"
}

# block <file> keeps a file open the way an editor or a virus scanner does on Windows, so that
# nobody else can read, replace or delete it; unblock lets it go. The holder gets its paths through
# the environment, so that no letter in them can end a quoted string, and gives up by itself after
# five minutes, should nobody ever let it go.
block() {
  : > "$base/blocking"
  # shellcheck disable=SC2016 # PowerShell expands these
  ASB_HELD=$(cygpath -w "$1") ASB_BLOCKED=$(cygpath -w "$base/blocked") ASB_BLOCKING=$(cygpath -w "$base/blocking") \
    powershell.exe -NoProfile -NonInteractive -Command '$f = [IO.File]::Open($env:ASB_HELD, "Open", "Read", "None"); [IO.File]::WriteAllText($env:ASB_BLOCKED, ""); for ($i = 0; $i -lt 3000 -and (Test-Path -LiteralPath $env:ASB_BLOCKING); $i++) { Start-Sleep -Milliseconds 100 }; $f.Close()' &
  blocker=$!
  tries=0
  while [ ! -e "$base/blocked" ] && [ "$tries" -lt 60 ]; do
    sleep 1
    tries=$((tries + 1))
  done
}
unblock() {
  rm -f "$base/blocking"
  wait "$blocker" 2> /dev/null
  blocker=
  rm -f "$base/blocked"
}

# meanwhile <repo> <text> <sh code> <ps1 code>: makes the bridge in <repo> run the code right after
# its line that holds <text>. That stands for what another program does at that moment of a sync:
# an edit, or a kill. No file time set by hand can stand for it, because the moment lies inside one
# run. It changes the repository's own copy of the script; pristine <repo> puts the kit's scripts
# back. The code must hold no backslash: awk would read it as an escape.
meanwhile() {
  f=$1/.claude/hooks/agent-skills-bridge.$impl
  if [ "$impl" = ps1 ]; then code=$4; else code=$3; fi
  awk -v text="$2" -v code="$code" '{ print } index($0, text) { print code }' "$f" > "$f.new" &&
    mv -f "$f.new" "$f"
}
pristine() { cp "$here/agent-skills-bridge.sh" "$here/agent-skills-bridge.ps1" "$1/.claude/hooks/"; }

# settled <description> <repo>: after a hook has dealt with something once, the next hook must find
# nothing left to do. It must give the answer of a hook that has every program at hand, and start
# none: see 2. Where that cannot be seen (see 2 for why), the two answers of the plain hook must match.
quiet_ok=0
settled() {
  first=$(bridge "$2" session 2>&1)
  if [ "$quiet_ok" = 1 ]; then
    dir=$2
    command -v cygpath > /dev/null 2>&1 && dir=$(cygpath -w "$2")
    second=$(quiet session)
  else
    second=$(bridge "$2" session 2>&1)
  fi
  check "$1" sh -c 'case $1 in *reloadSkills* | *"not found"* | *"no longer the copy"*) exit 1 ;; esac; test "$1" = "$2"' x "$second" "$first"
}

if [ "$impl" = ps1 ]; then echo "agent-skills bridge tests (ps1 in $powershell)"; else echo "agent-skills bridge tests (sh, hooks in $hook_shell)"; fi

settings=$here/../settings.json
if [ -f "$settings" ]; then
  echo "0. the kit's own files"
  for c in session sync guard; do
    esc=$(hook_command "$c" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    check "settings.json: hook command for $c" grep -qF -- "\"command\": \"$esc\"" "$settings"
  done
  if command -v node > /dev/null 2>&1; then
    f=$settings
    command -v cygpath > /dev/null 2>&1 && f=$(cygpath -w "$settings")
    check "settings.json is valid JSON" node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" "$f"
  else
    echo "  skip the JSON syntax check (no node here)"
  fi
  # A hook's "if" holds one rule, and an Edit rule filters only the Edit tool: the guard of every
  # other editing tool has to run unfiltered. Each entry is read as a pair: its matcher names the
  # tools, and its own command must be the guard.
  check "settings.json: each editing tool runs the guard, and only Edit through its filter" awk '
    /"matcher"[ \t]*:/ { m = $0; sub(/.*"matcher"[ \t]*:[ \t]*"/, "", m); sub(/".*/, "", m) }
    /"if"[ \t]*:/ { if (m != "Edit" || !index($0, "\"if\": \"Edit(**/.claude/skills/**)\"")) bad = 1 }
    /"command"[ \t]*:/ && m != "" {
      if (index($0, "ASB_CMD=guard . ") && index($0, ".ps1\\\" guard ;")) {
        n = split(m, tool, "|")
        for (i = 1; i <= n; i++) guarded[tool[i]] = 1
      }
    }
    END {
      if (!guarded["Edit"] || !guarded["MultiEdit"] || !guarded["Write"] || !guarded["NotebookEdit"]) bad = 1
      exit bad
    }' "$settings"
  check ".gitattributes keeps the shell scripts LF" grep -qx '\*\.sh text eol=lf' "$here/.gitattributes"
  check "the anchor ignores nothing" sh -c "! grep -v '^#' '$here/../skills/.gitignore' | grep -q ."
fi

echo "1. first sync"
R=$(new_repo one)
S=$R/.claude/skills/.agent-skills-bridge
skill "$R" alpha
skill "$R" beta
mkdir -p "$R/.agents/skills/alpha/scripts"
echo 'echo hi' > "$R/.agents/skills/alpha/scripts/run.sh"
mkdir -p "$R/.agents/skills/not-a-skill"
sleep 1 # BusyBox and bash before 5.1 compare whole seconds: an edit in the second of a sync counts as new
out=$(bridge "$R" session)
check "alpha copied with its scripts" test -f "$R/.claude/skills/alpha/scripts/run.sh"
check "beta copied" test -f "$R/.claude/skills/beta/SKILL.md"
check "folder without SKILL.md ignored" test ! -e "$R/.claude/skills/not-a-skill"
check "manifest lists both" sh -c "grep -qx alpha '$S/manifest' && grep -qx beta '$S/manifest'"
check "each copy has a .gitignore that ignores all of it" sh -c "grep -qx '\\*' '$R/.claude/skills/alpha/.gitignore' && grep -qx '\\*' '$R/.claude/skills/beta/.gitignore'"
check "the records folder ignores itself" grep -qx '\*' "$S/.gitignore"
check "a new .claude/skills gets an anchor that ignores nothing" sh -c "test -f '$R/.claude/skills/.gitignore' && ! grep -v '^#' '$R/.claude/skills/.gitignore' | grep -q ."
if writable "$R/.claude/skills/alpha/SKILL.md"; then bad "copy SKILL.md is read-only"; else ok "copy SKILL.md is read-only"; fi
check "session JSON asks to reload skills" contains "$out" '"reloadSkills":true'
check "session JSON watches .agents/skills" contains "$out" '"watchPaths":["'
check "session JSON names SessionStart" contains "$out" '"hookEventName":"SessionStart"'
check "lock released" test ! -e "$S/lock"

echo "2. nothing changed"
out=$(bridge "$R" session)
check "no reload when copies are current" lacks "$out" 'reloadSkills'
check "still watches .agents/skills" contains "$out" 'watchPaths'
out=$(bridge "$R" sync)
check "sync prints nothing when current" test -z "$out"

err=$(bridge "$R" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$R/.claude/skills/beta/SKILL.md")"'"}}' 2>&1)
check "with two copies, a refusal names the one that was meant" sh -c 'case $1 in *alpha*) exit 1 ;; *".agents/skills/beta/SKILL.md instead"*) exit 0 ;; esac; exit 1' x "$err"
guarded "a folder named like two copies is no copy" '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$R")$js.claude${js}skills${js}alpha beta${js}SKILL.md"'"}}' 0
hs=$(command -v "$hook_shell")
if [ "$impl" != sh ]; then
  echo "  skip the no-program checks (PowerShell is a program to start anyway)"
elif command -v cygpath > /dev/null 2>&1 && [ -z "$("$hs" -c 'echo "${BASH_VERSION:-}"')" ]; then
  echo "  skip the no-program checks (on Windows only bash turns backslashes into slashes by itself)"
else
  # With nothing to do a hook must start no program: on Windows each one can cost a second. A PATH
  # that leads nowhere shows it: the answer is the same, with no "not found" in it.
  dir=$R
  command -v cygpath > /dev/null 2>&1 && dir=$(cygpath -w "$R")
  mkdir -p "$base/zempty" # as ZDOTDIR: zsh then reads no startup file of whoever runs the tests
  quiet() { printf '%s' "${2:-}" | CLAUDE_PROJECT_DIR=$dir PATH=/nonexistent ZDOTDIR=$base/zempty "$hs" -c "$(hook_command "$1")" 2>&1; }
  quiet_ok=1 # later sections ask the same of other states: see settled
  normal=$(bridge "$R" session)
  check "a session with nothing to do starts no program" test "$(quiet session)" = "$normal"
  check "nor does a sync" test -z "$(quiet sync '{"hook_event_name":"FileChanged","file_path":"x/.agents/skills/alpha/SKILL.md"}')"
  out=$(quiet guard '{"cwd":"'"$(tool_path "$R")"'","tool_name":"Write","tool_input":{"file_path":"'"$(tool_path "$R/README.md")"'","content":"about skills"}}')
  check "nor the guard for a file outside .claude/skills" test -z "$out"
  out=$(quiet guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$R/.claude/skills/alpha/SKILL.md")"'"}}')
  check "nor the guard that refuses" sh -c 'case $1 in *"not found"*) exit 1 ;; "Blocked by the agent-skills bridge"*) exit 0 ;; esac; exit 1' x "$out"
fi

echo "3. source edits"
before=$(cksum < "$R/.claude/skills/beta/SKILL.md")
skill "$R" alpha "Changed body."
rm "$R/.agents/skills/alpha/scripts/run.sh"
echo 'new' > "$R/.agents/skills/alpha/notes.md"
bridge "$R" sync > /dev/null
check "changed SKILL.md copied" grep -q 'Changed body.' "$R/.claude/skills/alpha/SKILL.md"
check "deleted file deleted from copy" test ! -e "$R/.claude/skills/alpha/scripts/run.sh"
check "new file copied" test -f "$R/.claude/skills/alpha/notes.md"
check "untouched skill kept as is" test "$before" = "$(cksum < "$R/.claude/skills/beta/SKILL.md")"

echo "4. removed skill"
rm -rf "$R/.agents/skills/beta"
bridge "$R" sync > /dev/null
code=$?
check "a sync that only deletes succeeds (bash 3.2 trips over an empty \"\$@\")" test "$code" = 0
check "copy of removed skill deleted" test ! -e "$R/.claude/skills/beta"
check "manifest forgets it" sh -c "! grep -qx beta '$S/manifest'"

echo "5. conflict with a skill the bridge did not make"
mkdir -p "$R/.claude/skills/gamma"
echo 'mine' > "$R/.claude/skills/gamma/SKILL.md"
skill "$R" gamma
out=$(bridge "$R" session)
check "own skill left alone" grep -qx mine "$R/.claude/skills/gamma/SKILL.md"
check "conflict reported to the user" contains "$out" '"systemMessage":"agent-skills bridge: .claude/skills/gamma exists'
check "conflict not managed" sh -c "! grep -qx gamma '$S/manifest'"

echo "6. repair"
sleep 1 # whole-second clocks again: a real edit never lands in the second of the sync
chmod u+w "$R/.claude/skills/alpha/SKILL.md" 2> /dev/null
echo 'tampered' > "$R/.claude/skills/alpha/SKILL.md"
bridge "$R" sync > /dev/null
check "edited copy restored" grep -q 'Changed body.' "$R/.claude/skills/alpha/SKILL.md"
chmod -R u+w "$R/.claude/skills/alpha"
rm -rf "$R/.claude/skills/alpha"
bridge "$R" sync > /dev/null
check "deleted copy restored" test -f "$R/.claude/skills/alpha/SKILL.md"

echo "7. guard"
copy_md=$(tool_path "$R/.claude/skills/alpha/SKILL.md")
src_md=$(tool_path "$R/.agents/skills/alpha/SKILL.md")
own_md=$(tool_path "$R/.claude/skills/gamma/SKILL.md")
err=$(bridge "$R" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$copy_md"'","old_string":"a","new_string":"b"}}' 2>&1)
code=$?
check "edit inside a copy refused (exit 2)" test "$code" = 2
check "refusal names the source file" contains "$err" '.agents/skills/alpha/SKILL.md instead'
bridge "$R" guard '{"tool_name":"Write","tool_input":{"file_path":"'"$src_md"'","content":"x"}}' > /dev/null 2>&1
check "edit of the source allowed" test $? = 0
bridge "$R" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$own_md"'","old_string":"a","new_string":"b"}}' > /dev/null 2>&1
check "edit of a skill the bridge did not make allowed" test $? = 0
bridge "$R" guard '{"tool_name":"Write","tool_input":{"file_path":"'"$src_md"'","content":"see \"file_path\":\"'"$copy_md"'\""}}' > /dev/null 2>&1
check "path quoted inside content does not trigger" test $? = 0
up=$(printf '%s' "$copy_md" | tr '[:lower:]' '[:upper:]')
guarded "other letter case refused, on every system" '{"tool_name":"Edit","tool_input":{"file_path":"'"$up"'"}}'
upr=$(printf '%s' "$(tool_path "$R")" | tr '[:lower:]' '[:upper:]')
err=$(bridge "$R" guard '{"tool_name":"Write","tool_input":{"file_path":"'"$upr$js.claude${js}skills${js}alpha${js}Refs${js}Deep.MD"'","content":"x"}}' 2>&1)
check "a refusal in another letter case keeps the event's spelling of the file" contains "$err" '.agents/skills/alpha/Refs/Deep.MD instead'
if command -v cygpath > /dev/null 2>&1; then
  lowdrive=$(printf '%s' "$copy_md" | sed 's/^\(.\)/\L\1/')
  err=$(bridge "$R" guard '{"tool_name":"Write","tool_input":{"file_path":"'"$lowdrive"'","content":"x"}}' 2>&1)
  code=$?
  check "lower-case drive letter refused" test "$code" = 2
  check "refusal keeps the file name's letter case" contains "$err" 'alpha/SKILL.md instead'
fi
bridge "$R" guard '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$(tool_path "$R/.claude/skills/alpha/x.ipynb")"'"}}' > /dev/null 2>&1
check "NotebookEdit inside a copy refused" test $? = 2

# The same, for paths and events in the other spellings a tool or a harness could send.
jr=$(tool_path "$R")
guarded "MultiEdit inside a copy refused" '{"tool_name":"MultiEdit","tool_input":{"file_path":"'"$copy_md"'","edits":[]}}'
guarded "path through .. into a copy refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$jr$js.agents$js..$js.claude${js}skills${js}alpha${js}SKILL.md"'"}}'
guarded "path through another skill, .. and . refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$jr$js.claude${js}skills${js}gamma$js..${js}alpha$js.${js}SKILL.md"'"}}'
guarded "path through a copy and .. into an own skill allowed" '{"tool_name":"Edit","tool_input":{"file_path":"'"$jr$js.claude${js}skills${js}alpha$js..${js}gamma${js}SKILL.md"'"}}' 0
err=$(bridge "$R" guard '{"cwd":"'"$jr"'","tool_name":"Edit","tool_input":{"file_path":".claude/skills/alpha/SKILL.md"}}' 2>&1)
code=$?
check "relative path refused, counted from the event's cwd" test "$code" = 2
check "refusal for a relative path names the source file" contains "$err" '.agents/skills/alpha/SKILL.md instead'
guarded "relative path without a cwd counts from the repository" '{"tool_name":"Edit","tool_input":{"file_path":".claude/skills/alpha/SKILL.md"}}'
guarded "relative path from another cwd allowed" '{"cwd":"'"$jr$js.agents"'","tool_name":"Edit","tool_input":{"file_path":".claude/skills/alpha/SKILL.md"}}' 0
guarded "relative path with .. from another cwd refused" '{"cwd":"'"$jr$js.agents"'","tool_name":"Edit","tool_input":{"file_path":"../.claude/skills/alpha/SKILL.md"}}'
guarded "event with blanks around the colons refused" '{ "tool_name" : "Edit", "tool_input" : { "file_path" : "'"$copy_md"'" } }'
guarded "event spread over lines refused" "$(printf '{\n\t"tool_name": "Edit",\n\t"tool_input": {\n\t\t"file_path":\t"%s"\n\t}\n}' "$copy_md")"
guarded "path quoted inside content, with blanks, does not trigger" '{"tool_name":"Write","tool_input":{"file_path":"'"$src_md"'","content":"\"file_path\" : \"'"$copy_md"'\""}}' 0
guarded "path quoted inside content before the real one does not trigger" '{"tool_name":"Write","tool_input":{"content":"\"file_path\": \"'"$copy_md"'\"","file_path":"'"$src_md"'"}}' 0
guarded "relative path with .. after a folder refused" '{"cwd":"'"$jr"'","tool_name":"Edit","tool_input":{"file_path":"sub/../.claude/skills/alpha/SKILL.md"}}'
guarded "relative path that climbs two folders refused" '{"cwd":"'"$jr$js.agents${js}skills"'","tool_name":"Edit","tool_input":{"file_path":"../../.claude/skills/alpha/SKILL.md"}}'
guarded "skill folder in another letter case refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$jr$js.claude${js}skills${js}ALPHA${js}SKILL.md"'"}}'
guarded "relative path that climbs out of the repository allowed" '{"cwd":"'"$jr"'","tool_name":"Edit","tool_input":{"file_path":"../.claude/skills/alpha/SKILL.md"}}' 0
guarded "a value that reads like the key is skipped" '{"tool_name":"Edit","tool_input":{"old_string":"file_path","file_path":"'"$copy_md"'"}}'
if command -v cygpath > /dev/null 2>&1; then
  guarded "path with forward slashes refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$(cygpath -m "$R")"'/.claude/skills/alpha/SKILL.md"}}'
  guarded "Git Bash path (/c/...) refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$(cygpath -m "$R" | sed 's|^\(.\):|/\L\1|')"'/.claude/skills/alpha/SKILL.md"}}'
else
  echo "  skip the Windows spellings of a path (no drive letters here)"
fi

echo "8. symlinks and links"
if [ "$impl" = sh ] && ln -s "$R/.agents/skills/alpha" "$base/linktest" 2> /dev/null && [ -L "$base/linktest" ]; then
  rm -f "$base/linktest"
  chmod -R u+w "$R/.claude/skills/alpha"
  rm -rf "$R/.claude/skills/alpha"
  ln -s "$R/.agents/skills/alpha" "$R/.claude/skills/alpha"
  bridge "$R" sync > /dev/null
  check "symlink in place of a copy replaced, target kept" sh -c "test -f '$R/.agents/skills/alpha/SKILL.md' && test ! -L '$R/.claude/skills/alpha' && test -f '$R/.claude/skills/alpha/SKILL.md'"
  L=$(new_repo linked)
  skill "$L" delta
  mkdir -p "$L/.claude"
  ln -s ../.agents/skills "$L/.claude/skills"
  out=$(bridge "$L" session)
  check "linked .claude/skills left alone" sh -c "test -f '$L/.agents/skills/delta/SKILL.md' && test ! -e '$L/.agents/skills/.agent-skills-bridge'"
  check "link reported" contains "$out" '.claude/skills is a link'
  mkdir -p "$R/shared"
  echo v1 > "$R/shared/ref.md"
  ln -s ../../../shared "$R/.agents/skills/alpha/refs"
  bridge "$R" sync > /dev/null
  check "symlinked folder in a skill copied as files" sh -c "grep -qx v1 '$R/.claude/skills/alpha/refs/ref.md' && test ! -L '$R/.claude/skills/alpha/refs'"
  sleep 1
  echo v2 > "$R/shared/ref.md"
  bridge "$R" sync > /dev/null
  check "edit inside a symlinked folder synced" grep -qx v2 "$R/.claude/skills/alpha/refs/ref.md"
  rm "$R/.agents/skills/alpha/refs"
  ln -s . "$R/.agents/skills/alpha/loop"
  started=$(date +%s)
  bridge "$R" sync > /dev/null 2>&1
  check "a link loop does not hang the sync" test $(($(date +%s) - started)) -lt 30
  check "a link loop leaves the skill itself copied" test -f "$R/.claude/skills/alpha/SKILL.md"
  if cp --help 2>&1 | grep -q BusyBox; then
    echo "  skip the runaway check (BusyBox cp follows a link loop as deep as the kernel lets it)"
  else
    check "a link loop leaves no runaway copy" test ! -e "$R/.claude/skills/alpha/loop/loop"
  fi
  rm "$R/.agents/skills/alpha/loop"
  bridge "$R" sync > /dev/null
  check "skill copied again once the loop is gone" test -f "$R/.claude/skills/alpha/SKILL.md"
  ln -s nowhere "$R/.agents/skills/alpha/broken"
  sleep 1
  out=$(bridge "$R" session)
  check "skill with a link to nowhere copied" test -f "$R/.claude/skills/alpha/SKILL.md"
  check "the link to nowhere is reported" contains "$out" 'could be copied'
  out=$(bridge "$R" session)
  check "a link to nowhere does not make every hook sync again" lacks "$out" 'reloadSkills'
  rm "$R/.agents/skills/alpha/broken"
  bridge "$R" sync > /dev/null
else
  echo "  skip symlink cases (no symlinks here)"
fi
if command -v cygpath > /dev/null 2>&1; then
  junction() { cmd //c mklink //J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null; }
  chmod -R u+w "$R/.claude/skills/alpha"
  rm -rf "$R/.claude/skills/alpha"
  junction "$R/.claude/skills/alpha" "$R/.agents/skills/alpha"
  bridge "$R" sync > /dev/null
  check "junction in place of a copy replaced, target kept" sh -c "test -f '$R/.agents/skills/alpha/SKILL.md' && test ! -L '$R/.claude/skills/alpha' && test -f '$R/.claude/skills/alpha/SKILL.md'"
  J=$(new_repo junctioned)
  skill "$J" delta
  mkdir -p "$J/.claude"
  junction "$J/.claude/skills" "$J/.agents/skills"
  out=$(bridge "$J" session)
  check "junctioned .claude/skills left alone" sh -c "test -f '$J/.agents/skills/delta/SKILL.md' && test ! -e '$J/.agents/skills/.agent-skills-bridge'"
  check "junction reported" contains "$out" '.claude/skills is a link'
  unjunction() { cmd //c rmdir "$(cygpath -w "$1")" > /dev/null; }
  mkdir -p "$R/shared-j"
  echo v1 > "$R/shared-j/ref.md"
  echo x > "$R/shared-j/extra.md"
  junction "$R/.agents/skills/alpha/jrefs" "$R/shared-j"
  bridge "$R" sync > /dev/null
  check "junctioned folder in a skill copied as files" sh -c "grep -qx v1 '$R/.claude/skills/alpha/jrefs/ref.md' && test ! -L '$R/.claude/skills/alpha/jrefs'"
  sleep 1
  echo v2 > "$R/shared-j/ref.md"
  bridge "$R" sync > /dev/null
  check "edit inside a junctioned folder synced" grep -qx v2 "$R/.claude/skills/alpha/jrefs/ref.md"
  sleep 1
  rm "$R/shared-j/extra.md"
  bridge "$R" sync > /dev/null
  check "file deleted inside a junctioned folder deleted from the copy" test ! -e "$R/.claude/skills/alpha/jrefs/extra.md"
  check "the junction's target keeps its file, writable" writable "$R/shared-j/ref.md"
  unjunction "$R/.agents/skills/alpha/jrefs"
  mkdir -p "$R/elsewhere/eta"
  printf -- '---\nname: eta\ndescription: Test skill eta.\n---\n\none\n' > "$R/elsewhere/eta/SKILL.md"
  junction "$R/.agents/skills/eta" "$R/elsewhere/eta"
  bridge "$R" sync > /dev/null
  check "junctioned skill folder copied as files" sh -c "grep -qx one '$R/.claude/skills/eta/SKILL.md' && test ! -L '$R/.claude/skills/eta'"
  sleep 1
  printf -- '---\nname: eta\ndescription: Test skill eta.\n---\n\ntwo\n' > "$R/elsewhere/eta/SKILL.md"
  bridge "$R" sync > /dev/null
  check "edit inside a junctioned skill folder synced" grep -qx two "$R/.claude/skills/eta/SKILL.md"
  unjunction "$R/.agents/skills/eta"
  bridge "$R" sync > /dev/null
  check "copy of a removed junctioned skill deleted, target kept" sh -c "test ! -e '$R/.claude/skills/eta' && test -f '$R/elsewhere/eta/SKILL.md'"
  junction "$R/.agents/skills/alpha/loop" "$R/.agents/skills/alpha"
  started=$(date +%s)
  bridge "$R" sync > /dev/null 2>&1
  check "a junction loop does not hang the sync" test $(($(date +%s) - started)) -lt 60
  check "a junction loop leaves the skill itself copied, and no runaway copy" sh -c "test -f '$R/.claude/skills/alpha/SKILL.md' && test ! -e '$R/.claude/skills/alpha/loop/loop'"
  started=$(date +%s)
  bridge "$R" sync > /dev/null 2>&1
  check "nor the sync after it" test $(($(date +%s) - started)) -lt 60
  unjunction "$R/.agents/skills/alpha/loop"
  bridge "$R" sync > /dev/null
  check "skill copied again once the junction loop is gone" sh -c "test -f '$R/.claude/skills/alpha/SKILL.md' && test ! -e '$R/.claude/skills/alpha/loop'"
  mkdir -p "$R/gone-soon"
  echo x > "$R/gone-soon/f.md"
  junction "$R/.agents/skills/alpha/jgone" "$R/gone-soon"
  bridge "$R" sync > /dev/null
  rm -rf "$R/gone-soon"
  sleep 1
  skill "$R" theta
  out=$(bridge "$R" session 2>&1)
  check "a junction to nowhere in one skill does not stop the sync of another" test -f "$R/.claude/skills/theta/SKILL.md"
  check "nor fail the hook" lacks "$out" 'failed'
  out=$(bridge "$R" session 2>&1)
  check "nor make every hook sync again" lacks "$out" 'reloadSkills'
  unjunction "$R/.agents/skills/alpha/jgone"
  rm -rf "$R/.agents/skills/theta"
  bridge "$R" sync > /dev/null
  mkdir -p "$R/precious"
  echo keep > "$R/precious/keep.txt"
  junction "$R/.claude/skills/alpha/j" "$R/precious"
  sleep 1
  skill "$R" alpha "With a junction in the copy."
  bridge "$R" sync > /dev/null 2>&1
  check "copy with a junction in it replaced" sh -c "grep -q 'With a junction in the copy.' '$R/.claude/skills/alpha/SKILL.md' && test ! -e '$R/.claude/skills/alpha/j'"
  check "what that junction pointed to is untouched" grep -qx keep "$R/precious/keep.txt"
  junction "$R/.agents/skills/alpha/project" "$R"
  started=$(date +%s)
  out=$(bridge "$R" session 2>&1)
  check "a junction up to the repository does not hang the sync" test $(($(date +%s) - started)) -lt 60
  check "nor does the bridge copy its own copy" test ! -e "$R/.claude/skills/alpha/project/.claude/skills/alpha/project"
  if [ "$impl" = ps1 ]; then
    check "the PowerShell twin keeps the skill's copy, without the bridge's own folder" sh -c 'test -f "$1/SKILL.md" && test ! -e "$1/project/.claude/skills"' x "$R/.claude/skills/alpha"
    out=$(bridge "$R" session 2>&1)
    check "nor does every hook copy the skill again" lacks "$out" 'reloadSkills'
  else
    # The shell script leaves such a link to cp, and GNU cp may refuse the whole skill.
    check "the shell script says what cp refused" sh -c 'case $1 in *"Could not copy"* | *"could be copied"*) exit 0 ;; esac; exit 1' x "$out"
  fi
  unjunction "$R/.agents/skills/alpha/project"
  bridge "$R" sync > /dev/null 2>&1
  check "the skill is copied again once that junction is gone" sh -c 'test -f "$1/SKILL.md" && test ! -e "$1/project"' x "$R/.claude/skills/alpha"
  mkdir -p "$R/chain-end" "$R/chain-mid"
  echo a > "$R/chain-end/a.md"
  echo b > "$R/chain-end/b.md"
  junction "$R/chain-mid/current" "$R/chain-end"
  junction "$R/.agents/skills/alpha/chain" "$R/chain-mid/current"
  bridge "$R" sync > /dev/null 2>&1
  check "a junction to a junction is followed to its end" test -f "$R/.claude/skills/alpha/chain/b.md"
  sleep 1
  rm "$R/chain-end/b.md"
  bridge "$R" sync > /dev/null 2>&1
  check "a file deleted at the end of that chain is deleted from the copy" sh -c 'test -f "$1/a.md" && test ! -e "$1/b.md"' x "$R/.claude/skills/alpha/chain"
  unjunction "$R/.agents/skills/alpha/chain"
  unjunction "$R/chain-mid/current"
  mkdir -p "$R/.agents/skills/alpha/attr"
  echo one > "$R/.agents/skills/alpha/attr/f.md"
  bridge "$R" sync > /dev/null 2>&1
  cmd //c attrib +r "$(cygpath -w "$R/.claude/skills/alpha/attr")" > /dev/null
  sleep 1
  echo two > "$R/.agents/skills/alpha/attr/f.md"
  out=$(bridge "$R" session 2>&1)
  check "a copy with a read-only folder in it replaced" grep -qx two "$R/.claude/skills/alpha/attr/f.md"
  check "without a complaint" lacks "$out" 'Could not replace'
  rm -rf "$R/.agents/skills/alpha/attr"
  bridge "$R" sync > /dev/null 2>&1
else
  echo "  skip junction cases (no junctions here)"
fi

echo "9. stale lock"
mkdir "$S/lock"
touch -t 202001010000 "$S/lock"
skill "$R" alpha "After stale lock."
bridge "$R" sync > /dev/null
check "stale lock broken and sync done" grep -q 'After stale lock.' "$R/.claude/skills/alpha/SKILL.md"

echo "10. switch off"
skill "$R" epsilon
# In a subshell: before a function call, POSIX lets the assignment outlive the call (zsh keeps it).
(AGENT_SKILLS_BRIDGE=off bridge "$R" sync > /dev/null)
check "AGENT_SKILLS_BRIDGE=off does nothing" test ! -e "$R/.claude/skills/epsilon"
(
  AGENT_SKILLS_BRIDGE=off
  export AGENT_SKILLS_BRIDGE
  bridge "$R" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$R/.claude/skills/alpha/SKILL.md")"'"}}' > /dev/null 2>&1
)
check "nor does the guard refuse then" test $? = 0

echo "11. status and clean"
st=$(bridge "$R" status 2>&1)
check "status lists the source skills" contains "$st" 'epsilon'
check "status reports out of date" contains "$st" 'out of date'
check "status reports the conflict" contains "$st" 'gamma'
check "status runs to the end without a failure" sh -c 'case $1 in *failed*) exit 1 ;; *"hooks "*) exit 0 ;; *) exit 1 ;; esac' x "$st"
bridge "$R" clean > /dev/null
check "clean deletes copies" test ! -e "$R/.claude/skills/alpha"
check "clean deletes the records" test ! -e "$S"
check "clean keeps skills it did not make" test -f "$R/.claude/skills/gamma/SKILL.md"
check "clean keeps the anchor" test -f "$R/.claude/skills/.gitignore"
K=$(new_repo lastcopy)
skill "$K" alpha
bridge "$K" session > /dev/null
rm -rf "$K/.agents/skills/alpha"
bridge "$K" sync > /dev/null
bridge "$K" clean > /dev/null
check "clean deletes the records that a sync left when it deleted the last copy" test ! -e "$K/.claude/skills/.agent-skills-bridge"

echo "12. no .agents/skills"
E=$(new_repo empty)
out=$(bridge "$E" session)
check "no output without skills" test -z "$out"
check "no .claude/skills created" test ! -e "$E/.claude/skills"

echo "13. path with spaces"
W=$(new_repo "with space")
skill "$W" zeta
out=$(bridge "$W" session)
check "copied under a path with a space" test -f "$W/.claude/skills/zeta/SKILL.md"
check "watch path keeps the space" contains "$out" 'with space'

echo "14. git: next to an existing .claude/skills with its own skill and .gitignore"
if command -v git > /dev/null 2>&1; then
  G=$(new_repo "git repo")
  gq() { git -C "$G" -c user.name=test -c user.email=test@example.invalid -c core.autocrlf=false "$@"; }
  gq init -q
  mkdir -p "$G/.claude/skills/native"
  echo 'mine' > "$G/.claude/skills/native/SKILL.md"
  printf '%s\n' '*.bak' > "$G/.claude/skills/.gitignore"
  gq add -A
  gq commit -qm 'an existing .claude folder'
  skill "$G" alpha
  bridge "$G" session > /dev/null
  check "copy made next to the native skill" test -f "$G/.claude/skills/alpha/SKILL.md"
  check "native skill untouched" grep -qx mine "$G/.claude/skills/native/SKILL.md"
  check "existing .gitignore kept as it was" test "$(cat "$G/.claude/skills/.gitignore")" = '*.bak'
  echo 'more' > "$G/.claude/skills/native/reference.md"
  mkdir -p "$G/.claude/skills/native2"
  echo 'two' > "$G/.claude/skills/native2/SKILL.md"
  st=$(gq status --porcelain --untracked-files=all)
  check "git lists no file of the copy" lacks "$st" 'claude/skills/alpha'
  check "git lists no record" lacks "$st" 'skills/.agent-skills-bridge'
  check "git lists a new file in a native skill" contains "$st" 'native/reference.md'
  check "git lists a new native skill" contains "$st" 'native2/SKILL.md'
  st=$(bridge "$G" status 2>&1)
  check "status: copies are ignored" contains "$st" 'copies are ignored'
  check "status: .claude/skills is in the repository" contains "$st" '.claude/skills is in the repository'
  # A copy that someone added to git by force. Its files are as the bridge made them, so it stays
  # the bridge's copy, and status says that git does not ignore it.
  gq add -f .claude/skills/alpha 2> /dev/null
  st=$(bridge "$G" status 2>&1)
  check "status names a copy that git tracks" contains "$st" 'not ignored: alpha'
  gq rm -r -q --cached .claude/skills/alpha
  st=$(bridge "$G" status 2>&1)
  check "and no longer once git has let go of it" contains "$st" 'copies are ignored'
  # A copy without the .gitignore that the bridge wrote is the bridge's no longer: see 36.
  sleep 1 # see 6
  chmod u+w "$G/.claude/skills/alpha/.gitignore" 2> /dev/null
  rm -f "$G/.claude/skills/alpha/.gitignore"
  st=$(bridge "$G" status 2>&1)
  check "status says that a copy without its .gitignore is left alone" contains "$st" 'left alone      alpha: no longer the copy that the bridge made (the .gitignore that the bridge wrote is not in it)'
  out=$(bridge "$G" session 2>&1)
  check "the hook leaves that folder as it is, and says so" sh -c 'test -f "$1/SKILL.md" && test ! -e "$1/.gitignore" && case $2 in *".claude/skills/alpha is no longer the copy that the bridge made"*) exit 0 ;; esac; exit 1' x "$G/.claude/skills/alpha" "$out"
  st=$(gq status --porcelain --untracked-files=all)
  check "git lists the folder now, so nobody overlooks it" contains "$st" 'claude/skills/alpha/SKILL.md'
  # The kit in a clone that turns LF into CRLF (core.autocrlf=true, the Git for Windows default).
  git -c core.autocrlf=true clone -q "$G" "$base/clone-crlf" 2> /dev/null
  check "control: without .gitattributes an autocrlf clone gets CRLF" test "$(crs "$base/clone-crlf/.claude/hooks/agent-skills-bridge.sh")" -gt 0
  cp "$here/.gitattributes" "$G/.claude/hooks/.gitattributes"
  gq add .claude/hooks/.gitattributes
  gq commit -qm 'keep the shell scripts LF'
  git -c core.autocrlf=true clone -q "$G" "$base/clone-lf" 2> /dev/null
  check "with .claude/hooks/.gitattributes the clone keeps the script LF" test "$(crs "$base/clone-lf/.claude/hooks/agent-skills-bridge.sh")" = 0
else
  echo "  skip git cases (no git here)"
fi

echo "15. svn: svn:ignore on .claude/skills"
if command -v svn > /dev/null 2>&1 && command -v svnadmin > /dev/null 2>&1; then
  V=$base/svn
  mkdir -p "$V"
  if command -v cygpath > /dev/null 2>&1; then
    svnadmin create "$(cygpath -w "$V/repo")"
    url="file:///$(cygpath -m "$V/repo")"
  else
    svnadmin create "$V/repo"
    url="file://$V/repo"
  fi
  svn checkout -q "$url" "$V/wc"
  C=$V/wc
  mkdir -p "$C/.claude/hooks"
  cp "$here/agent-skills-bridge.sh" "$here/agent-skills-bridge.ps1" "$C/.claude/hooks/"
  skill "$C" alpha
  svn add -q "$C/.claude" "$C/.agents"
  svn mkdir -q "$C/.claude/skills"
  svn commit -q -m 'the kit' "$C"
  bridge "$C" session > /dev/null
  st=$(bridge "$C" status 2>&1)
  check "svn: status names what svn would add" contains "$st" 'not ignored: alpha .agent-skills-bridge'
  printf '*\n' > "$V/ignore.txt"
  svn propset -q svn:ignore -F "$V/ignore.txt" "$C/.claude/skills"
  st=$(bridge "$C" status 2>&1)
  check "svn: copies are ignored once svn:ignore is set" contains "$st" 'copies are ignored'
  check "svn: svn status lists no copy" sh -c "! svn status '$C' | grep -q 'claude.skills.alpha'"
  mkdir -p "$C/.claude/skills/native"
  echo 'mine' > "$C/.claude/skills/native/SKILL.md"
  svn add -q "$C/.claude/skills/native"
  check "svn: a native skill is added when named" sh -c "svn status '$C/.claude/skills/native' | grep -q '^A'"
  echo 'more' > "$C/.claude/skills/native/reference.md"
  check "svn: svn:ignore does not reach into a native skill" sh -c "svn status '$C/.claude/skills/native' | grep -q '^?'"
  # A copy that someone added to svn and changed then: svn is asked as git is, see 35.
  svn add -q "$C/.claude/skills/alpha"
  sleep 1 # see 6
  chmod u+w "$C/.claude/skills/alpha/SKILL.md" 2> /dev/null
  echo 'Changed in the copy.' >> "$C/.claude/skills/alpha/SKILL.md"
  out=$(bridge "$C" session 2>&1)
  check "svn: a changed folder that svn tracks is left alone" grep -q 'Changed in the copy.' "$C/.claude/skills/alpha/SKILL.md"
  check "svn: and the hook says so" contains "$out" '.claude/skills/alpha is no longer the copy that the bridge made (svn tracks it)'
else
  echo "  skip svn cases (no svn here)"
fi

echo "16. files saved with CRLF"
C=$(new_repo crlf)
skill "$C" alpha
crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$1.crlf" && mv -f "$1.crlf" "$1"; }
bridge "$C" session > /dev/null
crlf "$C/.claude/skills/.agent-skills-bridge/manifest"
out=$(bridge "$C" session)
check "a CRLF manifest still names the bridge's copies" lacks "$out" 'was not made by the bridge'
st=$(bridge "$C" status 2>&1)
check "status counts the copy in a CRLF manifest" contains "$st" '1 copy(ies): alpha'
crlf "$C/.agents/skills/alpha/SKILL.md"
st=$(bridge "$C" status 2>&1)
check "a CRLF SKILL.md name still matches its folder" lacks "$st" 'SKILL.md says name'

echo "17. read-only folders in a skill"
if command -v cygpath > /dev/null 2>&1 || [ "$(id -u)" = 0 ]; then
  echo "  skip read-only folder cases (Windows folders and root ignore the mode)"
else
  skill "$C" ro
  mkdir "$C/.agents/skills/ro/sub"
  echo one > "$C/.agents/skills/ro/sub/f"
  chmod 555 "$C/.agents/skills/ro/sub" "$C/.agents/skills/ro"
  sleep 1
  out=$(bridge "$C" session)
  check "skill with read-only folders copied" grep -qx one "$C/.claude/skills/ro/sub/f"
  check "its copy gets a .gitignore" grep -qx '\*' "$C/.claude/skills/ro/.gitignore"
  check "nothing to report" lacks "$out" 'systemMessage'
  sleep 1
  chmod 755 "$C/.agents/skills/ro/sub"
  echo two > "$C/.agents/skills/ro/sub/f"
  chmod 555 "$C/.agents/skills/ro/sub"
  out=$(bridge "$C" session 2>&1)
  check "copy with read-only folders replaced" grep -qx two "$C/.claude/skills/ro/sub/f"
  check "replaced without a complaint" sh -c 'case $1 in *systemMessage* | *"rm:"*) exit 1 ;; esac' x "$out"
  chmod -R u+w "$C/.agents/skills/ro"
  rm -rf "$C/.agents/skills/ro"
  bridge "$C" sync > /dev/null
  check "copy with read-only folders deleted with its skill" test ! -e "$C/.claude/skills/ro"
fi

echo "18. CDPATH"
if [ "$impl" = sh ]; then
  mkdir -p "$base/cdtrap/.claude/hooks" "$base/cdtrap/crlf"
  st=$(cd "$C" && CDPATH=$base/cdtrap sh .claude/hooks/agent-skills-bridge.sh status < /dev/null 2>&1)
  check "status by a relative path ignores CDPATH" sh -c 'case $1 in *cdtrap*) exit 1 ;; *"1 skill(s): alpha"*) exit 0 ;; *) exit 1 ;; esac' x "$st"
  out=$(cd "$base" && printf '' | CDPATH=$base/cdtrap CLAUDE_PROJECT_DIR=crlf "$hook_shell" -c "$(hook_command session)" 2>&1)
  # The watch path must be absolute: drawn from where the shell is, not from the relative name.
  absolute_watch() {
    case $1 in
      *cdtrap*) return 1 ;;
      *'"watchPaths":["/'*crlf/.agents/skills* | *'"watchPaths":["'[A-Za-z]:/*crlf/.agents/skills*) return 0 ;;
    esac
    return 1
  }
  check "a hook with a relative CLAUDE_PROJECT_DIR ignores CDPATH and watches an absolute path" absolute_watch "$out"
else
  echo "  skip (PowerShell has no CDPATH)"
fi

echo "19. a copy that cannot be replaced or deleted"
F=$(new_repo stuck)
if command -v cygpath > /dev/null 2>&1; then
  hold() { block "$F/.claude/skills/alpha/SKILL.md"; }
  let_go() { unblock; }
elif [ "$(id -u)" != 0 ]; then
  hold() { chmod 555 "$F/.claude/skills"; } # nothing in a read-only folder can be deleted
  let_go() { chmod 755 "$F/.claude/skills"; }
else
  F=
  echo "  skip (root deletes anything)"
fi
if [ -n "$F" ]; then
  skill "$F" alpha
  skill "$F" beta
  bridge "$F" session > /dev/null
  sleep 1
  skill "$F" alpha "Second body."
  sleep 1 # see 1: an edit in the second of a sync counts as new where clocks tick in whole seconds
  hold
  out=$(bridge "$F" session 2>&1)
  check "a copy that cannot be replaced is reported" contains "$out" 'Could not replace .claude/skills/alpha'
  st=$(bridge "$F" status 2>&1)
  check "status does not call it current" lacks "$st" 'copies are current'
  bridge "$F" clean > /dev/null 2>&1
  check "clean fails while a copy cannot be deleted" test $? != 0
  check "and keeps its records" grep -qx alpha "$F/.claude/skills/.agent-skills-bridge/manifest"
  let_go
  bridge "$F" session > /dev/null 2>&1
  check "the next sync replaces the copy" grep -q 'Second body.' "$F/.claude/skills/alpha/SKILL.md"
  check "and restores what clean deleted" test -f "$F/.claude/skills/beta/SKILL.md"
  st=$(bridge "$F" status 2>&1)
  check "then the copies are current" contains "$st" 'copies are current'
  rm -rf "$F/.agents/skills/alpha"
  hold
  out=$(bridge "$F" session 2>&1)
  check "a copy that cannot be deleted is reported" contains "$out" 'Could not delete the old copy .claude/skills/alpha'
  check "and stays the bridge's" grep -qx alpha "$F/.claude/skills/.agent-skills-bridge/manifest"
  let_go
  bridge "$F" session > /dev/null 2>&1
  check "the next sync deletes it" test ! -e "$F/.claude/skills/alpha"
  # The same once more, but now the skill comes back while its old copy still cannot be deleted: the
  # leftover is the bridge's own, to replace, and no skill of someone else's.
  skill "$F" alpha "Third body."
  bridge "$F" session > /dev/null 2>&1
  rm -rf "$F/.agents/skills/alpha"
  hold
  bridge "$F" session > /dev/null 2>&1
  skill "$F" alpha "Back again."
  let_go
  out=$(bridge "$F" session 2>&1)
  check "a skill that comes back replaces the copy that could not be deleted" grep -q 'Back again.' "$F/.claude/skills/alpha/SKILL.md"
  check "without calling that copy someone else's" lacks "$out" 'was not made by the bridge'
fi

echo "20. files that cannot be copied"
X=$(new_repo partial)
if command -v cygpath > /dev/null 2>&1; then
  hold() { block "$1"; }
  let_go() { unblock; }
elif [ "$(id -u)" != 0 ]; then
  hold() { chmod 000 "$1"; }
  let_go() { chmod 644 "$1"; }
else
  X=
  echo "  skip (root reads anything)"
fi
if [ -n "$X" ]; then
  skill "$X" alpha
  echo secret > "$X/.agents/skills/alpha/secret.md"
  sleep 1
  hold "$X/.agents/skills/alpha/secret.md"
  out=$(bridge "$X" session 2>&1)
  let_go "$X/.agents/skills/alpha/secret.md"
  check "a skill is copied without the file that cannot be read" sh -c "test -f '$X/.claude/skills/alpha/SKILL.md' && test ! -e '$X/.claude/skills/alpha/secret.md'"
  check "and the gap is reported" contains "$out" 'could be copied'
  bridge "$X" session > /dev/null 2>&1
  check "the file arrives once it can be read" test -f "$X/.claude/skills/alpha/secret.md"
  skill "$X" beta
  echo ref > "$X/.agents/skills/beta/ref.md"
  sleep 1
  hold "$X/.agents/skills/beta/SKILL.md"
  out=$(bridge "$X" session 2>&1)
  let_go "$X/.agents/skills/beta/SKILL.md"
  check "a skill whose SKILL.md cannot be read is reported" contains "$out" 'Could not copy .agents/skills/beta'
  check "and leaves no half copy" test ! -e "$X/.claude/skills/beta"
  bridge "$X" session > /dev/null 2>&1
  check "the next sync copies it" test -f "$X/.claude/skills/beta/SKILL.md"
fi

echo "21. path with a letter outside ASCII"
e=$(printf '\303\251') # e with an acute accent, in UTF-8
N=$(new_repo "caf$e")
skill "$N" alpha
out=$(bridge "$N" session)
check "copied under such a path" test -f "$N/.claude/skills/alpha/SKILL.md"
check "the watch path spells the letter in UTF-8" contains "$out" "caf$e/.agents/skills"
bridge "$N" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$N/.claude/skills/alpha/SKILL.md")"'"}}' > /dev/null 2>&1
check "edit inside a copy refused under such a path" test $? = 2
st=$(bridge "$N" status 2>&1)
check "status spells the letter in UTF-8 through a pipe too" contains "$st" "caf$e"

echo "22. network path"
U=$(new_repo share)
UN=
command -v cygpath > /dev/null 2>&1 && UN=$(cygpath -m "$U" | sed 's|^\(.\):|//localhost/\1$|')
if [ -n "$UN" ] && [ -d "$UN/.claude/hooks" ]; then
  skill "$U" alpha
  out=$(bridge "$UN" session)
  check "copied through a network path" test -f "$U/.claude/skills/alpha/SKILL.md"
  check "the watch path keeps the two slashes of a network path" contains "$out" '"watchPaths":["//localhost/'
  bridge "$UN" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$UN/.claude/skills/alpha/SKILL.md")"'"}}' > /dev/null 2>&1
  check "edit inside a copy refused through a network path" test $? = 2
  bridge "$UN" guard '{"cwd":"'"$(tool_path "$UN")"'","tool_name":"Edit","tool_input":{"file_path":".claude/skills/alpha/SKILL.md"}}' > /dev/null 2>&1
  check "and for a relative path under a network cwd" test $? = 2
else
  echo "  skip (no //localhost/<drive>\$ share here)"
fi

echo "23. zsh with an alias and an option from .zshenv"
if [ "$impl" = sh ] && [ "${hook_shell##*/}" = zsh ]; then
  A=$(new_repo zshenv)
  skill "$A" alpha
  mkdir -p "$base/zdot"
  printf '%s\n' "alias has='echo ALIAS-RAN'" 'setopt markdirs' > "$base/zdot/.zshenv"
  out=$( (
    ZDOTDIR=$base/zdot
    export ZDOTDIR
    bridge "$A" session
  ) 2>&1)
  check "the hook still syncs" sh -c 'case $1 in *"parse error"* | *ALIAS-RAN*) exit 1 ;; *reloadSkills*) exit 0 ;; esac; exit 1' x "$out"
  check "and copies the skill, whatever options .zshenv sets" test -f "$A/.claude/skills/alpha/SKILL.md"
else
  echo "  skip (the hooks do not run in zsh)"
fi

echo "24. an edit that lands while a sync runs"
M=$(new_repo meanwhile)
MS=$M/.claude/skills/.agent-skills-bridge
skill "$M" alpha
skill "$M" beta
sleep 1 # see 1
bridge "$M" session > /dev/null
skill "$M" beta "Second body."
# The sync finds beta changed and alpha unchanged. Right after it has looked, alpha changes too. The
# sync goes on a second later, so the edit is older than everything the sync writes from then on.
meanwhile "$M" 'again: a sync that held the lock' \
  "echo 'Landed while a sync ran.' >> .agents/skills/alpha/SKILL.md; sleep 1" \
  "[IO.File]::AppendAllText((Join-Path \$src 'alpha/SKILL.md'), 'Landed while a sync ran.'); Start-Sleep -Seconds 1"
bridge "$M" sync > /dev/null
pristine "$M"
check "an edit landed after the sync had looked at the skill" grep -q 'Landed while a sync ran.' "$M/.agents/skills/alpha/SKILL.md"
check "that sync copied what it had found changed" grep -q 'Second body.' "$M/.claude/skills/beta/SKILL.md"
bridge "$M" sync > /dev/null
check "the next sync copies the skill that changed meanwhile" grep -q 'Landed while a sync ran.' "$M/.claude/skills/alpha/SKILL.md"

echo "25. a sync that is killed midway"
skill "$M" beta "Third body."
# The kill comes when every copy is made and the manifest is not yet written. In a subshell: the
# shell reports a killed command, and that report belongs nowhere.
# shellcheck disable=SC2016 # the bridge expands these, not the test
meanwhile "$M" 'Copies made by' 'kill -9 $$' 'Stop-Process -Id $PID -Force'
(bridge "$M" sync) > /dev/null 2>&1
pristine "$M"
check "the killed sync leaves its lock behind" test -e "$MS/lock"
st=$(bridge "$M" status 2>&1)
check "a sync that was killed does not pass for finished" contains "$st" 'out of date: alpha beta'
sleep 1 # see 1: or the edit of beta counts as new once more, where clocks tick in whole seconds
touch -t 202001010000 "$MS/lock" # see 9
bridge "$M" sync > /dev/null
st=$(bridge "$M" status 2>&1)
check "the next sync finishes the work" contains "$st" 'copies are current'
check "and leaves nothing half-made in the records" test "$(cd "$MS" && echo .[!.]* *)" = '.gitignore manifest stamp'

echo "26. a sync that is killed after it made a new copy"
K=$(new_repo killed)
KS=$K/.claude/skills/.agent-skills-bridge
skill "$K" alpha
# A skill of someone's own, with the name of a skill in .agents/skills: a conflict before the kill,
# and after it.
mkdir -p "$K/.claude/skills/own"
echo 'mine' > "$K/.claude/skills/own/SKILL.md"
skill "$K" own
sleep 1 # see 1
bridge "$K" session > /dev/null
skill "$K" gamma
# As in 25, the kill comes when every copy is made and the manifest is not yet written. This time one
# of the copies is new: the manifest of the sync before does not list it.
# shellcheck disable=SC2016 # the bridge expands these, not the test
meanwhile "$K" 'Copies made by' 'kill -9 $$' 'Stop-Process -Id $PID -Force'
(bridge "$K" sync) > /dev/null 2>&1
pristine "$K"
check "the killed sync made the new copy" test -f "$K/.claude/skills/gamma/SKILL.md"
check "and did not get to list it in the manifest" sh -c "! grep -qx gamma '$KS/manifest'"
st=$(bridge "$K" status 2>&1)
check "status counts the new copy as the bridge's" contains "$st" 'copy(ies): alpha gamma'
check "and names only the skill of someone's own as a conflict" contains "$st" 'conflicts       own (in'
err=$(bridge "$K" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$K/.claude/skills/gamma/SKILL.md")"'"}}' 2>&1)
code=$?
check "an edit inside the new copy is refused" test "$code" = 2
check "and the refusal names the source file, also while the records are those of a sync that has begun" contains "$err" '.agents/skills/gamma/SKILL.md instead'
sleep 1 # see 25
touch -t 202001010000 "$KS/lock" # see 9
out=$(bridge "$K" session 2>&1)
check "the next session does not take the new copy for a skill of someone's own" lacks "$out" '.claude/skills/gamma exists'
check "it still reports the skill that is someone's own" contains "$out" '.claude/skills/own exists and was not made by the bridge'
check "and leaves that skill alone" grep -qx mine "$K/.claude/skills/own/SKILL.md"
check "the new copy is in the manifest now" grep -qx gamma "$KS/manifest"
check "the skill of someone's own is not" sh -c "! grep -qx own '$KS/manifest'"
st=$(bridge "$K" status 2>&1)
check "the copies are current again" contains "$st" 'copies are current'
check "and the records hold nothing half-made" test "$(cd "$KS" && echo .[!.]* *)" = '.gitignore manifest stamp'
if [ "$(id -u)" = 0 ]; then
  echo "  skip the stamp that cannot be written (root writes anything)"
else
  # A copy is on record before it is made. So where the record cannot be written, nothing is copied.
  skill "$K" epsilon
  chmod a-w "$KS/stamp"
  out=$(bridge "$K" session 2>&1)
  chmod u+w "$KS/stamp"
  check "a sync that cannot write its stamp says so" contains "$out" 'Could not write .claude/skills/.agent-skills-bridge/stamp'
  check "and makes no copy" test ! -e "$K/.claude/skills/epsilon"
fi
# Once more, and then clean instead of a sync.
skill "$K" delta
# shellcheck disable=SC2016
meanwhile "$K" 'Copies made by' 'kill -9 $$' 'Stop-Process -Id $PID -Force'
(bridge "$K" sync) > /dev/null 2>&1
pristine "$K"
check "a second killed sync made a new copy too" test -f "$K/.claude/skills/delta/SKILL.md"
touch -t 202001010000 "$KS/lock"
bridge "$K" clean > /dev/null 2>&1
check "clean deletes the copy that a killed sync made new" test ! -e "$K/.claude/skills/delta"
check "and the copies in the manifest" sh -c "test ! -e '$K/.claude/skills/alpha' && test ! -e '$K/.claude/skills/gamma'"
check "and keeps the skill of someone's own" grep -qx mine "$K/.claude/skills/own/SKILL.md"

echo "27. a first sync that is killed before a copy has its .gitignore"
Q=$(new_repo killed-first)
QS=$Q/.claude/skills/.agent-skills-bridge
skill "$Q" alpha
skill "$Q" beta
sleep 1 # see 1
# The kill comes when the files of a skill are copied and the copy's .gitignore is not yet written:
# nothing in the copy says who made it, and there is no manifest at all. The two scripts copy in
# different ways, so each has its own line for the kill.
# shellcheck disable=SC2016
if [ "$impl" = ps1 ]; then at='Copy-Folder $from.FullName $to'; else at='could be copied: look for a broken link'; fi
# shellcheck disable=SC2016
meanwhile "$Q" "$at" 'kill -9 $$' 'Stop-Process -Id $PID -Force'
(bridge "$Q" session) > /dev/null 2>&1
pristine "$Q"
check "the killed sync left a copy without its .gitignore" sh -c "test -f '$Q/.claude/skills/alpha/SKILL.md' && test ! -e '$Q/.claude/skills/alpha/.gitignore'"
check "and no manifest" test ! -e "$QS/manifest"
rm -rf "$Q/.agents/skills/alpha" # this skill goes before the next sync comes
sleep 1 # see 25
touch -t 202001010000 "$QS/lock" # see 9
out=$(bridge "$Q" session 2>&1)
check "the next session takes no copy for a skill of someone's own" lacks "$out" 'was not made by the bridge'
check "it deletes the copy of the skill that is gone" test ! -e "$Q/.claude/skills/alpha"
check "and copies the other skill, with its .gitignore" grep -qx '\*' "$Q/.claude/skills/beta/.gitignore"
check "the manifest lists what is left" sh -c "grep -qx beta '$QS/manifest' && ! grep -qx alpha '$QS/manifest'"
st=$(bridge "$Q" status 2>&1)
check "then the copies are current" contains "$st" 'copies are current'
check "and the records hold nothing half-made" test "$(cd "$QS" && echo .[!.]* *)" = '.gitignore manifest stamp'

echo "28. a sync whose manifest does not arrive"
skill "$Q" gamma
# The copies are made, and then the manifest cannot be put in place, as when a program holds the old
# one open on Windows. Here its file is taken away (the shell script), or its name is made to lead
# nowhere (the PowerShell twin). Nobody is killed: the sync ends by itself.
# shellcheck disable=SC2016
meanwhile "$Q" 'Copies made by' 'rm -f "$lock/manifest" "$lock/stamp"' '$manifest = Join-Path $manifest nowhere'
bridge "$Q" sync > /dev/null 2>&1
pristine "$Q"
check "the sync made a new copy" test -f "$Q/.claude/skills/gamma/SKILL.md"
check "and its manifest did not arrive" sh -c "! grep -qx gamma '$QS/manifest'"
st=$(bridge "$Q" status 2>&1)
check "that sync does not pass for finished" contains "$st" 'out of date: beta gamma'
check "and its new copy is no conflict" lacks "$st" 'conflicts'
sleep 1 # see 25
out=$(bridge "$Q" session 2>&1)
check "the next session takes the new copy for the bridge's" lacks "$out" 'was not made by the bridge'
check "and lists it in the manifest" grep -qx gamma "$QS/manifest"
st=$(bridge "$Q" status 2>&1)
check "then the copies are current" contains "$st" 'copies are current'
check "and the records hold nothing half-made" test "$(cd "$QS" && echo .[!.]* *)" = '.gitignore manifest stamp'

echo "29. a session that starts while another sync makes a new copy"
H=$(new_repo two-hooks)
skill "$H" alpha
sleep 1 # see 1
# The first sync makes its copy and then waits, for a minute at most, before it writes the manifest.
# The session hook that comes in meanwhile finds a copy that no manifest lists, and waits for the
# lock. Nobody is killed.
# shellcheck disable=SC2016
meanwhile "$H" 'Copies made by' \
  'i=0; while [ ! -e go ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done' \
  'for ($i = 0; $i -lt 300 -and -not (Test-Path -LiteralPath (Join-Path $root go)); $i++) { Start-Sleep -Milliseconds 200 }'
(bridge "$H" sync > /dev/null 2>&1) &
first=$!
tries=0
while [ ! -f "$H/.claude/skills/alpha/SKILL.md" ] && [ "$tries" -lt 60 ]; do
  sleep 1
  tries=$((tries + 1))
done
(bridge "$H" session > "$base/second.out" 2>&1) &
second=$!
sleep 5 # the session hook has looked by now
: > "$H/go"
wait "$first" "$second"
pristine "$H"
check "the first sync had made its copy when the session hook came" test "$tries" -lt 60
check "the session hook does not call that copy a skill of someone's own" sh -c "! grep -q 'was not made by the bridge' '$base/second.out'"
check "and the copy is in the manifest when both are done" grep -qx alpha "$H/.claude/skills/.agent-skills-bridge/manifest"

echo "30. a sync that could not replace a copy, and is killed before it deletes its stamp"
B=$(new_repo left-behind)
if command -v cygpath > /dev/null 2>&1; then
  hold() { block "$B/.claude/skills/alpha/SKILL.md"; }
  let_go() { unblock; }
elif [ "$(id -u)" != 0 ]; then
  hold() { chmod 555 "$B/.claude/skills"; } # nothing in a read-only folder can be deleted
  let_go() { chmod 755 "$B/.claude/skills"; }
else
  B=
  echo "  skip (root deletes anything)"
fi
if [ -n "$B" ]; then
  BS=$B/.claude/skills/.agent-skills-bridge
  skill "$B" alpha
  sleep 1 # see 1
  bridge "$B" session > /dev/null
  skill "$B" alpha "Second body."
  : > "$base/mark"
  sleep 1 # see 19; and the manifest of the next sync is newer than the mark, also in whole seconds
  # The sync cannot replace the copy. It puts its manifest in place and is killed then, before it
  # deletes the stamp. Until that moment the manifest must not make the sync look finished.
  # shellcheck disable=SC2016
  meanwhile "$B" 'counts as unfinished, and the next one makes every copy again.' 'kill -9 $$' 'Stop-Process -Id $PID -Force'
  hold
  (bridge "$B" sync) > /dev/null 2>&1
  let_go
  pristine "$B"
  check "the killed sync leaves its lock behind" test -e "$BS/lock"
  check "and had put its manifest in place" test "$BS/manifest" -nt "$base/mark"
  st=$(bridge "$B" status 2>&1)
  check "a sync that left a copy behind and was killed then does not pass for finished" lacks "$st" 'copies are current'
  sleep 1 # see 25
  touch -t 202001010000 "$BS/lock" # see 9
  bridge "$B" sync > /dev/null 2>&1
  check "the next sync replaces the copy" grep -q 'Second body.' "$B/.claude/skills/alpha/SKILL.md"
  st=$(bridge "$B" status 2>&1)
  check "then the copies are current" contains "$st" 'copies are current'
fi

echo "31. what a killed sync of the PowerShell twin leaves in the records"
HS=$H/.claude/skills/.agent-skills-bridge
# Its waiting stamp, and perhaps the manifest that was on its way. The shell script keeps both in its
# lock folder. The twin's lock is a file, so it keeps them next to the records, and a kill leaves
# them there.
: > "$HS/stamp.tmp"
echo 'half' > "$HS/manifest.tmp"
skill "$H" alpha "Second body."
bridge "$H" sync > /dev/null
check "the next sync copies as ever" grep -q 'Second body.' "$H/.claude/skills/alpha/SKILL.md"
check "and leaves neither of them in the records" test "$(cd "$HS" && echo .[!.]* *)" = '.gitignore manifest stamp'

echo "32. hooks without the script"
# The hooks can outlive the script: a branch without the kit, or a kit removed by halves. dash and
# BusyBox ash end with status 2 when "." finds no file, and Claude Code reads 2 as the guard's no.
Q=$base/noscript
mkdir -p "$Q/.claude/hooks"
bridge "$Q" guard '{"tool_name":"Write","tool_input":{"file_path":"'"$(tool_path "$Q/README.md")"'","content":"x"}}' > /dev/null 2>&1
check "a guard without its script lets the edit pass" test $? = 0
bridge "$Q" session > /dev/null 2>&1
check "a session hook without its script does not fail" test $? = 0

echo "33. a skill folder with a name the bridge cannot use"
B=$(new_repo badname)
skill "$B" alpha
skill "$B" "bad name"
sleep 1 # see 1
out=$(bridge "$B" session)
check "the folder is skipped, the other skill copied" sh -c 'test -f "$1/alpha/SKILL.md" && test ! -e "$1/bad name"' x "$B/.claude/skills"
check "it is reported once" test "$(printf '%s\n' "$out" | awk '{ n += gsub(/Skipped a folder/, "") } END { print n + 0 }')" = 1
out=$(bridge "$B" sync '{"hook_event_name":"FileChanged","file_path":"x/.agents/skills/alpha/SKILL.md"}')
check "and not again at every file event" test -z "$out"

echo "34. clean after a first sync that left no manifest"
# unlisted <name>: a repository with two skills and no sync yet. A third skill has the name of a
# skill of someone's own in .claude/skills, as in 26: clean must keep that one. Sets Z and ZS.
unlisted() {
  Z=$(new_repo "$1")
  ZS=$Z/.claude/skills/.agent-skills-bridge
  skill "$Z" alpha
  skill "$Z" beta
  mkdir -p "$Z/.claude/skills/own"
  echo 'mine' > "$Z/.claude/skills/own/SKILL.md"
  skill "$Z" own
}
# As in 26, the kill comes when every copy is made and the manifest is not yet written. This time
# the sync is the first one. There is no manifest at all, and only the stamp says that the copies
# are the bridge's. Records without a manifest can also be a leftover, see 11. If clean took these
# for one, it would delete the records and leave the copies, and no sync would touch those again.
unlisted unlisted
# shellcheck disable=SC2016 # the bridge expands these, not the test
meanwhile "$Z" 'Copies made by' 'kill -9 $$' 'Stop-Process -Id $PID -Force'
(bridge "$Z" session) > /dev/null 2>&1
pristine "$Z"
check "a first sync that was killed made its copies" sh -c 'test -f "$1/alpha/SKILL.md" && test -f "$1/beta/SKILL.md"' x "$Z/.claude/skills"
check "and left no manifest" test ! -e "$ZS/manifest"
touch -t 202001010000 "$ZS/lock" # see 9
out=$(bridge "$Z" clean 2>&1)
check "clean deletes the copies that only the stamp names" sh -c 'test ! -e "$1/alpha" && test ! -e "$1/beta"' x "$Z/.claude/skills"
check "and says which" contains "$out" 'deleted the copies: alpha beta.'
check "and deletes the records" test ! -e "$ZS"
check "and keeps the skill of someone's own" grep -qx mine "$Z/.claude/skills/own/SKILL.md"
# The same without a kill, as in 28: a first sync ends by itself, and its manifest does not arrive.
# That sync takes its lock with it, so nothing but the names in the stamp keeps clean from deleting
# the records alone. In a repository of its own, so that it does not rest on what the kill left.
unlisted unlisted-too
# shellcheck disable=SC2016
meanwhile "$Z" 'Copies made by' 'rm -f "$lock/manifest" "$lock/stamp"' '$manifest = Join-Path $manifest nowhere'
bridge "$Z" sync > /dev/null 2>&1
pristine "$Z"
check "a first sync whose manifest does not arrive made its copies" sh -c 'test -f "$1/alpha/SKILL.md" && test -f "$1/beta/SKILL.md"' x "$Z/.claude/skills"
check "and left neither a manifest nor a lock" sh -c 'test ! -e "$1/manifest" && test ! -e "$1/lock"' x "$ZS"
out=$(bridge "$Z" clean 2>&1)
check "clean deletes these copies too" sh -c 'test ! -e "$1/alpha" && test ! -e "$1/beta"' x "$Z/.claude/skills"
check "and says which" contains "$out" 'deleted the copies: alpha beta.'
check "and deletes the records" test ! -e "$ZS"
check "and keeps the skill of someone's own" grep -qx mine "$Z/.claude/skills/own/SKILL.md"

echo "35. git: a skill that git keeps in .claude/skills takes the place of a copy"
if command -v git > /dev/null 2>&1; then
  O=$(new_repo own-git)
  OS=$O/.claude/skills/.agent-skills-bridge
  go() { git -C "$O" -c user.name=test -c user.email=test@example.invalid -c core.autocrlf=false "$@"; }
  go init -q
  # The branch of before: the skill lives in .claude/skills, and git tracks it.
  mkdir -p "$O/.claude/skills/foo"
  echo 'The skill, where it was.' > "$O/.claude/skills/foo/SKILL.md"
  go add -A
  go commit -qm 'a skill in .claude/skills'
  go branch -M old
  # A branch that has the skill in both places.
  go checkout -q -b both
  skill "$O" foo 'For the other tools.'
  go add -A
  go commit -qm 'the skill for the other tools too'
  # The branch of today: the skill has moved to .agents/skills, which is what the kit is for.
  go checkout -q old
  go checkout -q -b new
  mkdir -p "$O/.agents/skills"
  go mv .claude/skills/foo .agents/skills/foo
  echo 'more' > "$O/.agents/skills/foo/reference.md"
  mkdir -p "$O/.claude/skills"
  echo '# The anchor.' > "$O/.claude/skills/.gitignore"
  go add -A
  go commit -qm 'move the skill to .agents/skills'
  sleep 1 # see 1
  bridge "$O" session > /dev/null
  check "on the branch of today the skill has its copy" sh -c 'test -f "$1/reference.md" && test -f "$1/.gitignore"' x "$O/.claude/skills/foo"
  # edited <file>: an edit that nobody has committed, in a file that git has just checked out.
  edited() { echo 'An edit that is not committed.' >> "$1"; }
  sleep 1 # what git checks out must be newer than the copy, also where clocks tick in whole seconds
  go checkout -q old
  check "git puts its file in the place of the ignored copy, without a word" writable "$O/.claude/skills/foo/SKILL.md"
  check "and the copy's own .gitignore stays behind" grep -qx '\*' "$O/.claude/skills/foo/.gitignore"
  edited "$O/.claude/skills/foo/SKILL.md"
  out=$(bridge "$O" session 2>&1)
  check "the hook leaves the tracked skill alone, with the edit that is not committed" grep -q 'not committed' "$O/.claude/skills/foo/SKILL.md"
  check "and says so" contains "$out" '.claude/skills/foo is no longer the copy that the bridge made'
  check "it also says that the copy's .gitignore still hides new files there from git" contains "$out" 'Its .gitignore still hides new files there from git'
  check "git finds the skill as that branch has it, with the edit" test "$(go status --porcelain)" = ' M .claude/skills/foo/SKILL.md'
  check "the folder is off the bridge's records" sh -c '! grep -qx foo "$1/manifest" 2> /dev/null' x "$OS"
  settled "the next hook has nothing to do, and starts no program" "$O"
  # Back to the branch of today. Git takes its file out again. What is left in the folder is what
  # the bridge had copied, and no record names it.
  go checkout -q -- .
  go checkout -q new
  check "back on the branch of today, the rest of the copy is still there" sh -c 'test -f "$1/reference.md" && test ! -e "$1/SKILL.md"' x "$O/.claude/skills/foo"
  out=$(bridge "$O" session 2>&1)
  check "the hook takes that rest for no skill of someone's own" lacks "$out" 'was not made by the bridge'
  check "and makes the copy again" grep -q 'where it was' "$O/.claude/skills/foo/SKILL.md"
  check "which is on record again" grep -qx foo "$OS/manifest"
  # An edit in a copy that git knows nothing about is still an edit of a copy: see 6.
  sleep 1 # see 6
  chmod u+w "$O/.claude/skills/foo/SKILL.md" 2> /dev/null
  echo 'An edit in the copy.' >> "$O/.claude/skills/foo/SKILL.md"
  bridge "$O" session > /dev/null 2>&1
  check "an edited copy is still restored, where git says that it tracks nothing in it" sh -c '! grep -q "An edit in the copy." "$1"' x "$O/.claude/skills/foo/SKILL.md"
  # The branch with the skill in both places. Its skill in .agents/skills is still there, so the
  # folder in .claude/skills looks like a copy that someone edited. Only git can say that it is not.
  sleep 1 # see above
  go checkout -q both
  edited "$O/.claude/skills/foo/SKILL.md"
  out=$(bridge "$O" session 2>&1)
  check "where the skill is in .agents/skills too, the tracked one is not replaced by its copy" grep -q 'not committed' "$O/.claude/skills/foo/SKILL.md"
  check "the hook has asked git, and says so" contains "$out" '.claude/skills/foo is no longer the copy that the bridge made (git tracks it)'
  check "and that the skill of that name is not copied" contains "$out" '.agents/skills/foo is not copied. Rename or delete one of them.'
  out=$(bridge "$O" session 2>&1)
  check "from then on it is a conflict like any other" contains "$out" '.claude/skills/foo exists and was not made by the bridge'
  settled "and a hook that finds it once more starts no program" "$O"
  # Clean, in the state of the first case: the records name a folder that holds the tracked skill.
  go checkout -q -- .
  go checkout -q new
  bridge "$O" session > /dev/null 2>&1
  sleep 1 # see above
  go checkout -q old
  edited "$O/.claude/skills/foo/SKILL.md"
  out=$(bridge "$O" clean 2>&1)
  check "clean leaves the tracked skill alone too" grep -q 'not committed' "$O/.claude/skills/foo/SKILL.md"
  check "and says so" contains "$out" 'left .claude/skills/foo alone: it is no longer the copy that the bridge made'
  check "it deletes its records" test ! -e "$OS"
  # While git checks a branch out, its index is still the one of the branch before, and it holds a
  # lock on it from the first file to the last. Its answer would be wrong then, so the sync waits.
  go checkout -q -- .
  go checkout -q new
  bridge "$O" session > /dev/null 2>&1
  sleep 1 # see 6
  chmod u+w "$O/.claude/skills/foo/SKILL.md" 2> /dev/null
  echo 'An edit in the copy.' >> "$O/.claude/skills/foo/SKILL.md"
  : > "$O/.git/index.lock"
  out=$(bridge "$O" session 2>&1)
  rm -f "$O/.git/index.lock"
  check "while git is at work on the checkout, a sync that has to ask it touches nothing" grep -q 'An edit in the copy.' "$O/.claude/skills/foo/SKILL.md"
  check "it says that it waits" contains "$out" 'git is at work in this checkout, so this sync waits for the next hook.'
  check "and the folder stays on record" grep -qx foo "$OS/manifest"
  # A git that fails in this checkout, because it does not trust it or is too old, tracks nothing
  # that the bridge could ask about. The other signs decide then, as where there is no git.
  mkdir -p "$base/nogit"
  printf '#!/bin/sh\nexit 128\n' > "$base/nogit/git"
  chmod +x "$base/nogit/git"
  printf '@exit /b 128\r\n' > "$base/nogit/git.cmd" # the same for PowerShell on Windows
  out=$( (
    PATH=$base/nogit:$PATH
    export PATH
    bridge "$O" session
  ) 2>&1)
  check "where git fails, an edited copy is restored as where there is no git" sh -c '! grep -q "An edit in the copy." "$1"' x "$O/.claude/skills/foo/SKILL.md"
  check "without a word about it" lacks "$out" 'no longer the copy'
  # Letter case: Windows and macOS take a folder in another letter case for the same one, so git's
  # files can lie in the copy's folder under such a name. The bridge cannot tell what the file
  # system does, so git's answer counts in any letter case.
  sleep 1 # see 6
  chmod u+w "$O/.claude/skills/foo/SKILL.md" 2> /dev/null
  echo 'An edit in the copy.' >> "$O/.claude/skills/foo/SKILL.md"
  go update-index --add --cacheinfo "100644,$(go hash-object -w "$O/.claude/skills/foo/SKILL.md"),.claude/skills/FOO/SKILL.md"
  out=$(bridge "$O" session 2>&1)
  check "a folder that git tracks under a name in another letter case is left alone as well" grep -q 'An edit in the copy.' "$O/.claude/skills/foo/SKILL.md"
  check "and the hook says that git tracks it" contains "$out" '.claude/skills/foo is no longer the copy that the bridge made (git tracks it)'
else
  echo "  skip git cases (no git here)"
fi

echo "36. a skill of someone's own that takes the place of a copy by hand"
P=$(new_repo own-hand)
PR=$P/.claude/skills/.agent-skills-bridge
for s in alpha beta gamma delta epsilon zeta; do skill "$P" "$s"; done
sleep 1 # see 1
bridge "$P" session > /dev/null
# The copy goes, and the skill moves from .agents/skills into its place: it is to be a skill for
# Claude Code alone. No file in the folder is new, so only the missing .gitignore tells.
chmod -R u+w "$P/.claude/skills/alpha"
rm -rf "$P/.claude/skills/alpha"
mv "$P/.agents/skills/alpha" "$P/.claude/skills/alpha"
out=$(bridge "$P" session 2>&1)
check "a skill that was moved into the place of its copy is left alone" grep -q 'Body of alpha.' "$P/.claude/skills/alpha/SKILL.md"
check "the hook says so, and why" contains "$out" '.claude/skills/alpha is no longer the copy that the bridge made (the .gitignore that the bridge wrote is not in it)'
check "the folder is off the bridge's records" sh -c '! grep -qx alpha "$1/manifest"' x "$PR"
check "the copies that still are copies stay on record" grep -qx beta "$PR/manifest"
bridge "$P" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$P/.claude/skills/alpha/SKILL.md")"'"}}' > /dev/null 2>&1
check "an edit of that skill is allowed now" test $? = 0
settled "the next hook has nothing to say about it, and starts no program" "$P"
# A folder of someone's own in the place of a copy whose skill is still in .agents/skills.
sleep 1 # see 6
chmod -R u+w "$P/.claude/skills/beta"
rm -rf "$P/.claude/skills/beta"
mkdir "$P/.claude/skills/beta"
echo 'mine' > "$P/.claude/skills/beta/SKILL.md"
out=$(bridge "$P" session 2>&1)
check "a folder of someone's own in the place of a copy is not overwritten" grep -qx mine "$P/.claude/skills/beta/SKILL.md"
check "the hook says that the skill of that name is not copied" contains "$out" '.agents/skills/beta is not copied. Rename or delete one of them.'
out=$(bridge "$P" session 2>&1)
check "from then on it is a conflict like any other" contains "$out" '.claude/skills/beta exists and was not made by the bridge'
# A copy whose SKILL.md someone changed, and whose skill goes then: an edited copy is restored from
# its skill (see 6), and here nothing is left to restore it from.
sleep 1 # see 6
chmod u+w "$P/.claude/skills/gamma/SKILL.md" 2> /dev/null
echo 'Changed in the copy.' >> "$P/.claude/skills/gamma/SKILL.md"
rm -rf "$P/.agents/skills/gamma"
out=$(bridge "$P" session 2>&1)
check "a copy with a changed SKILL.md stays when its skill is gone" grep -q 'Changed in the copy.' "$P/.claude/skills/gamma/SKILL.md"
check "and the hook says why" contains "$out" 'its SKILL.md is not the one that the bridge copied, and .agents/skills/gamma is gone'
# A copy that only gained a file, as a script leaves one that runs in it, is still the bridge's.
mkdir "$P/.claude/skills/delta/__pycache__"
echo 'x' > "$P/.claude/skills/delta/__pycache__/run.pyc"
rm -rf "$P/.agents/skills/delta"
out=$(bridge "$P" session 2>&1)
check "a copy that only gained a file is deleted with its skill" test ! -e "$P/.claude/skills/delta"
check "without a word" lacks "$out" 'no longer the copy'
# A file in the place of a copy: git checks a link out as one where links cannot be made.
chmod -R u+w "$P/.claude/skills/epsilon"
rm -rf "$P/.claude/skills/epsilon"
echo '../../.agents/skills/epsilon' > "$P/.claude/skills/epsilon"
out=$(bridge "$P" session 2>&1)
check "a file in the place of a copy is left alone" grep -q 'agents/skills/epsilon' "$P/.claude/skills/epsilon"
check "and reported" contains "$out" '.claude/skills/epsilon is no longer the copy that the bridge made (it is not a folder)'
# An empty folder is nobody's work.
sleep 1 # see 6
chmod -R u+w "$P/.claude/skills/zeta"
rm -rf "$P/.claude/skills/zeta"
mkdir "$P/.claude/skills/zeta"
bridge "$P" session > /dev/null 2>&1
check "an empty folder in the place of a copy gets the copy" test -f "$P/.claude/skills/zeta/SKILL.md"
# A skill file with a time ahead of the clock, as an archive or another machine's clock leaves it.
# The PowerShell twin gives a copy the time of its original, and this copy must not pass for one
# that someone changed after the bridge made it.
skill "$P" eta
touch -t 203701010000 "$P/.agents/skills/eta/SKILL.md"
bridge "$P" session > /dev/null 2>&1
rm -rf "$P/.agents/skills/eta"
out=$(bridge "$P" session 2>&1)
check "the copy of a file with a time ahead of the clock is deleted with its skill" test ! -e "$P/.claude/skills/eta"
check "like any other copy" lacks "$out" 'no longer the copy'
# The move by hand once more, the way a file manager does it that merges two folders: the copy is
# not deleted first, and each file of the skill lands on the copy's file of that name. The bridge's
# .gitignore stays, and no file is new, because a move keeps the times. What tells is that the
# files can be written: the bridge leaves every file of a copy read-only.
if [ "$(id -u)" = 0 ]; then
  echo "  skip the move over the files of a copy (root may write any file, so nothing tells)"
else
  skill "$P" iota
  sleep 1 # see 1: the skill's file is older than its copy, also in whole seconds
  bridge "$P" session > /dev/null 2>&1
  chmod u+w "$P/.claude/skills/iota/SKILL.md" 2> /dev/null # a file manager asks, and then does this
  mv -f "$P/.agents/skills/iota/SKILL.md" "$P/.claude/skills/iota/SKILL.md"
  rmdir "$P/.agents/skills/iota"
  check "the skill's file lies in the copy's folder, older than the copy, next to the bridge's .gitignore" sh -c 'test ! "$1/SKILL.md" -nt "$1/.gitignore" && grep -qx "\*" "$1/.gitignore"' x "$P/.claude/skills/iota"
  out=$(bridge "$P" session 2>&1)
  check "a skill whose files were moved over the files of its copy is left alone" grep -q 'Body of iota.' "$P/.claude/skills/iota/SKILL.md"
  check "and the hook says why" contains "$out" '.claude/skills/iota is no longer the copy that the bridge made (its SKILL.md is not the one that the bridge copied, and .agents/skills/iota is gone)'
fi
# A skill that is renamed in letter case only, where the file system takes both names for one
# folder. The PowerShell twin takes them for one name too, and its copy still says the name of
# before. The shell script goes by the letter case, so the rename is another matter there.
if [ "$impl" = ps1 ]; then
  skill "$P" theta
  bridge "$P" session > /dev/null 2>&1
  mv "$P/.agents/skills/theta" "$P/.agents/skills/theta-" && mv "$P/.agents/skills/theta-" "$P/.agents/skills/Theta"
  sleep 1 # see 1
  skill "$P" Theta "Second body."
  out=$(bridge "$P" session 2>&1)
  check "the twin still knows the copy of a skill that was renamed in letter case only" grep -q 'Second body.' "$P/.claude/skills/Theta/SKILL.md"
  check "and does not take it for a skill of someone's own" lacks "$out" 'no longer the copy'
else
  echo "  skip the rename in letter case only (the shell script tells such names apart)"
fi

echo "37. clean, where a skill of someone's own has taken the place of a copy"
L=$(new_repo own-clean)
skill "$L" alpha
skill "$L" beta
sleep 1 # see 1
bridge "$L" session > /dev/null
chmod -R u+w "$L/.claude/skills/alpha"
rm -rf "$L/.claude/skills/alpha"
mv "$L/.agents/skills/alpha" "$L/.claude/skills/alpha"
out=$(bridge "$L" clean 2>&1)
check "clean leaves a skill that was moved into the place of its copy" grep -q 'Body of alpha.' "$L/.claude/skills/alpha/SKILL.md"
check "and says so" contains "$out" 'left .claude/skills/alpha alone: it is no longer the copy that the bridge made (the .gitignore that the bridge wrote is not in it)'
check "it deletes the copy that still is one" test ! -e "$L/.claude/skills/beta"
check "and says which" contains "$out" 'deleted the copies: beta.'
check "and deletes its records" test ! -e "$L/.claude/skills/.agent-skills-bridge"

echo "38. a sync that finds a skill of someone's own, and is killed"
T=$(new_repo own-killed)
TS=$T/.claude/skills/.agent-skills-bridge
skill "$T" alpha
skill "$T" beta
sleep 1 # see 1
bridge "$T" session > /dev/null
chmod -R u+w "$T/.claude/skills/alpha"
rm -rf "$T/.claude/skills/alpha"
mv "$T/.agents/skills/alpha" "$T/.claude/skills/alpha"
skill "$T" beta "Second body."
# The sync sets out to take the folder off its records and to copy the other skill. The kill comes
# when that copy is made and the manifest is not yet written. So the records still name the folder,
# and they say that a sync did not end. After such a sync a copy may be without the bridge's
# .gitignore: one that the sync was making. This folder is none of those, and must stay.
# shellcheck disable=SC2016 # the bridge expands these, not the test
meanwhile "$T" 'Copies made by' 'kill -9 $$' 'Stop-Process -Id $PID -Force'
(bridge "$T" sync) > /dev/null 2>&1
pristine "$T"
check "the sync that was killed left the skill alone" grep -q 'Body of alpha.' "$T/.claude/skills/alpha/SKILL.md"
check "its manifest was never written, so the records still name the folder" grep -qx alpha "$TS/manifest"
sleep 1 # see 25
touch -t 202001010000 "$TS/lock" # see 9
out=$(bridge "$T" session 2>&1)
check "the sync after the kill leaves the skill alone as well" grep -q 'Body of alpha.' "$T/.claude/skills/alpha/SKILL.md"
check "and reports it" contains "$out" '.claude/skills/alpha is no longer the copy that the bridge made'
check "and takes it off the records" sh -c '! grep -qx alpha "$1/manifest"' x "$TS"
check "it finishes the copy that the killed sync was making" grep -q 'Second body.' "$T/.claude/skills/beta/SKILL.md"

echo "39. records of before, and records that were lost"
V=$(new_repo records-of-before)
VS=$V/.claude/skills/.agent-skills-bridge
skill "$V" alpha
skill "$V" beta
sleep 1 # see 1
bridge "$V" session > /dev/null
# A sync that the scripts of before left unfinished: their stamp names the copies, and no line of
# it says which of them the sync was making. Any of them may be half-made, without its .gitignore.
chmod u+w "$V/.claude/skills/alpha/.gitignore" 2> /dev/null
rm -f "$V/.claude/skills/alpha/.gitignore"
printf '%s\n' '# A sync began here and has not ended. Its copies, the ones it was about to make among them:' alpha beta > "$VS/stamp"
out=$(bridge "$V" session 2>&1)
check "a copy that such a sync left without its .gitignore is no skill of someone's own" lacks "$out" 'no longer the copy'
check "the next sync makes it again" grep -qx '\*' "$V/.claude/skills/alpha/.gitignore"
# Records that were lost: the copies are in no record, and still just as the bridge made them.
rm -rf "$VS"
out=$(bridge "$V" session 2>&1)
check "copies whose records were lost are no conflict" lacks "$out" 'was not made by the bridge'
check "and are on record again" sh -c 'grep -qx alpha "$1/manifest" && grep -qx beta "$1/manifest"' x "$VS"
rm -rf "$VS"
sleep 1 # see 6
chmod u+w "$V/.claude/skills/alpha/SKILL.md" 2> /dev/null
echo 'Changed in the copy.' >> "$V/.claude/skills/alpha/SKILL.md"
out=$(bridge "$V" session 2>&1)
check "a copy in no record that someone changed is a conflict" contains "$out" '.claude/skills/alpha exists and was not made by the bridge'
check "and keeps the change" grep -q 'Changed in the copy.' "$V/.claude/skills/alpha/SKILL.md"
check "the copy that nobody changed is the bridge's again" grep -qx beta "$VS/manifest"

echo "40. a skill with a file dated ahead of the clock"
D=$(new_repo ahead)
DS=$D/.claude/skills/.agent-skills-bridge
skill "$D" alpha
skill "$D" beta
mkdir -p "$D/.agents/skills/alpha/refs"
echo 'ref 1' > "$D/.agents/skills/alpha/refs/ref.md"
# An archive leaves such times, or the clock of another machine: here on a file and on its folder.
# No stamp of a sync is ever newer than they are.
touch -t 203701010000 "$D/.agents/skills/alpha/refs/ref.md" "$D/.agents/skills/alpha/refs"
sleep 1 # see 1
bridge "$D" session > /dev/null
check "the skill is copied, with that file" grep -qx 'ref 1' "$D/.claude/skills/alpha/refs/ref.md"
out=$(bridge "$D" session)
check "the next hook does not copy it again because of that time" lacks "$out" 'reloadSkills'
st=$(bridge "$D" status 2>&1)
check "and status calls the copies current" contains "$st" 'copies are current'
settled "a hook with nothing else to do starts no program for it" "$D"
# What is new is still copied. First a file next to that one, with the time it is.
sleep 1 # see 1
skill "$D" alpha "Second body."
sleep 1 # see 1: or this edit counts as new once more below, where clocks tick in whole seconds
bridge "$D" sync > /dev/null
check "an edit next to that file is copied" grep -q 'Second body.' "$D/.claude/skills/alpha/SKILL.md"
# Then that file itself. It changes in its place, so its folder says nothing, and it comes with a
# later time ahead of the clock, as from a drive whose clock runs ahead.
echo 'ref 2' > "$D/.agents/skills/alpha/refs/ref.md"
touch -t 203801010000 "$D/.agents/skills/alpha/refs/ref.md"
sleep 1 # see 1
bridge "$D" sync > /dev/null
check "an edit of that file which comes with a later time is copied too" grep -qx 'ref 2' "$D/.claude/skills/alpha/refs/ref.md"
out=$(bridge "$D" session)
check "and it is copied once, not at every hook" lacks "$out" 'reloadSkills'
# The record of those times goes with the skill.
rm -rf "$D/.agents/skills/alpha"
bridge "$D" sync > /dev/null
check "the copy goes with its skill" test ! -e "$D/.claude/skills/alpha"
check "and the records hold nothing of it any more" test "$(cd "$DS" && echo .[!.]* *)" = '.gitignore manifest stamp'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
