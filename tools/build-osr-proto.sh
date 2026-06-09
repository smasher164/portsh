#!/bin/sh
# P0 prototype for the OSR substrate-unification (memory: portsh-osr-substrate-unification).
# Proves the core mechanic: ONE trampoline driver runs TWO executors -- a COMPILED fn (dbl) and an
# INTERPRETED fn (sumdbl, via a resumable control+value-stack interpreter) -- that call each other and
# share frames/RS/heap, with the interpreted fn recursing DEEPLY with no host-stack overflow.
# Assembles osr-proto.sh = kernel sh-half (heap + reader) + the unified driver + dbl + interp() + test.
set -eu
cd "$(dirname "$0")/.."
[ -f portsh-full.cmd ] || sh build.sh >/dev/null

{
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat <<'PROTO'

# ============================ OSR P0 prototype ============================
# Conventions shared with the JIT: FP frame base, F<n> frame slots, R result, CURFN current fn,
# PC resume point, CALLEE (C:<label> compiled | I:<id> interpret), NFP callee frame base, RPC resume,
# RS* return stack. NEW: ICUR = id of the AST being interpreted; RSI<n> saves it across calls.

# ---- the unified driver: dispatch CURFN; C:<label> -> compiled, I:<id> -> interp(this AST) ----
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO; RSI$RSP=\$ICUR"; RSP=$((RSP+1))
            FP=$NFP; PC=0; CLO=""; ICUR=""
            case $CALLEE in
              C:*) CURFN=${CALLEE#C:} ;;
              I:*) CURFN=interp; ICUR=${CALLEE#I:} ;;
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;;
              *)   CURFN=$CALLEE ;;
            esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP; ICUR=\$RSI$RSP"; fi ;;
    esac
  done
}

# ---- COMPILED executor: dbl = (lambda (x) (* x 2)) (hand-placed; identical to comp output) ----
SIZE_dbl=1
dbl() {
  eval "p0=\"\$F$((FP+0))\""
  FTOP=$((FP + SIZE_dbl))
  NP=1
  case $PC in
    0) sht0="I:$(( ${p0#??} * 2 ))"; R="${sht0}"; ACTION=ret; return ;;
  esac
}

