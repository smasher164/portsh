#!/bin/sh
# P1 (OSR substrate-unification): the full resumable interpreter, standalone, on the trampoline.
# Generalises the P0 prototype to real programs: a loader lifts (via the embedded comp) + registers each
# fn's body/layout, then the resumable control+value-stack machine interprets, with full symbol
# resolution (local frame-slot / global-fn I:<name> / global-var value), computed operators, closures
# (make-closure create + clambda capture-load + K: dispatch), and the core prim set. Forms covered this
# increment: literal, var, if, begin, quote, make-closure, application, prims. let/cond/desugared forms +
# I/O prims + compiled-fn interop (P0) + kernel integration come next. Validate vs load-sh.sh.
#   usage: mksh interp-sh.sh PROGRAM.lisp   (prints each top-level expression's value, like load-sh)
set -eu
cd "$(dirname "$0")/.."
[ -f portsh-full.cmd ] || sh build.sh >/dev/null
[ -f src/comp-sh-compiled.sh ] || sh build-comp-sh.sh >/dev/null

{
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-sh-compiled.sh        # the comp -- we reuse lift_program (compiled) via the shared driver
  cat <<'INTERP'

# ===================== P1 resumable interpreter on the trampoline =====================
GLOBAL=NIL
# ---- unified driver: C:<label> compiled | I:<id> interpret | K:<idx> closure (route by label) ----
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
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; _lbl=${R#S:}; CLO=$_ri
                   if eval "[ -n \"\${ILAM_${_lbl}_body+x}\" ]"; then CURFN=interp; ICUR=$_lbl; else CURFN=$_lbl; fi ;;
              *)   CURFN=$CALLEE ;;
            esac ;;
      apply) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO; RSI$RSP=\$ICUR"; RSP=$((RSP+1))
            FP=$NFP; PC=0; CLO=""; ICUR=""
            _ai=0; _ac=$APLIST; while [ "$_ac" != NIL ]; do hp_car "$_ac"; eval "F$((FP+_ai))=\$R"; hp_cdr "$_ac"; _ac=$R; _ai=$((_ai+1)); done
            case $CALLEE in C:*) CURFN=${CALLEE#C:} ;; I:*) CURFN=interp; ICUR=${CALLEE#I:} ;; K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; *) CURFN=$CALLEE ;; esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP; ICUR=\$RSI$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}

# ---- interpreter helpers --------------------------------------------------------------------------
ips() { hp_cons "$1" "$IVS"; IVS=$R; }
ics() { hp_cons "$1" "$ICS"; ICS=$R; }
ilen() { il_n=0; il_l=$1; while [ "$il_l" != NIL ]; do il_n=$((il_n+1)); hp_cdr "$il_l"; il_l=$R; done; R=$il_n; }
# iresolve S:name -> R = value: local frame slot | global-fn I:<name> | global-var G_<name> value
iresolve() {
  ir_v=${1#S:}
  ir_s=$SCOPE                                           # let-bound vars (innermost first) shadow params
  while [ "$ir_s" != NIL ]; do
    hp_car "$ir_s"; ir_p=$R; hp_car "$ir_p"; [ "${R#S:}" = "$ir_v" ] && { hp_cdr "$ir_p"; eval "R=\$F$((FP+${R#I:}))"; return; }
    hp_cdr "$ir_s"; ir_s=$R
  done
  eval "ir_l=\${ILAM_${ICUR}_vars:-}"; ir_i=0; ir_hit=  # params + captures (static)
  for ir_w in $ir_l; do [ "$ir_w" = "$ir_v" ] && { ir_hit=$ir_i; break; }; ir_i=$((ir_i+1)); done
  if [ -n "$ir_hit" ]; then eval "R=\$F$((FP+ir_hit))"; return; fi
  case " $GFNS " in *" $ir_v "*) R="I:$ir_v"; return ;; esac   # global fn
  eval "R=\${G_${ir_v}:-NIL}"                           # global var
}
isprim() { case $1 in S:car|S:cdr|S:cons|S:null?|S:pair?|S:atom?|S:number?|S:+|S:-|'S:*'|'S:<'|S:=|S:eq?) return 0 ;; *) return 1 ;; esac; }
# push (S:EVAL arg) for each arg in REVERSE so leftmost is on top (eval'd first)
ipush_args() {
  ia_rev=NIL; ia_l=$1
  while [ "$ia_l" != NIL ]; do hp_car "$ia_l"; hp_cons "$R" "$ia_rev"; ia_rev=$R; hp_cdr "$ia_l"; ia_l=$R; done
  while [ "$ia_rev" != NIL ]; do hp_car "$ia_rev"; hp_cons "S:EVAL" "$R"; ics "$R"; hp_cdr "$ia_rev"; ia_rev=$R; done
}
ipop_n() {  # pop n values off IVS into ip_args (source order)
  ip_args=NIL; ip_k=$1
  while [ "$ip_k" -gt 0 ]; do hp_car "$IVS"; ip_v=$R; hp_cdr "$IVS"; IVS=$R; hp_cons "$ip_v" "$ip_args"; ip_args=$R; ip_k=$((ip_k-1)); done
}
iprim() {  # apply prim $1 to ip_args (1 or 2 values); push result
  hp_car "$ip_args"; ipa=$R
  case $1 in
    S:car) hp_car "$ipa"; ips "$R" ;;
    S:cdr) hp_cdr "$ipa"; ips "$R" ;;
    S:null?) [ "$ipa" = NIL ] && ips "S:t" || ips "NIL" ;;
    S:pair?) case $ipa in P:*) ips "S:t" ;; *) ips "NIL" ;; esac ;;
    S:atom?) case $ipa in P:*) ips "NIL" ;; *) ips "S:t" ;; esac ;;
    S:number?) case $ipa in I:*) ips "S:t" ;; *) ips "NIL" ;; esac ;;
    *) hp_cdr "$ip_args"; hp_car "$R"; ipb=$R
       case $1 in
         S:+)    ips "I:$(( ${ipa#??} + ${ipb#??} ))" ;;
         S:-)    ips "I:$(( ${ipa#??} - ${ipb#??} ))" ;;
         'S:*')  ips "I:$(( ${ipa#??} * ${ipb#??} ))" ;;
         'S:<')  [ "${ipa#??}" -lt "${ipb#??}" ] && ips "S:t" || ips "NIL" ;;
         S:=)    [ "${ipa#??}" = "${ipb#??}" ] && ips "S:t" || ips "NIL" ;;
         S:eq?)  [ "$ipa" = "$ipb" ] && ips "S:t" || ips "NIL" ;;
         S:cons) hp_cons "$ipa" "$ipb"; ips "$R" ;;
       esac ;;
  esac
}

