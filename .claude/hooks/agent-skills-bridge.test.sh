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
  printf '%s' "set \\' ; ASB_CMD=$1 . \"\$CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.sh\" ; exit ; #' ; & \"\$env:CLAUDE_PROJECT_DIR/.claude/hooks/agent-skills-bridge.ps1\" $1 ; exit \$LASTEXITCODE"
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
# nobody else can read, replace or delete it; unblock lets it go.
block() {
  : > "$base/blocking"
  powershell.exe -NoProfile -NonInteractive -Command "\$f = [IO.File]::Open('$(cygpath -w "$1")', 'Open', 'Read', 'None'); [IO.File]::WriteAllText('$(cygpath -w "$base/blocked")', ''); while (Test-Path -LiteralPath '$(cygpath -w "$base/blocking")') { Start-Sleep -Milliseconds 100 }; \$f.Close()" &
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
  rm -f "$base/blocked"
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
  # other editing tool has to run unfiltered.
  check "settings.json: only the guard of Edit runs through a filter" awk '
    /"matcher"[ \t]*:/ { edit = ($0 ~ /"matcher"[ \t]*:[ \t]*"Edit"/) }
    /"if"[ \t]*:/ { if (!edit) bad = 1 }
    END { exit bad }' "$settings"
  for t in Edit MultiEdit Write NotebookEdit; do
    check "settings.json: $t is guarded" grep -Eq "\"matcher\": \"([A-Za-z|]+\\|)?$t(\\|[A-Za-z|]+)?\"" "$settings"
  done
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

guarded "a folder named like two copies is no copy" '{"tool_name":"Edit","tool_input":{"file_path":"'"$(tool_path "$R")$js.claude${js}skills${js}alpha beta${js}SKILL.md"'"}}' 0
hs=$(command -v "$hook_shell")
if [ "$impl" != sh ]; then
  :
elif command -v cygpath > /dev/null 2>&1 && [ -z "$("$hs" -c 'echo "${BASH_VERSION:-}"')" ]; then
  echo "  skip the no-program checks (on Windows only bash turns backslashes into slashes by itself)"
else
  # With nothing to do a hook must start no program: on Windows each one can cost a second. A PATH
  # that leads nowhere shows it: the answer is the same, with no "not found" in it.
  dir=$R
  command -v cygpath > /dev/null 2>&1 && dir=$(cygpath -w "$R")
  quiet() { printf '%s' "${2:-}" | CLAUDE_PROJECT_DIR=$dir PATH=/nonexistent "$hs" -c "$(hook_command "$1")" 2>&1; }
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
if command -v cygpath > /dev/null 2>&1; then
  guarded "path with forward slashes refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$(cygpath -m "$R")"'/.claude/skills/alpha/SKILL.md"}}'
  guarded "Git Bash path (/c/...) refused" '{"tool_name":"Edit","tool_input":{"file_path":"'"$(cygpath -m "$R" | sed 's|^\(.\):|/\L\1|')"'/.claude/skills/alpha/SKILL.md"}}'
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
  check "a hook with a relative CLAUDE_PROJECT_DIR ignores CDPATH" sh -c 'case $1 in *cdtrap*) exit 1 ;; "{"*crlf/.agents/skills*) exit 0 ;; *) exit 1 ;; esac' x "$out"
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
  out=$(bridge "$F" session 2>&1)
  check "the next sync deletes it" test ! -e "$F/.claude/skills/alpha"
  check "without calling it someone else's" lacks "$out" 'was not made by the bridge'
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

echo "23. zsh with an alias from .zshenv"
if [ "$impl" = sh ] && [ "${hook_shell##*/}" = zsh ]; then
  A=$(new_repo zshenv)
  skill "$A" alpha
  mkdir -p "$base/zdot"
  echo "alias has='echo ALIAS-RAN'" > "$base/zdot/.zshenv"
  out=$( (
    ZDOTDIR=$base/zdot
    export ZDOTDIR
    bridge "$A" session
  ) 2>&1)
  check "the hook still syncs" sh -c 'case $1 in *"parse error"* | *ALIAS-RAN*) exit 1 ;; *reloadSkills*) exit 0 ;; esac; exit 1' x "$out"
else
  echo "  skip (the hooks do not run in zsh)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
