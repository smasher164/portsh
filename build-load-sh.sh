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
[ -f src/prims-aot.sh ] || sh tools/build-prims-aot.sh >/dev/null

{
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-sh-compiled.sh
  cat src/prims-aot.sh                 # primitive value-wrappers (__p_add/__p_cons/... for (foldr + 0 xs))
  cat src/stdlib-aot.sh                # AOT-compiled applicative stdlib (map/foldl/filter/assoc/...)
  cat <<'DRV'

# ---- closure-capable trampoline driver (K:/CLO/RSL) + comp's I/O prims --------------------
GLOBAL=NIL
G_DQ='T:"'
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
# I/O primitives the JIT lacked (script semantics; mirror the interpreter's prim_app).
print()          { _relem "$1"; printf '\n'; R=NIL; }
read_lines()     { _f=${1#T:}; _acc=NIL; while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
                   _rev=NIL; while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev; }
file_existszzQ() { [ -e "${1#T:}" ] && R="S:t" || R=NIL; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION (unbound global / first-class named fn?)\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; C:*) CURFN=${CALLEE#C:} ;; *) CURFN=$CALLEE ;; esac ;;
      apply) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            _ai=0; _ac=$APLIST; while [ "$_ac" != NIL ]; do hp_car "$_ac"; eval "F$((FP+_ai))=\$R"; hp_cdr "$_ac"; _ac=$R; _ai=$((_ai+1)); done
            case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; C:*) CURFN=${CALLEE#C:} ;; *) CURFN=$CALLEE ;; esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}
_relem() { case $1 in NIL) printf "()" ;; I:*) printf %s "${1#I:}" ;; T:*) printf %s "${1#T:}" ;; S:*) printf %s "${1#S:}" ;; K:*) printf "<closure>" ;; C:*) printf "<fn:%s>" "${1#C:}" ;; P:*) printf "("; _rlist "$1"; printf ")" ;; *) printf %s "$1" ;; esac; }
_rlist() { hp_car "$1"; _e=$R; _relem "$_e"; hp_cdr "$1"; _t=$R; case ${_t#P:} in "$_t") [ "$_t" = NIL ] || { printf " . "; _relem "$_t"; } ;; *) printf " "; _rlist "$_t" ;; esac; }
show_val() { _relem "$1"; printf "\n"; }

# ---- loader: partition forms, compile all, source, run thunks in program order -------------------
# Top-level forms are one of: a LAMBDA define -> compiled fn; an ATOM define -> G_<name> constant
# (compiler-emitted); a COMPUTED define (define x EXPR) -> a 0-arg thunk run in order whose result is
# bound to G_<name>; or a bare EXPRESSION -> a thunk run in order whose value is shown. Each thunk
# entry is "<fn>|<action>": S = show value, G:<name> = bind G_<name>. This is what lets compile+run
# stand in for the interpreter on whole programs (computed defines were the last :ev-only gap).
_mkthunk() {   # $1 = body heap-ref, $2 = action (S | G:name)  -> wraps (define __evN (lambda () body))
  hp_cons "$1" NIL;          _b=$R
  hp_cons NIL "$_b";         _ll=$R
  hp_cons "S:lambda" "$_ll"; _lam=$R
  hp_cons "$_lam" NIL;       _d3=$R
  hp_cons "S:__ev$_n" "$_d3"; _d2=$R
  hp_cons "S:define" "$_d2"; _def=$R
  hp_cons "$_def" "$_xf";    _xf=$R
  _thunks="$_thunks __ev$_n=$2"; _n=$((_n+1))   # '=' separator: mksh treats '|' as glob-alternation
}
SRC="($(cat "$1"))"; rd_expr; _forms=$R
_xf=NIL; _thunks=""; _n=0; _cur=$_forms
while [ "$_cur" != NIL ]; do
  hp_car "$_cur"; _form=$R
  hp_cdr "$_cur"; _cur=$R
  _hd=NIL; case $_form in P:*) hp_car "$_form"; _hd=$R ;; esac
  if [ "$_hd" = "S:define" ]; then
    hp_cdr "$_form"; _nv=$R; hp_car "$_nv"; _name=$R       # NAME  (cadr)
    hp_cdr "$_nv"; _vv=$R;   hp_car "$_vv"; _val=$R        # VALUE (caddr)
    case $_val in
      P:*) hp_car "$_val"; _vhd=$R
           if [ "$_vhd" = "S:lambda" ]; then
             hp_cons "$_form" "$_xf"; _xf=$R                # lambda define -> compiled fn
           else
             _mkthunk "$_val" "G:${_name#S:}"              # computed define -> thunk binds G_<name>
           fi ;;
      *)   hp_cons "$_form" "$_xf"; _xf=$R ;;              # atom define -> G_<name> constant
    esac
  else
    _mkthunk "$_form" "S"                                   # bare expression -> thunk, show value
  fi
done
# compile ALL forms (defines + thunk-defines) in-process; source so every fn/const is live.
_tmp=$(mktemp)
FP=0; RSP=0; PC=0; CLO=""; F0=$_xf; F1="T:$_tmp"; CURFN=compile_program_sh; drive
. "$_tmp"
# run each thunk in program order: show expressions, bind computed-define globals.
for _e in $_thunks; do
  _th=${_e%%=*}; _act=${_e#*=}
  FP=0; RSP=0; PC=0; CLO=""; CURFN=$_th; drive
  case $_act in
    S)   show_val "$R" ;;
    G:*) eval "G_${_act#G:}=\$R" ;;
  esac
done
rm -f "$_tmp"
DRV
} > load-sh.sh
echo "built load-sh.sh ($(wc -l < load-sh.sh) lines)"