# ---- the interpreter executor (resumable; PC 0 = fresh, 1 = resume-after-call) --------------------
interp() {
  ip_ret=$R                                            # save incoming call result before clobbering R
  eval "NP=\$ILAM_${ICUR}_np; ip_nc=\${ILAM_${ICUR}_ncap:-0}"
  if [ "$PC" = 0 ]; then
    ITOP=$((NP + ip_nc)); [ "$ITOP" -ge 1 ] || ITOP=1  # >=1 so NFP=FP+ITOP > FP: frame bases (and the
    SCOPE=NIL                                          # per-activation IS*_<FP> state) stay strictly distinct
    if [ "$ip_nc" -gt 0 ]; then                        # clambda: load captures from the record (CLO)
      hp_cdr "P:$CLO"; ld_l=$R; ld_i=$NP
      while [ "$ld_l" != NIL ]; do hp_car "$ld_l"; eval "F$((FP+ld_i))=\$R"; hp_cdr "$ld_l"; ld_l=$R; ld_i=$((ld_i+1)); done
    fi
    eval "ip_b=\$ILAM_${ICUR}_body"; ICS=NIL; IVS=NIL; hp_cons "S:EVAL" "$ip_b"; ics "$R"
  else                                                 # resume: per-activation state lives in IS*_<FP> globals
    eval "ICS=\$ISCS_$FP; IVS=\$ISVS_$FP; SCOPE=\$ISSCOPE_$FP; ITOP=\$ISTOP_$FP"
    ips "$ip_ret"
  fi
  while [ "$ICS" != NIL ]; do
    hp_car "$ICS"; ip_t=$R; hp_cdr "$ICS"; ICS=$R
    hp_car "$ip_t"; ip_tag=$R; hp_cdr "$ip_t"; ip_pl=$R
    case $ip_tag in
      S:EVAL)
        case $ip_pl in
          I:*|T:*) ips "$ip_pl" ;;
          S:nil) ips "NIL" ;;
          S:t) ips "S:t" ;;
          S:*) iresolve "$ip_pl"; ips "$R" ;;
          P:*)
            hp_car "$ip_pl"; ip_h=$R; hp_cdr "$ip_pl"; ip_rest=$R
            case $ip_h in
              S:quote) hp_car "$ip_rest"; ips "$R" ;;
              S:if)
                hp_car "$ip_rest"; ip_c=$R; hp_cdr "$ip_rest"; ip_r2=$R
                hp_car "$ip_r2"; ip_then=$R; hp_cdr "$ip_r2"; hp_car "$R"; ip_else=$R
                hp_cons "$ip_then" "$ip_else"; ip_te=$R; hp_cons "S:IFK" "$ip_te"; ics "$R"
                hp_cons "S:EVAL" "$ip_c"; ics "$R" ;;
              S:begin)                                   # eval each expr; discard all but the last
                bg_rev=NIL; bg_l=$ip_rest
                while [ "$bg_l" != NIL ]; do hp_car "$bg_l"; hp_cons "$R" "$bg_rev"; bg_rev=$R; hp_cdr "$bg_l"; bg_l=$R; done
                bg_first=1
                while [ "$bg_rev" != NIL ]; do
                  hp_car "$bg_rev"; bg_e=$R; hp_cdr "$bg_rev"; bg_rev=$R
                  [ "$bg_first" = 1 ] || { hp_cons "S:POPK" "NIL"; ics "$R"; }
                  hp_cons "S:EVAL" "$bg_e"; ics "$R"; bg_first=0
                done ;;
              S:let)                                     # sequential (let*-style) binding, matching the comp's lbinds
                hp_car "$ip_rest"; lt_binds=$R; hp_cdr "$ip_rest"; hp_car "$R"; lt_body=$R
                hp_cons "S:LETK" "$SCOPE"; ics "$R"       # LETK restores the pre-let scope after the body
                hp_cons "S:EVAL" "$lt_body"; ics "$R"
                lt_rev=NIL; lt_l=$lt_binds
                while [ "$lt_l" != NIL ]; do hp_car "$lt_l"; hp_cons "$R" "$lt_rev"; lt_rev=$R; hp_cdr "$lt_l"; lt_l=$R; done
                while [ "$lt_rev" != NIL ]; do
                  hp_car "$lt_rev"; lt_b=$R; hp_cdr "$lt_rev"; lt_rev=$R
                  hp_car "$lt_b"; lt_nm=$R; hp_cdr "$lt_b"; hp_car "$R"; lt_v=$R
                  hp_cons "S:BINDK" "$lt_nm"; ics "$R"
                  hp_cons "S:EVAL" "$lt_v"; ics "$R"
                done ;;
              S:cond)                                    # (cond (c e)...): eval c, CONDK picks e or recurses on the rest
                if [ "$ip_rest" = NIL ]; then ips "NIL"
                else
                  hp_car "$ip_rest"; cd_cl=$R; hp_cdr "$ip_rest"; cd_rest=$R
                  hp_car "$cd_cl"; cd_c=$R; hp_cdr "$cd_cl"; hp_car "$R"; cd_e=$R
                  hp_cons "$cd_e" "$cd_rest"; hp_cons "S:CONDK" "$R"; ics "$R"
                  hp_cons "S:EVAL" "$cd_c"; ics "$R"
                fi ;;
              S:make-closure)
                hp_car "$ip_rest"; hp_cdr "$R"; hp_car "$R"; mc_lbl=$R   # (quote __lamN) -> __lamN
                hp_cdr "$ip_rest"; mc_caps=$R
                mc_acc=NIL
                while [ "$mc_caps" != NIL ]; do hp_car "$mc_caps"; case $R in S:*) iresolve "$R" ;; esac; hp_cons "$R" "$mc_acc"; mc_acc=$R; hp_cdr "$mc_caps"; mc_caps=$R; done
                mc_rev=NIL; while [ "$mc_acc" != NIL ]; do hp_car "$mc_acc"; hp_cons "$R" "$mc_rev"; mc_rev=$R; hp_cdr "$mc_acc"; mc_acc=$R; done
                hp_cons "$mc_lbl" "$mc_rev"; ips "K:${R#P:}" ;;
              *)
                if isprim "$ip_h"; then
                  ilen "$ip_rest"; ip_n=$R
                  hp_cons "I:$ip_n" "NIL"; ip_pn=$R; hp_cons "$ip_h" "$ip_pn"; hp_cons "S:PRIMK" "$R"; ics "$R"
                  ipush_args "$ip_rest"
                else                                     # general call: eval operator + args, then CALLK
                  ilen "$ip_rest"; ip_n=$R
                  hp_cons "S:CALLK" "I:$ip_n"; ics "$R"
                  ipush_args "$ip_rest"
                  hp_cons "S:EVAL" "$ip_h"; ics "$R"     # operator on top -> eval'd first
                fi ;;
            esac ;;
        esac ;;
      S:IFK)
        hp_car "$IVS"; ip_cv=$R; hp_cdr "$IVS"; IVS=$R
        hp_car "$ip_pl"; ip_then=$R; hp_cdr "$ip_pl"; ip_else=$R
        if [ "$ip_cv" = NIL ]; then hp_cons "S:EVAL" "$ip_else"; ics "$R"
        else hp_cons "S:EVAL" "$ip_then"; ics "$R"; fi ;;
      S:PRIMK)
        hp_car "$ip_pl"; ip_op=$R; hp_cdr "$ip_pl"; hp_car "$R"; ip_n=${R#I:}
        ipop_n "$ip_n"; iprim "$ip_op" ;;
      S:CALLK)
        ip_n=${ip_pl#I:}
        ipop_n "$ip_n"; ip_av=$ip_args                  # args (source order)
        hp_car "$IVS"; ip_fv=$R; hp_cdr "$IVS"; IVS=$R   # operator value (C:/I:/K:)
        NFP=$((FP+ITOP)); ip_i=0; ip_a=$ip_av             # callee frame above this activation's let-vars
        while [ "$ip_a" != NIL ]; do hp_car "$ip_a"; eval "F$((NFP+ip_i))=\$R"; hp_cdr "$ip_a"; ip_a=$R; ip_i=$((ip_i+1)); done
        eval "ISCS_$FP=\$ICS; ISVS_$FP=\$IVS; ISSCOPE_$FP=\$SCOPE; ISTOP_$FP=\$ITOP"
        CALLEE=$ip_fv; RPC=1; ACTION=call; return ;;
      S:LETK) SCOPE=$ip_pl ;;                            # restore the pre-let scope (body value stays on VS)
      S:BINDK)                                           # bind a let value: pop it, give it a fresh frame slot, extend SCOPE
        hp_car "$IVS"; bk_v=$R; hp_cdr "$IVS"; IVS=$R
        eval "F$((FP+ITOP))=\$bk_v"; hp_cons "$ip_pl" "I:$ITOP"; hp_cons "$R" "$SCOPE"; SCOPE=$R; ITOP=$((ITOP+1)) ;;
      S:CONDK)                                           # ip_pl = (then . rest-clauses): if cond true eval then, else (cond rest)
        hp_car "$IVS"; ck_cv=$R; hp_cdr "$IVS"; IVS=$R
        hp_car "$ip_pl"; ck_then=$R; hp_cdr "$ip_pl"; ck_rest=$R
        if [ "$ck_cv" = NIL ]; then hp_cons "S:cond" "$ck_rest"; hp_cons "S:EVAL" "$R"; ics "$R"
        else hp_cons "S:EVAL" "$ck_then"; ics "$R"; fi ;;
      S:POPK) hp_cdr "$IVS"; IVS=$R ;;                   # discard a value (begin's non-final results)
    esac
  done
  hp_car "$IVS"; ACTION=ret; return                      # result = top of value stack
}

