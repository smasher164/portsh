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
  local name=$1 ops=$2 denv=$3 formals eformal body sym test r _cmd _lst _tok _acc _rev _v _ln _out
  case $name in
    run)
      _cmd=; _lst=$ops
      while [ "$_lst" != NIL ]; do
        hp_car "$_lst"; _tok=$R
        _cmd="$_cmd ${_tok#?:}"
        hp_cdr "$_lst"; _lst=$R
      done
      sh -c "$_cmd"; R="I:$?" ;;
    'run-capture')
      _cmd=; _lst=$ops
      while [ "$_lst" != NIL ]; do
        hp_car "$_lst"; _tok=$R
        _cmd="$_cmd ${_tok#?:}"
        hp_cdr "$_lst"; _lst=$R
      done
      _out=$(sh -c "$_cmd"); _acc=NIL
      while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done <<RCEOF
$_out
RCEOF
      _rev=NIL
      while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done
      R=$_rev ;;
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
  local name=$1 args=$2 sum prod lst v _sa _l _o _n _f _ln _acc _rev _v
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
    'file-exists?') arg1 "$args"; [ -e "${ARG1#T:}" ] && R="S:t" || R=NIL ;;
    'string-append') _sa=; _l=$args
             while [ "$_l" != NIL ]; do hp_car "$_l"; _sa="$_sa${R#T:}"; hp_cdr "$_l"; _l=$R; done
             R="T:$_sa" ;;
    'string-length') arg1 "$args"; _sa=${ARG1#T:}; R="I:${#_sa}" ;;
    substring) hp_car "$args"; _sa=${R#T:}
             hp_cdr "$args"; hp_car "$R"; _o=${R#I:}
             hp_cdr "$args"; hp_cdr "$R"; hp_car "$R"; _n=${R#I:}
             R="T:$(printf '%s' "$_sa" | cut -c$((_o + 1))-$((_o + _n)) 2>/dev/null)" ;;
    'symbol->string') arg1 "$args"; R="T:${ARG1#S:}" ;;
    'string->symbol') arg1 "$args"; R="S:${ARG1#T:}" ;;
    'number->string') arg1 "$args"; R="T:${ARG1#I:}" ;;
    'string->number') arg1 "$args"; R="I:${ARG1#T:}" ;;
    'read-lines') arg1 "$args"; _f=${ARG1#T:}; _acc=NIL
             while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
             _rev=NIL
             while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; hp_cons "$_v" "$_rev"; _rev=$R; done
             R=$_rev ;;
    'write-lines') arg2 "$args"; _f=${ARG1#T:}; _l=$ARG2; : > "$_f"
             while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done
             R="S:t" ;;
    wrap)    arg1 "$args"; hp_cons "$ARG1" NIL; R="A:${R#P:}" ;;
    unwrap)  arg1 "$args"; hp_car "P:${ARG1#A:}" ;;
    eval)    arg2 "$args"; ev "$ARG1" "$ARG2" ;;
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
    T:*) printf '%s' "${v#T:}" ;;
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
  for p in vau define if run 'run-capture'; do env_define "$GLOBAL" "S:$p" "F:$p"; done
  for p in cons car cdr 'eq?' 'null?' 'atom?' '+' '-' '*' '<' '=' 'file-exists?' 'string-append' 'string-length' substring 'symbol->string' 'string->symbol' 'number->string' 'string->number' 'read-lines' 'write-lines' wrap unwrap eval print; do
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
for /f "usebackq skip=%MLINE% delims=" %%L in ("%~f0") do (set "ln=%%L" & call :addsrc)
:after_payload
if "%~1"=="" goto run_it
for /f "usebackq delims=" %%L in ("%~1") do (set "ln=%%L" & call :addsrc)
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
if "!ch!"=="'" goto rf_quote
set "chq=!ch:"=!"
if "!chq!"=="" goto rf_string
goto rf_atom
:rf_quote
rem 'x -> (quote x): push a quote-marker; apply_quotes wraps the next datum
set "ST_!SP!=QM" & set /a SP+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_string
rem string literal "..." -> T:...  (quote detected by removing " and testing empty)
set "SRC=!SRC:~1!"
set "rfs="
:rfs_loop
if "!SRC!"=="" goto rfs_done
set "sc=!SRC:~0,1!"
set "scq=!sc:"=!"
if "!scq!"=="" set "SRC=!SRC:~1!" & goto rfs_done
set "rfs=!rfs!!sc!" & set "SRC=!SRC:~1!"
goto rfs_loop
:rfs_done
set "R=T:!rfs!"
call :emit_top "!R!"
goto rf_loop
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
call :apply_quotes
if !DEPTH! GTR 0 goto et_push
call :ev 1 "!R!" "!GLOBAL!"
goto :eof
:et_push
set "ST_!SP!=!R!" & set /a SP+=1
goto :eof
:apply_quotes
rem while a quote-marker sits on top of the stack, wrap R as (quote R)
:aq_loop
if "!SP!"=="0" goto :eof
set /a aqsp=SP-1
call set "aqtop=%%ST_!aqsp!%%"
if not "!aqtop!"=="QM" goto :eof
set "SP=!aqsp!"
call :hp_cons "!R!" "NIL"
call :hp_cons "S:quote" "!R!"
goto aq_loop

:addsrc
rem append a source line to SRC, stripping a ';' line comment. for/f delims=;
rem keeps the code before the first ';' and preserves string literals; only a
rem ';' INSIDE a string is mishandled (rare).
for /f "tokens=1 delims=;" %%C in ("!ln!") do set "SRC=!SRC! %%C"
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
:hp_setcdr
set "sdp=%~1" & set "sdp=!sdp:P:=!"
set "CDR_%sdp%=%~2"
goto :eof
:list_reverse
rem reverse a list (flat helper; never re-enters :ev, so plain temps are safe)
set "lrL=%~1" & set "lrAcc=NIL"
:lr_loop
if "!lrL!"=="NIL" set "R=!lrAcc!" & goto :eof
call :hp_car "!lrL!"
set "lrV=!R!"
call :hp_cdr "!lrL!"
set "lrL=!R!"
call :hp_cons "!lrV!" "!lrAcc!"
set "lrAcc=!R!"
goto lr_loop

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
rem Hot path: heap accessors are INLINED here (no call overhead). Walk frames;
rem within a frame walk the binding alist; on a hit past the head, splice to
rem front (move-to-front) so hot symbols settle into a single-set lookup.
set "elkEnv=%~1" & set "elkSym=%~2"
:elk_env
if "!elkEnv!"=="NIL" goto elk_unbound
set "ei=!elkEnv:P:=!"
set "elkB=!CAR_%ei%!"
set "elkPrev="
:elk_b
if "!elkB!"=="NIL" goto elk_next
set "bi=!elkB:P:=!"
set "elkP=!CAR_%bi%!"
set "pi=!elkP:P:=!"
if "!CAR_%pi%!"=="!elkSym!" goto elk_found
set "elkPrev=!elkB!"
set "elkB=!CDR_%bi%!"
goto elk_b
:elk_next
set "elkEnv=!CDR_%ei%!"
goto elk_env
:elk_found
if "!elkPrev!"=="" goto elk_val
set "elkNext=!CDR_%bi%!"
call :hp_setcdr "!elkPrev!" "!elkNext!"
set "elkHead=!CAR_%ei%!"
call :hp_setcdr "!elkB!" "!elkHead!"
call :hp_setcar "!elkEnv!" "!elkB!"
:elk_val
set "R=!CDR_%pi%!"
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
set "eci=%~2" & set "eci=!eci:P:=!"
set /a ND=%1+1 & call :ev !ND! "!CAR_%eci%!" "%~3"
set "_%1_c=!R!"
set "eci=%~2" & set "eci=!eci:P:=!"
set /a ND=%1+1 & call :combine !ND! "!_%1_c!" "!CDR_%eci%!" "%~3"
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
set "eli=%~2" & set "eli=!eli:P:=!"
set /a ND=%1+1 & call :ev !ND! "!CAR_%eli%!" "%~3"
set "_%1_e=!R!"
set "eli=%~2" & set "eli=!eli:P:=!"
set /a ND=%1+1 & call :eval_list !ND! "!CDR_%eli%!" "%~3"
set "CAR_%HN%=!_%1_e!" & set "CDR_%HN%=!R!" & set "R=P:%HN%" & set /a HN+=1
goto :eof

:prim_oper
set "poN=%~2"
if "!poN!"=="vau" goto po_vau
if "!poN!"=="define" goto po_define
if "!poN!"=="if" goto po_if
if "!poN!"=="run" goto po_run
if "!poN!"=="run-capture" goto po_runcap
set "R=NIL" & goto :eof
:po_runcap
rem render operands into a command line, run it, capture stdout as a line list
set "rcCmd=" & set "rcLst=%~3"
:rc_loop
if "!rcLst!"=="NIL" goto rc_exec
call :hp_car "!rcLst!"
set "rcTok=!R!"
set "rcCmd=!rcCmd! !rcTok:~2!"
call :hp_cdr "!rcLst!"
set "rcLst=!R!"
goto rc_loop
:rc_exec
cmd /c "!rcCmd!" > "%TEMP%\portsh_rc.txt" 2>&1
set "rcAcc=NIL"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rc.txt") do (
  call :hp_cons "T:%%L" "!rcAcc!"
  set "rcAcc=!R!"
)
call :list_reverse "!rcAcc!"
goto :eof
:po_run
rem render unevaluated operands (symbols/ints) into a command line, execute it
set "porCmd=" & set "porLst=%~3"
:po_run_loop
if "!porLst!"=="NIL" goto po_run_exec
call :hp_car "!porLst!"
set "porTok=!R!"
set "porCmd=!porCmd! !porTok:~2!"
call :hp_cdr "!porLst!"
set "porLst=!R!"
goto po_run_loop
:po_run_exec
cmd /c "!porCmd!"
set "R=I:!errorlevel!"
goto :eof
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
set "ci=%~2" & set "ci=!ci:O:=!"
set "_%1_f=!CAR_%ci%!"
set "cr1=!CDR_%ci%!" & set "cr1=!cr1:P:=!"
set "_%1_ef=!CAR_%cr1%!"
set "cr2=!CDR_%cr1%!" & set "cr2=!cr2:P:=!"
set "_%1_body=!CAR_%cr2%!"
set "_%1_senv=!CDR_%cr2%!"
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
if "!paN!"=="file-exists?" goto pa_fex
if "!paN!"=="string-append" goto pa_strapp
if "!paN!"=="string-length" goto pa_strlen
if "!paN!"=="substring" goto pa_substr
if "!paN!"=="symbol->string" goto pa_sym2str
if "!paN!"=="string->symbol" goto pa_str2sym
if "!paN!"=="number->string" goto pa_num2str
if "!paN!"=="string->number" goto pa_str2num
if "!paN!"=="read-lines" goto pa_rdlines
if "!paN!"=="write-lines" goto pa_wrlines
set "R=NIL" & goto :eof
:pa_rdlines
call :hp_car "%~3"
set "rlF=!R:~2!" & set "rlAcc=NIL"
for /f "usebackq delims=" %%L in ("!rlF!") do (
  call :hp_cons "T:%%L" "!rlAcc!"
  set "rlAcc=!R!"
)
call :list_reverse "!rlAcc!"
goto :eof
:pa_wrlines
call :hp_car "%~3"
set "wlF=!R:~2!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set "wlL=!R!"
break > "!wlF!"
:pa_wl_loop
if "!wlL!"=="NIL" set "R=S:t" & goto :eof
call :hp_car "!wlL!"
set "wlLine=!R:~2!"
call :wl_emit "!wlF!"
call :hp_cdr "!wlL!"
set "wlL=!R!"
goto pa_wl_loop
:wl_emit
rem redirect-first + delayed !var! so line content isn't re-scanned for redirs
>>"%~1" echo(!wlLine!
goto :eof
:pa_fex
call :hp_car "%~3"
set "fexP=!R:~2!"
if exist "!fexP!" (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_strapp
set "saS=" & set "saL=%~3"
:pa_sa_loop
if "!saL!"=="NIL" set "R=T:!saS!" & goto :eof
call :hp_car "!saL!"
set "saV=!R!" & set "saS=!saS!!saV:~2!"
call :hp_cdr "!saL!"
set "saL=!R!"
goto pa_sa_loop
:pa_strlen
call :hp_car "%~3"
set "slS=!R:~2!" & set "slN=0"
:pa_sl_loop
call set "slC=%%slS:~!slN!,1%%"
if "!slC!"=="" set "R=I:!slN!" & goto :eof
set /a slN+=1
goto pa_sl_loop
:pa_substr
call :hp_car "%~3"
set "ssS=!R:~2!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set "ssO=!R:~2!"
call :hp_cdr "%~3"
call :hp_cdr "!R!"
call :hp_car "!R!"
set "ssN=!R:~2!"
call set "R=T:%%ssS:~!ssO!,!ssN!%%"
goto :eof
:pa_sym2str
call :hp_car "%~3" & set "R=T:!R:~2!"
goto :eof
:pa_str2sym
call :hp_car "%~3" & set "R=S:!R:~2!"
goto :eof
:pa_num2str
call :hp_car "%~3" & set "R=T:!R:~2!"
goto :eof
:pa_str2num
call :hp_car "%~3" & set "R=I:!R:~2!"
goto :eof
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
if "!lwPre!"=="T:" set "R=!lwV:~2!" & goto :eof
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
call :env_define "!GLOBAL!" "S:file-exists?" "R:file-exists?"
call :env_define "!GLOBAL!" "S:string-append" "R:string-append"
call :env_define "!GLOBAL!" "S:string-length" "R:string-length"
call :env_define "!GLOBAL!" "S:substring" "R:substring"
call :env_define "!GLOBAL!" "S:symbol->string" "R:symbol->string"
call :env_define "!GLOBAL!" "S:string->symbol" "R:string->symbol"
call :env_define "!GLOBAL!" "S:number->string" "R:number->string"
call :env_define "!GLOBAL!" "S:string->number" "R:string->number"
call :env_define "!GLOBAL!" "S:read-lines" "R:read-lines"
call :env_define "!GLOBAL!" "S:write-lines" "R:write-lines"
call :env_define "!GLOBAL!" "S:run" "F:run"
call :env_define "!GLOBAL!" "S:run-capture" "F:run-capture"
call :env_define "!GLOBAL!" "S:t" "S:t"
call :env_define "!GLOBAL!" "S:nil" "NIL"
goto :eof
__PORTSH_PAYLOAD__
;;; portsh standard library — plain userspace Lisp on top of the kernel.
;;; Loaded at boot in the "full" distribution (portsh-full.cmd). Everything
;;; here is written with kernel primitives + the minimal prelude only.
;;;
;;; Primitives available (from the kernel + prelude):
;;;   operatives : vau define if quote lambda
;;;   applicative: cons car cdr eq? null? atom? + - * < = wrap unwrap eval
;;;                print run file-exists? list
;;; Notes / deliberate gaps in the kernel this stdlib must respect:
;;;   - binary - < =, no / and no mod, no >  (we derive > >= <= here)
;;;   - no string primitives (no length/concat/substring) -> out of scope
;;;   - eq? compares the underlying tagged value, so it works for symbols,
;;;     integers, nil, t, and identity of pairs (same cell).
;;;
;;; Organization (top to bottom): booleans, list accessors, list construction
;;; & length, list query/access (nth/member/assoc/take/drop), higher-order
;;; (map/filter/fold/apply/compose/for-each), numeric (min/max/abs),
;;; comparison derivatives, and control-flow operatives (and/or/when/cond/
;;; let/let*/case).

;;; ------------------------------------------------------------------ booleans
(define not (lambda (x) (if x nil t)))

;;; ----------------------------------------------------------- list accessors
(define cadr   (lambda (x) (car (cdr x))))
(define caddr  (lambda (x) (car (cdr (cdr x)))))
(define cddr   (lambda (x) (cdr (cdr x))))
(define cdar   (lambda (x) (cdr (car x))))
(define caar   (lambda (x) (car (car x))))
(define cadar  (lambda (x) (car (cdr (car x)))))

;;; -------------------------------------------------- list construction/length
(define last (lambda (xs) (if (null? (cdr xs)) (car xs) (last (cdr xs)))))
(define begin (lambda args (last args)))             ; eval args L-to-R, return last
(define length (lambda (xs) (if (null? xs) 0 (+ 1 (length (cdr xs))))))
(define append (lambda (a b) (if (null? a) b (cons (car a) (append (cdr a) b)))))
(define reverse (lambda (xs) (if (null? xs) nil (append (reverse (cdr xs)) (cons (car xs) nil)))))

;;; ----------------------------------------------- list access / query helpers
;; list-tail: drop the first n cells, return the rest of the list.
(define list-tail (lambda (xs n) (if (= n 0) xs (list-tail (cdr xs) (- n 1)))))
;; nth: 0-indexed element.
(define nth (lambda (xs n) (car (list-tail xs n))))
;; take/drop: first n / all-but-first n.
(define take (lambda (xs n) (if (= n 0) nil (if (null? xs) nil (cons (car xs) (take (cdr xs) (- n 1)))))))
(define drop list-tail)
;; member?: t if x is in xs (uses eq?, i.e. symbol/int/nil identity).
(define member? (lambda (x xs)
  (if (null? xs) nil
    (if (eq? x (car xs)) t (member? x (cdr xs))))))
;; assoc: find (key . val) pair in an alist by eq? on the key; nil if absent.
(define assoc (lambda (k al)
  (if (null? al) nil
    (if (eq? k (caar al)) (car al) (assoc k (cdr al))))))

;;; ------------------------------------------------------------- higher-order
(define map (lambda (f xs) (if (null? xs) nil (cons (f (car xs)) (map f (cdr xs))))))
;; map2: map a binary fn over two equal-length lists (zipping fn).
(define map2 (lambda (f xs ys)
  (if (null? xs) nil
    (cons (f (car xs) (car ys)) (map2 f (cdr xs) (cdr ys))))))
;; zip: list of (x . y) pairs from two lists.
(define zip (lambda (xs ys) (map2 cons xs ys)))
(define filter (lambda (p xs)
  (if (null? xs) nil
    (if (p (car xs)) (cons (car xs) (filter p (cdr xs))) (filter p (cdr xs))))))
(define foldl (lambda (f acc xs) (if (null? xs) acc (foldl f (f acc (car xs)) (cdr xs)))))
;; foldr: right fold. (foldr f z (a b c)) = (f a (f b (f c z))).
(define foldr (lambda (f z xs) (if (null? xs) z (f (car xs) (foldr f z (cdr xs))))))
;; for-each: like map but for side effects (run/print); returns nil.
(define for-each (lambda (f xs) (if (null? xs) nil (begin (f (car xs)) (for-each f (cdr xs))))))
;; apply: call applicative f on a list of already-evaluated args.
;;   built by consing f onto the (quoted) arg list and evaluating it; the
;;   args are quoted so they pass through unchanged (they're already values).
(define apply (vau (f args) env
  (eval (cons (eval f env)
              (map (lambda (a) (list (quote quote) a)) (eval args env)))
        env)))
;; compose: (compose f g) is the fn x -> (f (g x)).
(define compose (lambda (f g) (lambda (x) (f (g x)))))

;;; --------------------------------------------- comparison derivatives (< =)
(define <= (lambda (a b) (if (< a b) t (= a b))))
(define >  (lambda (a b) (< b a)))
(define >= (lambda (a b) (<= b a)))

;;; ----------------------------------------------------------------- numeric
(define abs (lambda (n) (if (< n 0) (- 0 n) n)))
(define max (lambda (a b) (if (< a b) b a)))
(define min (lambda (a b) (if (< a b) a b)))
;; sum/product over a list (handy for counting build steps, etc.)
(define sum     (lambda (xs) (foldl + 0 xs)))
(define product (lambda (xs) (foldl * 1 xs)))

;;; --------------------------------------------- control-flow operatives (vau)
;; and/or RETURN THE VALUE (not just t) and short-circuit.
(define and (vau args env
  (if (null? args) t
    (if (null? (cdr args)) (eval (car args) env)
      (if (eval (car args) env) (eval (cons (quote and) (cdr args)) env) nil)))))
(define or (vau args env
  (if (null? args) nil
    ((lambda (v) (if v v (eval (cons (quote or) (cdr args)) env))) (eval (car args) env)))))
(define when   (vau args env (if (eval (car args) env) (eval (cons (quote begin) (cdr args)) env) nil)))
(define unless (vau args env (if (eval (car args) env) nil (eval (cons (quote begin) (cdr args)) env))))
(define cond (vau clauses env
  (if (null? clauses) nil
    (if (eval (car (car clauses)) env)
        (eval (cons (quote begin) (cdr (car clauses))) env)
        (eval (cons (quote cond) (cdr clauses)) env)))))

;; let: ((x a) (y b)) body...  ->  ((lambda (x y) body...) a b)
(define let (vau args env
  (eval (cons (cons (quote lambda) (cons (map car (car args)) (cdr args)))
              (map cadr (car args)))
        env)))
;; let*: sequential binding — each binding sees the previous ones. Expands to
;; nested single-binding lets.
(define let* (vau args env
  (eval (if (null? (car args))
            (cons (quote begin) (cdr args))
            (cons (quote let)
                  (cons (cons (car (car args)) nil)
                        (cons (cons (quote let*)
                                    (cons (cdr (car args)) (cdr args)))
                              nil))))
        env)))

;; case: (case key (datum body...) ... (else body...)) — dispatch on eq? to a
;; literal datum. The key is evaluated once; clause data are unevaluated
;; literals (Scheme style: write `(case x (foo 1) (2 'two) (else ...))`, not
;; `(case x ('foo 1) ...)`). `else` matches anything.
(define case (vau args env
  ((lambda (k)
     (eval (cons (quote cond)
                 (map (lambda (cl)
                        (if (eq? (car cl) (quote else))
                            (cons (quote t) (cdr cl))
                            (cons (list (quote eq?) (list (quote quote) (car cl))
                                        (list (quote quote) k))
                                  (cdr cl))))
                      (cdr args)))
           env))
   (eval (car args) env))))
