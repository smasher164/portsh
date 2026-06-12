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
# G_ keys follow the comp's sh-mangle (raw dashed/? names are invalid sh identifiers); mangle when
# binding a computed define's value -- the comp's own G_ reads are baked mangled at compile time.
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
# I/O primitives the JIT lacked (script semantics; mirror prim_app).
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
print()          { _relem "$1"; printf '\n'; R=NIL; }
read_lines()     { _f=${1#T:}; _acc=NIL; while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
                   _rev=NIL; while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev; }
file_existszzQ() { [ -e "${1#T:}" ] && R="S:t" || R=NIL; }
split()          { _sp_s=${1#T:}; _sp_sep=${2#T:}; _sp_acc=NIL
                   if [ -z "$_sp_sep" ]; then hp_cons "T:$_sp_s" NIL; _sp_acc=$R
                   else
                     while case "$_sp_s" in *"$_sp_sep"*) true ;; *) false ;; esac; do
                       hp_cons "T:${_sp_s%%"$_sp_sep"*}" "$_sp_acc"; _sp_acc=$R; _sp_s=${_sp_s#*"$_sp_sep"}
                     done
                     hp_cons "T:$_sp_s" "$_sp_acc"; _sp_acc=$R
                   fi
                   _sp_rev=NIL; while [ "$_sp_acc" != NIL ]; do hp_car "$_sp_acc"; _sp_v=$R; hp_cdr "$_sp_acc"; _sp_acc=$R; hp_cons "$_sp_v" "$_sp_rev"; _sp_rev=$R; done; R=$_sp_rev; }
type_of()        { case $1 in NIL) R="S:nil" ;; I:*) R="S:number" ;; S:*) R="S:symbol" ;; T:*) R="S:string" ;; P:*) R="S:pair" ;; *) R="S:unknown" ;; esac; }  # pure: a kernel prim the comp now emits as a builtin call
# argv/getenv. The entry dispatch captures user args (after the program path) into PORTSH_ARGV_<n> /
# PORTSH_ARGC env vars -- front-ends may pre-set them, and child processes inherit them, so no arg
# re-quoting is ever needed. (argv) builds the list PER CALL (a boot-time list would need gc rooting).
# getenv: empty == unset == nil on BOTH hosts (cmd cannot store an empty env var; sh matches for
# consistency); non-identifier names return nil (also keeps the eval safe).
argv()   { _av=NIL; _ai=${PORTSH_ARGC:-0}
           while [ "$_ai" -gt 0 ]; do _ai=$((_ai-1)); eval "_avv=\${PORTSH_ARGV_$_ai-}"; hp_cons "T:$_avv" "$_av"; _av=$R; done; R=$_av; }
# setenv: ""-value UNSETS (cmd cannot store an empty env var -- mirror getenv's empty==unset==nil);
# same name guard. Children of run/run-capture inherit. exit_prim: terminate with the given code
# (the fn cannot be named `exit` in sh -- it would shadow the builtin and recurse; brt maps it).
# File ops (t/nil): make-dir = mkdir -p (parents, idempotent); delete-file = rm -f semantics
# (missing -> t: the desired state); copy-file overwrites.
setenv() { _sn=${1#T:}; _sv=${2#T:}
           case $_sn in *[!A-Za-z0-9_]*|"") R=NIL ;;
             *) if [ -n "$_sv" ]; then eval "export $_sn=\$_sv"; else eval "unset $_sn"; fi; R="S:t" ;; esac; }
exit_prim() { exit "${1#I:}"; }
make_dir()    { mkdir -p "${1#T:}" 2>/dev/null && R="S:t" || R=NIL; }
delete_file() { _df=${1#T:}; if [ -e "$_df" ]; then rm -f "$_df" 2>/dev/null; fi
                [ -e "$_df" ] && R=NIL || R="S:t"; }
copy_file()   { cp -f "${1#T:}" "${2#T:}" 2>/dev/null && R="S:t" || R=NIL; }
getenv() { _gn=${1#T:}
           case $_gn in *[!A-Za-z0-9_]*|"") R=NIL ;; *) eval "_gv=\${$_gn-}"; if [ -n "$_gv" ]; then R="T:$_gv"; else R=NIL; fi ;; esac; }