# ---- loader: read -> lift (comp) -> register fns/layout -> interpret top-level forms --------------
# join a param/capture list's symbol names into a space-string for ILAM_<name>_vars
ld_names() { ln_o=""; ln_l=$1; while [ "$ln_l" != NIL ]; do hp_car "$ln_l"; ln_o="$ln_o ${R#S:}"; hp_cdr "$ln_l"; ln_l=$R; done; R=$ln_o; }
SRC="($(cat "$1"))"; rd_expr; ld_prog=$R
FP=0; RSP=0; PC=0; CLO=""; ICUR=""; F0=$ld_prog; F1="I:0"; CURFN=lift_program; drive; ld_lifted=$R
GFNS=""; GVARS=""; ld_thunks=""; ld_cur=$ld_lifted; ld_evn=0
# pass 1: register every define (fn -> ILAM + GFNS; atom -> G_ + GVARS; computed -> thunk + GVARS)
while [ "$ld_cur" != NIL ]; do
  hp_car "$ld_cur"; ld_form=$R; hp_cdr "$ld_cur"; ld_cur=$R
  hp_car "$ld_form"; ld_hd=$R
  if [ "$ld_hd" = "S:define" ]; then
    hp_cdr "$ld_form"; ld_nv=$R; hp_car "$ld_nv"; ld_nm=${R#S:}; hp_cdr "$ld_nv"; hp_car "$R"; ld_val=$R
    ld_vhd=NIL; case $ld_val in P:*) hp_car "$ld_val"; ld_vhd=$R ;; esac
    case $ld_vhd in
      S:lambda)
        hp_cdr "$ld_val"; hp_car "$R"; ld_ps=$R; hp_cdr "$ld_val"; hp_cdr "$R"; hp_car "$R"; ld_body=$R
        ld_names "$ld_ps"; eval "ILAM_${ld_nm}_vars=\"$R\""
        ilen "$ld_ps"; eval "ILAM_${ld_nm}_np=$R; ILAM_${ld_nm}_ncap=0; ILAM_${ld_nm}_body=\$ld_body"
        GFNS="$GFNS $ld_nm" ;;
      S:clambda)
        hp_cdr "$ld_val"; hp_car "$R"; ld_ps=$R; hp_cdr "$ld_val"; hp_cdr "$R"; hp_car "$R"; ld_cap=$R
        hp_cdr "$ld_val"; hp_cdr "$R"; hp_cdr "$R"; hp_car "$R"; ld_body=$R
        ld_names "$ld_ps"; ld_pv=$R; ld_names "$ld_cap"; eval "ILAM_${ld_nm}_vars=\"$ld_pv $R\""
        ilen "$ld_ps"; eval "ILAM_${ld_nm}_np=$R"; ilen "$ld_cap"; eval "ILAM_${ld_nm}_ncap=$R; ILAM_${ld_nm}_body=\$ld_body"
        GFNS="$GFNS $ld_nm" ;;
      *) case $ld_val in
           I:*|T:*) eval "G_${ld_nm}=\$ld_val"; GVARS="$GVARS $ld_nm" ;;
           S:*) iresolve_init=$ld_val; eval "G_${ld_nm}=\$ld_val"; GVARS="$GVARS $ld_nm" ;;
           *) eval "ILAM___ev${ld_evn}_body=\$ld_val; ILAM___ev${ld_evn}_np=0; ILAM___ev${ld_evn}_ncap=0; ILAM___ev${ld_evn}_vars=\"\""
              ld_thunks="$ld_thunks __ev${ld_evn}=G:${ld_nm}"; GVARS="$GVARS $ld_nm"; ld_evn=$((ld_evn+1)) ;;
         esac ;;
    esac
  else
    eval "ILAM___ev${ld_evn}_body=\$ld_form; ILAM___ev${ld_evn}_np=0; ILAM___ev${ld_evn}_ncap=0; ILAM___ev${ld_evn}_vars=\"\""
    ld_thunks="$ld_thunks __ev${ld_evn}=S"; ld_evn=$((ld_evn+1))
  fi
