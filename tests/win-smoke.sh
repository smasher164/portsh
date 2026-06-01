#!/bin/sh
# Proves the whole CLI test pipeline end-to-end: copy a bare batch file into
# the Windows VM over SSH, run it under real cmd.exe, read stdout back.
#
#   PORTSH_WIN_SSH=user@vm-ip sh tests/win-smoke.sh
set -eu
: "${PORTSH_WIN_SSH:?set PORTSH_WIN_SSH=user@vm-ip (see docs/windows-vm.md)}"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

echo "ssh target: $PORTSH_WIN_SSH"
scp -q "$here/smoke/hello-win.cmd" "$PORTSH_WIN_SSH:portsh-smoke.cmd"
out=$(ssh "$PORTSH_WIN_SSH" "cmd /c portsh-smoke.cmd" | tr -d '\r')
printf -- '--- cmd.exe output ---\n%s\n----------------------\n' "$out"
if printf '%s\n' "$out" | grep -q 'portsh-vm-smoke-ok'; then
  echo "PIPELINE OK — we can run batch tests via the CLI."
else
  echo "PIPELINE FAIL — got unexpected output above."; exit 1
fi
