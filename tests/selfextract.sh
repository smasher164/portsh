#!/bin/sh
# Self-extractor round-trip guard: run comp-cmd.selfx.cmd on the VM (pure cmd, no external tools),
# pull the extracted tree back, and diff it byte-for-byte against the reference comp-cmd/. Proves the
# pure-cmd extraction reproduces the runtime exactly, and reports first-run wall-clock. VM-gated.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then echo "SKIP selfextract: set PORTSH_WIN_SSH=user@host"; exit 0; fi
VM=$PORTSH_WIN_SSH
[ -f comp-cmd.selfx.cmd ] || sh tools/pack-comp-cmd.sh >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q comp-cmd.selfx.cmd "${VM}:selfx.cmd"
echo "=== extract on VM (pure cmd, wall-clock) ==="
t0=$(date +%s)
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist psx rmdir /s /q psx) & call selfx.cmd %CD%\psx"' >/dev/null 2>&1
t1=$(date +%s)
echo "  extract wall-clock (incl. ssh round-trip): $((t1 - t0))s"
# content diff FIRST, on the PRISTINE extraction (before any run pollutes it). comp-cmd has MIXED
# endings (per-PC LF, runtime CRLF); normalize BOTH sides to LF.
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE%\psx & tar -czf ..\psx.tgz ."' >/dev/null 2>&1
scp -q "${VM}:psx.tgz" "$work/psx.tgz"
mkdir "$work/psx" "$work/ref"; tar -xzf "$work/psx.tgz" -C "$work/psx"; cp -R comp-cmd/. "$work/ref/"
find "$work/psx" "$work/ref" -type f ! -name .ok -exec perl -i -pe 's/\r$//' {} +
echo "=== content diff (pristine, both sides CR-normalized) ==="
if diff -r -x .ok "$work/psx" "$work/ref" >/dev/null 2>&1; then
  echo "  CONTENT-IDENTICAL ($(ls "$work/psx" | grep -vc '^\.ok$') files reproduced)"
else
  echo "selfextract: MISMATCH"; diff -r -x .ok "$work/psx" "$work/ref" 2>&1 | head -25
  exit 1
fi
# functional check LAST (run eval-cmd FROM the extracted dir -> proves the extracted runtime works;
# this writes t.lisp/elmain.lisp/ph_* into psx, which is why it must come AFTER the content diff).
got=$(ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE%\psx & echo (define __ev (lambda () (foldr + 0 (cons 1 (cons 2 (cons 3 nil))))))> t.lisp & eval-cmd.cmd t.lisp"' 2>&1 | tr -d '\r' | grep -vE '^$' | tail -1)
echo "=== functional: eval-cmd from the extracted runtime: got [$got] (expect 6) ==="
[ "$got" = "6" ] && echo "selfextract: PASS (content-identical + extracted runtime runs)" || { echo "selfextract: FUNCTIONAL FAIL"; exit 1; }
