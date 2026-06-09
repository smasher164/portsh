#!/bin/sh
# Assemble repl-sh.sh -- the interactive REPL (sh), JIT-backed ONLY (no :ev, no engine transition).
# Each input is compiled by the SAME native comp the loader uses, but INCREMENTALLY: repl-compile-sh
# threads the lambda-lift counter (so input N's __lamK never overwrites input N-1's -- which would
# clobber closures that still reference them) and ACCUMULATES the known-global-fn set (so a value-
# position reference to a fn defined in an earlier input still compiles to C:<label>). Compiled fns,
# G_<name> globals and the heap all persist in this one live shell process across inputs.
#
#   usage:  mksh repl-sh.sh        (reads forms from stdin; ctrl-d to exit)
# Shares the kernel reader + the K:/CLO trampoline driver + the AOT stdlib with load-sh.sh verbatim;
# only the top-level driver differs (an interactive read->compile->run->print loop vs whole-program).
set -eu
cd "$(dirname "$0")"
[ -f portsh-full.cmd ] || sh build.sh >/dev/null
[ -f src/comp-sh-compiled.sh ] || sh build-comp-sh.sh >/dev/null
[ -f src/prims-aot.sh ] || sh tools/build-prims-aot.sh >/dev/null

{
  tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat src/comp-sh-compiled.sh
  cat src/prims-aot.sh
  cat src/stdlib-aot.sh
  cat <<'DRV'

# ---- closure-capable trampoline driver (K:/CLO/RSL) + comp's I/O prims (live; no replay) ----------
GLOBAL=NIL
G_DQ='T:"'
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
print()          { _relem "$1"; printf '\n'; R=NIL; }
read_lines()     { _f=${1#T:}; _acc=NIL; while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
                   _rev=NIL; while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev; }
file_existszzQ() { [ -e "${1#T:}" ] && R="S:t" || R=NIL; }
run_cmd()        { sh -c "$1"; R="I:$?"; }
run_capture()    { _rc_out=$(sh -c "$1"); _rc_acc=NIL
  while IFS= read -r _rc_ln || [ -n "$_rc_ln" ]; do hp_cons "T:$_rc_ln" "$_rc_acc"; _rc_acc=$R; done <<RC_EOF
$_rc_out
RC_EOF
  _rc_rev=NIL; while [ "$_rc_acc" != NIL ]; do hp_car "$_rc_acc"; _rc_v=$R; hp_cdr "$_rc_acc"; _rc_acc=$R; hp_cons "$_rc_v" "$_rc_rev"; _rc_rev=$R; done; R=$_rc_rev; }
read_str()       { _rd_save=$SRC; SRC=${1#T:}; rd_expr; _rd_v=$R; SRC=$_rd_save; R=$_rd_v; }
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

# ---- interactive REPL: read a balanced form, compile it incrementally, run it, print the value -----
# State threaded across inputs: CTR (next lambda-lift index), GFNS (accumulated known-global fns),
# GVARS (accumulated known-global VARS -- so a closure bound to a global and called in operator
# position applies instead of mis-emitting a direct call), EVN (next __ev thunk index, monotonic).
CTR=0; GFNS=NIL; GVARS=NIL; EVN=0

# _balanced BUF -> succeeds iff BUF holds >=1 complete top-level form (paren depth back to 0, not mid-
# string), matching the kernel reader's lexing: ';' comments to EOL, "..." single-line strings (a '"'
# always toggles; no escapes), '(' / ')' nest, "'" is a prefix that doesn't change depth.
_balanced() {
  _b=$1; _depth=0; _instr=0; _incom=0; _seen=0
  while [ -n "$_b" ]; do
    _c=${_b%"${_b#?}"}; _b=${_b#?}
    if [ "$_incom" = 1 ]; then case $_c in "$_NL") _incom=0 ;; esac; continue; fi
    if [ "$_instr" = 1 ]; then [ "$_c" = '"' ] && _instr=0; continue; fi
    case $_c in
      ';') _incom=1 ;;
      '"') _instr=1; _seen=1 ;;
      '(') _depth=$((_depth+1)); _seen=1 ;;
      ')') _depth=$((_depth-1)); _seen=1 ;;
      ' '|"$_TAB"|"$_NL") ;;
      *) _seen=1 ;;
    esac
  done
  [ "$_instr" = 0 ] && [ "$_depth" -le 0 ] && [ "$_seen" = 1 ]
}

