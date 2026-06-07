#!/bin/sh
# portsh test harness
# ---------------------------------------------------------------------------
# The whole proposition of portsh is: ONE file behaves correctly when run as a
# POSIX sh script AND when run as a Windows .cmd batch script. So every fixture
# is run *both* ways and diffed against golden output.
#
#   tests/fixtures/NAME.cmd            the polyglot under test
#   tests/fixtures/NAME.sh.expected    expected stdout when run as sh
#   tests/fixtures/NAME.cmd.expected   expected stdout when run as cmd/batch
#
# sh side:  run under EVERY sh we can find (dash/bash/mksh/busybox-ash). A
#           portability bug is precisely "passes under one shell, fails another",
#           so we fan out instead of trusting a single interpreter.
# cmd side: needs a Windows-ish environment. Locally that means Wine; on
#           Apple-Silicon/darwin there is none, so the cmd leg is SKIPPED with a
#           loud notice and the real coverage comes from CI (windows-latest).
# ---------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixtures="$here/fixtures"
work="$here/.work"
rm -rf "$work"; mkdir -p "$work"

pass=0 fail=0 skip=0
red()  { printf '\033[31m%s\033[0m\n' "$1"; }
grn()  { printf '\033[32m%s\033[0m\n' "$1"; }
yel()  { printf '\033[33m%s\033[0m\n' "$1"; }

# Which sh implementations are available right now?
sh_impls=""
for s in dash bash mksh busybox; do
  if command -v "$s" >/dev/null 2>&1; then sh_impls="$sh_impls $s"; fi
done

# How do we run a .cmd as Windows batch on THIS machine?
#   PORTSH_WIN_SSH=user@host -> run on a REAL Windows box/VM over SSH (best
#                               fidelity; e.g. a UTM Win11-ARM VM, see
#                               docs/windows-vm.md).
#   else wine, if present    -> local approximation (Linux only; never on
#                               arm-darwin).
cmd_mode=none
wine_bin=
if [ -n "${PORTSH_WIN_SSH:-}" ]; then cmd_mode=ssh
elif command -v wine64 >/dev/null 2>&1; then cmd_mode=wine; wine_bin=wine64
elif command -v wine   >/dev/null 2>&1; then cmd_mode=wine; wine_bin=wine
fi

# Run one .cmd fixture as Windows batch; capture stdout (CRLF-normalised) to $2.
run_cmd() {
  _fx=$1; _out=$2
  case $cmd_mode in
    wine) "$wine_bin" cmd /c "$_fx" >"$_out" 2>/dev/null || true ;;
    ssh)
      scp -q "$_fx" "$PORTSH_WIN_SSH:portsh_run.cmd" >/dev/null 2>&1 || true
      ssh "$PORTSH_WIN_SSH" "cmd /c portsh_run.cmd" >"$_out" 2>/dev/null || true ;;
  esac
  tr -d '\r' <"$_out" >"$_out.norm" 2>/dev/null && mv "$_out.norm" "$_out" || true
}

run_one() {
  fixture=$1
  name=$(basename "$fixture" .cmd)

  # --- sh leg: run under each available shell -------------------------------
  exp_sh="$fixtures/$name.sh.expected"
  if [ -f "$exp_sh" ]; then
    for s in $sh_impls; do
      runner=$s
      [ "$s" = busybox ] && runner="busybox ash"
      got="$work/$name.$s.out"
      if $runner "$fixture" >"$got" 2>/dev/null; then :; fi
      if diff -u "$exp_sh" "$got" >"$work/$name.$s.diff" 2>&1; then
        grn "PASS  $name [sh:$s]"; pass=$((pass+1))
      else
        red "FAIL  $name [sh:$s]"; sed 's/^/        /' "$work/$name.$s.diff"; fail=$((fail+1))
      fi
    done
  fi

  # --- cmd leg: run as Windows batch, if we have any way to ------------------
  exp_cmd="$fixtures/$name.cmd.expected"
  if [ -f "$exp_cmd" ]; then
    if [ "$cmd_mode" != none ]; then
      got="$work/$name.cmd.out"
      run_cmd "$fixture" "$got"
      if diff -u "$exp_cmd" "$got" >"$work/$name.cmd.diff" 2>&1; then
        grn "PASS  $name [cmd:$cmd_mode]"; pass=$((pass+1))
      else
        red "FAIL  $name [cmd:$cmd_mode]"; sed 's/^/        /' "$work/$name.cmd.diff"; fail=$((fail+1))
      fi
    else
      yel "SKIP  $name [cmd]  (set PORTSH_WIN_SSH=user@host or install wine; CI covers windows-latest)"; skip=$((skip+1))
    fi
  fi
}

printf 'sh impls :%s\n' "${sh_impls:- (none!)}"
printf 'cmd mode : %s%s\n\n' "$cmd_mode" "$([ "$cmd_mode" = ssh ] && printf ' (%s)' "$PORTSH_WIN_SSH")"

for f in "$fixtures"/*.cmd; do
  [ -e "$f" ] || continue
  run_one "$f"
done

# --- cross-shell consistency guard ------------------------------------------
# The polyglot fixtures above re-exec into /bin/sh, so they don't actually test
# multiple shells. cross-shell.sh runs the kernel GENUINELY under every shell
# (cook + PORTSH_COOKED=1) and asserts byte-identical behavior + gc correctness +
# byte-identical compile. This is the regression guard for the no-local /
# explicit-root / FUNCNEST work. Skip with PORTSH_SKIP_XSHELL=1 (it's slower).
if [ -z "${PORTSH_SKIP_XSHELL:-}" ] && [ -f "$here/cross-shell.sh" ]; then
  echo; echo "=== cross-shell consistency guard ==="
  if sh "$here/cross-shell.sh"; then grn "PASS  cross-shell guard"; pass=$((pass+1))
  else red "FAIL  cross-shell guard"; fail=$((fail+1)); fi
fi

# --- native-comp equivalence guard ------------------------------------------
# Native (compiled) comp must produce byte-identical batch output to the interpreter.
# Regression guard for the trampoline codegen (frame framing + value quoting + mangle).
# Skip with PORTSH_SKIP_NATIVE=1 (it builds comp.sh, ~seconds).
if [ -z "${PORTSH_SKIP_NATIVE:-}" ] && [ -f "$here/native-comp.sh" ]; then
  echo; echo "=== native-comp equivalence guard ==="
  if sh "$here/native-comp.sh"; then grn "PASS  native-comp guard"; pass=$((pass+1))
  else red "FAIL  native-comp guard"; fail=$((fail+1)); fi
fi

echo
printf 'pass=%d fail=%d skip=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