# ---- INTERPRETED executor: a resumable control+value-stack machine -------------------------------
# State per activation: ICS (control stack) + IVS (value stack), both heap lists. Frame layout:
# F[FP+0..NP-1] = params; F[FP+NP] = saved ICS; F[FP+NP+1] = saved IVS (so they survive nested calls).
# Tasks (heap cells): (S:EVAL . expr) | (S:IFK . (then . else)) | (S:PRIMK . (op . n)) | (S:CALLK . (fval . n)).
# Two PCs only: 0 = fresh (ICS=(EVAL body), IVS=nil); 1 = resume (reload ICS/IVS, push R as the call value)
# -- the whole continuation lives in ICS/IVS, not in PC.
ips() { hp_cons "$1" "$IVS"; IVS=$R; }                 # value push
ics() { hp_cons "$1" "$ICS"; ICS=$R; }                 # control push
ilam_body() { eval "R=\$ILAM_${ICUR}_body"; }          # this lambda's body AST
ilam_np()   { eval "R=\$ILAM_${ICUR}_np"; }            # this lambda's param count
# resolve a symbol operator to a fn-value: dbl -> C:dbl (compiled), else I:<that name> (interpreted)
ifval() { case $1 in S:dbl) R="C:dbl" ;; *) R="I:${1#S:}" ;; esac; }
# slot of a param symbol (proto: single param 'n' -> slot 0; general pmap is P1)
islot() { R=0; }
interp() {
  ip_ret=$R                                            # SAVE the incoming call result before ilam_np clobbers R
  ilam_np; NP=$R
  FTOP=$((FP + NP + 2))
  if [ "$PC" = 0 ]; then
    ilam_body; ip_b=$R; ICS=NIL; IVS=NIL; hp_cons "S:EVAL" "$ip_b"; ics "$R"   # ICS = list of ONE EVAL task
  else
    eval "ICS=\$F$((FP+NP)); IVS=\$F$((FP+NP+1))"      # restore saved stacks
    ips "$ip_ret"                                       # push the just-returned call value
  fi
  # run the machine until it yields at a call or the control stack drains
  while [ "$ICS" != NIL ]; do
    hp_car "$ICS"; ip_t=$R; hp_cdr "$ICS"; ICS=$R       # pop a task
    hp_car "$ip_t"; ip_tag=$R; hp_cdr "$ip_t"; ip_pl=$R
    case $ip_tag in
      S:EVAL)
        case $ip_pl in
          I:*|T:*) ips "$ip_pl" ;;                       # literal
          S:*) islot; eval "ips \"\$F$((FP+R))\"" ;;      # variable -> frame slot
          P:*)                                            # compound: special form / prim / call
            hp_car "$ip_pl"; ip_h=$R
            hp_cdr "$ip_pl"; ip_rest=$R                   # the args/operands
            case $ip_h in
              S:if)
                hp_car "$ip_rest"; ip_c=$R; hp_cdr "$ip_rest"; ip_r2=$R
                hp_car "$ip_r2"; ip_then=$R; hp_cdr "$ip_r2"; ip_r3=$R; hp_car "$ip_r3"; ip_else=$R
                hp_cons "$ip_then" "$ip_else"; ip_te=$R; hp_cons "S:IFK" "$ip_te"; ics "$R"
                hp_cons "S:EVAL" "$ip_c"; ics "$R" ;;     # eval cond first (on top)
              S:+|S:-|'S:*'|S:eq?)
                ilen "$ip_rest"; ip_n=$R
                # PRIMK task = (S:PRIMK op n)
                hp_cons "I:$ip_n" "NIL"; ip_pn=$R; hp_cons "$ip_h" "$ip_pn"; ip_pk=$R
                hp_cons "S:PRIMK" "$ip_pk"; ics "$R"
                ipush_args "$ip_rest" ;;
              *)                                          # function call
                ifval "$ip_h"; ip_fv=$R
                ilen "$ip_rest"; ip_n=$R
                hp_cons "I:$ip_n" "NIL"; ip_cn=$R; hp_cons "T:$ip_fv" "$ip_cn"; ip_ck=$R
                hp_cons "S:CALLK" "$ip_ck"; ics "$R"
                ipush_args "$ip_rest" ;;
            esac ;;
        esac ;;
      S:IFK)
        hp_car "$IVS"; ip_cv=$R; hp_cdr "$IVS"; IVS=$R     # pop cond
        hp_car "$ip_pl"; ip_then=$R; hp_cdr "$ip_pl"; ip_else=$R
        if [ "$ip_cv" = NIL ]; then hp_cons "S:EVAL" "$ip_else"; ics "$R"
        else hp_cons "S:EVAL" "$ip_then"; ics "$R"; fi ;;
      S:PRIMK)
        hp_car "$ip_pl"; ip_op=$R; hp_cdr "$ip_pl"; hp_car "$R"; ip_n=${R#I:}
        ipop_n "$ip_n"                                    # ip_args = (a b ...) in source order
        iprim "$ip_op" ;;
      S:CALLK)
        hp_car "$ip_pl"; ip_fv=${R#T:}; hp_cdr "$ip_pl"; hp_car "$R"; ip_n=${R#I:}
        ipop_n "$ip_n"                                    # ip_args in source order
        NFP=$FTOP
        ip_i=0; ip_a=$ip_args
        while [ "$ip_a" != NIL ]; do hp_car "$ip_a"; eval "F$((NFP+ip_i))=\$R"; hp_cdr "$ip_a"; ip_a=$R; ip_i=$((ip_i+1)); done
        eval "F$((FP+NP))=\$ICS; F$((FP+NP+1))=\$IVS"     # save stacks into frame
        CALLEE=$ip_fv; RPC=1; ACTION=call; return ;;
    esac
  done
  hp_car "$IVS"; R=$R; ACTION=ret; return                # control drained: result = top of value stack
}
# ilen: length of a heap list
ilen() { il_n=0; il_l=$1; while [ "$il_l" != NIL ]; do il_n=$((il_n+1)); hp_cdr "$il_l"; il_l=$R; done; R=$il_n; }
# ipush_args: push (S:EVAL arg) for each arg in REVERSE so leftmost ends up on top (eval'd first)
ipush_args() {
  ia_rev=NIL; ia_l=$1
  while [ "$ia_l" != NIL ]; do hp_car "$ia_l"; hp_cons "$R" "$ia_rev"; ia_rev=$R; hp_cdr "$ia_l"; ia_l=$R; done
  # ia_rev is reversed; push EVAL tasks from it -> original-order args end up top-first
  while [ "$ia_rev" != NIL ]; do hp_car "$ia_rev"; hp_cons "S:EVAL" "$R"; ics "$R"; hp_cdr "$ia_rev"; ia_rev=$R; done
}
# ipop_n: pop n values off IVS into ip_args, in source order (pop reverses, cons reverses back)
ipop_n() {
  ip_args=NIL; ip_k=$1
  while [ "$ip_k" -gt 0 ]; do hp_car "$IVS"; ip_v=$R; hp_cdr "$IVS"; IVS=$R; hp_cons "$ip_v" "$ip_args"; ip_args=$R; ip_k=$((ip_k-1)); done
}
# iprim: apply op to ip_args (a b), push result. proto subset: + - * eq?
iprim() {
  hp_car "$ip_args"; ipa=$R; hp_cdr "$ip_args"; hp_car "$R"; ipb=$R
  case $1 in
    S:+)    ips "I:$(( ${ipa#??} + ${ipb#??} ))" ;;
    S:-)    ips "I:$(( ${ipa#??} - ${ipb#??} ))" ;;
    'S:*')  ips "I:$(( ${ipa#??} * ${ipb#??} ))" ;;
    S:eq?)  if [ "$ipa" = "$ipb" ]; then ips "S:t"; else ips "NIL"; fi ;;
  esac
}

# ---- test: sumdbl = (lambda (n) (if (eq? n 0) 0 (+ (dbl n) (sumdbl (- n 1))))) interpreted ----
GLOBAL=NIL
SRC="(if (eq? n 0) 0 (+ (dbl n) (sumdbl (- n 1))))"; rd_expr; ILAM_sumdbl_body=$R; ILAM_sumdbl_np=1
run_sumdbl() {  # $1 = n -> sum of dbl(k) for k=1..n = n(n+1)
  FP=0; RSP=0; PC=0; CLO=""; ICUR="sumdbl"; CURFN=interp; F0="I:$1"; drive; printf '%s\n' "${R#I:}"
}
printf 'sumdbl 5   (want 30):      '; run_sumdbl 5
printf 'sumdbl 100 (want 10100):   '; run_sumdbl 100
printf 'sumdbl 2000 (deep; want 4002000): '; run_sumdbl 2000
PROTO
} > osr-proto.sh
echo "built osr-proto.sh ($(wc -l < osr-proto.sh) lines)"
