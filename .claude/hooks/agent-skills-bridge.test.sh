#!/bin/sh
# agent-skills-bridge.test.sh - scenario tests for the agent-skills bridge.
#
# Usage: sh .claude/hooks/agent-skills-bridge.test.sh [sh|ps1]
#   sh   test agent-skills-bridge.sh (default; any POSIX sh, Git Bash included)
#   ps1  test agent-skills-bridge.ps1 through Windows PowerShell (run from Git Bash on Windows)
# Builds throwaway repositories under $TMPDIR and checks what the bridge leaves on disk. The git
# cases run where git is installed, the svn cases where svn and svnadmin are.

set -u
impl=${1:-sh}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
base=$(mktemp -d "${TMPDIR:-/tmp}/agent-skills-bridge-test.XXXXXX")
trap 'chmod -R u+w "$base" 2>/dev/null; rm -rf "$base"' EXIT
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
writable() { [ -w "$1" ]; } # Git Bash maps this to the Windows read-only attribute
crs() { tr -cd '\r' < "$1" | wc -c | tr -d ' '; }

# The hook command from .claude/settings.json, for one bridge command. The same string runs in
# POSIX sh and in PowerShell; see agent-skills-bridge.md.
hook_command() {
  printf '%s' "set \\' ; ASB_CMD=$1 . \"\$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh\" ; exit ; #' ; & \"\$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1\" $1 ; exit \$LASTEXITCODE"
}

# bridge <repo> <command> [stdin]: run the implementation under test the way Claude Code does:
# hook commands through sh -c or powershell -Command with CLAUDE_PROJECT_DIR set, others by hand.
bridge() {
  case $2 in
    sync | session | guard)
      if [ "$impl" = ps1 ]; then
        printf '%s' "${3:-}" | CLAUDE_PROJECT_DIR=$(cygpath -w "$1") powershell.exe -NoProfile -NonInteractive \
          -ExecutionPolicy Bypass -Command "$(hook_command "$2")"
      else
        dir=$1
        command -v cygpath > /dev/null 2>&1 && dir=$(cygpath -w "$1")
        printf '%s' "${3:-}" | CLAUDE_PROJECT_DIR=$dir sh -c "$(hook_command "$2")"
      fi
      ;;
    *)
      if [ "$impl" = ps1 ]; then
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
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

echo "agent-skills bridge tests ($impl)"

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
  fi
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
bridge "$R" guard '{"tool_name":"Edit","tool_input":{"file_path":"'"$up"'"}}' > /dev/null 2>&1
code=$?
if command -v cygpath > /dev/null 2>&1; then
  check "other letter case refused on Windows" test "$code" = 2
  lowdrive=$(printf '%s' "$copy_md" | sed 's/^\(.\)/\L\1/')
  err=$(bridge "$R" guard '{"tool_name":"Write","tool_input":{"file_path":"'"$lowdrive"'","content":"x"}}' 2>&1)
  code=$?
  check "lower-case drive letter refused" test "$code" = 2
  check "refusal keeps the file name's letter case" contains "$err" 'alpha/SKILL.md instead'
fi
bridge "$R" guard '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$(tool_path "$R/.claude/skills/alpha/x.ipynb")"'"}}' > /dev/null 2>&1
check "NotebookEdit inside a copy refused" test $? = 2

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
  rm "$R/.agents/skills/alpha/loop"
  bridge "$R" sync > /dev/null
  check "skill copied again once the loop is gone" test -f "$R/.claude/skills/alpha/SKILL.md"
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
  sleep 1 # see 6
  rm -f "$G/.claude/skills/alpha/.gitignore"
  st=$(bridge "$G" status 2>&1)
  check "status names a copy git can see" contains "$st" 'not ignored: alpha'
  bridge "$G" sync > /dev/null
  check "sync gives the copy its .gitignore back" grep -qx '\*' "$G/.claude/skills/alpha/.gitignore"
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
else
  echo "  skip svn cases (no svn here)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
