#!/bin/sh
# Packed-app conformance: every engines fixture is packed (tools/pack-app.sh) and the resulting
# single-file app must reproduce the SAME golden output as every other engine -- locally as sh,
# and (with PORTSH_WIN_SSH) on real cmd.exe, where a packed app runs the warm fast path from its
# FIRST run (the program is AOT-compiled at pack time and embedded as a self-extractor arm).
# This also guards the pack-time partition against drift from the loader's :in_part -- a __evN /
# __lamN numbering mismatch shows up as a broken fixture.
#
#   sh tests/pack.sh
#   PORTSH_WIN_SSH=user@vm sh tests/pack.sh
set -u
cd "$(dirname "$0")/.."
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
chk() {  # $1 leg, $2 fixture, $3 actual
  exp=$(cat "${2%.lisp}.out")
  if [ "$3" = "$exp" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf 'FAIL %-10s %s\n  want: %s\n  got : %s\n' "$1" "$(basename "$2")" "$(printf %s "$exp" | tr '\n' '|')" "$(printf %s "$3" | tr '\n' '|')"
  fi
}
for f in tests/engines/*.lisp; do
  b=$(basename "$f" .lisp)
  sh tools/pack-app.sh "$f" "$work/$b.cmd" >/dev/null 2>&1
  chk "pack-sh" "$f" "$(sh "$work/$b.cmd" 2>&1 | tr -d '\r')"
done
if [ -n "${PORTSH_WIN_SSH:-}" ]; then
  VM=$PORTSH_WIN_SSH; DIR="pk$$"
  tar czf "$work/p.tgz" -C "$work" $(cd "$work" && ls *.cmd)
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
  sleep 2
  scp -q "$work/p.tgz" "$VM:pk.tgz"
  ssh -n "$VM" "cmd /c \"mkdir %USERPROFILE%\\$DIR & cd /d %USERPROFILE%\\$DIR & tar -xzf %USERPROFILE%\\pk.tgz\"" >/dev/null 2>&1
  for f in tests/engines/*.lisp; do
    b=$(basename "$f" .lisp)
    chk "pack-cmd" "$f" "$(ssh -n -o ConnectTimeout=300 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & call $b.cmd 2>&1\"" 2>&1 | tr -d '\r')"
  done
fi
printf '\npack: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
