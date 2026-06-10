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
  chk "sh-jit"    "$f" "$(PORTSH_SCRIPT=1 $SH load-sh.sh "$f" 2>&1 | tr -d '\r')"
  chk "sh-interp" "$f" "$(PORTSH_SCRIPT=1 $SH interp-sh.sh "$f" 2>&1 | tr -d '\r')"
  chk "polyglot"  "$f" "$(PORTSH_SCRIPT=1 sh portsh.cmd "$f" 2>&1 | tr -d '\r')"
done
if [ -n "${PORTSH_WIN_SSH:-}" ]; then
  VM=$PORTSH_WIN_SSH; DIR="eng$$"
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  tar czf "$work/t.tgz" -C comp-cmd . -C "$root/tests" engines
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
  sleep 2
  scp -q "$work/t.tgz" "${VM}:eng.tgz"
  ssh -n "$VM" "cmd /c \"mkdir %USERPROFILE%\\$DIR & cd /d %USERPROFILE%\\$DIR & tar -xzf %USERPROFILE%\\eng.tgz\"" >/dev/null 2>&1
  for f in tests/engines/*.lisp; do
    b=$(basename "$f")
    chk "cmd-jit"    "$f" "$(ssh -n -o ConnectTimeout=300 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_SCRIPT=1& call load-cmd.cmd engines\\$b 2>&1\"" 2>&1 | tr -d '\r')"
    chk "cmd-interp" "$f" "$(ssh -n -o ConnectTimeout=540 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_SCRIPT=1& call interp-cmd.cmd engines\\$b 2>&1\"" 2>&1 | tr -d '\r')"
  done
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
fi
printf '\nengines: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
