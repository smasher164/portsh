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

# zsh (and bash) cap function-recursion depth; zsh's default FUNCNEST=500 aborts deep
# NON-tail recursion (append/reverse/gc_mark's car-recursion) that dash/mksh run fine,
# diverging behavior by shell. Raise it to the host-stack ceiling so every shell behaves
# the same (completes, or segfaults at the same pathological depth). dash/mksh have no
# FUNCNEST and harmlessly ignore this assignment.
FUNCNEST=1000000

die() { printf 'portsh: %s\n' "$1" >&2; exit 1; }

# ---- heap (swappable for the append-only dd-file heap later) --------------
HEAP_N=0; FREE_HEAD=NIL; MARKGEN=0; LAST_GC=0; NURSERY=${NURSERY:-50000}; GC_RUNNING=; ROOTS=
# allocate a pair: reuse a GC'd cell from the free-list if any, else grow the heap.
# The gc trigger lives ONLY in the grow branch -- the common (free-list reuse) path
# has zero extra cost. gc fires when the high-water HEAP_N has grown by NURSERY since
# the last collection, i.e. exactly when we are about to make the heap bigger; if gc
# reclaims enough that the free-list covers the churn, HEAP_N stops growing and gc
# stops firing (memory stays bounded). The cons args ($1/$2) are passed as extra
# roots so the cell about to be built survives the collection.
hp_cons() {
  if [ "$FREE_HEAD" != NIL ]; then
    _fi=$FREE_HEAD; eval "FREE_HEAD=\$H_${_fi}_d"
    eval "H_${_fi}_a=\$1"; eval "H_${_fi}_d=\$2"; R="P:$_fi"
  else
    if [ -z "$GC_RUNNING" ] && [ $((HEAP_N - LAST_GC)) -ge "$NURSERY" ]; then gc_run "$1" "$2"; fi
    if [ "$FREE_HEAD" != NIL ]; then
      _fi=$FREE_HEAD; eval "FREE_HEAD=\$H_${_fi}_d"
      eval "H_${_fi}_a=\$1"; eval "H_${_fi}_d=\$2"; R="P:$_fi"
    else
      eval "H_${HEAP_N}_a=\$1"; eval "H_${HEAP_N}_d=\$2"; R="P:$HEAP_N"; HEAP_N=$((HEAP_N + 1))
    fi
  fi
}
# ---- mark-sweep GC (region reclamation with explicit roots) ---------------
# mark: DFS from a root -- recurse on car (depth = data NESTING, shallow), loop on
# cdr (long list spines stay iterative, no host-stack growth). Generation marks
# (H_i_m == MARKGEN) avoid an O(heap) clear per cycle. A:/O: carry a heap index too.
gc_mark() {
  local _v=$1 _i _mk _ca
  while :; do
    case $_v in P:*|A:*|O:*) _i=${_v#?:} ;; *) return ;; esac
    eval "_mk=\${H_${_i}_m:-}"
    [ "$_mk" = "$MARKGEN" ] && return
    eval "H_${_i}_m=$MARKGEN"
    eval "_ca=\$H_${_i}_a"; gc_mark "$_ca"
    eval "_v=\$H_${_i}_d"
  done
}
# sweep: link every unmarked cell into the free-list via its own _d slot (no extra
# storage, no rename). Reused by hp_cons. Cells keep their var slots (names reused).
gc_sweep() {
  local _i=0 _mk
  FREE_HEAD=NIL
  while [ "$_i" -lt "$HEAP_N" ]; do
    eval "_mk=\${H_${_i}_m:-}"
    [ "$_mk" = "$MARKGEN" ] || { eval "H_${_i}_d=\$FREE_HEAD"; FREE_HEAD=$_i; }
    _i=$((_i + 1))
  done
}
# gc_run: a precise mark-sweep. Roots are GLOBAL, R, the cons args being built ($@),
# and the EXPLICIT root stack $ROOTS. We do NOT scan `set`: that only works on mksh
# (whose `set` lists every frame's locals); dash/bash/zsh `set` shows only the
# INNERMOST binding of a shadowed name, so a recursive interpreter (every frame reuses
# `env`/`x`/`e`) hides ancestor frames' live refs -> freed-while-live -> corruption.
# Instead each allocating frame appends its live, non-cons-arg refs (active envs +
# intermediate evaluated values) to $ROOTS and restores on exit. $ROOTS is peeled with
# parameter expansion (a `for ... in $ROOTS` would NOT split on zsh; read -a isn't in
# dash) so root-finding is identical on every shell.
gc_run() {
  [ -n "$GC_RUNNING" ] && return
  GC_RUNNING=1
  local _v _rest
  MARKGEN=$((MARKGEN + 1))
  gc_mark "$GLOBAL"; gc_mark "$R"
  for _v in "$@"; do gc_mark "$_v"; done
  _rest=$ROOTS
  while [ -n "$_rest" ]; do
    case $_rest in *' '*) _v=${_rest%% *}; _rest=${_rest#* } ;; *) _v=$_rest; _rest= ;; esac
    gc_mark "$_v"
  done
  gc_sweep
  LAST_GC=$HEAP_N
  GC_RUNNING=
}
# car/cdr of a non-pair -> NIL (matches the cmd kernel, which reads an unset CAR_/CDR_).
# Lisp-ish convention; keeps sh from dying under `set -u` where cmd silently continues,
# so both hosts agree (consistency) and recursions terminate instead of hanging.
hp_car()    { case $1 in P:*) _i=${1#P:}; eval "R=\$H_${_i}_a";; *) R=NIL;; esac; }
hp_cdr()    { case $1 in P:*) _i=${1#P:}; eval "R=\$H_${_i}_d";; *) R=NIL;; esac; }
hp_setcar() { _i=${1#P:}; eval "H_${_i}_a=\$2"; }
hp_setcdr() { _i=${1#P:}; eval "H_${_i}_d=\$2"; }

# ---- reader (token-based, pure POSIX — no per-char peek) ------------------
# We never extract one character at a time: dispatch by matching the SRC prefix
# with `case`, and grab whole atoms/strings with ${SRC%%[set]*} (cost is the
# distance to the next delimiter, not O(n) per char). A char-at-a-time reader is
# the *only* thing that needs the portable first-char peek ${SRC%"${SRC#?}"},
# which removes a whole-string suffix per char and makes parsing O(n^2) (~80s on
# the stdlib). This is O(n) (~0.2s) on every POSIX shell, dash included.
_NL='
'
_TAB=$(printf '\t')
_WS=" $_TAB$_NL"            # whitespace: space, tab, newline
_DELIM="$_WS()'\";"        # atom delimiters: whitespace + ( ) ' " ;

rd_skipws() {
  while :; do
    SRC=${SRC#"${SRC%%[!$_WS]*}"}              # drop the leading whitespace run
    case $SRC in
      ';'*) case $SRC in
              *"$_NL"*) SRC=${SRC#*"$_NL"} ;;  # comment: skip to end of line...
              *)        SRC= ;;                #          ...or to EOF
            esac ;;
      *) return ;;
    esac
  done
}

rd_expr() {
  rd_skipws
  case $SRC in
    '')   R=EOF; return 1 ;;
    '('*) SRC=${SRC#?}; rd_list ;;
    ')'*) SRC=${SRC#?}; R=RPAREN ;;
    "'"*) SRC=${SRC#?}; rd_quote ;;
    '"'*) rd_string ;;
    *)    rd_atom ;;
  esac
  return 0
}

rd_quote() { local q; rd_expr; q=$R; hp_cons "$q" NIL; q=$R; hp_cons "S:quote" "$q"; }

rd_list() {
  local head tail _rs=$ROOTS
  rd_expr
  case $R in RPAREN|EOF) R=NIL; return ;; esac
  # dotted tail: (a b . c) — '.' only appears in a tail-position read.
  if [ "$R" = 'S:.' ]; then
    rd_expr; tail=$R       # the cdr datum
    rd_expr                # consume the closing ')'
    R=$tail; return
  fi
  head=$R
  ROOTS="$_rs $head"                     # head must survive the recursive (allocating) tail read
  rd_list; tail=$R
  hp_cons "$head" "$tail"
  ROOTS=$_rs
}