# run / run-capture / read primitives (mirror the interpreter's prim_oper run/run-capture + prim_app
# read). $1 is the joined host command (run/run-capture) or the source string (read_str). run/run-capture
# EXECUTE a host command (live effects); read_str parses a source string.
run_cmd()     { sh -c "$1"; R="I:$?"; }
run_capture() { _rc_out=$(sh -c "$1"); _rc_acc=NIL
while IFS= read -r _rc_ln || [ -n "$_rc_ln" ]; do hp_cons "T:$_rc_ln" "$_rc_acc"; _rc_acc=$R; done <<RC_EOF
$_rc_out
RC_EOF
_rc_rev=NIL; while [ "$_rc_acc" != NIL ]; do hp_car "$_rc_acc"; _rc_v=$R; hp_cdr "$_rc_acc"; _rc_acc=$R; hp_cons "$_rc_v" "$_rc_rev"; _rc_rev=$R; done; R=$_rc_rev; }
read_str()    { _rd_save=$SRC; SRC=${1#T:}; rd_expr; _rd_v=$R; SRC=$_rd_save; R=$_rd_v; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION (unbound global / first-class named fn?)\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; C:*) CURFN=${CALLEE#C:} ;; *) CURFN=$CALLEE ;; esac ;;
      apply) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            _ai=0; _ac=$APLIST; while [ "$_ac" != NIL ]; do hp_car "$_ac"; eval "F$((FP+_ai))=\$R"; hp_cdr "$_ac"; _ac=$R; _ai=$((_ai+1)); done; ARGC=$_ai
            case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; C:*) CURFN=${CALLEE#C:} ;; *) CURFN=$CALLEE ;; esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}
_relem() { case $1 in NIL) printf "()" ;; I:*) printf %s "${1#I:}" ;; T:*) printf %s "${1#T:}" ;; S:*) printf %s "${1#S:}" ;; K:*) printf "<closure>" ;; C:*) printf "<fn:%s>" "${1#C:}" ;; P:*) printf "("; _rlist "$1"; printf ")" ;; *) printf %s "$1" ;; esac; }
_rlist() { hp_car "$1"; _e=$R; _relem "$_e"; hp_cdr "$1"; _t=$R; case ${_t#P:} in "$_t") [ "$_t" = NIL ] || { printf " . "; _relem "$_t"; } ;; *) printf " "; _rlist "$_t" ;; esac; }
show_val() { _relem "$1"; printf "\n"; }

# ---- interactive JIT REPL (no-arg mode; the repl-sh.sh behavior, unified into the one artifact) ----
# State threaded across inputs: CTR (next lambda-lift index), GFNS/GVARS (accumulated known globals),
# EVN (next __ev thunk index, monotonic). Each input compiles incrementally via repl_compile_sh.
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
_mkthunk1() {   # $1 = body heap-ref, $2 = action -> REPLXF = ((define __evEVN (lambda () body)))
  hp_cons "$1" NIL;            _b=$R
  hp_cons NIL "$_b";           _ll=$R
  hp_cons "S:lambda" "$_ll";   _lam=$R
  hp_cons "$_lam" NIL;         _d3=$R
  hp_cons "S:__ev$EVN" "$_d3"; _d2=$R
  hp_cons "S:define" "$_d2";   _def=$R
  hp_cons "$_def" NIL;         REPLXF=$R
  REPLTH="__ev$EVN"; REPLACT="$2"; EVN=$((EVN+1))
}
repl_form() {   # classify one input form, compile it incrementally (threading CTR/GFNS/GVARS), run+show
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
  # a COMPUTED define is compiled as a thunk, so gvar-names can't see its name -- add it here (the
  # thunk binds G_<name>), so a later input calling it in operator position applies.
  case $REPLACT in G:*) hp_cons "S:${REPLACT#G:}" "$GVARS"; GVARS=$R ;; esac
  . "$_tmp"; rm -f "$_tmp"
  if [ -n "$REPLTH" ]; then
    FP=0; RSP=0; PC=0; CLO=""; CURFN=$REPLTH; drive
    case $REPLACT in
      S)   show_val "$R" ;;
      G:*) _mgv=$R; mangle "${REPLACT#G:}"; eval "G_$R=\$_mgv" ;;   # mangle clobbers R -- save the value first
    esac
  fi
}
jit_repl() {
  CTR=0; GFNS=NIL; GVARS=NIL; EVN=0
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
}

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
# ---- dispatch: a file arg runs the program (always-JIT); no arg starts the JIT REPL ---------------
if [ "$#" -lt 1 ]; then jit_repl; exit $?; fi
# capture user args (after the program path) for (argv), unless a front-end already did
if [ -z "${PORTSH_ARGC:-}" ]; then
  _an=0; _askip=1
  for _aa in "$@"; do
    if [ "$_askip" = 1 ]; then _askip=0; continue; fi
    eval "PORTSH_ARGV_$_an=\$_aa"; export "PORTSH_ARGV_$_an"; _an=$((_an+1))
  done
  PORTSH_ARGC=$_an; export PORTSH_ARGC
fi
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
             # computed define -> a 0-arg thunk binds G_<name> in program order. ALSO emit a
             # (define <name> nil) placeholder so gvar-names sees <name> as a global VAR -> a later
             # call of it in operator position loads G_<name> and applies (the thunk's value is a
             # closure); without this the comp would emit a direct call to a fn that doesn't exist.
             hp_cons "S:nil" NIL; _ph=$R; hp_cons "$_name" "$_ph"; _ph=$R; hp_cons "S:define" "$_ph"; _ph=$R
             hp_cons "$_ph" "$_xf"; _xf=$R
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
# run each thunk in program order: bind computed-define globals; show bare-expression values UNLESS
# we're in script mode (a real program's only output is its explicit print/write-lines; the auto-show
# is just for the parity REPL tests).
for _e in $_thunks; do
  _th=${_e%%=*}; _act=${_e#*=}
  FP=0; RSP=0; PC=0; CLO=""; CURFN=$_th; drive
  case $_act in
    S)   [ -n "${PORTSH_SCRIPT:-}" ] || show_val "$R" ;;
    G:*) _mgv=$R; mangle "${_act#G:}"; eval "G_$R=\$_mgv" ;;   # mangle clobbers R -- save the value first
  esac
done
rm -f "$_tmp"
DRV
} > load-sh.sh
echo "built load-sh.sh ($(wc -l < load-sh.sh) lines)"
