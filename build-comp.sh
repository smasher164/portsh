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

# ---- native comp driver (TRAMPOLINE) ----------------------------------------------------
# Compiled comp functions are resumable segment-machines. This driver loop runs the current
# function for one segment (eval "$CURFN"), which yields back via ACTION + return:
#   call -> push (CURFN,resume-PC,FP) on the return stack, set up callee frame, dispatch callee
#   ret  -> pop the return stack (R holds the value); empty stack -> HALT
#   tail -> self-tail-call: segment already rewrote F[FP..] + reset PC=0; just re-eval
#   jump -> intra-function branch: segment already set PC; just re-eval
# Host stack depth stays 2 (loop + the one eval'd segment) regardless of logical recursion
# depth -- so deep non-tail recursion no longer overflows the host stack (no ulimit needed).
GLOBAL=NIL                            # gc_run marks $GLOBAL; compiled comp ignores the global env
G_DQ='T:"'                            # the (dq) primitive's value, referenced by compiled code
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP"; RSP=$((RSP+1)); FP=$NFP; CURFN=$CALLEE; PC=0 ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP"; fi ;;
      tail|jump) ;;   # CURFN/PC/F already updated by the segment; just re-enter
    esac
  done
}
SRC=$(cat "$1"); rd_expr; _forms=$R
FP=0; F0=$_forms; F1="T:$2"; F2="T:$3"; RSP=0; CURFN=compile_program; PC=0
drive
DRV
} > comp.sh

echo "built comp.sh ($(wc -l < comp.sh) lines)"