rd_atom() {
  local tok
  tok=${SRC%%[$_DELIM]*}        # grab up to the next delimiter, in one op
  SRC=${SRC#"$tok"}
  case $tok in
    -|''|*[!0-9-]*) R="S:$tok" ;;
    *)              R="I:$tok" ;;
  esac
}

rd_string() {
  # Strings are SINGLE-LINE on both hosts (a batch variable cannot hold a
  # newline). sh vars happen to tolerate one, so we reject a raw newline here
  # to keep the language consistent: a multiline string literal fails loudly on
  # sh exactly as it would mis-parse on batch, instead of silently working on
  # one host only. Multiline text is a list of line-strings (see read-lines).
  local s
  SRC=${SRC#?}                       # drop the opening "
  s=${SRC%%\"*}                      # body up to the closing " (one op)
  if [ "$s" = "$SRC" ]; then die "unterminated string literal"; fi
  SRC=${SRC#"$s"}; SRC=${SRC#?}      # drop the body and the closing "
  case $s in
    *"$_NL"*) die "newline in string literal (strings are single-line; use a list of lines)" ;;
  esac
  R="T:$s"
}

# ---- environment: pair (bindings-alist . parent) --------------------------
env_new() { hp_cons NIL "$1"; }

env_define() {
  local env=$1 sym=$2 val=$3 binds pair _rs=$ROOTS
  ROOTS="$_rs $env $sym $val"            # env live across the conses (hp_setcar after); binds reachable via env
  hp_car "$env"; binds=$R
  hp_cons "$sym" "$val"; pair=$R
  hp_cons "$pair" "$binds"
  hp_setcar "$env" "$R"
  ROOTS=$_rs
}

env_lookup() {
  local env=$1 sym=$2 binds pair k prev next head
  while [ "$env" != NIL ]; do
    hp_car "$env"; binds=$R
    prev=NIL
    while [ "$binds" != NIL ]; do
      hp_car "$binds"; pair=$R
      hp_car "$pair"; k=$R
      if [ "$k" = "$sym" ]; then
        if [ "$prev" != NIL ]; then        # move-to-front: splice pair to head
          hp_cdr "$binds"; next=$R
          hp_setcdr "$prev" "$next"
          hp_car "$env"; head=$R
          hp_setcdr "$binds" "$head"
          hp_setcar "$env" "$binds"
        fi
        hp_cdr "$pair"; return
      fi
      prev=$binds
      hp_cdr "$binds"; binds=$R
    done
    hp_cdr "$env"; env=$R
  done
  die "unbound symbol: ${sym#S:}"
}

# ---- evaluator: an explicit loop, so tail calls don't grow the host stack ---
# Self-evaluating values and symbol lookup return immediately. For a combination
# we evaluate the combiner, then dispatch in an inner loop: applicatives unwrap
# (and loop) after evaluating operands; primitives return; but the two TAIL
# positions — the chosen branch of `if`, and the last form of a compound
# operative's body — set x/env and `continue` the OUTER loop instead of
# recursing. That gives unbounded tail recursion (loops/foldl) in constant host
# stack, and skips a frame per tail call.
ev() {
  local x=$1 env=$2 c operands w r ne formals eformal body senv tv _rs=$ROOTS
  # _rs holds all ANCESTOR frames' roots; at each program point we set ROOTS to
  # "$_rs <this frame's live, non-cons-arg refs>" so a gc inside any hp_cons sees the
  # whole live stack. Every exit restores ROOTS=$_rs. (Cons ARGS are rooted by gc_run
  # "$@" already; values reachable from a rooted ref are marked transitively.)
  while :; do
    ROOTS="$_rs $x $env"
    case $x in
      S:*) env_lookup "$env" "$x"; ROOTS=$_rs; return ;;
      P:*) ;;
      *)   R=$x; ROOTS=$_rs; return ;;   # NIL, I:, T:, F:, R:, O:, A: self-evaluate
    esac
    hp_car "$x"; ev "$R" "$env"; c=$R     # evaluate the combiner (not tail)
    hp_cdr "$x"; operands=$R
    while :; do
      ROOTS="$_rs $x $env $c $operands"
      case $c in
        R:*) eval_list "$operands" "$env"; prim_app "${c#R:}" "$R"; ROOTS=$_rs; return ;;
        A:*) hp_car "P:${c#A:}"; w=$R
             ROOTS="$_rs $x $env $c $operands $w"
             eval_list "$operands" "$env"; operands=$R; c=$w ;;     # unwrap, loop
        F:*) case $c in
               'F:if') hp_car "$operands"; ev "$R" "$env"; tv=$R
                       hp_cdr "$operands"; r=$R
                       if [ "$tv" = NIL ]; then hp_cdr "$r"; hp_car "$R"; else hp_car "$r"; fi
                       x=$R; break ;;                              # tail -> outer loop
               *) prim_oper "${c#F:}" "$operands" "$env"; ROOTS=$_rs; return ;;
             esac ;;
        O:*) r="P:${c#O:}"
             hp_car "$r"; formals=$R
             hp_cdr "$r"; r=$R; hp_car "$r"; eformal=$R
             hp_cdr "$r"; r=$R; hp_car "$r"; body=$R
             hp_cdr "$r"; senv=$R
             ROOTS="$_rs $x $env $c $operands $body"
             env_new "$senv"; ne=$R
             ROOTS="$_rs $env $c $operands $body $ne"
             bind_tree "$ne" "$formals" "$operands"
             case $eformal in 'S:#ignore') ;; *) env_define "$ne" "$eformal" "$env" ;; esac
             [ "$body" = NIL ] && { R=NIL; ROOTS=$_rs; return; }
             while :; do                                          # eval body
               hp_cdr "$body"; r=$R
               [ "$r" = NIL ] && break                           # ...last form is tail
               ROOTS="$_rs $env $c $ne $body"
               hp_car "$body"; ev "$R" "$ne"
               body=$r
             done
             hp_car "$body"; x=$R; env=$ne; break ;;             # tail -> outer loop
        *) die "not combinable: $c" ;;
      esac
    done
  done
}

