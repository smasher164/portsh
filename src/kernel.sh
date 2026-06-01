#!/bin/sh
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
  local name=$1 ops=$2 denv=$3 formals eformal body sym test r _cmd _lst _tok
  case $name in
    run)
      _cmd=; _lst=$ops
      while [ "$_lst" != NIL ]; do
        hp_car "$_lst"; _tok=$R
        _cmd="$_cmd ${_tok#?:}"
        hp_cdr "$_lst"; _lst=$R
      done
      sh -c "$_cmd"; R="I:$?" ;;
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
  for p in vau define if run; do env_define "$GLOBAL" "S:$p" "F:$p"; done
  for p in cons car cdr 'eq?' 'null?' 'atom?' '+' '-' '*' '<' '=' wrap unwrap eval print; do
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
