#!/bin/sh
# Runs every tests/lisp/NAME.lisp through src/kernel.sh under each available
# shell and diffs stdout against tests/lisp/NAME.out. This is the regression
# net for the interpreter itself (separate from run.sh, which tests the
# sh-vs-cmd polyglot).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
kernel="$root/src/kernel.sh"
work="$here/.work"; rm -rf "$work"; mkdir -p "$work"

impls=""
for s in dash bash mksh busybox; do command -v "$s" >/dev/null 2>&1 && impls="$impls $s"; done

pass=0 fail=0
for prog in "$here"/lisp/*.lisp; do
  [ -e "$prog" ] || continue
  name=$(basename "$prog" .lisp)
  exp="$here/lisp/$name.out"
  for s in $impls; do
    runner=$s; [ "$s" = busybox ] && runner="busybox ash"
    got="$work/$name.$s.out"
    $runner "$kernel" "$prog" >"$got" 2>&1 || true
    if diff -u "$exp" "$got" >"$work/$name.$s.diff" 2>&1; then
      printf '\033[32mPASS\033[0m %s [%s]\n' "$name" "$s"; pass=$((pass+1))
    else
      printf '\033[31mFAIL\033[0m %s [%s]\n' "$name" "$s"; sed 's/^/    /' "$work/$name.$s.diff"; fail=$((fail+1))
    fi
  done
done
printf '\npass=%d fail=%d (shells:%s)\n' "$pass" "$fail" "${impls:- none}"
[ "$fail" -eq 0 ]
