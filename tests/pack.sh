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
  chk "pack-sh" "$f" "$(PORTSH_TEST_VAR=hello sh "$work/$b.cmd" alpha beta-42 2>&1 | tr -d '\r')"
done
# packed apps must propagate (exit n) as the app's exit code on both hosts
sh "$work/exitcode.cmd" >/dev/null 2>&1
rc=$?
if [ "$rc" = 3 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL pack-sh exitcode (got %s)\n' "$rc"; fi
# rt embed guard: the default pack carries the RUNTIME-ONLY tooling (~half the full tree); an app
# over the cap means the full selfx leaked back in
for f in "$work"/*.cmd; do
  if [ "$(wc -c < "$f")" -ge 1300000 ]; then fail=$((fail+1)); printf 'FAIL pack-size %s (%s bytes >= 1300000)\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')"; else pass=$((pass+1)); fi
done
# PORTSH_PACK_FULL=1 must still produce a working (bigger, full-tooling) app
PORTSH_PACK_FULL=1 sh tools/pack-app.sh tests/engines/exitcode.lisp "$work/exitcode-full.cmd" >/dev/null 2>&1
sh "$work/exitcode-full.cmd" >/dev/null 2>&1
rc=$?
if [ "$rc" = 3 ] && [ "$(wc -c < "$work/exitcode-full.cmd")" -gt "$(wc -c < "$work/exitcode.cmd")" ]; then pass=$((pass+1))
else fail=$((fail+1)); printf 'FAIL pack-full (rc=%s)\n' "$rc"; fi
if [ -n "${PORTSH_WIN_SSH:-}" ]; then
  VM=$PORTSH_WIN_SSH; DIR="pk$$"
  tar czf "$work/p.tgz" -C "$work" $(cd "$work" && ls *.cmd)
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
  sleep 2
  scp -q "$work/p.tgz" "$VM:pk.tgz"
  ssh -n "$VM" "cmd /c \"mkdir %USERPROFILE%\\$DIR & cd /d %USERPROFILE%\\$DIR & tar -xzf %USERPROFILE%\\pk.tgz\"" >/dev/null 2>&1
  for f in tests/engines/*.lisp; do
    b=$(basename "$f" .lisp)
    chk "pack-cmd" "$f" "$(ssh -n -o ConnectTimeout=300 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_TEST_VAR=hello& call $b.cmd alpha beta-42 2>&1\"" 2>&1 | tr -d '\r')"
  done
  rc=$(ssh -n -o ConnectTimeout=300 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & call exitcode.cmd >nul 2>&1 & if errorlevel 3 if not errorlevel 4 (echo RC=3) else (echo RC=BAD)\"" 2>&1 | tr -d '\r' | grep -o 'RC=[A-Z0-9]*')
  if [ "$rc" = "RC=3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL pack-cmd exitcode (%s)\n' "$rc"; fi
  rc=$(ssh -n -o ConnectTimeout=300 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & call exitcode-full.cmd >nul 2>&1 & if errorlevel 3 if not errorlevel 4 (echo RC=3) else (echo RC=BAD)\"" 2>&1 | tr -d '\r' | grep -o 'RC=[A-Z0-9]*')
  if [ "$rc" = "RC=3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL pack-cmd-full exitcode (%s)\n' "$rc"; fi
fi
printf '\npack: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
