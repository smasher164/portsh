#!/bin/sh
# `portsh.cmd pack` SUBCOMMAND conformance (distinct from tools/pack-app.sh, which tests pack.sh).
# The subcommand packs WITHOUT the repo or python: a packed app is a byte-exact copy of portsh.cmd
# plus an appended base64 payload (PEM block), self-decoded at run (sh: sed+base64 -d; cmd: certutil
# -decode self). Packed apps run the program from SOURCE -- JIT on sh, cold->warm on cmd. This guards:
#   - sh pack + sh run (local, every fixture)
#   - cmd pack + cmd run (VM) and CROSS-HOST sh-packed run on cmd (proves the PEM is host-agnostic)
#   - (exit n) propagates as the app's exit code on both hosts
#
#   sh tests/pack-subcommand.sh
#   PORTSH_WIN_SSH=user@vm sh tests/pack-subcommand.sh
set -u
cd "$(dirname "$0")/.."
[ -f portsh.cmd ] || sh build-polyglot.sh >/dev/null
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
chk() {  # $1 leg, $2 fixture, $3 actual
  exp=$(cat "${2%.lisp}.out")
  if [ "$3" = "$exp" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf 'FAIL %-12s %s\n  want: %s\n  got : %s\n' "$1" "$(basename "$2")" "$(printf %s "$exp" | tr '\n' '|')" "$(printf %s "$3" | tr '\n' '|')"
  fi
}

# ---- sh pack + sh run (local), every fixture ----
for f in tests/engines/*.lisp; do
  b=$(basename "$f" .lisp)
  sh portsh.cmd pack "$f" "$work/$b.cmd" >/dev/null 2>&1
  chk "shpack-sh" "$f" "$(PORTSH_TEST_VAR=hello sh "$work/$b.cmd" alpha beta-42 2>&1 | tr -d '\r')"
done
# (exit n) -> app exit code, sh
sh "$work/exitcode.cmd" >/dev/null 2>&1
if [ "$?" = 3 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL shpack-sh exitcode (got %s)\n' "$?"; fi
# the packed app must be self-contained: no payload sentinel leaked into the unpacked portsh.cmd
if grep -q '^__PORTSH_PAYLOAD__$' portsh.cmd 2>/dev/null; then fail=$((fail+1)); printf 'FAIL portsh.cmd carries a bare payload marker\n'; else pass=$((pass+1)); fi

if [ -n "${PORTSH_WIN_SSH:-}" ]; then
  VM=$PORTSH_WIN_SSH; DIR="ps$$"
  # ship portsh.cmd + the fixtures + the locally sh-packed apps (for the cross-host leg)
  tar czf "$work/s.tgz" portsh.cmd -C tests engines -C "$work" $(cd "$work" && ls *.cmd | sed 's/^/.\//')
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
  sleep 2
  scp -q "$work/s.tgz" "$VM:ps.tgz"
  ssh -n "$VM" "cmd /c \"mkdir %USERPROFILE%\\$DIR & cd /d %USERPROFILE%\\$DIR & tar -xzf %USERPROFILE%\\ps.tgz\"" >/dev/null 2>&1
  # representative fixtures for the (slow) cmd legs: cover stdlib, value-position, args, plain
  for b in numbers stdlib valuepos args hostops; do
    f="tests/engines/$b.lisp"; [ -f "$f" ] || continue
    # cmd PACK on the VM, then run the resulting app. Named ${b}.w.cmd (not ${b}_c.cmd): the
    # args fixture prints the argv0 STEM (text before the first dot), which must equal the
    # fixture stem on every leg -- and ${b}.cmd is taken by the sh-packed app in the same dir.
    out=$(ssh -n -o ConnectTimeout=400 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & call portsh.cmd pack engines\\$b.lisp ${b}.w.cmd >nul 2>&1 & set PORTSH_TEST_VAR=hello& call ${b}.w.cmd alpha beta-42 2>&1\"" 2>&1 | tr -d '\r')
    chk "cmdpack-cmd" "$f" "$out"
    # CROSS-HOST: the locally sh-packed app run on cmd
    out=$(ssh -n -o ConnectTimeout=400 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & set PORTSH_TEST_VAR=hello& call $b.cmd alpha beta-42 2>&1\"" 2>&1 | tr -d '\r')
    chk "shpack-cmd" "$f" "$out"
  done
  # (exit n) propagation on cmd: cmd-packed and sh-packed (cross-host)
  rc=$(ssh -n -o ConnectTimeout=400 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & call portsh.cmd pack engines\\exitcode.lisp ec_c.cmd >nul 2>&1 & call ec_c.cmd >nul 2>&1 & if errorlevel 3 if not errorlevel 4 (echo RC=3) else (echo RC=BAD)\"" 2>&1 | tr -d '\r' | grep -o 'RC=[A-Z0-9]*')
  if [ "$rc" = "RC=3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL cmdpack-cmd exitcode (%s)\n' "$rc"; fi
  rc=$(ssh -n -o ConnectTimeout=400 "$VM" "cmd /c \"cd /d %USERPROFILE%\\$DIR & call exitcode.cmd >nul 2>&1 & if errorlevel 3 if not errorlevel 4 (echo RC=3) else (echo RC=BAD)\"" 2>&1 | tr -d '\r' | grep -o 'RC=[A-Z0-9]*')
  if [ "$rc" = "RC=3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL shpack-cmd exitcode (%s)\n' "$rc"; fi
  ssh -n "$VM" "cmd /c \"rmdir /s /q %USERPROFILE%\\$DIR\"" >/dev/null 2>&1 || true
fi
printf '\npack-subcommand: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
