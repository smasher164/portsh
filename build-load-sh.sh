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
# write-lines / append-lines are EFFECT-only (file writes) -- in replay the file was already written by
# :ev, so just SUPPRESS the re-write (R=S:t). Live path writes. (replay_take is defined below; fine -- sh
# resolves function calls at call time, not definition time.)
write_lines()  { if replay_take write-lines; then R="S:t"; else _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; fi; }
append_lines() { if replay_take append-lines; then R="S:t"; else _f=${1#T:}; _l=$2; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; fi; }
gc()           { gc_run; R="S:t"; }
# --- record-and-replay: when PORTSH_REPLAY is set the JIT REPLAYS the interpreter's effect log (FD 9)
# --- in execution order -- output ops VERIFY their computed value == the log then SUPPRESS; world ops
# --- RETURN the logged result -- until the log is exhausted, then everything runs LIVE.
RP_ON=0; RP_TAB=$(printf '\t')
replay_init() { [ -n "${PORTSH_REPLAY:-}" ] && { exec 9<"$PORTSH_REPLAY"; RP_ON=1; }; return 0; }
replay_take() {  # $1 = expected op -> 0 replaying (RP_N + RP_PAYLOAD/RP_L* set), 1 live (EOF / off)
  [ "$RP_ON" = 1 ] || return 1
  IFS=$RP_TAB read -r RP_OP RP_N <&9 || { RP_ON=0; return 1; }
  [ "$RP_OP" = "$1" ] || { printf 'replay desync: expected %s got %s\n' "$1" "$RP_OP" >&2; exit 1; }
  rp_i=0; RP_PAYLOAD=
  while [ "$rp_i" -lt "$RP_N" ]; do IFS= read -r rp_l <&9 || rp_l=; eval "RP_L$rp_i=\$rp_l"; [ "$rp_i" = 0 ] && RP_PAYLOAD=$rp_l; rp_i=$((rp_i + 1)); done
  return 0
}
# I/O primitives the JIT lacked (script semantics; mirror prim_app) -- replay-aware.
print()          { if replay_take print; then rp_g=$(_relem "$1"); [ "$rp_g" = "$RP_PAYLOAD" ] || { printf 'replay mismatch print: log[%s] jit[%s]\n' "$RP_PAYLOAD" "$rp_g" >&2; exit 1; }; R=NIL
                   else _relem "$1"; printf '\n'; R=NIL; fi; }
read_lines()     { if replay_take read-lines; then _acc=NIL; rp_i=0
                     while [ "$rp_i" -lt "$RP_N" ]; do eval "rp_v=\$RP_L$rp_i"; hp_cons "T:$rp_v" "$_acc"; _acc=$R; rp_i=$((rp_i + 1)); done
                     _rev=NIL; while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev
                   else _f=${1#T:}; _acc=NIL; while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
                     _rev=NIL; while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev; fi; }
file_existszzQ() { if replay_take file-exists?; then R=$RP_PAYLOAD; else [ -e "${1#T:}" ] && R="S:t" || R=NIL; fi; }
# run / run-capture / read primitives (mirror the interpreter's prim_oper run/run-capture + prim_app
# read). $1 is the joined host command (run/run-capture) or the source string (read_str).
# run / run-capture EXECUTE a host command -- the effects that MUST happen exactly once. In replay
# the command already ran in :ev, so run returns the logged exit code and run-capture rebuilds the
# logged output list -- NEITHER re-executes. Live path runs the command.
run_cmd()     { if replay_take run; then R=$RP_PAYLOAD; else sh -c "$1"; R="I:$?"; fi; }
run_capture() { if replay_take run-capture; then _rc_acc=NIL; rp_i=0
  while [ "$rp_i" -lt "$RP_N" ]; do eval "rp_v=\$RP_L$rp_i"; hp_cons "T:$rp_v" "$_rc_acc"; _rc_acc=$R; rp_i=$((rp_i + 1)); done
  _rc_rev=NIL; while [ "$_rc_acc" != NIL ]; do hp_car "$_rc_acc"; _rc_v=$R; hp_cdr "$_rc_acc"; _rc_acc=$R; hp_cons "$_rc_v" "$_rc_rev"; _rc_rev=$R; done; R=$_rc_rev
else _rc_out=$(sh -c "$1"); _rc_acc=NIL
while IFS= read -r _rc_ln || [ -n "$_rc_ln" ]; do hp_cons "T:$_rc_ln" "$_rc_acc"; _rc_acc=$R; done <<RC_EOF
$_rc_out
RC_EOF
_rc_rev=NIL; while [ "$_rc_acc" != NIL ]; do hp_car "$_rc_acc"; _rc_v=$R; hp_cdr "$_rc_acc"; _rc_acc=$R; hp_cons "$_rc_v" "$_rc_rev"; _rc_rev=$R; done; R=$_rc_rev; fi; }
read_str()    { _rd_save=$SRC; SRC=${1#T:}; rd_expr; _rd_v=$R; SRC=$_rd_save; R=$_rd_v; }
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
replay_init   # arm REPLAY (FD 9) if PORTSH_REPLAY is set, BEFORE the program's effects run
# run each thunk in program order: bind computed-define globals; show bare-expression values UNLESS
# we're in script/replay mode (a real program's only output is its explicit print/write-lines, matching
# the :ev recorder -- which doesn't echo top-level values; the auto-show is just for the parity REPL tests).
for _e in $_thunks; do
  _th=${_e%%=*}; _act=${_e#*=}
  FP=0; RSP=0; PC=0; CLO=""; CURFN=$_th; drive
  case $_act in
    S)   [ -n "${PORTSH_REPLAY:-}${PORTSH_SCRIPT:-}" ] || show_val "$R" ;;
    G:*) eval "G_${_act#G:}=\$R" ;;
  esac
done
rm -f "$_tmp"
DRV
} > load-sh.sh
echo "built load-sh.sh ($(wc -l < load-sh.sh) lines)"
