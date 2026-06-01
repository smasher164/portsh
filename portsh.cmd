:;[ -n "${PORTSH_COOKED-}" ]||{ tr -d '\r'<"$0"|PORTSH_COOKED=1 PORTSH_SELF="$0" sh -s -- "$@";exit $?; } #
:<<'::CMDLITERAL'
@echo off
goto :CMDSTART
::CMDLITERAL
# portsh — sh-hosted Lisp kernel, v1 (operative / $vau core)
# ---------------------------------------------------------------------------
# The kernel knows only operatives. There are NO hardcoded special forms:
# `lambda`, `quote`, `if`, `define`, `list` are all defined in the Lisp PRELUDE
# below, in terms of three primitive operatives ($vau / $define! / $if) plus
# ordinary applicative primitives. This is the surface we'll port to batch —
# small and uniform — while the language keeps growing in userspace.
#
# Values are tagged strings:
#   NIL  empty list / false        I:<n> integer      S:<name> symbol
#   T:<text> string                P:<idx> pair
#   F:<name> primitive operative (gets UNEVALUATED operands + caller env)
#   R:<name> primitive applicative (gets evaluated args)
#   O:<idx>  compound operative made by $vau  -> cell (formals eformal body senv)
#   A:<idx>  applicative wrapping a combiner  -> cell (combiner)
#
# Functions return in global $R (NOT stdout: the reader mutates global state,
# and a command-substitution subshell would discard it). `local` keeps
# recursion correct (every modern /bin/sh has it).
# ---------------------------------------------------------------------------
set -u

die() { printf 'portsh: %s\n' "$1" >&2; exit 1; }

# ---- heap (swappable for the append-only dd-file heap later) --------------
HEAP_N=0
hp_cons() { eval "H_${HEAP_N}_a=\$1"; eval "H_${HEAP_N}_d=\$2"; R="P:$HEAP_N"; HEAP_N=$((HEAP_N + 1)); }
hp_car()    { _i=${1#P:}; eval "R=\$H_${_i}_a"; }
hp_cdr()    { _i=${1#P:}; eval "R=\$H_${_i}_d"; }
hp_setcar() { _i=${1#P:}; eval "H_${_i}_a=\$2"; }

# ---- reader ---------------------------------------------------------------
rd_first() { R=${SRC%"${SRC#?}"}; }

rd_skipws() {
  while :; do
    rd_first
    case $R in
      ' '|'	') SRC=${SRC#?} ;;
      '
') SRC=${SRC#?} ;;
      ';') case $SRC in *'
'*) SRC=${SRC#*'
'} ;; *) SRC= ;; esac ;;
      *) break ;;
    esac
  done
}

rd_expr() {
  rd_skipws; rd_first
  case $R in
    '')  R=EOF; return 1 ;;
    '(') SRC=${SRC#?}; rd_list ;;
    ')') SRC=${SRC#?}; R=RPAREN ;;
    "'") SRC=${SRC#?}; rd_quote ;;
    '"') rd_string ;;
    *)   rd_atom ;;
  esac
  return 0
}

rd_quote() { local q; rd_expr; q=$R; hp_cons "$q" NIL; q=$R; hp_cons "S:quote" "$q"; }

rd_list() {
  local head tail
  rd_expr
  case $R in RPAREN|EOF) R=NIL; return ;; esac
  # dotted tail: (a b . c) — '.' only appears in a tail-position read.
  if [ "$R" = 'S:.' ]; then
    rd_expr; tail=$R       # the cdr datum
    rd_expr                # consume the closing ')'
    R=$tail; return
  fi
  head=$R
  rd_list; tail=$R
  hp_cons "$head" "$tail"
}

rd_atom() {
  local tok=''
  while :; do
    rd_first
    case $R in
      ''|' '|'	'|'
'|'('|')'|"'"|'"'|';') break ;;
      *) tok=$tok$R; SRC=${SRC#?} ;;
    esac
  done
  case $tok in
    -|''|*[!0-9-]*) R="S:$tok" ;;
    *)              R="I:$tok" ;;
  esac
}