# _mkthunk1 BODY ACTION -> wrap (define __evEVN (lambda () BODY)) as the sole form in REPLXF; remember
# the thunk fn name (REPLTH) and action (REPLACT) to run after compile. Monotonic EVN avoids collision.
_mkthunk1() {
  hp_cons "$1" NIL;            _b=$R
  hp_cons NIL "$_b";           _ll=$R
  hp_cons "S:lambda" "$_ll";   _lam=$R
  hp_cons "$_lam" NIL;         _d3=$R
  hp_cons "S:__ev$EVN" "$_d3"; _d2=$R
  hp_cons "S:define" "$_d2";   _def=$R
  hp_cons "$_def" NIL;         REPLXF=$R
  REPLTH="__ev$EVN"; REPLACT="$2"; EVN=$((EVN+1))
}

# repl_form FORM -> classify (lambda-define -> compiled fn; computed-define -> thunk binding G_<name>;
# atom-define -> G_<name> const; bare expression -> thunk, show value), compile this one input's forms
# (threading CTR/GFNS), source so the new fns/consts go live, then run the thunk (if any) and print.
repl_form() {
  _form=$1; REPLXF=NIL; REPLTH=""; REPLACT=""
  _hd=NIL; case $_form in P:*) hp_car "$_form"; _hd=$R ;; esac
  if [ "$_hd" = "S:define" ]; then
    hp_cdr "$_form"; _nv=$R; hp_car "$_nv"; _name=$R
    hp_cdr "$_nv"; _vv=$R;   hp_car "$_vv"; _val=$R
    case $_val in
      P:*) hp_car "$_val"; _vhd=$R
           if [ "$_vhd" = "S:lambda" ]; then hp_cons "$_form" NIL; REPLXF=$R
           else _mkthunk1 "$_val" "G:${_name#S:}"; fi ;;
      *)   hp_cons "$_form" NIL; REPLXF=$R ;;
    esac
  else
    _mkthunk1 "$_form" "S"
  fi
  _tmp=$(mktemp)
  FP=0; RSP=0; PC=0; CLO=""; F0=$REPLXF; F1="T:$_tmp"; F2="I:$CTR"; F3=$GFNS; F4=$GVARS; CURFN=repl_compile_sh; drive
  _res=$R; hp_car "$_res"; CTR=${R#I:}; hp_cdr "$_res"; _gg=$R    # R = (newctr . (newgfns . newgvars))
  hp_car "$_gg"; GFNS=$R; hp_cdr "$_gg"; GVARS=$R
  # a COMPUTED define is compiled as a thunk, so gvar-names can't see its name -- add it here (we know
  # it's a global var: the thunk binds G_<name>), so a later input calling it in operator position applies.
  case $REPLACT in G:*) hp_cons "S:${REPLACT#G:}" "$GVARS"; GVARS=$R ;; esac
  . "$_tmp"; rm -f "$_tmp"
  if [ -n "$REPLTH" ]; then
    FP=0; RSP=0; PC=0; CLO=""; CURFN=$REPLTH; drive
    case $REPLACT in
      S)   show_val "$R" ;;
      G:*) eval "G_${REPLACT#G:}=\$R" ;;
    esac
  fi
}

[ -t 0 ] && printf 'portsh repl -- JIT-backed. ctrl-d to exit.\n'
_buf=""
while :; do
  if [ -t 0 ]; then [ -z "$_buf" ] && printf '> ' || printf '... '; fi
  IFS= read -r _line || { [ -n "$_buf" ] && printf '\n'; break; }
  _buf="$_buf$_line$_NL"
  _balanced "$_buf" || continue
  SRC=$_buf; _buf=""
  while rd_expr; do
    case $R in EOF) break ;; RPAREN) printf 'unexpected )\n' >&2; break ;; esac
    repl_form "$R"
  done
done
DRV
} > repl-sh.sh
echo "built repl-sh.sh ($(wc -l < repl-sh.sh) lines)"
