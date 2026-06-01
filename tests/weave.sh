#!/bin/sh
# Builds portsh.cmd and runs every fixture through it AS A SH SCRIPT (dash) —
# a fast, local regression guard for the weave (the re-exec/CR-strip header and
# the heredoc dispatch). The cmd side of the same woven file is covered by
# tests/kernel-cmd.sh on the Windows VM.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
sh "$root/build.sh" >/dev/null

runner=dash; command -v dash >/dev/null 2>&1 || runner=sh
pass=0 fail=0
for prog in "$here"/lisp/*.lisp; do
  [ -e "$prog" ] || continue
  name=$(basename "$prog" .lisp)
  exp=$(cat "$here/lisp/$name.out")
  got=$($runner "$root/portsh.cmd" "$prog")
  if [ "$got" = "$exp" ]; then
    printf '\033[32mPASS\033[0m %s -> %s\n' "$name" "$got"; pass=$((pass+1))
  else
    printf '\033[31mFAIL\033[0m %s (expect [%s] got [%s])\n' "$name" "$exp" "$got"; fail=$((fail+1))
  fi
done
printf '\npass=%d fail=%d (woven portsh.cmd as %s)\n' "$pass" "$fail" "$runner"
[ "$fail" -eq 0 ]