rd_string() {
  local s=''
  SRC=${SRC#?}
  while :; do
    rd_first
    case $R in
      '')  break ;;
      '"') SRC=${SRC#?}; break ;;
      *)   s=$s$R; SRC=${SRC#?} ;;
    esac
  done
  R="T:$s"
}

# ---- environment: pair (bindings-alist . parent) --------------------------
env_new() { hp_cons NIL "$1"; }

env_define() {
  local env=$1 sym=$2 val=$3 binds pair
  hp_car "$env"; binds=$R
  hp_cons "$sym" "$val"; pair=$R
  hp_cons "$pair" "$binds"
  hp_setcar "$env" "$R"
}

env_lookup() {
  local env=$1 sym=$2 binds pair k
  while [ "$env" != NIL ]; do
    hp_car "$env"; binds=$R
    while [ "$binds" != NIL ]; do
      hp_car "$binds"; pair=$R
      hp_car "$pair"; k=$R
      if [ "$k" = "$sym" ]; then hp_cdr "$pair"; return; fi
      hp_cdr "$binds"; binds=$R
    done
    hp_cdr "$env"; env=$R
  done
  die "unbound symbol: ${sym#S:}"
}

# ---- evaluator: evaluate operator, then combine ---------------------------
ev() {
  local x=$1 env=$2 c
  case $x in
    NIL)                         R=NIL ;;
    I:*|T:*|F:*|R:*|O:*|A:*)     R=$x ;;
    S:*)                         env_lookup "$env" "$x" ;;
    P:*) hp_car "$x"; ev "$R" "$env"; c=$R
         hp_cdr "$x"; combine "$c" "$R" "$env" ;;
    *) die "cannot evaluate: $x" ;;
  esac
}

ev_seq() {
  local lst=$1 env=$2 e val=NIL
  while [ "$lst" != NIL ]; do
    hp_car "$lst"; e=$R
    ev "$e" "$env"; val=$R
    hp_cdr "$lst"; lst=$R
  done
  R=$val
}

eval_list() {                    # map ev over a list -> R = list of values
  local lst=$1 env=$2 e rest
  [ "$lst" = NIL ] && { R=NIL; return; }
  hp_car "$lst"; e=$R; ev "$e" "$env"; e=$R
  hp_cdr "$lst"; eval_list "$R" "$env"; rest=$R
  hp_cons "$e" "$rest"
}

combine() {                      # combiner operands dynenv -> R
  local c=$1 operands=$2 denv=$3 w args
  case $c in
    F:*) prim_oper "${c#F:}" "$operands" "$denv" ;;
    R:*) eval_list "$operands" "$denv"; prim_app "${c#R:}" "$R" ;;
    A:*) hp_car "P:${c#A:}"; w=$R
         eval_list "$operands" "$denv"; args=$R
         combine "$w" "$args" "$denv" ;;
    O:*) combine_oper "$c" "$operands" "$denv" ;;
    *) die "not combinable: $c" ;;
  esac
}

combine_oper() {                 # O:idx operands dynenv
  local c=$1 operands=$2 denv=$3 cell formals eformal body senv ne r
  cell="P:${c#O:}"
  hp_car "$cell"; formals=$R
  hp_cdr "$cell"; r=$R; hp_car "$r"; eformal=$R
  hp_cdr "$r"; r=$R; hp_car "$r"; body=$R
  hp_cdr "$r"; senv=$R
  env_new "$senv"; ne=$R
  bind_tree "$ne" "$formals" "$operands"
  case $eformal in 'S:#ignore') ;; *) env_define "$ne" "$eformal" "$denv" ;; esac
  ev_seq "$body" "$ne"
}

bind_tree() {                    # env formals operands  (formals: NIL | symbol-rest | tree)
  local env=$1 formals=$2 operands=$3 fcar ftail
  case $formals in
    NIL) ;;
    S:*) env_define "$env" "$formals" "$operands" ;;
    P:*) hp_car "$formals"; fcar=$R
         hp_car "$operands"; env_define "$env" "$fcar" "$R"
         hp_cdr "$formals"; ftail=$R
         hp_cdr "$operands"; bind_tree "$env" "$ftail" "$R" ;;
  esac
}

