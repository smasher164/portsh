#!/bin/sh
# Assemble load-sh.sh -- the read->compile->run loader (sh). Generalises the eval keystone to a
# WHOLE PROGRAM: top-level (define ...) forms accumulate into the runtime (compiled to fns) and
# top-level EXPRESSIONS are evaluated in order (each wrapped as a thunk), referencing prior defines.
# eval = compile + run, comp embedded; no tree-walking interpreter.
#
#   usage:  mksh load-sh.sh PROGRAM.lisp   (a sequence of (define ...) forms and expressions)
#           prints the value of each top-level expression in order.
set -eu
cd "$(dirname "$0")"
[ -f portsh-full.cmd ] || sh build.sh >/dev/null
[ -f src/comp-sh-compiled.sh ] || sh build-comp-sh.sh >/dev/null

{
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-sh-compiled.sh
  cat <<'DRV'

# ---- closure-capable trampoline driver (K:/CLO/RSL) + comp's I/O prims --------------------
GLOBAL=NIL
G_DQ='T:"'
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION (unbound global / first-class named fn?)\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; *) CURFN=$CALLEE ;; esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}
show_val() { case $1 in NIL) printf 'nil\n' ;; I:*) printf '%s\n' "${1#I:}" ;; T:*) printf '%s\n' "${1#T:}" ;; S:*) printf '%s\n' "${1#S:}" ;; *) printf '%s\n' "$1" ;; esac; }

# ---- loader: partition forms (defines kept; exprs -> thunks), compile all, source, run thunks ----
SRC="($(cat "$1"))"; rd_expr; _forms=$R
_xf=NIL; _thunks=""; _n=0; _cur=$_forms
while [ "$_cur" != NIL ]; do
  hp_car "$_cur"; _form=$R
  hp_cdr "$_cur"; _cur=$R
  _hd=NIL; case $_form in P:*) hp_car "$_form"; _hd=$R ;; esac
  if [ "$_hd" = "S:define" ]; then
    hp_cons "$_form" "$_xf"; _xf=$R                       # keep the define
  else
    hp_cons "$_form" NIL;          _b=$R                  # wrap expr as (define __evN (lambda () expr))
    hp_cons NIL "$_b";             _ll=$R
    hp_cons "S:lambda" "$_ll";     _lam=$R
    hp_cons "$_lam" NIL;           _d3=$R
    hp_cons "S:__ev$_n" "$_d3";    _d2=$R
    hp_cons "S:define" "$_d2";     _def=$R
    hp_cons "$_def" "$_xf";        _xf=$R
    _thunks="$_thunks __ev$_n"; _n=$((_n+1))
  fi
done
# compile ALL forms (defines + thunk-defines) in-process; source so every fn is live.
_tmp=$(mktemp)
FP=0; RSP=0; PC=0; CLO=""; F0=$_xf; F1="T:$_tmp"; CURFN=compile_program_sh; drive
. "$_tmp"
# run each top-level expression's thunk in program order.
for _th in $_thunks; do
  FP=0; RSP=0; PC=0; CLO=""; CURFN=$_th; drive
  show_val "$R"
done
rm -f "$_tmp"
DRV
} > load-sh.sh
echo "built load-sh.sh ($(wc -l < load-sh.sh) lines)"
