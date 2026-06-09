#!/bin/sh
# I/O primitive parity (JIT): the cmd JIT's runtime prims print / read-lines / file-exists?
# (src/runtime.cmd, split into per-entry .cmd files) must produce output BYTE-IDENTICAL to the
# sh JIT's prims (build-{eval,load}-sh.sh DRV) on the same programs. This is the cross-backend
# leg of the record-replay invariant for the I/O surface; parity.sh already covers sh :ev==JIT.
#
# Each top-level expression's VALUE is auto-shown by the loader (so a (print X) line emits X's
# render via print, THEN "()" -- print returns nil). That doubling is identical on both backends,
# so it's fine for a parity diff. read-lines/file-exists? read a fixture file deployed alongside.
# NOTE: read-lines data avoids a literal '!' -- cmd's for/f eats it (a known, separately-tracked
# sh/cmd read-lines divergence, NOT introduced by this prim).
#
# VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP io-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH
[ -f load-sh.sh ] || sh build-load-sh.sh >/dev/null
[ -f comp-cmd/load-cmd.cmd ] || sh build-load-cmd.sh >/dev/null

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# a data file both backends read via read-lines (deployed into each run dir).
printf 'alpha\nbeta\ngamma\n' > "$work/data.txt"

i=0; progs=""
add() { printf '%s' "$1" > "$work/p$i.lisp"; progs="$progs p$i.lisp"; i=$((i+1)); }
add '(print 42)'
add '(print (cons 1 2))'
add '(print (quote hi))'
add '(print (cons 1 (cons 2 (cons 3 nil))))'
add '(print "literal string")'
add '(print (cons (quote a) (cons (cons 1 2) (cons (quote b) nil))))'
add '(read-lines "data.txt")'
add '(print (read-lines "data.txt"))'
add '(file-exists? "data.txt")'
add '(file-exists? "nope.txt")'
add '(read "(a b c)")'
add '(read "42")'
add '(read "(nested (1 2) x)")'
add '(read "hello")'
add '(print (read "(a b c)"))'

# ---- sh JIT (reference): run each program through load-sh.sh, tag blocks. -------------------
# Run load-sh from the work dir so the relative "data.txt" resolves there.
( cd "$work" && for p in $progs; do
    tag=$(printf '%s' "$p" | sed 's/\.lisp$//')
    out=$(mksh "$OLDPWD/load-sh.sh" "$p" 2>&1 || true)
    printf '===%s===\n%s\n' "$tag" "$out"
  done ) > "$work/ref.txt"

# ---- cmd JIT: deploy comp-cmd/ + programs + data.txt; run each through load-cmd.cmd. --------
tar czf "$work/run.tgz" -C comp-cmd . -C "$work" $progs data.txt
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "${VM}:iorun.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist iorun rmdir /s /q iorun) & mkdir iorun & cd iorun & tar -xzf ..\iorun.tgz & del ..\iorun.tgz"' >/dev/null 2>&1
script=""
for p in $progs; do tag=$(printf '%s' "$p" | sed 's/\.lisp$//'); script="$script(echo ===$tag===) & (call load-cmd.cmd $p) & "; done
ssh -n "$VM" "cmd /c \"cd /d %USERPROFILE%\\iorun & ${script}rem done\"" 2>/dev/null | tr -d '\r' > "$work/got.txt"

if diff -u "$work/ref.txt" "$work/got.txt" >/dev/null 2>&1; then
  echo "io-cmd: PASS (cmd JIT print/read-lines/file-exists? == sh JIT, $i programs)"
else
  echo "io-cmd: MISMATCH"; diff -u "$work/ref.txt" "$work/got.txt" | sed 's/^/  /' | head -60
  exit 1
fi