done
GFNS="$GFNS $(for e in $ld_thunks; do printf '%s ' "${e%%=*}"; done)"   # thunks are interp fns too
_relem() { case $1 in NIL) printf "()" ;; I:*) printf %s "${1#I:}" ;; T:*) printf %s "${1#T:}" ;; S:*) printf %s "${1#S:}" ;; K:*) printf "<closure>" ;; C:*) printf "<fn:%s>" "${1#C:}" ;; P:*) printf "("; _rlist "$1"; printf ")" ;; *) printf %s "$1" ;; esac; }
_rlist() { hp_car "$1"; _e=$R; _relem "$_e"; hp_cdr "$1"; _t=$R; case ${_t#P:} in "$_t") [ "$_t" = NIL ] || { printf " . "; _relem "$_t"; } ;; *) printf " "; _rlist "$_t" ;; esac; }
# pass 2: run each top-level thunk (interpreted) in order
for e in $ld_thunks; do
  th=${e%%=*}; act=${e#*=}
  FP=0; RSP=0; PC=0; CLO=""; ICUR="$th"; CURFN=interp; drive
  case $act in
    S)   _relem "$R"; printf '\n' ;;
    G:*) eval "G_${act#G:}=\$R" ;;
  esac
done
INTERP
} > interp-sh.sh
echo "built interp-sh.sh ($(wc -l < interp-sh.sh) lines)"
