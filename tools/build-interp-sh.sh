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
[ -f src/prims-aot.sh ] || sh tools/build-prims-aot.sh >/dev/null

{
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-sh-compiled.sh        # the comp -- we reuse lift_program (compiled) via the shared driver
  cat src/prims-aot.sh               # __p_<op> wrappers: prims-as-values resolve to C:__p_<op>, like the comp
  cat <<'INTERP'

# ===================== P1 resumable interpreter on the trampoline =====================
GLOBAL=NIL
G_DQ='T:"'    # the double-quote constant the comp's (dq) reads (G_DQ) -- needed when osr_compile runs the comp
# type_of runtime helper: the comp (with type-of in builtin?) emits a direct call `type_of "$arg"`; needed
# for OSR-compiled fns that use type-of. The interpreter inlines type-of in iprim -- both give the same result.
type_of() { case $1 in NIL) R="S:nil" ;; I:*) R="S:number" ;; S:*) R="S:symbol" ;; T:*) R="S:string" ;; P:*) R="S:pair" ;; *) R="S:unknown" ;; esac; }
# ---- unified driver: C:<label> compiled | I:<id> interpret | K:<idx> closure (route by label) ----
# route a fn label to its CURRENT executor by the registry -- this is the OSR dispatch: a fn is compiled
# if COMPILED_<lbl> is set, else interpreted if it has an ILAM body, else assumed a compiled/external fn.
# Consulted on EVERY call so a flip (set COMPILED_<lbl>) takes effect immediately for interp AND compiled
# callers, and compiled<->interpreted cross-calls route correctly.
route() {
  if eval "[ -n \"\${COMPILED_$1+x}\" ]"; then CURFN=$1
  elif eval "[ -n \"\${ILAM_${1}_body+x}\" ]"; then CURFN=interp; ICUR=$1
  else CURFN=$1; fi
}
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO; RSI$RSP=\$ICUR"; RSP=$((RSP+1))
            FP=$NFP; PC=0; CLO=""; ICUR=""
            case $CALLEE in
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CLO=$_ri; route "${R#S:}" ;;
              C:*) route "${CALLEE#C:}" ;;
              I:*) route "${CALLEE#I:}" ;;
              *)   route "$CALLEE" ;;
            esac ;;
      apply) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO; RSI$RSP=\$ICUR"; RSP=$((RSP+1))
            FP=$NFP; PC=0; CLO=""; ICUR=""
            _ai=0; _ac=$APLIST; while [ "$_ac" != NIL ]; do hp_car "$_ac"; eval "F$((FP+_ai))=\$R"; hp_cdr "$_ac"; _ac=$R; _ai=$((_ai+1)); done
            case $CALLEE in
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CLO=$_ri; route "${R#S:}" ;;
              C:*) route "${CALLEE#C:}" ;;
              I:*) route "${CALLEE#I:}" ;;
              *)   route "$CALLEE" ;;
            esac ;;
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
# mangle a fn name to a safe identifier, matching the comp's sh-mangle (so interp registry keys and route
# labels line up with the comp's compiled fn names). Identity for names without special chars.
mangle() {
  mg_o=""; mg_s=$1
  while [ -n "$mg_s" ]; do
    mg_c=${mg_s%"${mg_s#?}"}; mg_s=${mg_s#?}
    case $mg_c in
      -) mg_o="${mg_o}_" ;; ">") mg_o="${mg_o}zzG" ;; "<") mg_o="${mg_o}zzL" ;; "*") mg_o="${mg_o}zzS" ;;
      "?") mg_o="${mg_o}zzQ" ;; "!") mg_o="${mg_o}zzB" ;; "=") mg_o="${mg_o}zzE" ;; "+") mg_o="${mg_o}zzP" ;;
      *) mg_o="${mg_o}${mg_c}" ;;
    esac
  done
  R=$mg_o
}
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
  mangle "$ir_v"; ir_m=$R                                       # global fn -> I:<mangled> fn-value
  case " $GFNS " in *" $ir_m "*) R="I:$ir_m"; return ;; esac
  prim_wrap "$ir_v"; if [ -n "$R" ]; then R="C:$R"; return; fi  # primitive as a value -> C:<wrapper> (like the comp)
  eval "R=\${G_${ir_v}:-NIL}"                           # global var
}
prim_wrap() {  # raw op -> AOT wrapper name (C:<this> as a value), or "" if not wrappable (matches comp prim-wrap)
  case $1 in
    +) R=__p_add ;; -) R=__p_sub ;; '*') R=__p_mul ;; '<') R=__p_lt ;; =) R=__p_neq ;;
    cons) R=__p_cons ;; car) R=__p_car ;; cdr) R=__p_cdr ;; null?) R=__p_null ;; eq?) R=__p_eq ;; pair?) R=__p_pair ;; not) R=__p_not ;;
    *) R="" ;;
  esac
}
isprim() { case $1 in S:car|S:cdr|S:cons|S:null?|S:pair?|S:atom?|S:number?|S:not|S:type-of|'S:symbol->string'|'S:number->string'|'S:string->symbol'|'S:string->number'|S:string-length|S:string-append|S:substring|S:split|S:print|S:file-exists?|S:read|S:read-lines|S:write-lines|S:append-lines|S:+|S:-|'S:*'|'S:<'|'S:<='|S:=|S:eq?) return 0 ;; *) return 1 ;; esac; }
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
iprim() {  # apply prim $1 to ip_args (the arg-value list); push result. mirrors kernel prim_app.
  hp_car "$ip_args"; ipa=$R                            # first arg (most prims need it)
  case $1 in
    S:car) hp_car "$ipa"; ips "$R" ;;
    S:cdr) hp_cdr "$ipa"; ips "$R" ;;
    S:null?) [ "$ipa" = NIL ] && ips "S:t" || ips "NIL" ;;
    S:pair?) case $ipa in P:*) ips "S:t" ;; *) ips "NIL" ;; esac ;;
    S:atom?) case $ipa in P:*) ips "NIL" ;; *) ips "S:t" ;; esac ;;
    S:number?) case $ipa in I:*) ips "S:t" ;; *) ips "NIL" ;; esac ;;
    S:not) [ "$ipa" = NIL ] && ips "S:t" || ips "NIL" ;;
    S:type-of) case $ipa in NIL) ips "S:nil" ;; I:*) ips "S:number" ;; S:*) ips "S:symbol" ;; T:*) ips "S:string" ;; P:*) ips "S:pair" ;; *) ips "S:unknown" ;; esac ;;
    'S:symbol->string') ips "T:${ipa#S:}" ;;
    'S:number->string') ips "T:${ipa#I:}" ;;
    'S:string->symbol') ips "S:${ipa#T:}" ;;
    'S:string->number') ips "I:${ipa#T:}" ;;
    S:string-length) pa_s=${ipa#T:}; ips "I:${#pa_s}" ;;
    S:string-append) pa_o=""; pa_l=$ip_args; while [ "$pa_l" != NIL ]; do hp_car "$pa_l"; pa_o="$pa_o${R#T:}"; hp_cdr "$pa_l"; pa_l=$R; done; ips "T:$pa_o" ;;
    S:substring) pa_s=${ipa#T:}; hp_cdr "$ip_args"; hp_car "$R"; pa_off=${R#I:}; hp_cdr "$ip_args"; hp_cdr "$R"; hp_car "$R"; pa_n=${R#I:}
       pa_i=0; while [ "$pa_i" -lt "$pa_off" ]; do pa_s=${pa_s#?}; pa_i=$((pa_i+1)); done
       pa_r=""; pa_i=0; while [ "$pa_i" -lt "$pa_n" ] && [ -n "$pa_s" ]; do pa_c=${pa_s%"${pa_s#?}"}; pa_r="$pa_r$pa_c"; pa_s=${pa_s#?}; pa_i=$((pa_i+1)); done
       ips "T:$pa_r" ;;
    S:cons) hp_cdr "$ip_args"; hp_car "$R"; ipb=$R; hp_cons "$ipa" "$ipb"; ips "$R" ;;
    S:split) pa_s=${ipa#T:}; hp_cdr "$ip_args"; hp_car "$R"; pa_sep=${R#T:}; pa_acc=NIL   # split s on sep -> list (mirror kernel)
       if [ -z "$pa_sep" ]; then hp_cons "T:$pa_s" "NIL"; pa_acc=$R
       else
         while case "$pa_s" in *"$pa_sep"*) true ;; *) false ;; esac; do
           hp_cons "T:${pa_s%%"$pa_sep"*}" "$pa_acc"; pa_acc=$R; pa_s=${pa_s#*"$pa_sep"}
         done
         hp_cons "T:$pa_s" "$pa_acc"; pa_acc=$R
       fi
       pa_rev=NIL; while [ "$pa_acc" != NIL ]; do hp_car "$pa_acc"; pa_rv=$R; hp_cdr "$pa_acc"; pa_acc=$R; hp_cons "$pa_rv" "$pa_rev"; pa_rev=$R; done; ips "$pa_rev" ;;
    S:print) _relem "$ipa"; printf '\n'; ips "NIL" ;;
    S:file-exists?) [ -e "${ipa#T:}" ] && ips "S:t" || ips "NIL" ;;
    S:read) pa_sv=$SRC; SRC=${ipa#T:}; rd_expr; pa_rd=$R; SRC=$pa_sv; ips "$pa_rd" ;;
    S:read-lines) pa_f=${ipa#T:}; pa_acc=NIL
       while IFS= read -r pa_ln || [ -n "$pa_ln" ]; do hp_cons "T:$pa_ln" "$pa_acc"; pa_acc=$R; done < "$pa_f"
       pa_rev=NIL; while [ "$pa_acc" != NIL ]; do hp_car "$pa_acc"; pa_v=$R; hp_cdr "$pa_acc"; pa_acc=$R; hp_cons "$pa_v" "$pa_rev"; pa_rev=$R; done; ips "$pa_rev" ;;
    S:write-lines) pa_f=${ipa#T:}; hp_cdr "$ip_args"; hp_car "$R"; pa_l=$R; : > "$pa_f"
       while [ "$pa_l" != NIL ]; do hp_car "$pa_l"; printf '%s\n' "${R#T:}" >> "$pa_f"; hp_cdr "$pa_l"; pa_l=$R; done; ips "S:t" ;;
    S:append-lines) pa_f=${ipa#T:}; hp_cdr "$ip_args"; hp_car "$R"; pa_l=$R
       while [ "$pa_l" != NIL ]; do hp_car "$pa_l"; printf '%s\n' "${R#T:}" >> "$pa_f"; hp_cdr "$pa_l"; pa_l=$R; done; ips "S:t" ;;
    *) hp_cdr "$ip_args"; hp_car "$R"; ipb=$R                       # 2-arg arith / compare
       case $1 in
         S:+)    ips "I:$(( ${ipa#??} + ${ipb#??} ))" ;;
         S:-)    ips "I:$(( ${ipa#??} - ${ipb#??} ))" ;;
         'S:*')  ips "I:$(( ${ipa#??} * ${ipb#??} ))" ;;
         'S:<')  [ "${ipa#??}" -lt "${ipb#??}" ] && ips "S:t" || ips "NIL" ;;
         'S:<=') [ "${ipa#??}" -le "${ipb#??}" ] && ips "S:t" || ips "NIL" ;;
         S:=)    [ "${ipa#??}" = "${ipb#??}" ] && ips "S:t" || ips "NIL" ;;
         S:eq?)  [ "$ipa" = "$ipb" ] && ips "S:t" || ips "NIL" ;;
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
              S:let|S:let*)                              # sequential binding (matches lbinds); let==let* here
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
              S:list)                                    # variadic list build
                ilen "$ip_rest"; hp_cons "S:LISTK" "I:$R"; ics "$R"; ipush_args "$ip_rest" ;;
              S:str)                                     # variadic stringify + concat
                ilen "$ip_rest"; hp_cons "S:STRK" "I:$R"; ics "$R"; ipush_args "$ip_rest" ;;
              S:and)
                if [ "$ip_rest" = NIL ]; then ips "S:t"
                else hp_car "$ip_rest"; an_c=$R; hp_cdr "$ip_rest"; an_r=$R
                  hp_cons "S:ANDK" "$an_r"; ics "$R"; hp_cons "S:EVAL" "$an_c"; ics "$R"; fi ;;
              S:or)
                if [ "$ip_rest" = NIL ]; then ips "NIL"
                else hp_car "$ip_rest"; or_c=$R; hp_cdr "$ip_rest"; or_r=$R
                  hp_cons "S:ORK" "$or_r"; ics "$R"; hp_cons "S:EVAL" "$or_c"; ics "$R"; fi ;;
              S:when)                                    # (if c (begin body) nil)
                hp_car "$ip_rest"; wn_c=$R; hp_cdr "$ip_rest"; wn_b=$R
                hp_cons "S:begin" "$wn_b"; wn_g=$R
                hp_cons "S:nil" "NIL"; wn_t=$R; hp_cons "$wn_g" "$wn_t"; wn_t=$R; hp_cons "$wn_c" "$wn_t"; wn_t=$R; hp_cons "S:if" "$wn_t"
                hp_cons "S:EVAL" "$R"; ics "$R" ;;
              S:unless)                                  # (if c nil (begin body))
                hp_car "$ip_rest"; un_c=$R; hp_cdr "$ip_rest"; un_b=$R
                hp_cons "S:begin" "$un_b"; un_g=$R
                hp_cons "$un_g" "NIL"; un_t=$R; hp_cons "S:nil" "$un_t"; un_t=$R; hp_cons "$un_c" "$un_t"; un_t=$R; hp_cons "S:if" "$un_t"
                hp_cons "S:EVAL" "$R"; ics "$R" ;;
              S:case)                                    # eval key once; CASEK matches a clause
                hp_car "$ip_rest"; cs_k=$R; hp_cdr "$ip_rest"; cs_cl=$R
                hp_cons "S:CASEK" "$cs_cl"; ics "$R"; hp_cons "S:EVAL" "$cs_k"; ics "$R" ;;
              S:run)                                     # operative: join UNEVALUATED operand tokens -> host cmd
                rn_c=""; rn_l=$ip_rest
                while [ "$rn_l" != NIL ]; do hp_car "$rn_l"; rn_c="$rn_c ${R#??}"; hp_cdr "$rn_l"; rn_l=$R; done
                sh -c "$rn_c"; ips "I:$?" ;;
              S:run-capture)                             # operative: run, capture stdout as a list of lines
                rn_c=""; rn_l=$ip_rest
                while [ "$rn_l" != NIL ]; do hp_car "$rn_l"; rn_c="$rn_c ${R#??}"; hp_cdr "$rn_l"; rn_l=$R; done
                rn_out=$(sh -c "$rn_c"); rn_acc=NIL
                while IFS= read -r rn_ln || [ -n "$rn_ln" ]; do hp_cons "T:$rn_ln" "$rn_acc"; rn_acc=$R; done <<RC_EOF
