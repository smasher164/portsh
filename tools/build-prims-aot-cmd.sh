#!/bin/sh
# Compile src/prims.lisp (value-position primitive wrappers __p_add/__p_cons/...) to NATIVE cmd
# per-PC .cmd files and install into comp-cmd/, so value-position primitives ((foldr + 0 xs)) resolve
# to C:__p_<op> at runtime. The cmd analog of tools/build-prims-aot.sh. The wrappers have no inline
# lambdas (no __lam lifting -> no namespacing). Consts (content-named) append to _consts_std.cmd, which
# eval-cmd/load-cmd already `call` at boot. Run AFTER build-comp-cmd.sh (and after build-stdlib-aot-cmd.sh
# if used) -- it adds to comp-cmd/, it doesn't regenerate it.
set -eu
cd "$(dirname "$0")/.."
[ -f comp.sh ] || sh build-comp.sh >/dev/null
[ -d comp-cmd ] || sh build-comp-cmd.sh >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
{ printf '('; cat src/prims.lisp; printf ')'; } > "$work/p.lisp"
mkdir "$work/out"
env NURSERY=999999999 mksh comp.sh "$work/p.lisp" "$work/out" "$work/out/main.lisp"
rm -f "$work/out/main.lisp"
# merge consts into _consts_std.cmd (content-named -> idempotent); install fn files.
if [ -f "$work/out/_consts.cmd" ]; then cat "$work/out/_consts.cmd" >> comp-cmd/_consts_std.cmd; rm -f "$work/out/_consts.cmd"; fi
[ -f comp-cmd/_consts_std.cmd ] || : > comp-cmd/_consts_std.cmd
cp "$work/out"/*.cmd comp-cmd/ 2>/dev/null || true
# append to the runtime manifest (see build-stdlib-aot-cmd.sh, which creates it)
{ [ -f comp-cmd/_rt.lst ] && cat comp-cmd/_rt.lst; ls "$work/out" 2>/dev/null; } | sort -u > comp-cmd/_rt.lst.tmp
mv comp-cmd/_rt.lst.tmp comp-cmd/_rt.lst
echo "installed prims into comp-cmd/ ($(ls "$work/out"/*.cmd 2>/dev/null | wc -l | tr -d ' ') .cmd files)"
