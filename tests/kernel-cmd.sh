#!/bin/sh
# Runs tests/lisp/*.lisp on the BATCH kernel (src/kernel.cmd) inside the Windows
# VM over SSH, diffing stdout against *.out — the cross-host parity check
# (same fixtures, same prelude, must match the sh kernel from tests/kernel.sh).
#
#   PORTSH_WIN_SSH=user@vm-ip sh tests/kernel-cmd.sh
#
# Output is captured to a file in the guest (1>out.txt 2>&1) then read back:
# piping cmd's stdout directly over ssh mis-parses (a known cmd-on-pipe quirk).
set -eu
: "${PORTSH_WIN_SSH:?set PORTSH_WIN_SSH=user@vm-ip (see docs/windows-vm.md)}"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

# ship the kernel once, converted to CRLF (cmd needs it for label lookup)
perl -pe 's/\n/\r\n/' "$root/src/kernel.cmd" > /tmp/portsh-kernel.cmd
scp -q /tmp/portsh-kernel.cmd "$PORTSH_WIN_SSH:portsh-kernel.cmd"

pass=0 fail=0
for prog in "$here"/lisp/*.lisp; do
  [ -e "$prog" ] || continue
  name=$(basename "$prog" .lisp)
  exp=$(cat "$here/lisp/$name.out")
  scp -q "$prog" "$PORTSH_WIN_SSH:$name.lisp"
  ssh "$PORTSH_WIN_SSH" "cmd /c portsh-kernel.cmd $name.lisp 1>out.txt 2>&1"
  got=$(ssh "$PORTSH_WIN_SSH" "type out.txt" | tr -d '\r')
  if [ "$got" = "$exp" ]; then
    printf '\033[32mPASS\033[0m %s -> %s\n' "$name" "$got"; pass=$((pass+1))
  else
    printf '\033[31mFAIL\033[0m %s (expect [%s] got [%s])\n' "$name" "$exp" "$got"; fail=$((fail+1))
  fi
done
printf '\npass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