$rn_out
RC_EOF
                rn_rev=NIL; while [ "$rn_acc" != NIL ]; do hp_car "$rn_acc"; rn_v=$R; hp_cdr "$rn_acc"; rn_acc=$R; hp_cons "$rn_v" "$rn_rev"; rn_rev=$R; done; ips "$rn_rev" ;;
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
        hp_car "$IVS"; ip_fv=$R; hp_cdr "$IVS"; IVS=$R   # operator value (C:/I:/K:; prims-as-values are C:<wrapper>)
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
      S:ANDK)                                            # ip_pl = rest exprs; short-circuit on NIL
        hp_car "$IVS"; an_v=$R; hp_cdr "$IVS"; IVS=$R
        if [ "$an_v" = NIL ]; then ips "NIL"
        elif [ "$ip_pl" = NIL ]; then ips "$an_v"
        else hp_cons "S:and" "$ip_pl"; hp_cons "S:EVAL" "$R"; ics "$R"; fi ;;
      S:ORK)                                             # ip_pl = rest exprs; short-circuit on non-NIL
        hp_car "$IVS"; or_v=$R; hp_cdr "$IVS"; IVS=$R
        if [ "$or_v" != NIL ]; then ips "$or_v"
        elif [ "$ip_pl" = NIL ]; then ips "NIL"
        else hp_cons "S:or" "$ip_pl"; hp_cons "S:EVAL" "$R"; ics "$R"; fi ;;
      S:LISTK) ipop_n "${ip_pl#I:}"; ips "$ip_args" ;;   # the popped arg-list IS the result list
      S:STRK)                                            # concat each value's printed text
        ipop_n "${ip_pl#I:}"; sk_o=""; sk_l=$ip_args
        while [ "$sk_l" != NIL ]; do hp_car "$sk_l"; sk_o="$sk_o${R#??}"; hp_cdr "$sk_l"; sk_l=$R; done
        ips "T:$sk_o" ;;
      S:CASEK)                                           # ip_pl = clauses; key on VS. match datum-list (or else)
        hp_car "$IVS"; ck_key=$R; hp_cdr "$IVS"; IVS=$R; ck_cl=$ip_pl
        while [ "$ck_cl" != NIL ]; do
          hp_car "$ck_cl"; ck_c=$R; hp_cdr "$ck_cl"; ck_cl=$R
          hp_car "$ck_c"; ck_dat=$R; hp_cdr "$ck_c"; ck_body=$R; ck_m=
          # match the comp's case->cond: a clause is (DATUM body...), compared (eq? key DATUM) -- a SINGLE
          # quoted datum, NOT Scheme's ((d1 d2) body) datum-list. else always matches.
          if [ "$ck_dat" = "S:else" ]; then ck_m=1
          elif [ "$ck_dat" = "$ck_key" ]; then ck_m=1; fi
          if [ -n "$ck_m" ]; then hp_cons "S:begin" "$ck_body"; hp_cons "S:EVAL" "$R"; ics "$R"; break; fi
        done ;;
    esac
  done
  hp_car "$IVS"; ACTION=ret; return                      # result = top of value stack
}