eval_list() {                    # map ev over a list -> R = list of values
  local lst=$1 env=$2 e rest _rs=$ROOTS
  [ "$lst" = NIL ] && { R=NIL; return; }
  ROOTS="$_rs $lst $env"                  # lst (for cdr) + env live across element ev
  hp_car "$lst"; e=$R; ev "$e" "$env"; e=$R
  hp_cdr "$lst"
  ROOTS="$_rs $env $e"                    # evaluated e must survive the recursive eval_list
  eval_list "$R" "$env"; rest=$R
  hp_cons "$e" "$rest"
  ROOTS=$_rs
}

bind_tree() {                    # env formals operands  (formals: NIL | symbol-rest | tree)
  local env=$1 formals=$2 operands=$3 fcar ftail _rs=$ROOTS
  ROOTS="$_rs $env $formals $operands"   # all three live across env_define/recursion (it conses)
  case $formals in
    NIL) ;;
    S:*) env_define "$env" "$formals" "$operands" ;;
    P:*) hp_car "$formals"; fcar=$R
         hp_car "$operands"; env_define "$env" "$fcar" "$R"
         hp_cdr "$formals"; ftail=$R
         hp_cdr "$operands"; bind_tree "$env" "$ftail" "$R" ;;
  esac
  ROOTS=$_rs
}