# ---- primitive operatives (unevaluated operands + env) --------------------
prim_oper() {
  local name=$1 ops=$2 denv=$3 formals eformal body sym test r
  case $name in
    vau)
      hp_car "$ops"; formals=$R
      hp_cdr "$ops"; r=$R; hp_car "$r"; eformal=$R
      hp_cdr "$r"; body=$R
      hp_cons "$body" "$denv"; r=$R
      hp_cons "$eformal" "$r"; r=$R
      hp_cons "$formals" "$r"
      R="O:${R#P:}" ;;
    define)
      hp_car "$ops"; sym=$R
      hp_cdr "$ops"; hp_car "$R"; ev "$R" "$denv"
      env_define "$denv" "$sym" "$R"
      R=$sym ;;
    if)
      hp_car "$ops"; test=$R
      ev "$test" "$denv"
      if [ "$R" = NIL ]; then hp_cdr "$ops"; hp_cdr "$R"; hp_car "$R"; ev "$R" "$denv"
      else                    hp_cdr "$ops"; hp_car "$R"; ev "$R" "$denv"; fi ;;
    *) die "unknown operative: $name" ;;
  esac
}

# ---- primitive applicatives (evaluated args) ------------------------------
arg1() { hp_car "$1"; ARG1=$R; }
arg2() { hp_car "$1"; ARG1=$R; hp_cdr "$1"; hp_car "$R"; ARG2=$R; }

prim_app() {
  local name=$1 args=$2 sum prod lst v
  case $name in
    cons)    arg2 "$args"; hp_cons "$ARG1" "$ARG2" ;;
    car)     arg1 "$args"; hp_car "$ARG1" ;;
    cdr)     arg1 "$args"; hp_cdr "$ARG1" ;;
    'eq?')   arg2 "$args"; [ "$ARG1" = "$ARG2" ] && R="S:t" || R=NIL ;;
    'null?') arg1 "$args"; [ "$ARG1" = NIL ] && R="S:t" || R=NIL ;;
    'atom?') arg1 "$args"; case $ARG1 in P:*) R=NIL ;; *) R="S:t" ;; esac ;;
    '+')     sum=0;  lst=$args; while [ "$lst" != NIL ]; do hp_car "$lst"; v=$R; sum=$((sum + ${v#I:}));  hp_cdr "$lst"; lst=$R; done; R="I:$sum" ;;
    '*')     prod=1; lst=$args; while [ "$lst" != NIL ]; do hp_car "$lst"; v=$R; prod=$((prod * ${v#I:})); hp_cdr "$lst"; lst=$R; done; R="I:$prod" ;;
    '-')     arg2 "$args"; R="I:$(( ${ARG1#I:} - ${ARG2#I:} ))" ;;
    '<')     arg2 "$args"; [ "${ARG1#I:}" -lt "${ARG2#I:}" ] && R="S:t" || R=NIL ;;
    '=')     arg2 "$args"; [ "${ARG1#I:}" -eq "${ARG2#I:}" ] && R="S:t" || R=NIL ;;
    wrap)    arg1 "$args"; hp_cons "$ARG1" NIL; R="A:${R#P:}" ;;
    unwrap)  arg1 "$args"; hp_car "P:${ARG1#A:}" ;;
    eval)    arg2 "$args"; ev "$ARG1" "$ARG2" ;;
    run)     arg1 "$args"; sh -c "${ARG1#T:}"; R="I:$?" ;;
    print)   arg1 "$args"; lisp_write "$ARG1"; printf '\n'; R=NIL ;;
    *)       die "unknown primitive: $name" ;;
  esac
}

