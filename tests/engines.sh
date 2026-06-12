#!/bin/sh
# Cross-ENGINE differential conformance: every fixture in tests/engines/*.lisp runs on every engine and
# must be byte-identical to its golden .out. This is the conformance metric for the REAL execution
# stack (the vau-kernel fixtures in tests/lisp/ cover the bootstrap evaluator separately).
#
#   local (always):  sh JIT (load-sh.sh)          sh interpreter (interp-sh.sh)
#                    the shipping polyglot's sh half (portsh.cmd)
#   VM   (optional): cmd JIT (load-cmd.cmd)       cmd interpreter (interp-cmd.cmd)
#                    PORTSH_WIN_SSH=user@host sh tests/engines.sh
#
# Fixtures are deliberately SMALL: the cmd interpreter runs each in seconds.
set -u
cd "$(dirname "$0")/.."
root=$(pwd)
[ -f load-sh.sh ]   || sh build-load-sh.sh >/dev/null
[ -f interp-sh.sh ] || sh tools/build-interp-sh.sh >/dev/null
[ -f portsh.cmd ]   || sh build-polyglot.sh >/dev/null
SH=${PORTSH_SH:-mksh}
pass=0; fail=0
chk() {  # $1 engine-name, $2 fixture, $3 actual-output
  exp=$(cat "${2%.lisp}.out")
  if [ "$3" = "$exp" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf 'FAIL %-12s %s\n  want: %s\n  got : %s\n' "$1" "$(basename "$2")" "$(printf %s "$exp" | tr '\n' '|')" "$(printf %s "$3" | tr '\n' '|')"
  fi
}
for f in tests/engines/*.lisp; do
  chk "sh-jit"    "$f" "$(PORTSH_SCRIPT=1 PORTSH_TEST_VAR=hello $SH load-sh.sh "$f" alpha beta-42 2>&1 | tr -d '\r')"
  chk "sh-interp" "$f" "$(PORTSH_SCRIPT=1 PORTSH_TEST_VAR=hello $SH interp-sh.sh "$f" alpha beta-42 2>&1 | tr -d '\r')"
  chk "polyglot"  "$f" "$(PORTSH_SCRIPT=1 PORTSH_TEST_VAR=hello sh portsh.cmd "$f" alpha beta-42 2>&1 | tr -d '\r')"
done
# (exit n) must set the SCRIPT's exit code (output is goldened above; the code needs its own check)
xchk() { if [ "$2" = 3 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-12s exitcode (got %s, want 3)\n' "$1" "$2"; fi; }
PORTSH_SCRIPT=1 $SH load-sh.sh tests/engines/exitcode.lisp >/dev/null 2>&1; xchk "sh-jit" "$?"
PORTSH_SCRIPT=1 $SH interp-sh.sh tests/engines/exitcode.lisp >/dev/null 2>&1; xchk "sh-interp" "$?"
PORTSH_SCRIPT=1 sh portsh.cmd tests/engines/exitcode.lisp >/dev/null 2>&1; xchk "polyglot" "$?"
if [ -n "${PORTSH_WIN_SSH:-}" ]; then
  VM=$PORTSH_WIN_SSH; DIR="eng$$"
  # build-comp-cmd.sh regenerates comp-cmd/ with rm -rf, dropping the loader and interp; rebuild
  # whichever is missing (load-cmd.cmd is deliberately NOT in the selfx pack -- it exists for these
  # engine-differential legs).
  [ -f comp-cmd/interp-cmd.cmd ] || sh build-interp-cmd.sh >/dev/null
  [ -f comp-cmd/load-cmd.cmd ]   || sh build-load-cmd.sh >/dev/null
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  tar czf "$work/t.tgz" -C comp-cmd . -C "$root/tests" engines
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
  sleep 2
  scp -q "$work/t.tgz" "${VM}:eng.tgz"
  ssh -n "$VM" "cmd /c \"mkdir %USERPROFILE%\\$DIR & cd /d %USERPROFILE%\\$DIR & tar -xzf %USERPROFILE%\\eng.tgz\"" >/dev/null 2>&1
  for f in tests/engines/*.lisp; do
    b=$(basename "$f")
    chk "cmd-jit"    "$f" "$(ssh -n -o ConnectTimeout=300 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_SCRIPT=1& set PORTSH_TEST_VAR=hello& call load-cmd.cmd engines\\$b alpha beta-42 2>&1\"" 2>&1 | tr -d '\r')"
    chk "cmd-interp" "$f" "$(ssh -n -o ConnectTimeout=540 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_SCRIPT=1& set PORTSH_TEST_VAR=hello& call interp-cmd.cmd engines\\$b alpha beta-42 2>&1\"" 2>&1 | tr -d '\r')"
  done
  for eng in load-cmd.cmd interp-cmd.cmd; do
    rc=$(ssh -n -o ConnectTimeout=540 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_SCRIPT=1& cmd /c call $eng engines\\exitcode.lisp >nul 2>&1 & if errorlevel 3 if not errorlevel 4 (echo RC=3) else (echo RC=BAD)\"" 2>&1 | tr -d '\r' | grep -o 'RC=[A-Z0-9]*')
    if [ "$rc" = "RC=3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-12s exitcode (%s)\n' "$eng" "$rc"; fi
  done
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
fi
printf '\nengines: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