# ---- primitive operatives (unevaluated operands + env) --------------------
prim_oper() {
  local name=$1 ops=$2 denv=$3 formals eformal body sym test r _cmd _lst _tok _acc _rev _v _ln _out _rs=$ROOTS
  case $name in
    gc)  # explicit collection; auto-gc from hp_cons already fires every NURSERY allocs,
         # so this is now mostly redundant. Conservative roots (incl. denv) via gc_run.
      gc_run "$denv"; R="S:t" ;;
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
      while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; ROOTS="$_rs $_acc"; hp_cons "$_v" "$_rev"; _rev=$R; done
      R=$_rev; ROOTS=$_rs ;;
    vau)
      hp_car "$ops"; formals=$R
      hp_cdr "$ops"; r=$R; hp_car "$r"; eformal=$R
      hp_cdr "$r"; body=$R
      hp_cons "$body" "$denv"; r=$R
      hp_cons "$eformal" "$r"; r=$R
      hp_cons "$formals" "$r"
      R="O:${R#P:}" ;;
    quote) hp_car "$ops" ;;                  # (quote x) -> x, unevaluated
    lambda)                                  # (lambda formals . body) -> applicative
      hp_car "$ops"; formals=$R              # wrapping a vau with eformal=#ignore
      hp_cdr "$ops"; body=$R
      hp_cons "$body" "$denv"; r=$R
      hp_cons "S:#ignore" "$r"; r=$R
      hp_cons "$formals" "$r"; r="O:${R#P:}"
      hp_cons "$r" NIL; R="A:${R#P:}" ;;
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
  local name=$1 args=$2 sum prod lst v _sa _l _o _n _f _ln _acc _rev _v _rdsave _rdv _sep _part _rs=$ROOTS
  case $name in
    list)    R=$args ;;                       # already-evaluated args, as a list
    cons)    arg2 "$args"; hp_cons "$ARG1" "$ARG2" ;;
    car)     arg1 "$args"; hp_car "$ARG1" ;;
    cdr)     arg1 "$args"; hp_cdr "$ARG1" ;;
    dq)      R='T:"' ;;                        # a '"'-valued string (0x08 sentinel on cmd)
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
    'read') arg1 "$args"; _rdsave=$SRC; SRC=${ARG1#T:}; rd_expr; _rdv=$R; SRC=$_rdsave; R=$_rdv ;;
    'split') arg2 "$args"; _sa=${ARG1#T:}; _sep=${ARG2#T:}; _acc=NIL
             if [ -z "$_sep" ]; then hp_cons "T:$_sa" NIL; else
               while case "$_sa" in *"$_sep"*) true ;; *) false ;; esac; do
                 _part=${_sa%%"$_sep"*}; hp_cons "T:$_part" "$_acc"; _acc=$R; _sa=${_sa#*"$_sep"}
               done
               hp_cons "T:$_sa" "$_acc"; _acc=$R
               _rev=NIL; while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; ROOTS="$_rs $_acc"; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev; ROOTS=$_rs
             fi ;;
    'type-of') arg1 "$args"; case $ARG1 in
             NIL) R="S:nil" ;; I:*) R="S:number" ;; S:*) R="S:symbol" ;; T:*) R="S:string" ;;
             P:*) R="S:pair" ;; O:*|F:*) R="S:operative" ;; A:*|R:*) R="S:applicative" ;; *) R="S:unknown" ;; esac ;;
    'read-lines') arg1 "$args"; _f=${ARG1#T:}; _acc=NIL
             while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
             _rev=NIL
             while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; ROOTS="$_rs $_acc"; hp_cons "$_v" "$_rev"; _rev=$R; done
             R=$_rev; ROOTS=$_rs ;;
    'write-lines') arg2 "$args"; _f=${ARG1#T:}; _l=$ARG2; : > "$_f"
             while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done
             R="S:t" ;;
    'append-lines') arg2 "$args"; _f=${ARG1#T:}; _l=$ARG2
             while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done
             R="S:t" ;;
    hmark)   R="I:$HEAP_N" ;;          # current heap bump pointer (region reclamation)
    hreset)  arg1 "$args"; HEAP_N=${ARG1#I:}; R="S:t" ;;   # reset bump pointer -> reuse slots
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
# quote/list/lambda are kernel primitives (not a parsed prelude) — same as batch,
# and it skips re-parsing/re-expanding them.
PRELUDE=""

setup_global() {
  env_new NIL; GLOBAL=$R
  for p in vau define if run 'run-capture' quote lambda gc; do env_define "$GLOBAL" "S:$p" "F:$p"; done
  for p in cons car cdr 'eq?' 'null?' 'atom?' '+' '-' '*' '<' '=' 'file-exists?' 'string-append' 'string-length' substring 'symbol->string' 'string->symbol' 'number->string' 'string->number' split 'read' 'type-of' 'read-lines' 'write-lines' 'append-lines' hmark hreset list wrap unwrap eval print dq; do
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