# ---- printer --------------------------------------------------------------
lisp_write() {
  local v=$1
  case $v in
    NIL) printf '()' ;;
    I:*) printf '%s' "${v#I:}" ;;
    S:*) printf '%s' "${v#S:}" ;;
    T:*) printf '"%s"' "${v#T:}" ;;
    O:*) printf '#<operative>' ;;
    A:*) printf '#<applicative>' ;;
    F:*) printf '#<prim-op %s>' "${v#F:}" ;;
    R:*) printf '#<prim %s>' "${v#R:}" ;;
    P:*) printf '('; write_list "$v"; printf ')' ;;
  esac
}
write_list() {
  local lst=$1 first=1
  while [ "$lst" != NIL ]; do
    case $lst in P:*) ;; *) printf ' . '; lisp_write "$lst"; return ;; esac
    [ "$first" = 1 ] || printf ' '; first=0
    hp_car "$lst"; lisp_write "$R"
    hp_cdr "$lst"; lst=$R
  done
}

# ---- bootstrap ------------------------------------------------------------
# Everything here is DEFINED IN LISP, on top of the operative core. None of it
# lives in the (bilingual) kernel.
PRELUDE="
  (define quote  (vau (x) #ignore x))
  (define list   (wrap (vau args #ignore args)))
  (define lambda (vau p env
                   (wrap (eval (cons (quote vau)
                                     (cons (car p) (cons (quote #ignore) (cdr p))))
                               env))))
"

setup_global() {
  env_new NIL; GLOBAL=$R
  for p in vau define if; do env_define "$GLOBAL" "S:$p" "F:$p"; done
  for p in cons car cdr 'eq?' 'null?' 'atom?' '+' '-' '*' '<' '=' wrap unwrap eval run print; do
    env_define "$GLOBAL" "S:$p" "R:$p"
  done
  env_define "$GLOBAL" "S:t"   "S:t"
  env_define "$GLOBAL" "S:nil" NIL
}

run_forms() {
  while rd_expr; do
    case $R in EOF) break ;; RPAREN) die "unexpected )" ;; esac
    ev "$R" "$GLOBAL"
  done
}

main() {
  setup_global
  # Boot order: minimal prelude -> embedded Lisp after the marker (stdlib
  # and/or program) -> explicit file-arg program -> stdin (standalone only).
  # The marker is built from fragments so it never appears literally here (else
  # the self-scan would match the kernel before the real, baked-in marker).
  SRC=$PRELUDE
  _mark="__PORTSH""_PAYLOAD__"
  _ran=0
  if [ -n "${PORTSH_SELF-}" ]; then
    _payload=$(awk -v m="$_mark" 'p;$0~m{p=1}' "$PORTSH_SELF" | tr -d '\r')
    [ -n "$_payload" ] && { SRC="$SRC $_payload"; _ran=1; }
  fi
  if [ "$#" -ge 1 ]; then SRC="$SRC $(cat "$1")"; _ran=1; fi
  [ "$_ran" = 0 ] && [ -z "${PORTSH_SELF-}" ] && SRC="$SRC $(cat)"
  run_forms
}

main "$@"
exit $?
:CMDSTART
@echo off
rem portsh — batch-hosted Lisp kernel (operative / vau core), port of kernel.sh.
rem FAST heap: cons cells live in variables CAR_<i>/CDR_<i> (O(1) read/write),
rem so there is NO setlocal anywhere in the eval chain (endlocal would revert
rem the heap). Recursion-safe locals use frame ids: a caller does
rem `set /a ND=%1+1 & call :fn !ND! args`, the callee's id is %1, inputs are
rem %2.. (stable across sub-calls), and any value held ACROSS a sub-call is
rem stored as _%1_name. Reader is iterative (mutates global SRC + parse stack).
rem MUST be CRLF (label lookup) and uses goto-dispatch (values contain parens).
setlocal enabledelayedexpansion
set "HN=0" & set "FID=0"
call :setup_global

rem Boot order: minimal prelude -> embedded Lisp after the marker (stdlib and/or
rem program) -> file-arg program. MK is built from fragments so the literal
rem never appears here (the self-scan would match the kernel, not the baked-in
rem final-line marker).
set "SRC="
set "SRC=!SRC! (define quote (vau (x) #ignore x))"
set "SRC=!SRC! (define list (wrap (vau args #ignore args)))"
set "SRC=!SRC! (define lambda (vau p env (wrap (eval (cons (quote vau) (cons (car p) (cons (quote #ignore) (cdr p)))) env))))"
set "MK=__PORTSH"
set "MK=!MK!_PAYLOAD__"
findstr /c:"!MK!" "%~f0" >nul 2>&1 || goto after_payload
for /f "delims=:" %%n in ('findstr /n /c:"!MK!" "%~f0"') do set "MLINE=%%n" & goto load_payload
:load_payload
for /f "usebackq skip=%MLINE% delims=" %%L in ("%~f0") do set "SRC=!SRC! %%L"
:after_payload
if "%~1"=="" goto run_it
for /f "usebackq delims=" %%L in ("%~1") do set "SRC=!SRC! %%L"
:run_it
set "SP=0" & set "DEPTH=0"
call :run_forms
exit /b 0

rem ============================ reader (iterative) ============================
:run_forms
:rf_loop
call :skipws
if "!SRC!"=="" goto :eof
set "ch=!SRC:~0,1!"
if "!ch!"=="(" goto rf_open
if "!ch!"==")" goto rf_close
goto rf_atom
:rf_open
set "ST_!SP!=LP" & set /a SP+=1 & set /a DEPTH+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_close
set "SRC=!SRC:~1!"
call :reduce_list
call :emit_top "!R!"
goto rf_loop
:rf_atom
call :read_atom
call :emit_top "!R!"
goto rf_loop

:skipws
if "!SRC!"=="" goto :eof
if "!SRC:~0,1!"==" " set "SRC=!SRC:~1!" & goto :skipws
goto :eof

:read_atom
set "tok="
:ra_loop
if "!SRC!"=="" goto ra_done
set "ch=!SRC:~0,1!"
if "!ch!"==" " goto ra_done
if "!ch!"=="(" goto ra_done
if "!ch!"==")" goto ra_done
set "tok=!tok!!ch!" & set "SRC=!SRC:~1!"
goto ra_loop
:ra_done
set "t=!tok!"
if "!t!"=="" set "R=S:" & goto :eof
set "c0=!t:~0,1!"
set "isnum=0"
for %%d in (0 1 2 3 4 5 6 7 8 9) do if "!c0!"=="%%d" set "isnum=1"
if "!isnum!"=="1" (set "R=I:!t!") else (set "R=S:!t!")
goto :eof

:reduce_list
set "acc=NIL"
:rl_loop
set /a SP-=1
call set "top=%%ST_!SP!%%"
if "!top!"=="LP" set /a DEPTH-=1 & set "R=!acc!" & goto :eof
call :hp_cons "!top!" "!acc!"
set "acc=!R!"
goto rl_loop

:emit_top
if !DEPTH! GTR 0 goto et_push
call :ev 1 "%~1" "!GLOBAL!"
goto :eof
:et_push
set "ST_!SP!=%~1" & set /a SP+=1
goto :eof

rem ===================== heap (variables: CAR_i / CDR_i) =====================
:hp_cons
set "CAR_%HN%=%~1"
set "CDR_%HN%=%~2"
set "R=P:%HN%"
set /a HN+=1
goto :eof
:hp_car
set "hcp=%~1" & set "hcp=!hcp:P:=!"
set "R=!CAR_%hcp%!"
goto :eof
:hp_cdr
set "hdp=%~1" & set "hdp=!hdp:P:=!"
set "R=!CDR_%hdp%!"
goto :eof
:hp_setcar
set "scp=%~1" & set "scp=!scp:P:=!"
set "CAR_%scp%=%~2"
goto :eof

rem ============================== environment ==============================
:env_new
call :hp_cons "NIL" "%~1"
goto :eof

:env_define
call :hp_car "%~1"
set "edB=!R!"
call :hp_cons "%~2" "%~3"
call :hp_cons "!R!" "!edB!"
call :hp_setcar "%~1" "!R!"
goto :eof

:env_lookup
set "elkEnv=%~1" & set "elkSym=%~2"
:elk_env
if "!elkEnv!"=="NIL" goto elk_unbound
call :hp_car "!elkEnv!"
set "elkB=!R!"
:elk_b
if "!elkB!"=="NIL" goto elk_next
call :hp_car "!elkB!"
set "elkP=!R!"
call :hp_car "!elkP!"
if "!R!"=="!elkSym!" goto elk_found
call :hp_cdr "!elkB!"
set "elkB=!R!"
goto elk_b
:elk_next
call :hp_cdr "!elkEnv!"
set "elkEnv=!R!"
goto elk_env
:elk_found
call :hp_cdr "!elkP!"
goto :eof
:elk_unbound
set "elkU=!elkSym:S:=!"
1>&2 echo portsh: unbound symbol: !elkU!
set "R=NIL"
goto :eof

rem =============================== evaluator ===============================
:ev
set "evX=%~2"
if "!evX!"=="NIL" set "R=NIL" & goto :eof
set "evPre=!evX:~0,2!"
if "!evPre!"=="I:" set "R=!evX!" & goto :eof
if "!evPre!"=="F:" set "R=!evX!" & goto :eof
if "!evPre!"=="R:" set "R=!evX!" & goto :eof
if "!evPre!"=="O:" set "R=!evX!" & goto :eof
if "!evPre!"=="A:" set "R=!evX!" & goto :eof
if "!evPre!"=="S:" call :env_lookup "%~3" "!evX!" & goto :eof
if "!evPre!"=="P:" goto ev_comb
set "R=!evX!" & goto :eof
:ev_comb
call :hp_car "%~2"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~3"
set "_%1_c=!R!"
call :hp_cdr "%~2"
set /a ND=%1+1 & call :combine !ND! "!_%1_c!" "!R!" "%~3"
goto :eof

:combine
set "cmbC=%~2" & set "cmbPre=!cmbC:~0,2!"
if "!cmbPre!"=="F:" goto cmb_oper
if "!cmbPre!"=="R:" goto cmb_app
if "!cmbPre!"=="A:" goto cmb_appl
if "!cmbPre!"=="O:" goto cmb_compound
set "R=NIL" & goto :eof
:cmb_oper
set "cmbN=%~2" & set "cmbN=!cmbN:~2!"
set /a ND=%1+1 & call :prim_oper !ND! "!cmbN!" "%~3" "%~4"
goto :eof
:cmb_app
set /a ND=%1+1 & call :eval_list !ND! "%~3" "%~4"
set "cmbN=%~2" & set "cmbN=!cmbN:~2!"
set /a ND=%1+1 & call :prim_app !ND! "!cmbN!" "!R!"
goto :eof
:cmb_appl
set "cmbC=%~2"
call :hp_car "P:!cmbC:~2!"
set "_%1_u=!R!"
set /a ND=%1+1 & call :eval_list !ND! "%~3" "%~4"
set /a ND=%1+1 & call :combine !ND! "!_%1_u!" "!R!" "%~4"
goto :eof
:cmb_compound
set /a ND=%1+1 & call :combine_oper !ND! "%~2" "%~3" "%~4"
goto :eof

:eval_list
if "%~2"=="NIL" set "R=NIL" & goto :eof
call :hp_car "%~2"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~3"
set "_%1_e=!R!"
call :hp_cdr "%~2"
set /a ND=%1+1 & call :eval_list !ND! "!R!" "%~3"
call :hp_cons "!_%1_e!" "!R!"
goto :eof

:prim_oper
set "poN=%~2"
if "!poN!"=="vau" goto po_vau
if "!poN!"=="define" goto po_define
if "!poN!"=="if" goto po_if
set "R=NIL" & goto :eof
:po_vau
call :hp_car "%~3"
set "poF=!R!"
call :hp_cdr "%~3"
set "poR1=!R!"
call :hp_car "!poR1!"
set "poEf=!R!"
call :hp_cdr "!poR1!"
set "poBody=!R!"
call :hp_cons "!poBody!" "%~4"
call :hp_cons "!poEf!" "!R!"
call :hp_cons "!poF!" "!R!"
set "poRes=!R!"
set "R=O:!poRes:P:=!"
goto :eof
:po_define
call :hp_car "%~3"
set "_%1_sym=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
call :env_define "%~4" "!_%1_sym!" "!R!"
set "R=!_%1_sym!"
goto :eof
:po_if
call :hp_car "%~3"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
set "poT=!R!"
call :hp_cdr "%~3"
set "poR1=!R!"
if "!poT!"=="NIL" goto po_if_else
call :hp_car "!poR1!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
goto :eof
:po_if_else
call :hp_cdr "!poR1!"
call :hp_car "!R!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
goto :eof

:combine_oper
set "coC=%~2"
set "coCell=P:!coC:O:=!"
call :hp_car "!coCell!"
set "_%1_f=!R!"
call :hp_cdr "!coCell!"
set "coR1=!R!"
call :hp_car "!coR1!"
set "_%1_ef=!R!"
call :hp_cdr "!coR1!"
set "coR2=!R!"
call :hp_car "!coR2!"
set "_%1_body=!R!"
call :hp_cdr "!coR2!"
set "_%1_senv=!R!"
set /a ND=%1+1 & call :build_alist !ND! "!_%1_f!" "%~3" "NIL"
set "_%1_al=!R!"
if "!_%1_ef!"=="S:#ignore" goto co_noenv
call :hp_cons "!_%1_ef!" "%~4"
call :hp_cons "!R!" "!_%1_al!"
set "_%1_al=!R!"
:co_noenv
call :hp_cons "!_%1_al!" "!_%1_senv!"
set /a ND=%1+1 & call :ev_seq !ND! "!_%1_body!" "!R!"
goto :eof

:build_alist
if "%~2"=="NIL" set "R=%~4" & goto :eof
set "baF=%~2"
if "!baF:~0,2!"=="S:" goto ba_rest
call :hp_car "%~2"
set "_%1_p=!R!"
call :hp_car "%~3"
call :hp_cons "!_%1_p!" "!R!"
call :hp_cons "!R!" "%~4"
set "_%1_acc=!R!"
call :hp_cdr "%~2"
set "_%1_ft=!R!"
call :hp_cdr "%~3"
set /a ND=%1+1 & call :build_alist !ND! "!_%1_ft!" "!R!" "!_%1_acc!"
goto :eof
:ba_rest
call :hp_cons "%~2" "%~3"
call :hp_cons "!R!" "%~4"
goto :eof

:ev_seq
set "_%1_lst=%~2"
set "_%1_val=NIL"
:es_loop
if "!_%1_lst!"=="NIL" set "R=!_%1_val!" & goto :eof
call :hp_car "!_%1_lst!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~3"
set "_%1_val=!R!"
call :hp_cdr "!_%1_lst!"
set "_%1_lst=!R!"
goto es_loop

rem =========================== primitives (applicative) ===========================
:prim_app
set "paN=%~2"
if "!paN!"=="cons" goto pa_cons
if "!paN!"=="car" goto pa_car
if "!paN!"=="cdr" goto pa_cdr
if "!paN!"=="eq?" goto pa_eq
if "!paN!"=="null?" goto pa_null
if "!paN!"=="atom?" goto pa_atom
if "!paN!"=="+" goto pa_add
if "!paN!"=="-" goto pa_sub
if "!paN!"=="*" goto pa_mul
if "!paN!"=="<" goto pa_lt
if "!paN!"=="=" goto pa_numeq
if "!paN!"=="wrap" goto pa_wrap
if "!paN!"=="unwrap" goto pa_unwrap
if "!paN!"=="eval" goto pa_eval
if "!paN!"=="print" goto pa_print
set "R=NIL" & goto :eof
:pa_cons
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
call :hp_cons "!paA1!" "!R!"
goto :eof
:pa_car
call :hp_car "%~3"
call :hp_car "!R!"
goto :eof
:pa_cdr
call :hp_car "%~3"
call :hp_cdr "!R!"
goto :eof
:pa_eq
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
if "!paA1!"=="!R!" (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_null
call :hp_car "%~3"
if "!R!"=="NIL" (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_atom
call :hp_car "%~3"
if "!R:~0,2!"=="P:" (set "R=NIL") else (set "R=S:t")
goto :eof
:pa_add
set "paSum=0" & set "paLst=%~3"
:pa_add_loop
if "!paLst!"=="NIL" set "R=I:!paSum!" & goto :eof
call :hp_car "!paLst!"
set "paV=!R!" & set /a paSum=paSum+!paV:~2!
call :hp_cdr "!paLst!"
set "paLst=!R!"
goto pa_add_loop
:pa_mul
set "paProd=1" & set "paLst=%~3"
:pa_mul_loop
if "!paLst!"=="NIL" set "R=I:!paProd!" & goto :eof
call :hp_car "!paLst!"
set "paV=!R!" & set /a paProd=paProd*!paV:~2!
call :hp_cdr "!paLst!"
set "paLst=!R!"
goto pa_mul_loop
:pa_sub
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a paD=!paA1:~2! - !R:~2!
set "R=I:!paD!"
goto :eof
:pa_lt
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a paX1=!paA1:~2!, paX2=!R:~2!
if !paX1! LSS !paX2! (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_numeq
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a paX1=!paA1:~2!, paX2=!R:~2!
if !paX1! EQU !paX2! (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_wrap
call :hp_car "%~3"
call :hp_cons "!R!" "NIL"
set "R=A:!R:P:=!"
goto :eof
:pa_unwrap
call :hp_car "%~3"
set "paA1=!R!"
call :hp_car "P:!paA1:A:=!"
goto :eof
:pa_eval
call :hp_car "%~3"
set "paEx=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a ND=%1+1 & call :ev !ND! "!paEx!" "!R!"
goto :eof
:pa_print
call :hp_car "%~3"
set /a ND=%1+1 & call :lisp_write !ND! "!R!"
<nul set /p "=!R!"
echo(
set "R=NIL"
goto :eof

rem ================================ printer ================================
:lisp_write
set "lwV=%~2"
if "!lwV!"=="NIL" set "R=()" & goto :eof
set "lwPre=!lwV:~0,2!"
if "!lwPre!"=="I:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="S:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="P:" goto lw_pair
set "R=#<obj>" & goto :eof
:lw_pair
set /a ND=%1+1 & call :render_list !ND! "%~2"
set "R=(!R!)"
goto :eof

:render_list
set "_%1_lst=%~2"
set "_%1_acc="
set "_%1_first=1"
:rl2
if "!_%1_lst!"=="NIL" set "R=!_%1_acc!" & goto :eof
call :hp_car "!_%1_lst!"
set /a ND=%1+1 & call :lisp_write !ND! "!R!"
set "_%1_piece=!R!"
if "!_%1_first!"=="1" (set "_%1_acc=!_%1_piece!") else (set "_%1_acc=!_%1_acc! !_%1_piece!")
set "_%1_first=0"
call :hp_cdr "!_%1_lst!"
set "_%1_lst=!R!"
goto rl2

rem ================================ bootstrap ================================
:setup_global
call :env_new "NIL"
set "GLOBAL=!R!"
call :env_define "!GLOBAL!" "S:vau" "F:vau"
call :env_define "!GLOBAL!" "S:define" "F:define"
call :env_define "!GLOBAL!" "S:if" "F:if"
call :env_define "!GLOBAL!" "S:cons" "R:cons"
call :env_define "!GLOBAL!" "S:car" "R:car"
call :env_define "!GLOBAL!" "S:cdr" "R:cdr"
call :env_define "!GLOBAL!" "S:eq?" "R:eq?"
call :env_define "!GLOBAL!" "S:null?" "R:null?"
call :env_define "!GLOBAL!" "S:atom?" "R:atom?"
call :env_define "!GLOBAL!" "S:+" "R:+"
call :env_define "!GLOBAL!" "S:-" "R:-"
call :env_define "!GLOBAL!" "S:*" "R:*"
call :env_define "!GLOBAL!" "S:<" "R:<"
call :env_define "!GLOBAL!" "S:=" "R:="
call :env_define "!GLOBAL!" "S:wrap" "R:wrap"
call :env_define "!GLOBAL!" "S:unwrap" "R:unwrap"
call :env_define "!GLOBAL!" "S:eval" "R:eval"
call :env_define "!GLOBAL!" "S:print" "R:print"
call :env_define "!GLOBAL!" "S:t" "S:t"
call :env_define "!GLOBAL!" "S:nil" "NIL"
goto :eof
__PORTSH_PAYLOAD__
