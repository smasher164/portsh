#!/bin/sh
# Assemble eval-sh.sh -- the eval keystone (sh): eval = compile + run, with comp EMBEDDED in the
# runtime. The runtime IS the native Lisp->sh compiler (comp-sh-compiled.sh) + the trampoline + a
# thin reader/eval loop. No tree-walking interpreter. Each expression is wrapped as a 0-arg thunk,
# compiled in-process by the embedded comp, sourced, and dispatched -> result.
#
#   usage:  mksh eval-sh.sh EXPR.lisp    (EXPR.lisp = ONE Lisp expression) -> prints its value
set -eu
cd "$(dirname "$0")"
[ -f portsh-full.cmd ] || sh build.sh >/dev/null
[ -f src/comp-sh-compiled.sh ] || sh build-comp-sh.sh >/dev/null
[ -f src/prims-aot.sh ] || sh tools/build-prims-aot.sh >/dev/null

{
  # kernel runtime: heap / reader / sentinels / prims (cooked, no REPL, no :ev needed for eval).
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  # the EMBEDDED compiler: compile.lisp's Lisp->sh backend, native (compile_program_sh + deps).
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
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION (unbound global / first-class named fn?)\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            case $CALLEE in
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;;   # closure: label from record, CLO=record
              C:*) CURFN=${CALLEE#C:} ;;                                            # first-class named fn value
              *)   CURFN=$CALLEE ;;
            esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}

# ---- eval keystone: eval(expr) = run(compile((lambda () expr))) ---------------------------
eval_form() {   # $1 = a heap ref to the form to eval
  _tmp=$(mktemp)
  # wrap: build (define __ev (lambda () <expr>)) on the heap, then [that] as a 1-form program.
  hp_cons "$1" NIL;            _body=$R          # (<expr>)
  hp_cons NIL "$_body";        _ll=$R            # (() <expr>)
  hp_cons "S:lambda" "$_ll";   _lam=$R           # (lambda () <expr>)
  hp_cons "$_lam" NIL;         _d3=$R
  hp_cons "S:__ev" "$_d3";     _d2=$R            # (__ev (lambda () <expr>))
  hp_cons "S:define" "$_d2";   _def=$R           # (define __ev (lambda () <expr>))
  hp_cons "$_def" NIL;         _forms=$R         # ((define __ev ...))
  # compile in-process via the embedded comp -> _tmp holds __ev() (+ any lifted __lamN()).
  FP=0; RSP=0; PC=0; CLO=""; F0=$_forms; F1="T:$_tmp"; CURFN=compile_program_sh; drive
  . "$_tmp"                                       # define __ev() in this shell
  # run the thunk.
  FP=0; RSP=0; PC=0; CLO=""; CURFN=__ev; drive
  rm -f "$_tmp"
}

# render a runtime value (I:n -> n, T:str -> str, S:sym -> sym, P:/K: -> as-is) for display.
_relem() { case $1 in NIL) printf nil ;; I:*) printf %s "${1#I:}" ;; T:*) printf %s "${1#T:}" ;; S:*) printf %s "${1#S:}" ;; K:*) printf "<closure>" ;; C:*) printf "<fn:%s>" "${1#C:}" ;; P:*) printf "("; _rlist "$1"; printf ")" ;; *) printf %s "$1" ;; esac; }
_rlist() { hp_car "$1"; _e=$R; _relem "$_e"; hp_cdr "$1"; _t=$R; case ${_t#P:} in "$_t") [ "$_t" = NIL ] || { printf " . "; _relem "$_t"; } ;; *) printf " "; _rlist "$_t" ;; esac; }
show_val() { _relem "$1"; printf "\n"; }

SRC=$(cat "$1"); rd_expr; _expr=$R
eval_form "$_expr"
show_val "$R"
DRV
} > eval-sh.sh
echo "built eval-sh.sh ($(wc -l < eval-sh.sh) lines)"
