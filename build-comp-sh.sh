#!/bin/sh
# Assemble comp-sh.sh — the NATIVE (compiled) Lisp->sh compiler, the sh-emitter analog of
# build-comp.sh (which builds comp.sh, the Lisp->batch compiler).
#
# WHY: comp-compiled.sh (comp.sh's core) is the Lisp->batch compiler expressed in sh, produced
# by compiling compile.lisp with the Lisp->sh backend (compile-sh.lisp). But compile-sh.lisp was
# only ever run INTERPRETED (in tools/bootstrap-comp.sh) -> every comp-compiled.sh rebuild ate a
# ~30-min interpreted compile. This builds the missing rung of the tower: compile-sh.lisp
# self-hosted to native sh. Then comp-sh.sh compiles compile.lisp -> comp-compiled.sh in SECONDS.
#
#   usage:  mksh comp-sh.sh INPUT.lisp OUTPUT.sh
#           INPUT.lisp = ONE parenthesised list of (define ...) forms; writes native-sh to OUTPUT.sh.
#
# The one-time interpreted self-compile of compile-sh.lisp -> src/comp-sh-compiled.sh is done by
# tools/bootstrap-comp.sh (parameterized: SRC=compile-sh.lisp, DEPS="" since it's self-contained).
# Pass FORCE=1 to redo it; otherwise a checked-in/cached comp-sh-compiled.sh is reused.
set -eu
cd "$(dirname "$0")"

[ -f portsh-full.cmd ] || sh build.sh >/dev/null

if [ ! -f src/comp-sh-compiled.sh ] || [ -n "${FORCE:-}" ]; then
  echo "self-compiling compile-sh.lisp -> src/comp-sh-compiled.sh (one-time, interpreted ~30min)..."
  SRC=src/compile-sh.lisp OUT=src/comp-sh-compiled.sh DEPS="" sh tools/bootstrap-comp.sh
fi

{
  # Kernel runtime: cooked polyglot, line 2 .. before `main "$@"` (every kernel fn + init, no REPL).
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-sh-compiled.sh
  cat <<'DRV'

# ---- native sh-emitter driver (TRAMPOLINE; identical to comp.sh's) ----------------------
GLOBAL=NIL
G_DQ='T:"'
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP"; RSP=$((RSP+1)); FP=$NFP; CURFN=$CALLEE; PC=0 ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}
# entry: compile-program-sh(forms, "T:<outfile>") -> writes native sh to <outfile>.
SRC=$(cat "$1"); rd_expr; _forms=$R
FP=0; F0=$_forms; F1="T:$2"; RSP=0; CURFN=compile_program_sh; PC=0
drive
DRV
} > comp-sh.sh

echo "built comp-sh.sh ($(wc -l < comp-sh.sh) lines)"
