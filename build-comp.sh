#!/bin/sh
# Assemble comp.sh — the NATIVE (compiled) portsh Lisp->batch compiler.
#
# comp.sh = the portsh kernel runtime (heap/reader/gc, minus the REPL) + comp compiled
# to native sh (src/comp-compiled.sh) + a thin driver. It compiles a Lisp program to
# batch ~100x faster than interpreting src/compile.lisp on the kernel, because it runs
# native sh functions instead of the tree-walker.
#
#   usage:  mksh comp.sh INPUT.lisp OUTDIR MAINFILE
#           INPUT.lisp = ONE parenthesised list of (define ...) forms.
#           writes <label>.cmd per compiled fn + _consts.cmd into OUTDIR, residual to MAINFILE.
#
# src/comp-compiled.sh is the bootstrap output; regenerate it with tools/bootstrap-comp.sh
# (the ~15-min self-compile) only when src/compile.lisp or src/compile-sh.lisp change.
set -eu
cd "$(dirname "$0")"

[ -f portsh-full.cmd ] || sh build.sh >/dev/null

{
  # Kernel runtime: cooked polyglot (CR-stripped) from line 2 (drop the sh re-exec guard so
  # comp.sh runs directly, no PORTSH_COOKED needed) up to — but not including — `main "$@"`.
  # That yields every kernel function + the top-level init, without the interpreter REPL.
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-compiled.sh
  cat <<'DRV'

# ---- native comp driver ----------------------------------------------------------------
ulimit -s 65500 2>/dev/null || true   # deep non-tail recursion is host-stack-bound (Phase 2: trampoline)
GLOBAL=NIL                            # gc_run marks $GLOBAL; compiled comp ignores the global env
G_DQ='T:"'                            # the (dq) primitive's value, referenced by compiled code
SP=0                                  # caller-save / frame-mirror stack pointer (gc roots = STK0..SP-1)
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
SRC=$(cat "$1"); rd_expr; _forms=$R
compile_program "$_forms" "T:$2" "T:$3"
DRV
} > comp.sh

echo "built comp.sh ($(wc -l < comp.sh) lines)"
