#!/bin/sh
# run / run-capture parity (cmd): the cmd JIT's operative prims run_cmd.cmd / run_capture.cmd must
# produce output IDENTICAL to the cmd interpreter (:ev) for the same program -- the record-replay
# invariant for the host-command ops. run/run-capture use `cmd /c` (NOT sh -c), so this is a cmd-vs-cmd
# check (sh-JIT differs by design). The JIT auto-prints a top-level expr's value; :ev does not, so the
# :ev program is wrapped in (print ...). For run-capture (value = the list) and run (side-effect output
# + auto-printed exit code) both forms yield the same text, so we diff JIT output vs :ev output directly.
#
# VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP run-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH
[ -f comp-cmd/load-cmd.cmd ] || sh build-load-cmd.sh >/dev/null
[ -f portsh-full.cmd ] || sh build.sh >/dev/null

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# corpus: bare expr -> j<i>.lisp (JIT, auto-print); (print expr) -> e<i>.lisp (:ev).
i=0; tags=""
add() { printf '%s' "$1" > "$work/j$i.lisp"; printf '(print %s)' "$1" > "$work/e$i.lisp"
        tags="$tags $i"; i=$((i+1)); }
add '(run-capture echo hi)'
add '(run-capture echo a b c)'
add '(run echo hi)'
add '(run-capture echo x "&" echo y)'

cp portsh-full.cmd "$work/psf.cmd"
tar czf "$work/run.tgz" -C comp-cmd . -C "$work" $(cd "$work" && ls *.lisp psf.cmd)
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "${VM}:rcrun.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist rcrun rmdir /s /q rcrun) & mkdir rcrun & cd rcrun & tar -xzf ..\rcrun.tgz & del ..\rcrun.tgz"' >/dev/null 2>&1

jscript=""; escript=""
for t in $tags; do
  jscript="$jscript(echo ===t$t===) & (call load-cmd.cmd j$t.lisp) & "
  escript="$escript(echo ===t$t===) & (call psf.cmd e$t.lisp) & "
done
ssh -n "$VM" "cmd /c \"cd /d %USERPROFILE%\\rcrun & ${jscript}rem done\"" 2>/dev/null | tr -d '\r' > "$work/gotj.txt"
ssh -n "$VM" "cmd /c \"cd /d %USERPROFILE%\\rcrun & ${escript}rem done\"" 2>/dev/null | tr -d '\r' > "$work/gote.txt"

if diff -u "$work/gote.txt" "$work/gotj.txt" >/dev/null 2>&1; then
  echo "run-cmd: PASS (cmd JIT run/run-capture == cmd :ev, $i programs)"
  echo "  JIT output:"; sed 's/^/    /' "$work/gotj.txt"
else
  echo "run-cmd: MISMATCH (:ev[-] vs JIT[+])"; diff -u "$work/gote.txt" "$work/gotj.txt" | sed 's/^/  /' | head -50
  exit 1
fi