# ---- loader: read -> lift (comp) -> register fns/layout -> interpret top-level forms --------------
# join a param/capture list's symbol names into a space-string for ILAM_<name>_vars
ld_names() { ln_o=""; ln_l=$1; while [ "$ln_l" != NIL ]; do hp_car "$ln_l"; ln_o="$ln_o ${R#S:}"; hp_cdr "$ln_l"; ln_l=$R; done; R=$ln_o; }
ld_mkthunk() {  # $1 = body ref, $2 = action (S | G:name) -> prepend (define __evN (lambda () body)) to XF
  hp_cons "$1" NIL; mk_b=$R; hp_cons NIL "$mk_b"; mk_ll=$R; hp_cons "S:lambda" "$mk_ll"; mk_lam=$R
  hp_cons "$mk_lam" NIL; mk_d3=$R; hp_cons "S:__ev$ld_evn" "$mk_d3"; mk_d2=$R; hp_cons "S:define" "$mk_d2"; mk_def=$R
  hp_cons "$mk_def" "$XF"; XF=$R; ld_thunks="$ld_thunks __ev$ld_evn=$2"; ld_evn=$((ld_evn+1))
}
_relem() { case $1 in NIL) printf "()" ;; I:*) printf %s "${1#I:}" ;; T:*) printf %s "${1#T:}" ;; S:*) printf %s "${1#S:}" ;; K:*) printf "<closure>" ;; C:*) printf "<fn:%s>" "${1#C:}" ;; P:*) printf "("; _rlist "$1"; printf ")" ;; *) printf %s "$1" ;; esac; }
_rlist() { hp_car "$1"; _e=$R; _relem "$_e"; hp_cdr "$1"; _t=$R; case ${_t#P:} in "$_t") [ "$_t" = NIL ] || { printf " . "; _relem "$_t"; } ;; *) printf " "; _rlist "$_t" ;; esac; }
# --- OSR flip: compile a registered fn at runtime (via the embedded comp, on the shared driver), source it,
# and mark COMPILED so route() dispatches the compiled version on the next call. PORTSH_OSR="f g ..." flips. ---
str_to_symlist() { sl_o=NIL; for sl_w in $1; do hp_cons "S:$sl_w" "$sl_o"; sl_o=$R; done; R=$sl_o; }
osr_compile() {
  mangle "$1"; oc_n=$R
  eval "[ -n \"\${ILAM_${oc_n}_def+x}\" ]" || return 0
  eval "oc_def=\$ILAM_${oc_n}_def"
  str_to_symlist "$GFNS"; oc_gf=$R; str_to_symlist "$GVARS"; oc_gv=$R
  FP=0; RSP=0; PC=0; CLO=""; ICUR=""; F0=$oc_def; F1=$oc_gf; F2=$oc_gv; CURFN=compile_def_sh; drive
  oc_l=$R; oc_tmp=$(mktemp)
  while [ "$oc_l" != NIL ]; do hp_car "$oc_l"; printf '%s\n' "${R#T:}" >> "$oc_tmp"; hp_cdr "$oc_l"; oc_l=$R; done
  . "$oc_tmp"; rm -f "$oc_tmp"; eval "COMPILED_$oc_n=1"
  [ -n "${PORTSH_OSR_VERBOSE:-}" ] && printf 'OSR: compiled %s\n' "$1" >&2
}
# process one batch of top-level forms: partition -> lift (threaded CTR via lift_program_c, so successive
# REPL inputs don't collide __lamN) -> register -> [OSR flip] -> run thunks. State (CTR/GFNS/GVARS/ILAM_*/
# G_*/heap) persists across calls, so the REPL accumulates definitions. Malformed defines are skipped (not
# eval'd) so bad input can't create stray ILAM_* files.
CTR=0; GFNS=""; GVARS=""
process_forms() {
  XF=NIL; ld_thunks=""; ld_evn=0; ld_cur=$1
  while [ "$ld_cur" != NIL ]; do                              # pass 0: partition
    hp_car "$ld_cur"; ld_form=$R; hp_cdr "$ld_cur"; ld_cur=$R
    ld_hd=NIL; case $ld_form in P:*) hp_car "$ld_form"; ld_hd=$R ;; esac
    if [ "$ld_hd" = "S:define" ]; then
      hp_cdr "$ld_form"; ld_nv=$R; hp_car "$ld_nv"; ld_nm0=$R
      case $ld_nm0 in S:*) ;; *) printf 'portsh: skipping malformed define (name is not a symbol)\n' >&2; continue ;; esac
      hp_cdr "$ld_nv"; hp_car "$R"; ld_val=$R
      ld_vhd=NIL; case $ld_val in P:*) hp_car "$ld_val"; ld_vhd=$R ;; esac
      if [ "$ld_vhd" = "S:lambda" ]; then hp_cons "$ld_form" "$XF"; XF=$R
      else case $ld_val in
             I:*|T:*|S:*) hp_cons "$ld_form" "$XF"; XF=$R ;;
             *) ld_mkthunk "$ld_val" "G:${ld_nm0#S:}" ;;
           esac
      fi
    else
      ld_mkthunk "$ld_form" "S"
    fi
  done
  FP=0; RSP=0; PC=0; CLO=""; ICUR=""; F0=$XF; F1="I:$CTR"; CURFN=lift_program_c; drive   # lift, threading CTR
  pf_r=$R; hp_car "$pf_r"; ld_lifted=$R; hp_cdr "$pf_r"; CTR=${R#I:}                      # = (lifted . newctr)
  ld_cur=$ld_lifted
  while [ "$ld_cur" != NIL ]; do                              # pass 1: register
    hp_car "$ld_cur"; ld_form=$R; hp_cdr "$ld_cur"; ld_cur=$R
    hp_cdr "$ld_form"; ld_nv=$R; hp_car "$ld_nv"; ld_nmt=$R
    case $ld_nmt in S:*) ;; *) continue ;; esac
    ld_nm_raw=${ld_nmt#S:}; mangle "$ld_nm_raw"; ld_nm=$R; hp_cdr "$ld_nv"; hp_car "$R"; ld_val=$R
    ld_vhd=NIL; case $ld_val in P:*) hp_car "$ld_val"; ld_vhd=$R ;; esac
    case $ld_vhd in
      S:lambda)
        hp_cdr "$ld_val"; hp_car "$R"; ld_ps=$R; hp_cdr "$ld_val"; hp_cdr "$R"; hp_car "$R"; ld_body=$R
        ld_names "$ld_ps"; eval "ILAM_${ld_nm}_vars=\"$R\""
        ilen "$ld_ps"; eval "ILAM_${ld_nm}_np=$R; ILAM_${ld_nm}_ncap=0; ILAM_${ld_nm}_body=\$ld_body; ILAM_${ld_nm}_def=\$ld_form"
        GFNS="$GFNS $ld_nm" ;;
      S:clambda)
        hp_cdr "$ld_val"; hp_car "$R"; ld_ps=$R; hp_cdr "$ld_val"; hp_cdr "$R"; hp_car "$R"; ld_cap=$R
        hp_cdr "$ld_val"; hp_cdr "$R"; hp_cdr "$R"; hp_car "$R"; ld_body=$R
        ld_names "$ld_ps"; ld_pv=$R; ld_names "$ld_cap"; eval "ILAM_${ld_nm}_vars=\"$ld_pv $R\""
        ilen "$ld_ps"; eval "ILAM_${ld_nm}_np=$R"; ilen "$ld_cap"; eval "ILAM_${ld_nm}_ncap=$R; ILAM_${ld_nm}_body=\$ld_body; ILAM_${ld_nm}_def=\$ld_form"
        GFNS="$GFNS $ld_nm" ;;
      *) eval "G_${ld_nm_raw}=\$ld_val"; GVARS="$GVARS $ld_nm_raw" ;;
    esac
  done
  for f in ${PORTSH_OSR:-}; do osr_compile "$f"; done         # OSR flip (no-op if PORTSH_OSR unset)
  for e in $ld_thunks; do                                     # pass 2: run thunks in order
    th=${e%%=*}; act=${e#*=}
    FP=0; RSP=0; PC=0; CLO=""; ICUR="$th"; CURFN=interp; drive
    case $act in
      S)   [ -n "${PORTSH_SCRIPT:-}" ] || { _relem "$R"; printf '\n'; } ;;
      G:*) eval "G_${act#G:}=\$R" ;;
    esac
  done
}
# _balanced BUF -> succeeds iff BUF holds >=1 complete top-level form (paren depth back to 0, not mid-
# string), matching the kernel reader's lexing (';' comments, "..." single-line strings, '(' ')' nest).
_balanced() {
  _b=$1; _depth=0; _instr=0; _incom=0; _seen=0
  while [ -n "$_b" ]; do
    _c=${_b%"${_b#?}"}; _b=${_b#?}
    if [ "$_incom" = 1 ]; then case $_c in "$_NL") _incom=0 ;; esac; continue; fi
    if [ "$_instr" = 1 ]; then [ "$_c" = '"' ] && _instr=0; continue; fi
    case $_c in ';') _incom=1 ;; '"') _instr=1; _seen=1 ;; '(') _depth=$((_depth+1)); _seen=1 ;; ')') _depth=$((_depth-1)); _seen=1 ;; ' '|"$_TAB"|"$_NL") ;; *) _seen=1 ;; esac
  done
  [ "$_instr" = 0 ] && [ "$_depth" -le 0 ] && [ "$_seen" = 1 ]
}
# ---- dispatch: a file arg runs the program; no arg starts the interactive REPL (state persists) --------
if [ "$#" -ge 1 ]; then
  SRC="($(cat "$1"))"; rd_expr; process_forms "$R"
else
  [ -t 0 ] && printf 'portsh interp repl -- ctrl-d to exit.\n'
  _buf=""
  while :; do
    if [ -t 0 ]; then [ -z "$_buf" ] && printf '> ' || printf '... '; fi
    IFS= read -r _line || { [ -n "$_buf" ] && printf '\n'; break; }
    _buf="$_buf$_line$_NL"
    _balanced "$_buf" || continue
    SRC="($_buf)"; rd_expr; process_forms "$R"             # wrap input in (...) -> a form list
    _buf=""
  done
fi
INTERP
} > interp-sh.sh
echo "built interp-sh.sh ($(wc -l < interp-sh.sh) lines)"
