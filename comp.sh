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
# and a command-substitution subshell would discard it). There are NO shell
# `local`s: ksh93's POSIX name() functions don't frame-scope typeset, and there
# is no local-scoping syntax common to dash AND ksh93. Instead each frame's
# register file is its POSITIONAL PARAMETERS (managed with `set --`) — private
# per call, so recursion can't clobber them — and leaf/non-reentrant helpers use
# uniquely-prefixed globals. This runs identically on dash/bash/mksh/zsh/ksh93.
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
HEAP_N=0; FREE_HEAD=NIL; MARKGEN=0; LAST_GC=0; NURSERY=${NURSERY:-50000}; GC_RUNNING=; RSP=0
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
  # No locals (ksh93). $1=current node, $2=its index (index is live across the recursive
  # gc_mark on the car). gm_* globals are used within one iteration only.
  set -- "$1" ""
  while :; do
    case $1 in P:*|A:*|O:*) set -- "$1" "${1#?:}" ;; *) return ;; esac
    eval "gm_mk=\${H_$2_m:-}"
    [ "$gm_mk" = "$MARKGEN" ] && return
    eval "H_$2_m=$MARKGEN"
    eval "gm_ca=\$H_$2_a"; gc_mark "$gm_ca"
    eval "gm_v=\$H_$2_d"; set -- "$gm_v" "$2"
  done
}
# sweep: link every unmarked cell into the free-list via its own _d slot (no extra
# storage, no rename). Reused by hp_cons. Cells keep their var slots (names reused).
gc_sweep() {
  gs_i=0                                 # no locals (ksh93); gs_* globals, non-recursive
  FREE_HEAD=NIL
  while [ "$gs_i" -lt "$HEAP_N" ]; do
    eval "gs_mk=\${H_${gs_i}_m:-}"
    [ "$gs_mk" = "$MARKGEN" ] || { eval "H_${gs_i}_d=\$FREE_HEAD"; FREE_HEAD=$gs_i; }
    gs_i=$((gs_i + 1))
  done
}
# gc_run: a precise mark-sweep. Roots are GLOBAL, R, the cons args being built ($@),
# and the EXPLICIT root stack ROOT0..ROOT(RSP-1). We do NOT scan `set`: that only works
# on mksh (whose `set` lists every frame's locals); dash/bash/zsh `set` shows only the
# INNERMOST binding of a shadowed name, so a recursive interpreter (every frame reuses
# `env`/`x`/`e`) hides ancestor frames' live refs -> freed-while-live -> corruption.
# Each allocating frame OWNS one slot ROOT<base> (base saved at entry, RSP bumped) and
# writes only ITS live refs there; ancestors live in lower slots, so a frame never copies
# the parent root string -- root upkeep is O(1)/frame, not O(depth) (recursion was
# O(depth^2): every frame re-copying the growing ancestor string). Each slot is a
# space-list peeled with parameter expansion (a `for ... in` would NOT split on zsh;
# read -a isn't in dash) so root-finding is identical on every shell.
gc_run() {
  [ -n "$GC_RUNNING" ] && return
  GC_RUNNING=1                           # no locals (ksh93); gr_* globals, non-recursive (guarded)
  MARKGEN=$((MARKGEN + 1))
  gc_mark "$GLOBAL"; gc_mark "$R"
  for gr_v in "$@"; do gc_mark "$gr_v"; done
  gr_i=0
  while [ "$gr_i" -lt "$RSP" ]; do
    # ${ROOT$i-} not $ROOT$i: a frame may have reserved its slot (bumped RSP) but not yet
    # written it when gc fires (rd_list before its head read; run-capture's cons loop) --
    # set -u would abort. Empty is correct there: those refs are not-yet-live or cons-arg-rooted.
    eval "gr_rest=\${ROOT$gr_i-}"
    while [ -n "$gr_rest" ]; do
      case $gr_rest in *' '*) gr_v=${gr_rest%% *}; gr_rest=${gr_rest#* } ;; *) gr_v=$gr_rest; gr_rest= ;; esac
      gc_mark "$gr_v"
    done
    gr_i=$((gr_i + 1))
  done
  # COMPILED-code roots: native (compiled) functions hold live cells in the caller-save
  # stack STK0..STK(SP-1) (one tagged value per slot) -- the interpreter's ROOT slots don't
  # see them. SP is unset under the plain interpreter (no compiled code) -> ${SP-0} = no scan.
  gs_i=0; gs_sp=${SP-0}
  while [ "$gs_i" -lt "$gs_sp" ]; do
    eval "gr_v=\${STK$gs_i-}"
    gc_mark "$gr_v"
    gs_i=$((gs_i + 1))
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

rd_quote() { rd_expr; rq_q=$R; hp_cons "$rq_q" NIL; rq_q=$R; hp_cons "S:quote" "$rq_q"; }  # rq_q set post-recursion + is a cons arg -> safe global

rd_list() {
  # No locals (ksh93). $1=head $2=this frame's root slot index, both live across the
  # recursive tail read.
  set -- "" "$RSP"; RSP=$(($2 + 1))
  rd_expr
  case $R in RPAREN|EOF) R=NIL; RSP=$2; return ;; esac
  # dotted tail: (a b . c) — '.' only appears in a tail-position read.
  if [ "$R" = 'S:.' ]; then
    rd_expr; rl_tail=$R    # the cdr datum (then consume ')'; rd_expr for ')' doesn't recurse)
    rd_expr
    R=$rl_tail; RSP=$2; return
  fi
  set -- "$R" "$2"                        # head=$R
  eval "ROOT$2=\"\$1\""                   # head must survive the recursive (allocating) tail read
  rd_list
  hp_cons "$1" "$R"
  RSP=$2
}

rd_atom() {
  ra_tok=${SRC%%[$_DELIM]*}     # no locals (ksh93); ra_tok global, used immediately
  SRC=${SRC#"$ra_tok"}
  case $ra_tok in
    -|''|*[!0-9-]*) R="S:$ra_tok" ;;
    *)              R="I:$ra_tok" ;;
  esac
}

rd_string() {
  # Strings are SINGLE-LINE on both hosts (a batch variable cannot hold a
  # newline). sh vars happen to tolerate one, so we reject a raw newline here
  # to keep the language consistent: a multiline string literal fails loudly on
  # sh exactly as it would mis-parse on batch, instead of silently working on
  # one host only. Multiline text is a list of line-strings (see read-lines).
  SRC=${SRC#?}                       # no locals (ksh93); rs_s global. drop the opening "
  rs_s=${SRC%%\"*}                   # body up to the closing " (one op)
  if [ "$rs_s" = "$SRC" ]; then die "unterminated string literal"; fi
  SRC=${SRC#"$rs_s"}; SRC=${SRC#?}   # drop the body and the closing "
  case $rs_s in
    *"$_NL"*) die "newline in string literal (strings are single-line; use a list of lines)" ;;
  esac
  R="T:$rs_s"
}

# ---- environment: pair (bindings-alist . parent) --------------------------
env_new() { hp_cons NIL "$1"; }

env_define() {
  # No locals (ksh93); ed_* globals (non-recursive, never re-enters via ev).
  ed_env=$1; ed_sym=$2; ed_val=$3; ed_b=$RSP; RSP=$((ed_b + 1))
  eval "ROOT$ed_b=\"\$ed_env \$ed_sym \$ed_val\"" # env live across the conses (hp_setcar after); binds reachable via env
  hp_car "$ed_env"; ed_binds=$R
  hp_cons "$ed_sym" "$ed_val"; ed_pair=$R
  hp_cons "$ed_pair" "$ed_binds"
  hp_setcar "$ed_env" "$R"
  RSP=$ed_b
}

env_lookup() {
  # No locals (ksh93); el_* globals (non-recursive, leaf calls only).
  el_env=$1; el_sym=$2
  while [ "$el_env" != NIL ]; do
    hp_car "$el_env"; el_binds=$R
    el_prev=NIL
    while [ "$el_binds" != NIL ]; do
      hp_car "$el_binds"; el_pair=$R
      hp_car "$el_pair"; el_k=$R
      if [ "$el_k" = "$el_sym" ]; then
        if [ "$el_prev" != NIL ]; then     # move-to-front: splice pair to head
          hp_cdr "$el_binds"; el_next=$R
          hp_setcdr "$el_prev" "$el_next"
          hp_car "$el_env"; el_head=$R
          hp_setcdr "$el_binds" "$el_head"
          hp_setcar "$el_env" "$el_binds"
        fi
        hp_cdr "$el_pair"; return
      fi
      el_prev=$el_binds
      hp_cdr "$el_binds"; el_binds=$R
    done
    hp_cdr "$el_env"; el_env=$R
  done
  die "unbound symbol: ${el_sym#S:}"
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
  # NO shell locals (ksh93 has neither a frame-scoped `local` nor `typeset` in name()).
  # This frame's register file is its positional params; recursion can't clobber them
  # (each call owns its $@), and `set --` updates a slot. Slot map:
  #   $1=x  $2=env  $3=c(combiner)  $4=operands  $5=ne(new env)  $6=body  $7=r(scratch
  #   that must survive recursion)  $8=this frame's root slot index. Pure transients that
  #   never live across ev's OWN recursion use ev_* globals (sub-calls are positional too,
  #   so they don't clobber them): ev_formals ev_eformal ev_senv ev_tv. (ev_w can't be a
  #   global: it lives across eval_list, which recurses into ev — so it rides in slot $7.)
  # This frame OWNS root slot ROOT<$8> (ancestors are in lower slots ROOT0..$8-1), so each
  # update writes only this frame's live refs -- O(1), no ancestor copy; every exit pops
  # with RSP=$8. (Cons args are rooted by gc_run "$@".)
  set -- "$1" "$2" "${3-}" "${4-}" "${5-}" "${6-}" "${7-}" "$RSP"; RSP=$(($8 + 1))
  while :; do
    eval "ROOT$8=\"\$1 \$2\""
    case $1 in
      S:*) env_lookup "$2" "$1"; RSP=$8; return ;;
      P:*) ;;
      *)   R=$1; RSP=$8; return ;;   # NIL, I:, T:, F:, R:, O:, A: self-evaluate
    esac
    hp_car "$1"; ev "$R" "$2"; set -- "$1" "$2" "$R" "$4" "$5" "$6" "$7" "$8"   # c=R
    hp_cdr "$1"; set -- "$1" "$2" "$3" "$R" "$5" "$6" "$7" "$8"                 # operands=R
    while :; do
      eval "ROOT$8=\"\$1 \$2 \$3 \$4\""
      case $3 in
        R:*) eval_list "$4" "$2"; prim_app "${3#R:}" "$R"; RSP=$8; return ;;
        A:*) hp_car "P:${3#A:}"; set -- "$1" "$2" "$3" "$4" "$5" "$6" "$R" "$8"          # r=$7=unwrapped w
             eval "ROOT$8=\"\$1 \$2 \$3 \$4 \$7\""
             eval_list "$4" "$2"; set -- "$1" "$2" "$7" "$R" "$5" "$6" "$7" "$8" ;;      # c=w (survived eval_list's ev-recursion in $7), operands=R
        F:*) case $3 in
               'F:if') hp_car "$4"; ev "$R" "$2"; ev_tv=$R
                       hp_cdr "$4"; set -- "$1" "$2" "$3" "$4" "$5" "$6" "$R" "$8"      # r=cdr(operands)
                       if [ "$ev_tv" = NIL ]; then hp_cdr "$7"; hp_car "$R"; else hp_car "$7"; fi
                       set -- "$R" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; break ;;          # x=R, tail
               *) prim_oper "${3#F:}" "$4" "$2"; RSP=$8; return ;;
             esac ;;
        O:*) set -- "$1" "$2" "$3" "$4" "$5" "$6" "P:${3#O:}" "$8"                       # r=O cell
             hp_car "$7"; ev_formals=$R
             hp_cdr "$7"; set -- "$1" "$2" "$3" "$4" "$5" "$6" "$R" "$8"; hp_car "$7"; ev_eformal=$R
             hp_cdr "$7"; set -- "$1" "$2" "$3" "$4" "$5" "$6" "$R" "$8"; hp_car "$7"; set -- "$1" "$2" "$3" "$4" "$5" "$R" "$7" "$8"   # body=$6
             hp_cdr "$7"; ev_senv=$R
             eval "ROOT$8=\"\$1 \$2 \$3 \$4 \$6\""
             env_new "$ev_senv"; set -- "$1" "$2" "$3" "$4" "$R" "$6" "$7" "$8"          # ne=$5
             eval "ROOT$8=\"\$2 \$3 \$4 \$6 \$5\""
             bind_tree "$5" "$ev_formals" "$4"
             case $ev_eformal in 'S:#ignore') ;; *) env_define "$5" "$ev_eformal" "$2" ;; esac
             [ "$6" = NIL ] && { R=NIL; RSP=$8; return; }
             while :; do                                          # eval body
               hp_cdr "$6"; set -- "$1" "$2" "$3" "$4" "$5" "$6" "$R" "$8"               # r=cdr(body)
               [ "$7" = NIL ] && break                            # ...last form is tail
               eval "ROOT$8=\"\$2 \$3 \$5 \$6\""
               hp_car "$6"; ev "$R" "$5"
               set -- "$1" "$2" "$3" "$4" "$5" "$7" "$7" "$8"                            # body=r
             done
             hp_car "$6"; set -- "$R" "$5" "$3" "$4" "$5" "$6" "$7" "$8"; break ;;        # x=R, env=ne, tail
        *) die "not combinable: $3" ;;
      esac
    done
  done
}

eval_list() {                    # map ev over a list -> R = list of values
  # NO shell locals (ksh93 has no `local`, and name()+typeset isn't frame-scoped there).
  # The frame's register file is its positional params: $1=lst $2=env $3=root slot index
  # $4=evaluated-element. Each call has its own $@, so recursion can't clobber them, and
  # `set --` updates are ~as fast as `local` (measured). Identical on dash/bash/mksh/zsh/ksh93.
  [ "$1" = NIL ] && { R=NIL; return; }
  set -- "$1" "$2" "$RSP"; RSP=$(($3 + 1))  # $3 = this frame's root slot index
  eval "ROOT$3=\"\$1 \$2\""                # lst (for cdr) + env live across element ev
  hp_car "$1"; ev "$R" "$2"
  set -- "$1" "$2" "$3" "$R"               # $4 = evaluated element (must survive recursion)
  hp_cdr "$1"
  eval "ROOT$3=\"\$2 \$4\""
  eval_list "$R" "$2"                      # recurse; our $1..$4 survive (callee has its own $@)
  hp_cons "$4" "$R"                        # cons(element, rest)
  RSP=$3
}

bind_tree() {                    # env formals operands  (formals: NIL | symbol-rest | tree)
  # No locals (ksh93); bt_* globals. Self-recursive, but recursion is in tail position so
  # no bt_* is live across it, and env_define uses ed_*. No own ROOTS: the caller (ev) has
  # already rooted ne/operands/c, which reach every value bind_tree touches.
  bt_env=$1; bt_formals=$2; bt_operands=$3
  case $bt_formals in
    NIL) ;;
    S:*) env_define "$bt_env" "$bt_formals" "$bt_operands" ;;
    P:*) hp_car "$bt_formals"; bt_fcar=$R
         hp_car "$bt_operands"; env_define "$bt_env" "$bt_fcar" "$R"
         hp_cdr "$bt_formals"; bt_ftail=$R
         hp_cdr "$bt_operands"; bind_tree "$bt_env" "$bt_ftail" "$R" ;;
  esac
}

# ---- primitive operatives (unevaluated operands + env) --------------------
prim_oper() {
  # No locals (ksh93). $1=name $2=ops $3=denv are positional (private per call, so they
  # survive the ev calls in define/if). define's `sym` is also live across its value-ev,
  # so it rides in $4. Other cases don't call ev, so po_* globals are safe.
  case $1 in
    gc)  gc_run "$3"; R="S:t" ;;            # conservative roots (incl. denv) via gc_run
    run)
      po_cmd=; po_lst=$2
      while [ "$po_lst" != NIL ]; do
        hp_car "$po_lst"; po_tok=$R
        po_cmd="$po_cmd ${po_tok#?:}"
        hp_cdr "$po_lst"; po_lst=$R
      done
      sh -c "$po_cmd"; R="I:$?" ;;
    'run-capture')
      po_cmd=; po_lst=$2
      while [ "$po_lst" != NIL ]; do
        hp_car "$po_lst"; po_tok=$R
        po_cmd="$po_cmd ${po_tok#?:}"
        hp_cdr "$po_lst"; po_lst=$R
      done
      po_out=$(sh -c "$po_cmd"); po_acc=NIL; po_b=$RSP; RSP=$((po_b + 1))
      while IFS= read -r po_ln || [ -n "$po_ln" ]; do hp_cons "T:$po_ln" "$po_acc"; po_acc=$R; done <<RCEOF
$po_out
RCEOF
      po_rev=NIL
      while [ "$po_acc" != NIL ]; do hp_car "$po_acc"; po_v=$R; hp_cdr "$po_acc"; po_acc=$R; eval "ROOT$po_b=\"\$po_acc\""; hp_cons "$po_v" "$po_rev"; po_rev=$R; done
      R=$po_rev; RSP=$po_b ;;
    vau)
      hp_car "$2"; po_formals=$R
      hp_cdr "$2"; po_r=$R; hp_car "$po_r"; po_eformal=$R
      hp_cdr "$po_r"; po_body=$R
      hp_cons "$po_body" "$3"; po_r=$R
      hp_cons "$po_eformal" "$po_r"; po_r=$R
      hp_cons "$po_formals" "$po_r"
      R="O:${R#P:}" ;;
    quote) hp_car "$2" ;;                    # (quote x) -> x, unevaluated
    lambda)                                  # (lambda formals . body) -> applicative
      hp_car "$2"; po_formals=$R             # wrapping a vau with eformal=#ignore
      hp_cdr "$2"; po_body=$R
      hp_cons "$po_body" "$3"; po_r=$R
      hp_cons "S:#ignore" "$po_r"; po_r=$R
      hp_cons "$po_formals" "$po_r"; po_r="O:${R#P:}"
      hp_cons "$po_r" NIL; R="A:${R#P:}" ;;
    define)
      hp_car "$2"; set -- "$1" "$2" "$3" "$R"   # $4 = sym (live across the value ev)
      hp_cdr "$2"; hp_car "$R"; ev "$R" "$3"
      env_define "$3" "$4" "$R"
      R=$4 ;;
    if)
      hp_car "$2"; po_test=$R
      ev "$po_test" "$3"
      if [ "$R" = NIL ]; then hp_cdr "$2"; hp_cdr "$R"; hp_car "$R"; ev "$R" "$3"
      else                    hp_cdr "$2"; hp_car "$R"; ev "$R" "$3"; fi ;;
    *) die "unknown operative: $1" ;;
  esac
}

# ---- primitive applicatives (evaluated args) ------------------------------
arg1() { hp_car "$1"; ARG1=$R; }
arg2() { hp_car "$1"; ARG1=$R; hp_cdr "$1"; hp_car "$R"; ARG2=$R; }

prim_app() {
  # No locals (ksh93). name/args + scratch are globals; none is live across a prim_app
  # re-entry (only `eval`->ev and `read`->rd_expr re-enter, and neither needs them after).
  name=$1; args=$2
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
               _rev=NIL; pa_b=$RSP; RSP=$((pa_b + 1)); while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; eval "ROOT$pa_b=\"\$_acc\""; hp_cons "$_v" "$_rev"; _rev=$R; done; R=$_rev; RSP=$pa_b
             fi ;;
    'type-of') arg1 "$args"; case $ARG1 in
             NIL) R="S:nil" ;; I:*) R="S:number" ;; S:*) R="S:symbol" ;; T:*) R="S:string" ;;
             P:*) R="S:pair" ;; O:*|F:*) R="S:operative" ;; A:*|R:*) R="S:applicative" ;; *) R="S:unknown" ;; esac ;;
    'read-lines') arg1 "$args"; _f=${ARG1#T:}; _acc=NIL
             while IFS= read -r _ln || [ -n "$_ln" ]; do hp_cons "T:$_ln" "$_acc"; _acc=$R; done < "$_f"
             _rev=NIL; pa_b=$RSP; RSP=$((pa_b + 1))
             while [ "$_acc" != NIL ]; do hp_car "$_acc"; _v=$R; hp_cdr "$_acc"; _acc=$R; eval "ROOT$pa_b=\"\$_acc\""; hp_cons "$_v" "$_rev"; _rev=$R; done
             R=$_rev; RSP=$pa_b ;;
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
  lw_v=$1                                 # no locals (ksh93); lw_v not live across write_list
  case $lw_v in
    NIL) printf '()' ;;
    I:*) printf '%s' "${lw_v#I:}" ;;
    S:*) printf '%s' "${lw_v#S:}" ;;
    T:*) printf '%s' "${lw_v#T:}" ;;
    O:*) printf '#<operative>' ;;
    A:*) printf '#<applicative>' ;;
    F:*) printf '#<prim-op %s>' "${lw_v#F:}" ;;
    R:*) printf '#<prim %s>' "${lw_v#R:}" ;;
    P:*) printf '('; write_list "$lw_v"; printf ')' ;;
  esac
}
write_list() {
  # No locals (ksh93). $1=lst $2=first. lst is live across lisp_write (which recurses
  # back into write_list for nested lists), so it must ride in $1, not a global.
  set -- "$1" 1
  while [ "$1" != NIL ]; do
    case $1 in P:*) ;; *) printf ' . '; lisp_write "$1"; return ;; esac
    [ "$2" = 1 ] || printf ' '; set -- "$1" 0
    hp_car "$1"; lisp_write "$R"
    hp_cdr "$1"; set -- "$R" "$2"
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

# comp-compiled.sh — comp (src/compile.lisp) + its stdlib deps, compiled to native sh
# by the Lisp->sh backend (src/compile-sh.lisp). GENERATED — regenerate with
# tools/bootstrap-comp.sh when compile.lisp or compile-sh.lisp change.
# Assembled into a runnable compiler by build-comp.sh -> comp.sh.
caar() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_car "${1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"
SP=${2}
return
done
}
cadr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_cdr "${1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"
SP=${2}
return
done
}
caddr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_cdr "${1}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
R="${sht2}"
SP=${2}
return
done
}
not() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" != NIL ]; then
R="NIL"
SP=${2}
return
else
R="S:t"
SP=${2}
return
fi
done
}
append() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="${2}"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
hp_cdr "${1}"
sht1="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
append "${sht1}" "${2}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
R="${sht3}"
SP=${3}
return
fi
done
}
reverse() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_cdr "${1}"
sht0="${R}"
reverse "${sht0}"
sht1="${R}"
hp_car "${1}"
sht2="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
hp_cons "${sht2}" "NIL"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
append "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${2}
return
fi
done
}
assoc() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${2}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${2}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "${1}" ]; then
hp_car "${2}"
sht2="${R}"
R="${sht2}"
SP=${3}
return
else
hp_cdr "${2}"
sht3="${R}"
set -- "${1}" "${sht3}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
fi
done
}
cadddr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_cdr "${1}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
R="${sht3}"
SP=${2}
return
done
}
op_zzGbatch() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = "S:+" ]; then
R="T:+"
SP=${2}
return
else
if [ "${1}" = "S:-" ]; then
R="T:-"
SP=${2}
return
else
if [ "${1}" = "S:*" ]; then
R="T:*"
SP=${2}
return
else
R="T:?"
SP=${2}
return
fi
fi
fi
done
}
cmp_zzGbatch() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = "S:<" ]; then
R="T:LSS"
SP=${2}
return
else
if [ "${1}" = "S:=" ]; then
R="T:EQU"
SP=${2}
return
else
R="T:?"
SP=${2}
return
fi
fi
done
}
arithzzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = "S:+" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:-" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:*" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"
SP=${2}
return
fi
fi
done
}
tpredzzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = "S:eq?" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:null?" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:pair?" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:number?" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:string?" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:symbol?" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:<" ]; then
R="S:t"
SP=${2}
return
else
if [ "${1}" = "S:=" ]; then
R="S:t"
SP=${2}
return
else
R="NIL"
SP=${2}
return
fi
fi
fi
fi
fi
fi
fi
fi
done
}
iszzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "${2}" ]; then
sht1="S:t"
else
sht1="NIL"
fi
R="${sht1}"
SP=${3}
return
else
R="NIL"
SP=${3}
return
fi
done
}
aref() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then
hp_cdr "${1}"
sht1="${R}"
R="${sht1}"
SP=${2}
return
else
hp_car "${1}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then
hp_cdr "${1}"
sht3="${R}"
R="${sht3}"
SP=${2}
return
else
hp_car "${1}"
sht4="${R}"
if [ "${sht4}" = "S:cst" ]; then
hp_cdr "${1}"
sht5="${R}"
R="${sht5}"
SP=${2}
return
else
hp_cdr "${1}"
sht6="${R}"
sht7="T:${sht6#??}:~2!"
sht8="T:!${sht7#??}"
R="${sht8}"
SP=${2}
return
fi
fi
fi
done
}
iref() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then
hp_cdr "${1}"
sht1="${R}"
R="${sht1}"
SP=${2}
return
else
hp_car "${1}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then
hp_cdr "${1}"
sht3="${R}"
sht4="T:${sht3#??}!"
sht5="T:!${sht4#??}"
R="${sht5}"
SP=${2}
return
else
hp_car "${1}"
sht6="${R}"
if [ "${sht6}" = "S:cst" ]; then
hp_cdr "${1}"
sht7="${R}"
R="${sht7}"
SP=${2}
return
else
hp_cdr "${1}"
sht8="${R}"
sht9="T:${sht8#??}:~2!"
sht10="T:!${sht9#??}"
R="${sht10}"
SP=${2}
return
fi
fi
fi
done
}
vref() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then
hp_cdr "${1}"
sht1="${R}"
sht2="T:I:${sht1#??}"
R="${sht2}"
SP=${2}
return
else
hp_car "${1}"
sht3="${R}"
if [ "${sht3}" = "S:raw" ]; then
hp_cdr "${1}"
sht4="${R}"
sht5="T:${sht4#??}!"
sht6="T:I:!${sht5#??}"
R="${sht6}"
SP=${2}
return
else
hp_car "${1}"
sht7="${R}"
if [ "${sht7}" = "S:cst" ]; then
hp_cdr "${1}"
sht8="${R}"
R="${sht8}"
SP=${2}
return
else
hp_cdr "${1}"
sht9="${R}"
sht10="T:${sht9#??}!"
sht11="T:!${sht10#??}"
R="${sht11}"
SP=${2}
return
fi
fi
fi
done
}
cref() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:cst" ]; then
hp_cdr "${1}"
sht1="${R}"
hp_cdr "${1}"
sht2="${R}"
sht3="I:$(( ${#sht2} - 2 ))"
sht4="I:$(( ${sht3#??} - 2 ))"
sht5="T:$(printf '%s' "${sht1#??}" | cut -c$(( 2 + 1 ))-$(( 2 + ${sht4#??} )))"
R="${sht5}"
SP=${2}
return
else
hp_cdr "${1}"
sht6="${R}"
sht7="T:${sht6#??}:~2!"
sht8="T:!${sht7#??}"
R="${sht8}"
SP=${2}
return
fi
done
}
G_B1='T:!'
G_B2='T:%'
G_B7='T:^'
G_BLT='T:<'
G_BGT='T:>'
G_BAMP='T:&'
G_BPIPE='T:|'
mc_at() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = "${G_B1}" ]; then
R="T:!BANG!"
SP=${2}
return
else
if [ "${1}" = "${G_B2}" ]; then
R="T:!BANG2!"
SP=${2}
return
else
if [ "${1}" = "${G_B7}" ]; then
R="T:!BANG7!"
SP=${2}
return
else
if [ "${1}" = "${G_BLT}" ]; then
R="T:!LT!"
SP=${2}
return
else
if [ "${1}" = "${G_BGT}" ]; then
R="T:!GT!"
SP=${2}
return
else
if [ "${1}" = "${G_BAMP}" ]; then
R="T:!AMP!"
SP=${2}
return
else
if [ "${1}" = "${G_BPIPE}" ]; then
R="T:!PIPE!"
SP=${2}
return
else
R="${1}"
SP=${2}
return
fi
fi
fi
fi
fi
fi
fi
done
}
enc_mc_go() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
while :; do
if [ ${2#??} -eq ${3#??} ]; then
R="${4}"
SP=${5}
return
else
sht0="I:$(( ${2#??} + 1 ))"
sht1="T:$(printf '%s' "${1#??}" | cut -c$(( ${2#??} + 1 ))-$(( ${2#??} + 1 )))"
eval STK$SP='${sht0}'
SP=$((SP+1))
mc_at "${sht1}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
sht3="T:${4#??}${sht2#??}"
set -- "${1}" "${sht0}" "${3}" "${sht3}" "${5}"
SP=${5}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
fi
done
}
enc_mc() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
sht0="I:$(( ${#1} - 2 ))"
enc_mc_go "${1}" "I:0" "${sht0}" "T:"
sht1="${R}"
R="${sht1}"
SP=${2}
return
done
}
G_BST='T:*'
mangle_at() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = "${G_BGT}" ]; then
R="T:zzG"
SP=${2}
return
else
if [ "${1}" = "${G_BLT}" ]; then
R="T:zzL"
SP=${2}
return
else
if [ "${1}" = "${G_BAMP}" ]; then
R="T:zzA"
SP=${2}
return
else
if [ "${1}" = "${G_BPIPE}" ]; then
R="T:zzP"
SP=${2}
return
else
if [ "${1}" = "${G_BST}" ]; then
R="T:zzS"
SP=${2}
return
else
if [ "${1}" = "T:?" ]; then
R="T:zzQ"
SP=${2}
return
else
R="${1}"
SP=${2}
return
fi
fi
fi
fi
fi
fi
done
}
mangle_go() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
while :; do
if [ ${2#??} -eq ${3#??} ]; then
R="${4}"
SP=${5}
return
else
sht0="I:$(( ${2#??} + 1 ))"
sht1="T:$(printf '%s' "${1#??}" | cut -c$(( ${2#??} + 1 ))-$(( ${2#??} + 1 )))"
eval STK$SP='${sht0}'
SP=$((SP+1))
mangle_at "${sht1}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
sht3="T:${4#??}${sht2#??}"
set -- "${1}" "${sht0}" "${3}" "${sht3}" "${5}"
SP=${5}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
fi
done
}
mangle() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
sht0="I:$(( ${#1} - 2 ))"
mangle_go "${1}" "I:0" "${sht0}" "T:"
sht1="${R}"
R="${sht1}"
SP=${2}
return
done
}
rev() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="${2}"
SP=${3}
return
else
hp_cdr "${1}"
sht0="${R}"
hp_car "${1}"
sht1="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
hp_cons "${sht1}" "${2}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
set -- "${sht0}" "${sht2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
done
}
pvars() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1#T:}" != "${sht1}" ]; then
hp_cdr "${1}"
sht2="${R}"
set -- "${sht2}" "${2}"
SP=${2}
eval STK$SP='${1}'
SP=$((SP+1))
else
hp_car "${1}"
sht3="${R}"
hp_cdr "${sht3}"
sht4="${R}"
hp_cdr "${1}"
sht5="${R}"
eval STK$SP='${sht4}'
SP=$((SP+1))
pvars "${sht5}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
hp_cons "${sht4}" "${sht6}"
sht7="${R}"
R="${sht7}"
SP=${2}
return
fi
fi
done
}
live_add() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then
R="${2}"
SP=${3}
return
else
hp_car "${1}"
sht1="${R}"
if [ "${sht1}" = "S:cst" ]; then
R="${2}"
SP=${3}
return
else
hp_cdr "${1}"
sht2="${R}"
hp_cons "${sht2}" "${2}"
sht3="${R}"
R="${sht3}"
SP=${3}
return
fi
fi
done
}
qset() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
sht0="T:${1#??}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:set ${sht1#??}"
R="${sht2}"
SP=${2}
return
done
}
save_lines() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
sht1="T:${sht0#??}!"
sht2="T:STK!SP!=!${sht1#??}"
qset "${sht2}"
sht3="${R}"
hp_cdr "${1}"
sht4="${R}"
eval STK$SP='${sht3}'
SP=$((SP+1))
save_lines "${sht4}"
sht5="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
hp_cons "T:set /a SP+=1" "${sht5}"
sht6="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
R="${sht7}"
SP=${2}
return
fi
done
}
restore_lines() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
sht1="T:=%%STK!SP!%%${G_DQ#??}"
sht2="T:${sht0#??}${sht1#??}"
sht3="T:${G_DQ#??}${sht2#??}"
sht4="T:call set ${sht3#??}"
hp_cdr "${1}"
sht5="${R}"
eval STK$SP='${sht4}'
SP=$((SP+1))
restore_lines "${sht5}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
hp_cons "${sht4}" "${sht6}"
sht7="${R}"
hp_cons "T:set /a SP-=1" "${sht7}"
sht8="${R}"
R="${sht8}"
SP=${2}
return
fi
done
}
pmap_local() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
hp_car "${1}"
sht1="${R}"
sht2="T:${sht1#??}"
sht3="T:_${sht2#??}"
sht4="T:${2#??}${sht3#??}"
hp_cons "${sht0}" "${sht4}"
sht5="${R}"
hp_cdr "${1}"
sht6="${R}"
eval STK$SP='${sht5}'
SP=$((SP+1))
pmap_local "${sht6}" "${2}"
sht7="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
hp_cons "${sht5}" "${sht7}"
sht8="${R}"
R="${sht8}"
SP=${3}
return
fi
done
}
load_params() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${4}
return
else
hp_car "${1}"
sht0="${R}"
sht1="T:${sht0#??}"
sht2="T:${2#??}"
sht3="T:${sht2#??}!"
sht4="T:=!A${sht3#??}"
sht5="T:${sht1#??}${sht4#??}"
sht6="T:_${sht5#??}"
sht7="T:${3#??}${sht6#??}"
qset "${sht7}"
sht8="${R}"
hp_cdr "${1}"
sht9="${R}"
sht10="I:$(( ${2#??} + 1 ))"
eval STK$SP='${sht8}'
SP=$((SP+1))
load_params "${sht9}" "${sht10}" "${3}"
sht11="${R}"
SP=$((SP-1))
eval sht8='${STK'$SP'}'
hp_cons "${sht8}" "${sht11}"
sht12="${R}"
R="${sht12}"
SP=${4}
return
fi
done
}
aassign() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
sht0="T:${2#??}"
hp_car "${1}"
sht1="${R}"
sht2="T:=${sht1#??}"
sht3="T:${sht0#??}${sht2#??}"
sht4="T:A${sht3#??}"
qset "${sht4}"
sht5="${R}"
hp_cdr "${1}"
sht6="${R}"
sht7="I:$(( ${2#??} + 1 ))"
eval STK$SP='${sht5}'
SP=$((SP+1))
aassign "${sht6}" "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
hp_cons "${sht5}" "${sht8}"
sht9="${R}"
R="${sht9}"
SP=${3}
return
fi
done
}
cquote() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
hp_cons "S:cst" "T:NIL"
sht0="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht1="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
hp_cons "${sht0}" "${sht1}"
sht2="${R}"
hp_cons "${5}" "${sht2}"
sht3="${R}"
R="${sht3}"
SP=${6}
return
else
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht4="${R}"
hp_cons "${sht4}" "NIL"
sht5="${R}"
hp_cons "S:quote" "${sht5}"
sht6="${R}"
hp_cdr "${1}"
sht7="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
hp_cons "${sht7}" "NIL"
sht8="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
hp_cons "S:quote" "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
hp_cons "${sht9}" "NIL"
sht10="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_cons "${sht6}" "${sht10}"
sht11="${R}"
hp_cons "S:cons" "${sht11}"
sht12="${R}"
cexpr "${sht12}" "${2}" "${3}" "${4}" "${5}"
sht13="${R}"
R="${sht13}"
SP=${6}
return
else
if [ "${1#I:}" != "${1}" ]; then
sht14="T:${1#??}"
hp_cons "S:lit" "${sht14}"
sht15="${R}"
eval STK$SP='${sht15}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht16="${R}"
SP=$((SP-1))
eval sht15='${STK'$SP'}'
hp_cons "${sht15}" "${sht16}"
sht17="${R}"
hp_cons "${5}" "${sht17}"
sht18="${R}"
R="${sht18}"
SP=${6}
return
else
if [ "${1#T:}" != "${1}" ]; then
enc_mc "${1}"
sht19="${R}"
sht20="T:T:${sht19#??}"
hp_cons "S:cst" "${sht20}"
sht21="${R}"
eval STK$SP='${sht21}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht22="${R}"
SP=$((SP-1))
eval sht21='${STK'$SP'}'
hp_cons "${sht21}" "${sht22}"
sht23="${R}"
hp_cons "${5}" "${sht23}"
sht24="${R}"
R="${sht24}"
SP=${6}
return
else
sht25="T:${1#??}"
enc_mc "${sht25}"
sht26="${R}"
sht27="T:S:${sht26#??}"
hp_cons "S:cst" "${sht27}"
sht28="${R}"
eval STK$SP='${sht28}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht29="${R}"
SP=$((SP-1))
eval sht28='${STK'$SP'}'
hp_cons "${sht28}" "${sht29}"
sht30="${R}"
hp_cons "${5}" "${sht30}"
sht31="${R}"
R="${sht31}"
SP=${6}
return
fi
fi
fi
fi
done
}
cbegin() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
hp_cdr "${1}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then
hp_car "${1}"
sht1="${R}"
cexpr "${sht1}" "${2}" "${3}" "${4}" "${5}"
sht2="${R}"
R="${sht2}"
SP=${6}
return
else
hp_car "${1}"
sht3="${R}"
cexpr "${sht3}" "${2}" "${3}" "${4}" "${5}"
sht4="${R}"
sht5="${sht4}"
hp_cdr "${1}"
sht6="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
caddr "${sht5}"
sht7="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_car "${sht5}"
sht8="${R}"
set -- "${sht6}" "${2}" "${sht7}" "${4}" "${sht8}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
fi
done
}
cexpr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
if [ "${1#I:}" != "${1}" ]; then
sht0="T:${1#??}"
hp_cons "S:lit" "${sht0}"
sht1="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht2="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht2}"
sht3="${R}"
hp_cons "${5}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${6}
return
else
if [ "${1}" = "S:nil" ]; then
hp_cons "S:cst" "T:NIL"
sht5="${R}"
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht6="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
hp_cons "${sht5}" "${sht6}"
sht7="${R}"
hp_cons "${5}" "${sht7}"
sht8="${R}"
R="${sht8}"
SP=${6}
return
else
if [ "${1}" = "S:t" ]; then
hp_cons "S:cst" "T:S:t"
sht9="${R}"
eval STK$SP='${sht9}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht10="${R}"
SP=$((SP-1))
eval sht9='${STK'$SP'}'
hp_cons "${sht9}" "${sht10}"
sht11="${R}"
hp_cons "${5}" "${sht11}"
sht12="${R}"
R="${sht12}"
SP=${6}
return
else
if [ "${1#T:}" != "${1}" ]; then
enc_mc "${1}"
sht13="${R}"
sht14="T:T:${sht13#??}"
hp_cons "S:cst" "${sht14}"
sht15="${R}"
eval STK$SP='${sht15}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht16="${R}"
SP=$((SP-1))
eval sht15='${STK'$SP'}'
hp_cons "${sht15}" "${sht16}"
sht17="${R}"
hp_cons "${5}" "${sht17}"
sht18="${R}"
R="${sht18}"
SP=${6}
return
else
if [ "${1#S:}" != "${1}" ]; then
assoc "${1}" "${2}"
sht19="${R}"
sht20="${sht19}"
if [ "${sht20}" = NIL ]; then
sht22="T:${1#??}"
sht23="T:G_${sht22#??}"
sht21="${sht23}"
else
hp_cdr "${sht20}"
sht24="${R}"
sht21="${sht24}"
fi
eval STK$SP='${sht20}'
SP=$((SP+1))
hp_cons "S:val" "${sht21}"
sht25="${R}"
SP=$((SP-1))
eval sht20='${STK'$SP'}'
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht20}'
SP=$((SP+1))
hp_cons "${3}" "NIL"
sht26="${R}"
SP=$((SP-1))
eval sht20='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
eval STK$SP='${sht20}'
SP=$((SP+1))
hp_cons "${sht25}" "${sht26}"
sht27="${R}"
SP=$((SP-1))
eval sht20='${STK'$SP'}'
eval STK$SP='${sht20}'
SP=$((SP+1))
hp_cons "${5}" "${sht27}"
sht28="${R}"
SP=$((SP-1))
eval sht20='${STK'$SP'}'
R="${sht28}"
SP=${6}
return
else
hp_car "${1}"
sht29="${R}"
if [ "${sht29}" = "S:quote" ]; then
cadr "${1}"
sht30="${R}"
cquote "${sht30}" "${2}" "${3}" "${4}" "${5}"
sht31="${R}"
R="${sht31}"
SP=${6}
return
else
hp_car "${1}"
sht32="${R}"
if [ "${sht32}" = "S:begin" ]; then
hp_cdr "${1}"
sht33="${R}"
cbegin "${sht33}" "${2}" "${3}" "${4}" "${5}"
sht34="${R}"
R="${sht34}"
SP=${6}
return
else
hp_car "${1}"
sht35="${R}"
arithzzQ "${sht35}"
sht36="${R}"
if [ "${sht36}" != NIL ]; then
cadr "${1}"
sht37="${R}"
cexpr "${sht37}" "${2}" "${3}" "${4}" "${5}"
sht38="${R}"
sht39="${sht38}"
eval STK$SP='${sht39}'
SP=$((SP+1))
caddr "${1}"
sht40="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
caddr "${sht39}"
sht41="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
eval STK$SP='${sht41}'
SP=$((SP+1))
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
cadr "${sht39}"
sht42="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
SP=$((SP-1))
eval sht41='${STK'$SP'}'
eval STK$SP='${sht41}'
SP=$((SP+1))
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
live_add "${sht42}" "${4}"
sht43="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
SP=$((SP-1))
eval sht41='${STK'$SP'}'
hp_car "${sht39}"
sht44="${R}"
eval STK$SP='${sht39}'
SP=$((SP+1))
cexpr "${sht40}" "${2}" "${sht41}" "${sht43}" "${sht44}"
sht45="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
sht46="${sht45}"
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
caddr "${sht46}"
sht47="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
sht48="T:${sht47#??}"
sht49="T:zt${sht48#??}"
sht50="${sht49}"
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
cadr "${sht39}"
sht51="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
aref "${sht51}"
sht52="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
hp_car "${1}"
sht53="${R}"
eval STK$SP='${sht52}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
op_zzGbatch "${sht53}"
sht54="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht52='${STK'$SP'}'
eval STK$SP='${sht54}'
SP=$((SP+1))
eval STK$SP='${sht52}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
cadr "${sht46}"
sht55="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht52='${STK'$SP'}'
SP=$((SP-1))
eval sht54='${STK'$SP'}'
eval STK$SP='${sht54}'
SP=$((SP+1))
eval STK$SP='${sht52}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
aref "${sht55}"
sht56="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht52='${STK'$SP'}'
SP=$((SP-1))
eval sht54='${STK'$SP'}'
sht57="T:${sht54#??}${sht56#??}"
sht58="T:${sht52#??}${sht57#??}"
sht59="T:=${sht58#??}"
sht60="T:${sht50#??}${sht59#??}"
sht61="T:set /a ${sht60#??}"
hp_car "${sht46}"
sht62="${R}"
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
hp_cons "${sht61}" "${sht62}"
sht63="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
eval STK$SP='${sht63}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
hp_cons "S:raw" "${sht50}"
sht64="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht63='${STK'$SP'}'
eval STK$SP='${sht64}'
SP=$((SP+1))
eval STK$SP='${sht63}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
caddr "${sht46}"
sht65="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht63='${STK'$SP'}'
SP=$((SP-1))
eval sht64='${STK'$SP'}'
sht66="I:$(( ${sht65#??} + 1 ))"
eval STK$SP='${sht64}'
SP=$((SP+1))
eval STK$SP='${sht63}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
hp_cons "${sht66}" "NIL"
sht67="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht63='${STK'$SP'}'
SP=$((SP-1))
eval sht64='${STK'$SP'}'
eval STK$SP='${sht63}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
hp_cons "${sht64}" "${sht67}"
sht68="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht63='${STK'$SP'}'
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht46}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
hp_cons "${sht63}" "${sht68}"
sht69="${R}"
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht46='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
R="${sht69}"
SP=${6}
return
else
hp_car "${1}"
sht70="${R}"
if [ "${sht70}" = "S:cons" ]; then
cadr "${1}"
sht71="${R}"
cexpr "${sht71}" "${2}" "${3}" "${4}" "${5}"
sht72="${R}"
sht73="${sht72}"
eval STK$SP='${sht73}'
SP=$((SP+1))
caddr "${1}"
sht74="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
eval STK$SP='${sht74}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
caddr "${sht73}"
sht75="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht74='${STK'$SP'}'
eval STK$SP='${sht75}'
SP=$((SP+1))
eval STK$SP='${sht74}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
cadr "${sht73}"
sht76="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht74='${STK'$SP'}'
SP=$((SP-1))
eval sht75='${STK'$SP'}'
eval STK$SP='${sht75}'
SP=$((SP+1))
eval STK$SP='${sht74}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
live_add "${sht76}" "${4}"
sht77="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht74='${STK'$SP'}'
SP=$((SP-1))
eval sht75='${STK'$SP'}'
hp_car "${sht73}"
sht78="${R}"
eval STK$SP='${sht73}'
SP=$((SP+1))
cexpr "${sht74}" "${2}" "${sht75}" "${sht77}" "${sht78}"
sht79="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
sht80="${sht79}"
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
caddr "${sht80}"
sht81="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
sht82="T:${sht81#??}"
sht83="T:zt${sht82#??}"
sht84="${sht83}"
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
cadr "${sht73}"
sht85="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
vref "${sht85}"
sht86="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
sht87="T:${sht86#??}#"
sht88="T:>%HD%\car%HN% echo(${sht87#??}"
eval STK$SP='${sht88}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
cadr "${sht80}"
sht89="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht88='${STK'$SP'}'
eval STK$SP='${sht88}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
vref "${sht89}"
sht90="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht88='${STK'$SP'}'
sht91="T:${sht90#??}#"
sht92="T:>%HD%\cdr%HN% echo(${sht91#??}"
sht93="T:${sht84#??}=P:!HN!"
sht94="T:${sht93#??}"
eval STK$SP='${sht92}'
SP=$((SP+1))
eval STK$SP='${sht88}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
qset "${sht94}"
sht95="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht88='${STK'$SP'}'
SP=$((SP-1))
eval sht92='${STK'$SP'}'
eval STK$SP='${sht95}'
SP=$((SP+1))
eval STK$SP='${sht92}'
SP=$((SP+1))
eval STK$SP='${sht88}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "T:set /a HN+=1" "NIL"
sht96="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht88='${STK'$SP'}'
SP=$((SP-1))
eval sht92='${STK'$SP'}'
SP=$((SP-1))
eval sht95='${STK'$SP'}'
eval STK$SP='${sht92}'
SP=$((SP+1))
eval STK$SP='${sht88}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "${sht95}" "${sht96}"
sht97="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht88='${STK'$SP'}'
SP=$((SP-1))
eval sht92='${STK'$SP'}'
eval STK$SP='${sht88}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "${sht92}" "${sht97}"
sht98="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht88='${STK'$SP'}'
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "${sht88}" "${sht98}"
sht99="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
hp_car "${sht80}"
sht100="${R}"
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
rev "${sht99}" "${sht100}"
sht101="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
eval STK$SP='${sht101}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "S:val" "${sht84}"
sht102="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht101='${STK'$SP'}'
eval STK$SP='${sht102}'
SP=$((SP+1))
eval STK$SP='${sht101}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
caddr "${sht80}"
sht103="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht101='${STK'$SP'}'
SP=$((SP-1))
eval sht102='${STK'$SP'}'
sht104="I:$(( ${sht103#??} + 1 ))"
eval STK$SP='${sht102}'
SP=$((SP+1))
eval STK$SP='${sht101}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "${sht104}" "NIL"
sht105="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht101='${STK'$SP'}'
SP=$((SP-1))
eval sht102='${STK'$SP'}'
eval STK$SP='${sht101}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "${sht102}" "${sht105}"
sht106="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht101='${STK'$SP'}'
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht80}'
SP=$((SP+1))
eval STK$SP='${sht73}'
SP=$((SP+1))
hp_cons "${sht101}" "${sht106}"
sht107="${R}"
SP=$((SP-1))
eval sht73='${STK'$SP'}'
SP=$((SP-1))
eval sht80='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
R="${sht107}"
SP=${6}
return
else
hp_car "${1}"
sht108="${R}"
if [ "${sht108}" = "S:car" ]; then
ccell "${1}" "T:car" "${2}" "${3}" "${4}" "${5}"
sht109="${R}"
R="${sht109}"
SP=${6}
return
else
hp_car "${1}"
sht110="${R}"
if [ "${sht110}" = "S:cdr" ]; then
ccell "${1}" "T:cdr" "${2}" "${3}" "${4}" "${5}"
sht111="${R}"
R="${sht111}"
SP=${6}
return
else
hp_car "${1}"
sht112="${R}"
if [ "${sht112}" = "S:symbol->string" ]; then
cretag "${1}" "${2}" "${3}" "${4}" "${5}"
sht113="${R}"
R="${sht113}"
SP=${6}
return
else
hp_car "${1}"
sht114="${R}"
if [ "${sht114}" = "S:number->string" ]; then
cretag "${1}" "${2}" "${3}" "${4}" "${5}"
sht115="${R}"
R="${sht115}"
SP=${6}
return
else
hp_car "${1}"
sht116="${R}"
if [ "${sht116}" = "S:string-append" ]; then
cadr "${1}"
sht117="${R}"
cexpr "${sht117}" "${2}" "${3}" "${4}" "${5}"
sht118="${R}"
sht119="${sht118}"
eval STK$SP='${sht119}'
SP=$((SP+1))
caddr "${1}"
sht120="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
eval STK$SP='${sht120}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
caddr "${sht119}"
sht121="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht120='${STK'$SP'}'
eval STK$SP='${sht121}'
SP=$((SP+1))
eval STK$SP='${sht120}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
cadr "${sht119}"
sht122="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht120='${STK'$SP'}'
SP=$((SP-1))
eval sht121='${STK'$SP'}'
eval STK$SP='${sht121}'
SP=$((SP+1))
eval STK$SP='${sht120}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
live_add "${sht122}" "${4}"
sht123="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht120='${STK'$SP'}'
SP=$((SP-1))
eval sht121='${STK'$SP'}'
hp_car "${sht119}"
sht124="${R}"
eval STK$SP='${sht119}'
SP=$((SP+1))
cexpr "${sht120}" "${2}" "${sht121}" "${sht123}" "${sht124}"
sht125="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
sht126="${sht125}"
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
caddr "${sht126}"
sht127="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
sht128="T:${sht127#??}"
sht129="T:zt${sht128#??}"
sht130="${sht129}"
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
cadr "${sht119}"
sht131="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
cref "${sht131}"
sht132="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
eval STK$SP='${sht132}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
cadr "${sht126}"
sht133="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht132='${STK'$SP'}'
eval STK$SP='${sht132}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
cref "${sht133}"
sht134="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht132='${STK'$SP'}'
sht135="T:${sht132#??}${sht134#??}"
sht136="T:=T:${sht135#??}"
sht137="T:${sht130#??}${sht136#??}"
sht138="T:${sht137#??}"
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
qset "${sht138}"
sht139="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
hp_car "${sht126}"
sht140="${R}"
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
hp_cons "${sht139}" "${sht140}"
sht141="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
eval STK$SP='${sht141}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
hp_cons "S:val" "${sht130}"
sht142="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht141='${STK'$SP'}'
eval STK$SP='${sht142}'
SP=$((SP+1))
eval STK$SP='${sht141}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
caddr "${sht126}"
sht143="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht141='${STK'$SP'}'
SP=$((SP-1))
eval sht142='${STK'$SP'}'
sht144="I:$(( ${sht143#??} + 1 ))"
eval STK$SP='${sht142}'
SP=$((SP+1))
eval STK$SP='${sht141}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
hp_cons "${sht144}" "NIL"
sht145="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht141='${STK'$SP'}'
SP=$((SP-1))
eval sht142='${STK'$SP'}'
eval STK$SP='${sht141}'
SP=$((SP+1))
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
hp_cons "${sht142}" "${sht145}"
sht146="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
SP=$((SP-1))
eval sht141='${STK'$SP'}'
eval STK$SP='${sht130}'
SP=$((SP+1))
eval STK$SP='${sht126}'
SP=$((SP+1))
eval STK$SP='${sht119}'
SP=$((SP+1))
hp_cons "${sht141}" "${sht146}"
sht147="${R}"
SP=$((SP-1))
eval sht119='${STK'$SP'}'
SP=$((SP-1))
eval sht126='${STK'$SP'}'
SP=$((SP-1))
eval sht130='${STK'$SP'}'
R="${sht147}"
SP=${6}
return
else
hp_car "${1}"
sht148="${R}"
if [ "${sht148}" = "S:string-length" ]; then
cstrlen "${1}" "${2}" "${3}" "${4}" "${5}"
sht149="${R}"
R="${sht149}"
SP=${6}
return
else
hp_car "${1}"
sht150="${R}"
if [ "${sht150}" = "S:substring" ]; then
csubstr "${1}" "${2}" "${3}" "${4}" "${5}"
sht151="${R}"
R="${sht151}"
SP=${6}
return
else
hp_car "${1}"
sht152="${R}"
if [ "${sht152}" = "S:dq" ]; then
sht153="T:${3#??}"
sht154="T:zt${sht153#??}"
sht155="${sht154}"
sht156="T:${sht155#??}=T:!BANG8!"
sht157="T:${sht156#??}"
eval STK$SP='${sht155}'
SP=$((SP+1))
qset "${sht157}"
sht158="${R}"
SP=$((SP-1))
eval sht155='${STK'$SP'}'
eval STK$SP='${sht155}'
SP=$((SP+1))
hp_cons "${sht158}" "${5}"
sht159="${R}"
SP=$((SP-1))
eval sht155='${STK'$SP'}'
eval STK$SP='${sht159}'
SP=$((SP+1))
eval STK$SP='${sht155}'
SP=$((SP+1))
hp_cons "S:val" "${sht155}"
sht160="${R}"
SP=$((SP-1))
eval sht155='${STK'$SP'}'
SP=$((SP-1))
eval sht159='${STK'$SP'}'
sht161="I:$(( ${3#??} + 1 ))"
eval STK$SP='${sht160}'
SP=$((SP+1))
eval STK$SP='${sht159}'
SP=$((SP+1))
eval STK$SP='${sht155}'
SP=$((SP+1))
hp_cons "${sht161}" "NIL"
sht162="${R}"
SP=$((SP-1))
eval sht155='${STK'$SP'}'
SP=$((SP-1))
eval sht159='${STK'$SP'}'
SP=$((SP-1))
eval sht160='${STK'$SP'}'
eval STK$SP='${sht159}'
SP=$((SP+1))
eval STK$SP='${sht155}'
SP=$((SP+1))
hp_cons "${sht160}" "${sht162}"
sht163="${R}"
SP=$((SP-1))
eval sht155='${STK'$SP'}'
SP=$((SP-1))
eval sht159='${STK'$SP'}'
eval STK$SP='${sht155}'
SP=$((SP+1))
hp_cons "${sht159}" "${sht163}"
sht164="${R}"
SP=$((SP-1))
eval sht155='${STK'$SP'}'
R="${sht164}"
SP=${6}
return
else
hp_car "${1}"
sht165="${R}"
tpredzzQ "${sht165}"
sht166="${R}"
if [ "${sht166}" != NIL ]; then
hp_cons "S:t" "NIL"
sht167="${R}"
hp_cons "S:quote" "${sht167}"
sht168="${R}"
eval STK$SP='${sht168}'
SP=$((SP+1))
hp_cons "S:nil" "NIL"
sht169="${R}"
SP=$((SP-1))
eval sht168='${STK'$SP'}'
hp_cons "${sht168}" "${sht169}"
sht170="${R}"
hp_cons "${1}" "${sht170}"
sht171="${R}"
hp_cons "S:if" "${sht171}"
sht172="${R}"
set -- "${sht172}" "${2}" "${3}" "${4}" "${5}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
else
hp_car "${1}"
sht173="${R}"
if [ "${sht173}" = "S:let" ]; then
cadr "${1}"
sht174="${R}"
clet_binds "${sht174}" "${2}" "${3}" "${4}" "${5}"
sht175="${R}"
sht176="${sht175}"
eval STK$SP='${sht176}'
SP=$((SP+1))
caddr "${1}"
sht177="${R}"
SP=$((SP-1))
eval sht176='${STK'$SP'}'
eval STK$SP='${sht177}'
SP=$((SP+1))
eval STK$SP='${sht176}'
SP=$((SP+1))
cadr "${sht176}"
sht178="${R}"
SP=$((SP-1))
eval sht176='${STK'$SP'}'
SP=$((SP-1))
eval sht177='${STK'$SP'}'
eval STK$SP='${sht178}'
SP=$((SP+1))
eval STK$SP='${sht177}'
SP=$((SP+1))
eval STK$SP='${sht176}'
SP=$((SP+1))
caddr "${sht176}"
sht179="${R}"
SP=$((SP-1))
eval sht176='${STK'$SP'}'
SP=$((SP-1))
eval sht177='${STK'$SP'}'
SP=$((SP-1))
eval sht178='${STK'$SP'}'
hp_car "${sht176}"
sht180="${R}"
set -- "${sht177}" "${sht178}" "${sht179}" "${4}" "${sht180}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
else
hp_car "${1}"
sht181="${R}"
if [ "${sht181}" = "S:if" ]; then
sht182="T:${3#??}"
sht183="T:zT${sht182#??}"
sht184="${sht183}"
sht185="T:${3#??}"
sht186="T:zE${sht185#??}"
sht187="${sht186}"
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
cadr "${1}"
sht188="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
sht189="I:$(( ${3#??} + 1 ))"
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
test_stmts "${sht188}" "${sht184}" "${2}" "${sht189}" "${4}" "${5}"
sht190="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
sht191="${sht190}"
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
cadddr "${1}"
sht192="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
hp_cdr "${sht191}"
sht193="${R}"
hp_car "${sht191}"
sht194="${R}"
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
cexpr "${sht192}" "${2}" "${sht193}" "${4}" "${sht194}"
sht195="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
sht196="${sht195}"
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
caddr "${1}"
sht197="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
eval STK$SP='${sht197}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
caddr "${sht196}"
sht198="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht197='${STK'$SP'}'
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
cexpr "${sht197}" "${2}" "${sht198}" "${4}" "NIL"
sht199="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
sht200="${sht199}"
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
caddr "${sht200}"
sht201="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
sht202="T:${sht201#??}"
sht203="T:zt${sht202#??}"
sht204="${sht203}"
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
cadr "${sht200}"
sht205="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
vref "${sht205}"
sht206="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
sht207="T:=${sht206#??}"
sht208="T:${sht204#??}${sht207#??}"
sht209="T:${sht208#??}"
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
qset "${sht209}"
sht210="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
sht211="T::${sht187#??}"
eval STK$SP='${sht210}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht211}" "NIL"
sht212="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht210='${STK'$SP'}'
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht210}" "${sht212}"
sht213="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
hp_car "${sht200}"
sht214="${R}"
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
cadr "${sht196}"
sht215="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
vref "${sht215}"
sht216="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
sht217="T:=${sht216#??}"
sht218="T:${sht204#??}${sht217#??}"
sht219="T:${sht218#??}"
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
qset "${sht219}"
sht220="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
sht221="T:goto ${sht187#??}"
sht222="T::${sht184#??}"
eval STK$SP='${sht221}'
SP=$((SP+1))
eval STK$SP='${sht220}'
SP=$((SP+1))
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht222}" "NIL"
sht223="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
SP=$((SP-1))
eval sht220='${STK'$SP'}'
SP=$((SP-1))
eval sht221='${STK'$SP'}'
eval STK$SP='${sht220}'
SP=$((SP+1))
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht221}" "${sht223}"
sht224="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
SP=$((SP-1))
eval sht220='${STK'$SP'}'
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht220}" "${sht224}"
sht225="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
hp_car "${sht196}"
sht226="${R}"
eval STK$SP='${sht214}'
SP=$((SP+1))
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
rev "${sht225}" "${sht226}"
sht227="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
SP=$((SP-1))
eval sht214='${STK'$SP'}'
eval STK$SP='${sht213}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
append "${sht214}" "${sht227}"
sht228="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht213='${STK'$SP'}'
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
rev "${sht213}" "${sht228}"
sht229="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
eval STK$SP='${sht229}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "S:val" "${sht204}"
sht230="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht229='${STK'$SP'}'
eval STK$SP='${sht230}'
SP=$((SP+1))
eval STK$SP='${sht229}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
caddr "${sht200}"
sht231="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht229='${STK'$SP'}'
SP=$((SP-1))
eval sht230='${STK'$SP'}'
sht232="I:$(( ${sht231#??} + 1 ))"
eval STK$SP='${sht230}'
SP=$((SP+1))
eval STK$SP='${sht229}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht232}" "NIL"
sht233="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht229='${STK'$SP'}'
SP=$((SP-1))
eval sht230='${STK'$SP'}'
eval STK$SP='${sht229}'
SP=$((SP+1))
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht230}" "${sht233}"
sht234="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
SP=$((SP-1))
eval sht229='${STK'$SP'}'
eval STK$SP='${sht204}'
SP=$((SP+1))
eval STK$SP='${sht200}'
SP=$((SP+1))
eval STK$SP='${sht196}'
SP=$((SP+1))
eval STK$SP='${sht191}'
SP=$((SP+1))
eval STK$SP='${sht187}'
SP=$((SP+1))
eval STK$SP='${sht184}'
SP=$((SP+1))
hp_cons "${sht229}" "${sht234}"
sht235="${R}"
SP=$((SP-1))
eval sht184='${STK'$SP'}'
SP=$((SP-1))
eval sht187='${STK'$SP'}'
SP=$((SP-1))
eval sht191='${STK'$SP'}'
SP=$((SP-1))
eval sht196='${STK'$SP'}'
SP=$((SP-1))
eval sht200='${STK'$SP'}'
SP=$((SP-1))
eval sht204='${STK'$SP'}'
R="${sht235}"
SP=${6}
return
else
hp_cdr "${1}"
sht236="${R}"
cargszzS "${sht236}" "${2}" "${3}" "${4}" "${5}"
sht237="${R}"
sht238="${sht237}"
eval STK$SP='${sht238}'
SP=$((SP+1))
caddr "${sht238}"
sht239="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
sht240="T:${sht239#??}"
sht241="T:zt${sht240#??}"
sht242="${sht241}"
hp_car "${1}"
sht243="${R}"
eval STK$SP='${sht243}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
elide_of "${2}"
sht244="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht243='${STK'$SP'}'
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
memzzQ "${sht243}" "${sht244}"
sht245="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
if [ "${sht245}" != NIL ]; then
sht246="NIL"
else
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
pvars "${2}"
sht247="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
append "${sht247}" "${4}"
sht248="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
sht246="${sht248}"
fi
sht249="${sht246}"
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
save_lines "${sht249}"
sht250="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
cadr "${sht238}"
sht251="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
aassign "${sht251}" "I:1"
sht252="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
hp_car "${1}"
sht253="${R}"
sht254="T:${sht253#??}"
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
mangle "${sht254}"
sht255="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
sht256="T:${sht255#??}.cmd"
sht257="T:call ${sht256#??}"
eval STK$SP='${sht257}'
SP=$((SP+1))
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
rev "${sht249}" "NIL"
sht258="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
SP=$((SP-1))
eval sht257='${STK'$SP'}'
eval STK$SP='${sht257}'
SP=$((SP+1))
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
restore_lines "${sht258}"
sht259="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
SP=$((SP-1))
eval sht257='${STK'$SP'}'
sht260="T:${sht242#??}=!R!"
sht261="T:${sht260#??}"
eval STK$SP='${sht259}'
SP=$((SP+1))
eval STK$SP='${sht257}'
SP=$((SP+1))
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
qset "${sht261}"
sht262="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
SP=$((SP-1))
eval sht257='${STK'$SP'}'
SP=$((SP-1))
eval sht259='${STK'$SP'}'
eval STK$SP='${sht259}'
SP=$((SP+1))
eval STK$SP='${sht257}'
SP=$((SP+1))
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
hp_cons "${sht262}" "NIL"
sht263="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
SP=$((SP-1))
eval sht257='${STK'$SP'}'
SP=$((SP-1))
eval sht259='${STK'$SP'}'
eval STK$SP='${sht257}'
SP=$((SP+1))
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
append "${sht259}" "${sht263}"
sht264="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
SP=$((SP-1))
eval sht257='${STK'$SP'}'
eval STK$SP='${sht252}'
SP=$((SP+1))
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
hp_cons "${sht257}" "${sht264}"
sht265="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
SP=$((SP-1))
eval sht252='${STK'$SP'}'
eval STK$SP='${sht250}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
append "${sht252}" "${sht265}"
sht266="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht250='${STK'$SP'}'
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
append "${sht250}" "${sht266}"
sht267="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
hp_car "${sht238}"
sht268="${R}"
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
rev "${sht267}" "${sht268}"
sht269="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
eval STK$SP='${sht269}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
hp_cons "S:val" "${sht242}"
sht270="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht269='${STK'$SP'}'
eval STK$SP='${sht270}'
SP=$((SP+1))
eval STK$SP='${sht269}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
caddr "${sht238}"
sht271="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht269='${STK'$SP'}'
SP=$((SP-1))
eval sht270='${STK'$SP'}'
sht272="I:$(( ${sht271#??} + 1 ))"
eval STK$SP='${sht270}'
SP=$((SP+1))
eval STK$SP='${sht269}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
hp_cons "${sht272}" "NIL"
sht273="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht269='${STK'$SP'}'
SP=$((SP-1))
eval sht270='${STK'$SP'}'
eval STK$SP='${sht269}'
SP=$((SP+1))
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
hp_cons "${sht270}" "${sht273}"
sht274="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
SP=$((SP-1))
eval sht269='${STK'$SP'}'
eval STK$SP='${sht249}'
SP=$((SP+1))
eval STK$SP='${sht242}'
SP=$((SP+1))
eval STK$SP='${sht238}'
SP=$((SP+1))
hp_cons "${sht269}" "${sht274}"
sht275="${R}"
SP=$((SP-1))
eval sht238='${STK'$SP'}'
SP=$((SP-1))
eval sht242='${STK'$SP'}'
SP=$((SP-1))
eval sht249='${STK'$SP'}'
R="${sht275}"
SP=${6}
return
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
fi
done
}
cstrlen() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
cadr "${1}"
sht0="${R}"
cexpr "${sht0}" "${2}" "${3}" "${4}" "${5}"
sht1="${R}"
sht2="${sht1}"
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
sht4="T:${sht3#??}"
sht5="${sht4}"
sht6="T:zc${sht5#??}"
sht7="${sht6}"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht8="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
sht9="I:$(( ${sht8#??} + 1 ))"
sht10="T:${sht9#??}"
sht11="T:zt${sht10#??}"
sht12="${sht11}"
sht13="T:zSL${sht5#??}"
sht14="${sht13}"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht15="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cref "${sht15}"
sht16="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
sht17="T:=${sht16#??}"
sht18="T:${sht7#??}${sht17#??}"
sht19="T:${sht18#??}"
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht19}"
sht20="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
sht21="T:${sht12#??}=0"
sht22="T:set /a ${sht21#??}"
sht23="T::${sht14#??}"
sht24="T:${sht14#??})"
sht25="T:+=1& goto ${sht24#??}"
sht26="T:${sht12#??}${sht25#??}"
sht27="T::~1!& set /a ${sht26#??}"
sht28="T:${sht7#??}${sht27#??}"
sht29="T:=!${sht28#??}"
sht30="T:${sht7#??}${sht29#??}"
sht31="T: (set ${sht30#??}"
sht32="T:${sht7#??}${sht31#??}"
sht33="T:if defined ${sht32#??}"
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht22}'
SP=$((SP+1))
eval STK$SP='${sht20}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht33}" "NIL"
sht34="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht20='${STK'$SP'}'
SP=$((SP-1))
eval sht22='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
eval STK$SP='${sht22}'
SP=$((SP+1))
eval STK$SP='${sht20}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht23}" "${sht34}"
sht35="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht20='${STK'$SP'}'
SP=$((SP-1))
eval sht22='${STK'$SP'}'
eval STK$SP='${sht20}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht22}" "${sht35}"
sht36="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht20='${STK'$SP'}'
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht20}" "${sht36}"
sht37="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
hp_car "${sht2}"
sht38="${R}"
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
rev "${sht37}" "${sht38}"
sht39="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
eval STK$SP='${sht39}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "S:raw" "${sht12}"
sht40="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht39='${STK'$SP'}'
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht41="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
sht42="I:$(( ${sht41#??} + 2 ))"
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht39}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht42}" "NIL"
sht43="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht39='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
eval STK$SP='${sht39}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht40}" "${sht43}"
sht44="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht39='${STK'$SP'}'
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht39}" "${sht44}"
sht45="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
R="${sht45}"
SP=${6}
return
done
}
csubstr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
cadr "${1}"
sht0="${R}"
cexpr "${sht0}" "${2}" "${3}" "${4}" "${5}"
sht1="${R}"
sht2="${sht1}"
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${1}"
sht3="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht4="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht5="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
live_add "${sht5}" "${4}"
sht6="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht4='${STK'$SP'}'
hp_car "${sht2}"
sht7="${R}"
eval STK$SP='${sht2}'
SP=$((SP+1))
cexpr "${sht3}" "${2}" "${sht4}" "${sht6}" "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
sht9="${sht8}"
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadddr "${1}"
sht10="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
eval STK$SP='${sht10}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht9}"
sht11="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht10='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht10}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht9}"
sht12="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht10='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht10}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht13="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht10='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht10}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
live_add "${sht13}" "${4}"
sht14="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht10='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht10}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
live_add "${sht12}" "${sht14}"
sht15="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht10='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
hp_car "${sht9}"
sht16="${R}"
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cexpr "${sht10}" "${2}" "${sht11}" "${sht15}" "${sht16}"
sht17="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
sht18="${sht17}"
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht18}"
sht19="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
sht20="T:${sht19#??}"
sht21="${sht20}"
sht22="T:zc${sht21#??}"
sht23="${sht22}"
sht24="T:zsk${sht21#??}"
sht25="${sht24}"
sht26="T:ztk${sht21#??}"
sht27="${sht26}"
sht28="T:zr${sht21#??}"
sht29="${sht28}"
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht18}"
sht30="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
sht31="I:$(( ${sht30#??} + 1 ))"
sht32="T:${sht31#??}"
sht33="T:zt${sht32#??}"
sht34="${sht33}"
sht35="T:zSK${sht21#??}"
sht36="${sht35}"
sht37="T:zTK${sht21#??}"
sht38="${sht37}"
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht39="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cref "${sht39}"
sht40="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
sht41="T:=${sht40#??}"
sht42="T:${sht23#??}${sht41#??}"
sht43="T:${sht42#??}"
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht43}"
sht44="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht9}"
sht45="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
aref "${sht45}"
sht46="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
sht47="T:=${sht46#??}"
sht48="T:${sht25#??}${sht47#??}"
sht49="T:set /a ${sht48#??}"
sht50="T::${sht36#??}"
sht51="T:${sht36#??})"
sht52="T:-=1& goto ${sht51#??}"
sht53="T:${sht25#??}${sht52#??}"
sht54="T::~1!& set /a ${sht53#??}"
sht55="T:${sht23#??}${sht54#??}"
sht56="T:=!${sht55#??}"
sht57="T:${sht23#??}${sht56#??}"
sht58="T:! gtr 0 (set ${sht57#??}"
sht59="T:${sht25#??}${sht58#??}"
sht60="T: if !${sht59#??}"
sht61="T:${sht23#??}${sht60#??}"
sht62="T:if defined ${sht61#??}"
sht63="T:${sht29#??}="
sht64="T:${sht63#??}"
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht64}"
sht65="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht18}"
sht66="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
aref "${sht66}"
sht67="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
sht68="T:=${sht67#??}"
sht69="T:${sht27#??}${sht68#??}"
sht70="T:set /a ${sht69#??}"
sht71="T::${sht38#??}"
sht72="T:${sht38#??})"
sht73="T:-=1& goto ${sht72#??}"
sht74="T:${sht27#??}${sht73#??}"
sht75="T::~1!& set /a ${sht74#??}"
sht76="T:${sht23#??}${sht75#??}"
sht77="T:=!${sht76#??}"
sht78="T:${sht23#??}${sht77#??}"
sht79="T::~0,1!& set ${sht78#??}"
sht80="T:${sht23#??}${sht79#??}"
sht81="T:!!${sht80#??}"
sht82="T:${sht29#??}${sht81#??}"
sht83="T:=!${sht82#??}"
sht84="T:${sht29#??}${sht83#??}"
sht85="T:! gtr 0 (set ${sht84#??}"
sht86="T:${sht27#??}${sht85#??}"
sht87="T: if !${sht86#??}"
sht88="T:${sht23#??}${sht87#??}"
sht89="T:if defined ${sht88#??}"
sht90="T:${sht29#??}!"
sht91="T:=T:!${sht90#??}"
sht92="T:${sht34#??}${sht91#??}"
sht93="T:${sht92#??}"
eval STK$SP='${sht89}'
SP=$((SP+1))
eval STK$SP='${sht71}'
SP=$((SP+1))
eval STK$SP='${sht70}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht93}"
sht94="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht70='${STK'$SP'}'
SP=$((SP-1))
eval sht71='${STK'$SP'}'
SP=$((SP-1))
eval sht89='${STK'$SP'}'
eval STK$SP='${sht89}'
SP=$((SP+1))
eval STK$SP='${sht71}'
SP=$((SP+1))
eval STK$SP='${sht70}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht94}" "NIL"
sht95="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht70='${STK'$SP'}'
SP=$((SP-1))
eval sht71='${STK'$SP'}'
SP=$((SP-1))
eval sht89='${STK'$SP'}'
eval STK$SP='${sht71}'
SP=$((SP+1))
eval STK$SP='${sht70}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht89}" "${sht95}"
sht96="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht70='${STK'$SP'}'
SP=$((SP-1))
eval sht71='${STK'$SP'}'
eval STK$SP='${sht70}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht71}" "${sht96}"
sht97="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht70='${STK'$SP'}'
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht70}" "${sht97}"
sht98="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
eval STK$SP='${sht62}'
SP=$((SP+1))
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht65}" "${sht98}"
sht99="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
SP=$((SP-1))
eval sht62='${STK'$SP'}'
eval STK$SP='${sht50}'
SP=$((SP+1))
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht62}" "${sht99}"
sht100="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
SP=$((SP-1))
eval sht50='${STK'$SP'}'
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht50}" "${sht100}"
sht101="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
eval STK$SP='${sht44}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht49}" "${sht101}"
sht102="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht44='${STK'$SP'}'
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht44}" "${sht102}"
sht103="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
hp_car "${sht18}"
sht104="${R}"
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
rev "${sht103}" "${sht104}"
sht105="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
eval STK$SP='${sht105}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "S:val" "${sht34}"
sht106="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht105='${STK'$SP'}'
eval STK$SP='${sht106}'
SP=$((SP+1))
eval STK$SP='${sht105}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht18}"
sht107="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht105='${STK'$SP'}'
SP=$((SP-1))
eval sht106='${STK'$SP'}'
sht108="I:$(( ${sht107#??} + 2 ))"
eval STK$SP='${sht106}'
SP=$((SP+1))
eval STK$SP='${sht105}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht108}" "NIL"
sht109="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht105='${STK'$SP'}'
SP=$((SP-1))
eval sht106='${STK'$SP'}'
eval STK$SP='${sht105}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht106}" "${sht109}"
sht110="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht105='${STK'$SP'}'
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht34}'
SP=$((SP+1))
eval STK$SP='${sht29}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht25}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht105}" "${sht110}"
sht111="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht25='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht29='${STK'$SP'}'
SP=$((SP-1))
eval sht34='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
R="${sht111}"
SP=${6}
return
done
}
cretag() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
cadr "${1}"
sht0="${R}"
cexpr "${sht0}" "${2}" "${3}" "${4}" "${5}"
sht1="${R}"
sht2="${sht1}"
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
sht4="T:${sht3#??}"
sht5="T:zt${sht4#??}"
sht6="${sht5}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht7="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cref "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
sht9="T:=T:${sht8#??}"
sht10="T:${sht6#??}${sht9#??}"
sht11="T:${sht10#??}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht11}"
sht12="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_car "${sht2}"
sht13="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht12}" "${sht13}"
sht14="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "S:val" "${sht6}"
sht15="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht16="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
sht17="I:$(( ${sht16#??} + 1 ))"
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht17}" "NIL"
sht18="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht15}" "${sht18}"
sht19="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht14}" "${sht19}"
sht20="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
R="${sht20}"
SP=${6}
return
done
}
ccell() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
while :; do
cadr "${1}"
sht0="${R}"
cexpr "${sht0}" "${3}" "${4}" "${5}" "${6}"
sht1="${R}"
sht2="${sht1}"
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
sht4="T:${sht3#??}"
sht5="T:zi${sht4#??}"
sht6="${sht5}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht7="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
sht8="I:$(( ${sht7#??} + 1 ))"
sht9="T:${sht8#??}"
sht10="T:zt${sht9#??}"
sht11="${sht10}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht12="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_cdr "${sht12}"
sht13="${R}"
sht14="T:${sht13#??}:~2!"
sht15="T:=!${sht14#??}"
sht16="T:${sht6#??}${sht15#??}"
sht17="T:${sht16#??}"
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht17}"
sht18="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
sht19="T:${sht6#??}!"
sht20="T: !${sht19#??}"
sht21="T:${2#??}${sht20#??}"
sht22="T:call rdfield.cmd ${sht21#??}"
sht23="T:${sht11#??}=!R!"
sht24="T:${sht23#??}"
eval STK$SP='${sht22}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht24}"
sht25="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht22='${STK'$SP'}'
eval STK$SP='${sht22}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht25}" "NIL"
sht26="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht22='${STK'$SP'}'
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht22}" "${sht26}"
sht27="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht18}" "${sht27}"
sht28="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
hp_car "${sht2}"
sht29="${R}"
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
rev "${sht28}" "${sht29}"
sht30="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "S:val" "${sht11}"
sht31="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
eval STK$SP='${sht31}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht32="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht31='${STK'$SP'}'
sht33="I:$(( ${sht32#??} + 2 ))"
eval STK$SP='${sht31}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht33}" "NIL"
sht34="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht31='${STK'$SP'}'
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht31}" "${sht34}"
sht35="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht30}" "${sht35}"
sht36="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
R="${sht36}"
SP=${7}
return
done
}
cargszzS() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
hp_cons "${3}" "NIL"
sht0="${R}"
hp_cons "NIL" "${sht0}"
sht1="${R}"
hp_cons "${5}" "${sht1}"
sht2="${R}"
R="${sht2}"
SP=${6}
return
else
hp_car "${1}"
sht3="${R}"
cexpr "${sht3}" "${2}" "${3}" "${4}" "${5}"
sht4="${R}"
sht5="${sht4}"
hp_cdr "${1}"
sht6="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
caddr "${sht5}"
sht7="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
cadr "${sht5}"
sht8="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
live_add "${sht8}" "${4}"
sht9="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
hp_car "${sht5}"
sht10="${R}"
eval STK$SP='${sht5}'
SP=$((SP+1))
cargszzS "${sht6}" "${2}" "${sht7}" "${sht9}" "${sht10}"
sht11="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
sht12="${sht11}"
hp_car "${sht12}"
sht13="${R}"
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
cadr "${sht5}"
sht14="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
vref "${sht14}"
sht15="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
cadr "${sht12}"
sht16="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${sht15}" "${sht16}"
sht17="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
caddr "${sht12}"
sht18="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${sht18}" "NIL"
sht19="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
eval STK$SP='${sht13}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${sht17}" "${sht19}"
sht20="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht13='${STK'$SP'}'
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${sht13}" "${sht20}"
sht21="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
R="${sht21}"
SP=${6}
return
fi
done
}
clet_binds() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
hp_cons "${3}" "NIL"
sht0="${R}"
hp_cons "${2}" "${sht0}"
sht1="${R}"
hp_cons "${5}" "${sht1}"
sht2="${R}"
R="${sht2}"
SP=${6}
return
else
hp_car "${1}"
sht3="${R}"
sht4="${sht3}"
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht4}"
sht5="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht5}" "${2}" "${3}" "${4}" "${5}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
sht7="${sht6}"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
sht9="T:${sht8#??}"
sht10="T:zt${sht9#??}"
sht11="${sht10}"
hp_cdr "${1}"
sht12="${R}"
hp_car "${sht4}"
sht13="${R}"
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht13}" "${sht11}"
sht14="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht14}" "${2}"
sht15="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht7}"
sht16="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
sht17="I:$(( ${sht16#??} + 1 ))"
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht11}" "${4}"
sht18="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht7}"
sht19="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
vref "${sht19}"
sht20="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
sht21="T:=${sht20#??}"
sht22="T:${sht11#??}${sht21#??}"
sht23="T:${sht22#??}"
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
qset "${sht23}"
sht24="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
hp_car "${sht7}"
sht25="${R}"
eval STK$SP='${sht18}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht15}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht24}" "${sht25}"
sht26="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht15='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht18='${STK'$SP'}'
set -- "${sht12}" "${sht15}" "${sht17}" "${sht18}" "${sht26}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
fi
done
}
uassign() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
sht0="T:${2#??}"
hp_car "${1}"
sht1="${R}"
sht2="T:=${sht1#??}"
sht3="T:${sht0#??}${sht2#??}"
sht4="T:zu${sht3#??}"
qset "${sht4}"
sht5="${R}"
hp_cdr "${1}"
sht6="${R}"
sht7="I:$(( ${2#??} + 1 ))"
eval STK$SP='${sht5}'
SP=$((SP+1))
uassign "${sht6}" "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
hp_cons "${sht5}" "${sht8}"
sht9="${R}"
R="${sht9}"
SP=${3}
return
fi
done
}
pupd() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${4}
return
else
hp_car "${1}"
sht0="${R}"
sht1="T:${sht0#??}"
sht2="T:${2#??}"
sht3="T:${sht2#??}!"
sht4="T:=!zu${sht3#??}"
sht5="T:${sht1#??}${sht4#??}"
sht6="T:_${sht5#??}"
sht7="T:${3#??}${sht6#??}"
qset "${sht7}"
sht8="${R}"
hp_cdr "${1}"
sht9="${R}"
sht10="I:$(( ${2#??} + 1 ))"
eval STK$SP='${sht8}'
SP=$((SP+1))
pupd "${sht9}" "${sht10}" "${3}"
sht11="${R}"
SP=$((SP-1))
eval sht8='${STK'$SP'}'
hp_cons "${sht8}" "${sht11}"
sht12="${R}"
R="${sht12}"
SP=${4}
return
fi
done
}
ctag_test() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
eval STK$SP='${7}'
SP=$((SP+1))
while :; do
cadr "${1}"
sht0="${R}"
cexpr "${sht0}" "${3}" "${4}" "${6}" "${7}"
sht1="${R}"
sht2="${sht1}"
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
sht4="T:${sht3#??}"
sht5="T:zp${sht4#??}"
sht6="${sht5}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht7="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
vref "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
sht9="T:=${sht8#??}"
sht10="T:${sht6#??}${sht9#??}"
sht11="T:${sht10#??}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht11}"
sht12="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
sht13="T:${sht6#??}:~0,1!"
sht14="T:=!${sht13#??}"
sht15="T:${sht6#??}${sht14#??}"
sht16="T:${sht15#??}"
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
qset "${sht16}"
sht17="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
sht18="T: goto ${2#??}"
sht19="T:${5#??}${sht18#??}"
sht20="T:!==${sht19#??}"
sht21="T:${sht6#??}${sht20#??}"
sht22="T:if !${sht21#??}"
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht22}" "NIL"
sht23="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht17}" "${sht23}"
sht24="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht12}" "${sht24}"
sht25="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_car "${sht2}"
sht26="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
rev "${sht25}" "${sht26}"
sht27="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht28="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
sht29="I:$(( ${sht28#??} + 1 ))"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht27}" "${sht29}"
sht30="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
R="${sht30}"
SP=${8}
return
done
}
test_stmts() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht1="${R}"
tpredzzQ "${sht1}"
sht2="${R}"
sht0="${sht2}"
else
sht0="NIL"
fi
if [ "${sht0}" != NIL ]; then
hp_car "${1}"
sht3="${R}"
sht4="${sht3}"
if [ "${sht4}" = "S:null?" ]; then
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${1}"
sht5="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht5}" "${3}" "${4}" "${5}" "${6}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
sht7="${sht6}"
sht8="${G_DQ}"
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht7}"
sht9="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
vref "${sht9}"
sht10="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
sht11="T: goto ${2#??}"
sht12="T:${sht8#??}${sht11#??}"
sht13="T:NIL${sht12#??}"
sht14="T:${sht8#??}${sht13#??}"
sht15="T:==${sht14#??}"
sht16="T:${sht8#??}${sht15#??}"
sht17="T:${sht10#??}${sht16#??}"
sht18="T:${sht8#??}${sht17#??}"
sht19="T:if ${sht18#??}"
hp_car "${sht7}"
sht20="${R}"
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht19}" "${sht20}"
sht21="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
eval STK$SP='${sht21}'
SP=$((SP+1))
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht7}"
sht22="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
SP=$((SP-1))
eval sht21='${STK'$SP'}'
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht21}" "${sht22}"
sht23="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
R="${sht23}"
SP=${7}
return
else
if [ "${sht4}" = "S:pair?" ]; then
eval STK$SP='${sht4}'
SP=$((SP+1))
ctag_test "${1}" "${2}" "${3}" "${4}" "T:P" "${5}" "${6}"
sht24="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
R="${sht24}"
SP=${7}
return
else
if [ "${sht4}" = "S:number?" ]; then
eval STK$SP='${sht4}'
SP=$((SP+1))
ctag_test "${1}" "${2}" "${3}" "${4}" "T:I" "${5}" "${6}"
sht25="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
R="${sht25}"
SP=${7}
return
else
if [ "${sht4}" = "S:string?" ]; then
eval STK$SP='${sht4}'
SP=$((SP+1))
ctag_test "${1}" "${2}" "${3}" "${4}" "T:T" "${5}" "${6}"
sht26="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
R="${sht26}"
SP=${7}
return
else
if [ "${sht4}" = "S:symbol?" ]; then
eval STK$SP='${sht4}'
SP=$((SP+1))
ctag_test "${1}" "${2}" "${3}" "${4}" "T:S" "${5}" "${6}"
sht27="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
R="${sht27}"
SP=${7}
return
else
if [ "${sht4}" = "S:eq?" ]; then
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${1}"
sht28="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht28}" "${3}" "${4}" "${5}" "${6}"
sht29="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
sht30="${sht29}"
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${1}"
sht31="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
eval STK$SP='${sht31}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht30}"
sht32="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht31='${STK'$SP'}'
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht31}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht30}"
sht33="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht31='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht31}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
live_add "${sht33}" "${5}"
sht34="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht31='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
hp_car "${sht30}"
sht35="${R}"
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht31}" "${3}" "${sht32}" "${sht34}" "${sht35}"
sht36="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
sht37="${sht36}"
sht38="${G_DQ}"
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht30}"
sht39="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
vref "${sht39}"
sht40="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht37}"
sht41="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht40}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
vref "${sht41}"
sht42="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht40='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
sht43="T: goto ${2#??}"
sht44="T:${sht38#??}${sht43#??}"
sht45="T:${sht42#??}${sht44#??}"
sht46="T:${sht38#??}${sht45#??}"
sht47="T:==${sht46#??}"
sht48="T:${sht38#??}${sht47#??}"
sht49="T:${sht40#??}${sht48#??}"
sht50="T:${sht38#??}${sht49#??}"
sht51="T:if ${sht50#??}"
hp_car "${sht37}"
sht52="${R}"
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht51}" "${sht52}"
sht53="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
eval STK$SP='${sht53}'
SP=$((SP+1))
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht37}"
sht54="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
SP=$((SP-1))
eval sht53='${STK'$SP'}'
eval STK$SP='${sht38}'
SP=$((SP+1))
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht30}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht53}" "${sht54}"
sht55="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht30='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
SP=$((SP-1))
eval sht38='${STK'$SP'}'
R="${sht55}"
SP=${7}
return
else
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${1}"
sht56="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht56}" "${3}" "${4}" "${5}" "${6}"
sht57="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
sht58="${sht57}"
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${1}"
sht59="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
eval STK$SP='${sht59}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht58}"
sht60="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht59='${STK'$SP'}'
eval STK$SP='${sht60}'
SP=$((SP+1))
eval STK$SP='${sht59}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht58}"
sht61="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht59='${STK'$SP'}'
SP=$((SP-1))
eval sht60='${STK'$SP'}'
eval STK$SP='${sht60}'
SP=$((SP+1))
eval STK$SP='${sht59}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
live_add "${sht61}" "${5}"
sht62="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht59='${STK'$SP'}'
SP=$((SP-1))
eval sht60='${STK'$SP'}'
hp_car "${sht58}"
sht63="${R}"
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht59}" "${3}" "${sht60}" "${sht62}" "${sht63}"
sht64="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
sht65="${sht64}"
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht58}"
sht66="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
iref "${sht66}"
sht67="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
eval STK$SP='${sht67}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cmp_zzGbatch "${sht4}"
sht68="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht67='${STK'$SP'}'
eval STK$SP='${sht68}'
SP=$((SP+1))
eval STK$SP='${sht67}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht65}"
sht69="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht67='${STK'$SP'}'
SP=$((SP-1))
eval sht68='${STK'$SP'}'
eval STK$SP='${sht68}'
SP=$((SP+1))
eval STK$SP='${sht67}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
iref "${sht69}"
sht70="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht67='${STK'$SP'}'
SP=$((SP-1))
eval sht68='${STK'$SP'}'
sht71="T: goto ${2#??}"
sht72="T:${sht70#??}${sht71#??}"
sht73="T: ${sht72#??}"
sht74="T:${sht68#??}${sht73#??}"
sht75="T: ${sht74#??}"
sht76="T:${sht67#??}${sht75#??}"
sht77="T:if ${sht76#??}"
hp_car "${sht65}"
sht78="${R}"
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht77}" "${sht78}"
sht79="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
eval STK$SP='${sht79}'
SP=$((SP+1))
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht65}"
sht80="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
SP=$((SP-1))
eval sht79='${STK'$SP'}'
eval STK$SP='${sht65}'
SP=$((SP+1))
eval STK$SP='${sht58}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht79}" "${sht80}"
sht81="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht58='${STK'$SP'}'
SP=$((SP-1))
eval sht65='${STK'$SP'}'
R="${sht81}"
SP=${7}
return
fi
fi
fi
fi
fi
fi
else
cexpr "${1}" "${3}" "${4}" "${5}" "${6}"
sht82="${R}"
sht83="${sht82}"
sht84="${G_DQ}"
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht83}'
SP=$((SP+1))
cadr "${sht83}"
sht85="${R}"
SP=$((SP-1))
eval sht83='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht83}'
SP=$((SP+1))
vref "${sht85}"
sht86="${R}"
SP=$((SP-1))
eval sht83='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
sht87="T: goto ${2#??}"
sht88="T:${sht84#??}${sht87#??}"
sht89="T:NIL${sht88#??}"
sht90="T:${sht84#??}${sht89#??}"
sht91="T:==${sht90#??}"
sht92="T:${sht84#??}${sht91#??}"
sht93="T:${sht86#??}${sht92#??}"
sht94="T:${sht84#??}${sht93#??}"
sht95="T:if not ${sht94#??}"
hp_car "${sht83}"
sht96="${R}"
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht83}'
SP=$((SP+1))
hp_cons "${sht95}" "${sht96}"
sht97="${R}"
SP=$((SP-1))
eval sht83='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
eval STK$SP='${sht97}'
SP=$((SP+1))
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht83}'
SP=$((SP+1))
caddr "${sht83}"
sht98="${R}"
SP=$((SP-1))
eval sht83='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
SP=$((SP-1))
eval sht97='${STK'$SP'}'
eval STK$SP='${sht84}'
SP=$((SP+1))
eval STK$SP='${sht83}'
SP=$((SP+1))
hp_cons "${sht97}" "${sht98}"
sht99="${R}"
SP=$((SP-1))
eval sht83='${STK'$SP'}'
SP=$((SP-1))
eval sht84='${STK'$SP'}'
R="${sht99}"
SP=${7}
return
fi
done
}
ctail_begin() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
eval STK$SP='${7}'
SP=$((SP+1))
while :; do
hp_cdr "${1}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then
hp_car "${1}"
sht1="${R}"
ctail "${sht1}" "${2}" "${3}" "${4}" "${5}" "${6}" "${7}"
sht2="${R}"
R="${sht2}"
SP=${8}
return
else
hp_car "${1}"
sht3="${R}"
cexpr "${sht3}" "${5}" "${6}" "NIL" "${7}"
sht4="${R}"
sht5="${sht4}"
hp_cdr "${1}"
sht6="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
caddr "${sht5}"
sht7="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_car "${sht5}"
sht8="${R}"
set -- "${sht6}" "${2}" "${3}" "${4}" "${5}" "${sht7}" "${sht8}" "${8}"
SP=${8}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
eval STK$SP='${7}'
SP=$((SP+1))
fi
done
}
ctail() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
eval STK$SP='${7}'
SP=$((SP+1))
while :; do
iszzQ "${1}" "S:begin"
sht0="${R}"
if [ "${sht0}" != NIL ]; then
hp_cdr "${1}"
sht1="${R}"
ctail_begin "${sht1}" "${2}" "${3}" "${4}" "${5}" "${6}" "${7}"
sht2="${R}"
R="${sht2}"
SP=${8}
return
else
iszzQ "${1}" "${2}"
sht3="${R}"
if [ "${sht3}" != NIL ]; then
hp_cdr "${1}"
sht4="${R}"
cargszzS "${sht4}" "${5}" "${6}" "NIL" "${7}"
sht5="${R}"
sht6="${sht5}"
eval STK$SP='${sht6}'
SP=$((SP+1))
cadr "${sht6}"
sht7="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
uassign "${sht7}" "I:1"
sht8="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
pupd "${4}" "I:1" "${3}"
sht9="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
sht10="T:${3#??}_top"
sht11="T:goto ${sht10#??}"
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
hp_cons "${sht11}" "NIL"
sht12="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
eval STK$SP='${sht8}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
append "${sht9}" "${sht12}"
sht13="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht8='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
append "${sht8}" "${sht13}"
sht14="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
hp_car "${sht6}"
sht15="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
rev "${sht14}" "${sht15}"
sht16="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht16}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
caddr "${sht6}"
sht17="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht16='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
hp_cons "${sht16}" "${sht17}"
sht18="${R}"
SP=$((SP-1))
eval sht6='${STK'$SP'}'
R="${sht18}"
SP=${8}
return
else
iszzQ "${1}" "S:if"
sht19="${R}"
if [ "${sht19}" != NIL ]; then
sht20="T:${6#??}"
sht21="T:_L${sht20#??}"
sht22="T:${3#??}${sht21#??}"
sht23="${sht22}"
eval STK$SP='${sht23}'
SP=$((SP+1))
cadr "${1}"
sht24="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
sht25="I:$(( ${6#??} + 1 ))"
eval STK$SP='${sht23}'
SP=$((SP+1))
test_stmts "${sht24}" "${sht23}" "${5}" "${sht25}" "NIL" "${7}"
sht26="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
sht27="${sht26}"
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
cadddr "${1}"
sht28="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
hp_cdr "${sht27}"
sht29="${R}"
hp_car "${sht27}"
sht30="${R}"
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
ctail "${sht28}" "${2}" "${3}" "${4}" "${5}" "${sht29}" "${sht30}"
sht31="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
sht32="${sht31}"
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
caddr "${1}"
sht33="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
hp_cdr "${sht32}"
sht34="${R}"
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
ctail "${sht33}" "${2}" "${3}" "${4}" "${5}" "${sht34}" "NIL"
sht35="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
sht36="${sht35}"
hp_car "${sht36}"
sht37="${R}"
sht38="T::${sht23#??}"
hp_car "${sht32}"
sht39="${R}"
eval STK$SP='${sht37}'
SP=$((SP+1))
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
hp_cons "${sht38}" "${sht39}"
sht40="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
SP=$((SP-1))
eval sht37='${STK'$SP'}'
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
append "${sht37}" "${sht40}"
sht41="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
hp_cdr "${sht36}"
sht42="${R}"
eval STK$SP='${sht36}'
SP=$((SP+1))
eval STK$SP='${sht32}'
SP=$((SP+1))
eval STK$SP='${sht27}'
SP=$((SP+1))
eval STK$SP='${sht23}'
SP=$((SP+1))
hp_cons "${sht41}" "${sht42}"
sht43="${R}"
SP=$((SP-1))
eval sht23='${STK'$SP'}'
SP=$((SP-1))
eval sht27='${STK'$SP'}'
SP=$((SP-1))
eval sht32='${STK'$SP'}'
SP=$((SP-1))
eval sht36='${STK'$SP'}'
R="${sht43}"
SP=${8}
return
else
iszzQ "${1}" "S:let"
sht44="${R}"
if [ "${sht44}" != NIL ]; then
cadr "${1}"
sht45="${R}"
clet_binds "${sht45}" "${5}" "${6}" "NIL" "${7}"
sht46="${R}"
sht47="${sht46}"
eval STK$SP='${sht47}'
SP=$((SP+1))
caddr "${1}"
sht48="${R}"
SP=$((SP-1))
eval sht47='${STK'$SP'}'
eval STK$SP='${sht48}'
SP=$((SP+1))
eval STK$SP='${sht47}'
SP=$((SP+1))
cadr "${sht47}"
sht49="${R}"
SP=$((SP-1))
eval sht47='${STK'$SP'}'
SP=$((SP-1))
eval sht48='${STK'$SP'}'
eval STK$SP='${sht49}'
SP=$((SP+1))
eval STK$SP='${sht48}'
SP=$((SP+1))
eval STK$SP='${sht47}'
SP=$((SP+1))
caddr "${sht47}"
sht50="${R}"
SP=$((SP-1))
eval sht47='${STK'$SP'}'
SP=$((SP-1))
eval sht48='${STK'$SP'}'
SP=$((SP-1))
eval sht49='${STK'$SP'}'
hp_car "${sht47}"
sht51="${R}"
set -- "${sht48}" "${2}" "${3}" "${4}" "${sht49}" "${sht50}" "${sht51}" "${8}"
SP=${8}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
eval STK$SP='${7}'
SP=$((SP+1))
else
cexpr "${1}" "${5}" "${6}" "NIL" "${7}"
sht52="${R}"
sht53="${sht52}"
eval STK$SP='${sht53}'
SP=$((SP+1))
cadr "${sht53}"
sht54="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
eval STK$SP='${sht53}'
SP=$((SP+1))
vref "${sht54}"
sht55="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
sht56="T:R=${sht55#??}"
eval STK$SP='${sht53}'
SP=$((SP+1))
qset "${sht56}"
sht57="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
eval STK$SP='${sht57}'
SP=$((SP+1))
eval STK$SP='${sht53}'
SP=$((SP+1))
hp_cons "T:goto :eof" "NIL"
sht58="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
SP=$((SP-1))
eval sht57='${STK'$SP'}'
eval STK$SP='${sht53}'
SP=$((SP+1))
hp_cons "${sht57}" "${sht58}"
sht59="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
hp_car "${sht53}"
sht60="${R}"
eval STK$SP='${sht53}'
SP=$((SP+1))
rev "${sht59}" "${sht60}"
sht61="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
eval STK$SP='${sht61}'
SP=$((SP+1))
eval STK$SP='${sht53}'
SP=$((SP+1))
caddr "${sht53}"
sht62="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
SP=$((SP-1))
eval sht61='${STK'$SP'}'
eval STK$SP='${sht53}'
SP=$((SP+1))
hp_cons "${sht61}" "${sht62}"
sht63="${R}"
SP=$((SP-1))
eval sht53='${STK'$SP'}'
R="${sht63}"
SP=${8}
return
fi
fi
fi
fi
done
}
compile_fn() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
eval STK$SP='${6}'
SP=$((SP+1))
while :; do
hp_cons "T:\$ELIDE" "${6}"
sht0="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
pmap_local "${3}" "${2}"
sht1="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
hp_cons "${sht0}" "${sht1}"
sht2="${R}"
ctail "${4}" "${1}" "${2}" "${3}" "${sht2}" "${5}" "NIL"
sht3="${R}"
sht4="${sht3}"
sht5="T::${2#??}"
eval STK$SP='${sht5}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
load_params "${3}" "I:1" "${2}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht5='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht5}" "${sht6}"
sht7="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
sht8="T:${2#??}_top"
sht9="T::${sht8#??}"
hp_car "${sht4}"
sht10="${R}"
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
rev "${sht10}" "NIL"
sht11="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht9}" "${sht11}"
sht12="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
append "${sht7}" "${sht12}"
sht13="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
hp_cdr "${sht4}"
sht14="${R}"
eval STK$SP='${sht4}'
SP=$((SP+1))
hp_cons "${sht13}" "${sht14}"
sht15="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
R="${sht15}"
SP=${7}
return
done
}
show_list() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
hp_cdr "${1}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then
hp_car "${1}"
sht1="${R}"
show "${sht1}"
sht2="${R}"
R="${sht2}"
SP=${2}
return
else
hp_cdr "${1}"
sht3="${R}"
if [ "${sht3#P:}" != "${sht3}" ]; then
hp_car "${1}"
sht4="${R}"
show "${sht4}"
sht5="${R}"
hp_cdr "${1}"
sht6="${R}"
eval STK$SP='${sht5}'
SP=$((SP+1))
show_list "${sht6}"
sht7="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
sht8="T: ${sht7#??}"
sht9="T:${sht5#??}${sht8#??}"
R="${sht9}"
SP=${2}
return
else
hp_car "${1}"
sht10="${R}"
show "${sht10}"
sht11="${R}"
hp_cdr "${1}"
sht12="${R}"
eval STK$SP='${sht11}'
SP=$((SP+1))
show "${sht12}"
sht13="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
sht14="T: . ${sht13#??}"
sht15="T:${sht11#??}${sht14#??}"
R="${sht15}"
SP=${2}
return
fi
fi
done
}
show() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="T:()"
SP=${2}
return
else
if [ "${1#I:}" != "${1}" ]; then
sht0="T:${1#??}"
R="${sht0}"
SP=${2}
return
else
if [ "${1#S:}" != "${1}" ]; then
sht1="T:${1#??}"
R="${sht1}"
SP=${2}
return
else
if [ "${1#T:}" != "${1}" ]; then
sht2="T:${1#??}${G_DQ#??}"
sht3="T:${G_DQ#??}${sht2#??}"
R="${sht3}"
SP=${2}
return
else
show_list "${1}"
sht4="${R}"
sht5="T:${sht4#??})"
sht6="T:(${sht5#??}"
R="${sht6}"
SP=${2}
return
fi
fi
fi
fi
done
}
def_lambdazzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:define" ]; then
caddr "${1}"
sht1="${R}"
if [ "${sht1#P:}" != "${sht1}" ]; then
caddr "${1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
if [ "${sht3}" = "S:lambda" ]; then
sht4="S:t"
else
sht4="NIL"
fi
R="${sht4}"
SP=${2}
return
else
R="NIL"
SP=${2}
return
fi
else
R="NIL"
SP=${2}
return
fi
else
R="NIL"
SP=${2}
return
fi
done
}
resid_bind() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
sht0="T:${1#??}"
mangle "${sht0}"
sht1="${R}"
hp_cons "${sht1}" "NIL"
sht2="${R}"
hp_cons "S:make-compiled" "${sht2}"
sht3="${R}"
hp_cons "${sht3}" "NIL"
sht4="${R}"
hp_cons "${1}" "${sht4}"
sht5="${R}"
hp_cons "S:define" "${sht5}"
sht6="${R}"
R="${sht6}"
SP=${2}
return
done
}
subst() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
while :; do
if [ "${3}" = "${1}" ]; then
R="${2}"
SP=${4}
return
else
if [ "${3#P:}" != "${3}" ]; then
hp_car "${3}"
sht0="${R}"
subst "${1}" "${2}" "${sht0}"
sht1="${R}"
hp_cdr "${3}"
sht2="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
subst "${1}" "${2}" "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${4}
return
else
R="${3}"
SP=${4}
return
fi
fi
done
}
substzzS() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="${3}"
SP=${4}
return
else
hp_cdr "${1}"
sht0="${R}"
hp_cdr "${2}"
sht1="${R}"
hp_car "${1}"
sht2="${R}"
hp_car "${2}"
sht3="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
eval STK$SP='${sht0}'
SP=$((SP+1))
subst "${sht2}" "${sht3}" "${3}"
sht4="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
SP=$((SP-1))
eval sht1='${STK'$SP'}'
set -- "${sht0}" "${sht1}" "${sht4}" "${4}"
SP=${4}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
fi
done
}
refszzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${2}" = "${1}" ]; then
R="S:t"
SP=${3}
return
else
if [ "${2#P:}" != "${2}" ]; then
hp_car "${2}"
sht0="${R}"
refszzQ "${1}" "${sht0}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
R="S:t"
SP=${3}
return
else
hp_cdr "${2}"
sht2="${R}"
set -- "${1}" "${sht2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
else
R="NIL"
SP=${3}
return
fi
fi
done
}
map_inline_expr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
inline_expr "${sht0}" "${2}"
sht1="${R}"
hp_cdr "${1}"
sht2="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
map_inline_expr "${sht2}" "${2}"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${3}
return
fi
done
}
map_inline_form() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
inline_form "${sht0}" "${2}"
sht1="${R}"
hp_cdr "${1}"
sht2="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
map_inline_form "${sht2}" "${2}"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${3}
return
fi
done
}
map_mexpand() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
mexpand "${sht0}"
sht1="${R}"
hp_cdr "${1}"
sht2="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
map_mexpand "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${2}
return
fi
done
}
map_show() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
show "${sht0}"
sht1="${R}"
hp_cdr "${1}"
sht2="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
map_show "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${2}
return
fi
done
}
inline_expr() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht0="${R}"
assoc "${sht0}" "${2}"
sht1="${R}"
sht2="${sht1}"
if [ "${sht2}" = NIL ]; then
hp_car "${1}"
sht3="${R}"
hp_cdr "${1}"
sht4="${R}"
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
map_inline_expr "${sht4}" "${2}"
sht5="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht3}" "${sht5}"
sht6="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
R="${sht6}"
SP=${3}
return
else
eval STK$SP='${sht2}'
SP=$((SP+1))
cadr "${sht2}"
sht7="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
hp_cdr "${1}"
sht8="${R}"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
map_inline_expr "${sht8}" "${2}"
sht9="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht2}'
SP=$((SP+1))
caddr "${sht2}"
sht10="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
eval STK$SP='${sht2}'
SP=$((SP+1))
substzzS "${sht7}" "${sht9}" "${sht10}"
sht11="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
set -- "${sht11}" "${2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
else
R="${1}"
SP=${3}
return
fi
done
}
mk_tbl() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
def_lambdazzQ "${sht0}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
hp_car "${1}"
sht3="${R}"
cadr "${sht3}"
sht4="${R}"
hp_car "${1}"
sht5="${R}"
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht5}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht6}"
sht7="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
refszzQ "${sht4}" "${sht7}"
sht8="${R}"
not "${sht8}"
sht9="${R}"
sht2="${sht9}"
else
sht2="NIL"
fi
if [ "${sht2}" != NIL ]; then
hp_car "${1}"
sht10="${R}"
cadr "${sht10}"
sht11="${R}"
hp_car "${1}"
sht12="${R}"
eval STK$SP='${sht11}'
SP=$((SP+1))
caddr "${sht12}"
sht13="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
cadr "${sht13}"
sht14="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
hp_car "${1}"
sht15="${R}"
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
caddr "${sht15}"
sht16="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
caddr "${sht16}"
sht17="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
eval STK$SP='${sht14}'
SP=$((SP+1))
eval STK$SP='${sht11}'
SP=$((SP+1))
hp_cons "${sht17}" "NIL"
sht18="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
SP=$((SP-1))
eval sht14='${STK'$SP'}'
eval STK$SP='${sht11}'
SP=$((SP+1))
hp_cons "${sht14}" "${sht18}"
sht19="${R}"
SP=$((SP-1))
eval sht11='${STK'$SP'}'
hp_cons "${sht11}" "${sht19}"
sht20="${R}"
hp_cdr "${1}"
sht21="${R}"
eval STK$SP='${sht20}'
SP=$((SP+1))
mk_tbl "${sht21}"
sht22="${R}"
SP=$((SP-1))
eval sht20='${STK'$SP'}'
hp_cons "${sht20}" "${sht22}"
sht23="${R}"
R="${sht23}"
SP=${2}
return
else
hp_cdr "${1}"
sht24="${R}"
set -- "${sht24}" "${2}"
SP=${2}
eval STK$SP='${1}'
SP=$((SP+1))
fi
fi
done
}
inline_form() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
def_lambdazzQ "${1}"
sht0="${R}"
if [ "${sht0}" != NIL ]; then
cadr "${1}"
sht1="${R}"
eval STK$SP='${sht1}'
SP=$((SP+1))
caddr "${1}"
sht2="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
eval STK$SP='${sht1}'
SP=$((SP+1))
cadr "${sht2}"
sht3="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
caddr "${1}"
sht4="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
caddr "${sht4}"
sht5="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
inline_expr "${sht5}" "${2}"
sht6="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
hp_cons "${sht6}" "NIL"
sht7="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht1}'
SP=$((SP+1))
hp_cons "${sht3}" "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
eval STK$SP='${sht1}'
SP=$((SP+1))
hp_cons "S:lambda" "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
eval STK$SP='${sht1}'
SP=$((SP+1))
hp_cons "${sht9}" "NIL"
sht10="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
hp_cons "${sht1}" "${sht10}"
sht11="${R}"
hp_cons "S:define" "${sht11}"
sht12="${R}"
R="${sht12}"
SP=${3}
return
else
R="${1}"
SP=${3}
return
fi
done
}
inline_program() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
mk_tbl "${1}"
sht0="${R}"
sht1="${sht0}"
eval STK$SP='${sht1}'
SP=$((SP+1))
map_inline_form "${1}" "${sht1}"
sht2="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
R="${sht2}"
SP=${2}
return
done
}
cond_zzGif() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="S:nil"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "S:t" ]; then
hp_car "${1}"
sht2="${R}"
cadr "${sht2}"
sht3="${R}"
R="${sht3}"
SP=${2}
return
else
hp_car "${1}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
hp_car "${1}"
sht6="${R}"
eval STK$SP='${sht5}'
SP=$((SP+1))
cadr "${sht6}"
sht7="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
hp_cdr "${1}"
sht8="${R}"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
cond_zzGif "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${sht9}" "NIL"
sht10="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht5}'
SP=$((SP+1))
hp_cons "${sht7}" "${sht10}"
sht11="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
hp_cons "${sht5}" "${sht11}"
sht12="${R}"
hp_cons "S:if" "${sht12}"
sht13="${R}"
R="${sht13}"
SP=${2}
return
fi
fi
done
}
str_zzGapp() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="T:"
SP=${2}
return
else
hp_cdr "${1}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then
hp_car "${1}"
sht1="${R}"
R="${sht1}"
SP=${2}
return
else
hp_car "${1}"
sht2="${R}"
hp_cdr "${1}"
sht3="${R}"
eval STK$SP='${sht2}'
SP=$((SP+1))
str_zzGapp "${sht3}"
sht4="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
eval STK$SP='${sht2}'
SP=$((SP+1))
hp_cons "${sht4}" "NIL"
sht5="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:string-append" "${sht6}"
sht7="${R}"
R="${sht7}"
SP=${2}
return
fi
fi
done
}
list_zzGcons() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="S:nil"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
hp_cdr "${1}"
sht1="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
list_zzGcons "${sht1}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
eval STK$SP='${sht0}'
SP=$((SP+1))
hp_cons "${sht2}" "NIL"
sht3="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
hp_cons "${sht0}" "${sht3}"
sht4="${R}"
hp_cons "S:cons" "${sht4}"
sht5="${R}"
R="${sht5}"
SP=${2}
return
fi
done
}
mexpand() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then
R="${1}"
SP=${2}
return
else
hp_car "${1}"
sht1="${R}"
if [ "${sht1}" = "S:cond" ]; then
hp_cdr "${1}"
sht2="${R}"
cond_zzGif "${sht2}"
sht3="${R}"
set -- "${sht3}" "${2}"
SP=${2}
eval STK$SP='${1}'
SP=$((SP+1))
else
hp_car "${1}"
sht4="${R}"
if [ "${sht4}" = "S:str" ]; then
hp_cdr "${1}"
sht5="${R}"
map_mexpand "${sht5}"
sht6="${R}"
str_zzGapp "${sht6}"
sht7="${R}"
R="${sht7}"
SP=${2}
return
else
hp_car "${1}"
sht8="${R}"
if [ "${sht8}" = "S:list" ]; then
hp_cdr "${1}"
sht9="${R}"
map_mexpand "${sht9}"
sht10="${R}"
list_zzGcons "${sht10}"
sht11="${R}"
R="${sht11}"
SP=${2}
return
else
hp_car "${1}"
sht12="${R}"
mexpand "${sht12}"
sht13="${R}"
sht14="${sht13}"
hp_cdr "${1}"
sht15="${R}"
eval STK$SP='${sht14}'
SP=$((SP+1))
mexpand "${sht15}"
sht16="${R}"
SP=$((SP-1))
eval sht14='${STK'$SP'}'
sht17="${sht16}"
hp_car "${1}"
sht18="${R}"
if [ "${sht14}" = "${sht18}" ]; then
hp_cdr "${1}"
sht20="${R}"
if [ "${sht17}" = "${sht20}" ]; then
sht21="S:t"
else
sht21="NIL"
fi
sht19="${sht21}"
else
sht19="NIL"
fi
if [ "${sht19}" != NIL ]; then
R="${1}"
SP=${2}
return
else
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht14}'
SP=$((SP+1))
hp_cons "${sht14}" "${sht17}"
sht22="${R}"
SP=$((SP-1))
eval sht14='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
R="${sht22}"
SP=${2}
return
fi
fi
fi
fi
fi
else
R="${1}"
SP=${2}
return
fi
done
}
mexpand_program() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
map_mexpand "${1}"
sht0="${R}"
R="${sht0}"
SP=${2}
return
done
}
concat() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
hp_cdr "${1}"
sht1="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
concat "${sht1}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
append "${sht0}" "${sht2}"
sht3="${R}"
R="${sht3}"
SP=${2}
return
fi
done
}
cp() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="S:done"
SP=${6}
return
else
gc
sht0="${R}"
hp_car "${1}"
sht1="${R}"
def_lambdazzQ "${sht1}"
sht2="${R}"
if [ "${sht2}" != NIL ]; then
hp_car "${1}"
sht3="${R}"
cadr "${sht3}"
sht4="${R}"
sht5="T:${sht4#??}"
mangle "${sht5}"
sht6="${R}"
sht7="${sht6}"
hp_car "${1}"
sht8="${R}"
eval STK$SP='${sht7}'
SP=$((SP+1))
cadr "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
hp_car "${1}"
sht10="${R}"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
caddr "${sht10}"
sht11="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
cadr "${sht11}"
sht12="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
hp_car "${1}"
sht13="${R}"
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
caddr "${sht13}"
sht14="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht12}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht9}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
caddr "${sht14}"
sht15="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht9='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht12='${STK'$SP'}'
eval STK$SP='${sht7}'
SP=$((SP+1))
compile_fn "${sht9}" "${sht7}" "${sht12}" "${sht15}" "${4}" "${5}"
sht16="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
sht17="${sht16}"
hp_cdr "${sht17}"
sht18="${R}"
sht19="${sht18}"
sht20="T:${sht7#??}.cmd"
sht21="T:/${sht20#??}"
sht22="T:${2#??}${sht21#??}"
hp_car "${sht17}"
sht23="${R}"
eval STK$SP='${sht19}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
write_lines "${sht22}" "${sht23}"
sht24="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht19='${STK'$SP'}'
hp_car "${1}"
sht25="${R}"
eval STK$SP='${sht19}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
cadr "${sht25}"
sht26="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht19='${STK'$SP'}'
eval STK$SP='${sht19}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
resid_bind "${sht26}"
sht27="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht19='${STK'$SP'}'
eval STK$SP='${sht19}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
show "${sht27}"
sht28="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht19='${STK'$SP'}'
eval STK$SP='${sht19}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
hp_cons "${sht28}" "NIL"
sht29="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht19='${STK'$SP'}'
eval STK$SP='${sht19}'
SP=$((SP+1))
eval STK$SP='${sht17}'
SP=$((SP+1))
eval STK$SP='${sht7}'
SP=$((SP+1))
append_lines "${3}" "${sht29}"
sht30="${R}"
SP=$((SP-1))
eval sht7='${STK'$SP'}'
SP=$((SP-1))
eval sht17='${STK'$SP'}'
SP=$((SP-1))
eval sht19='${STK'$SP'}'
hp_cdr "${1}"
sht31="${R}"
set -- "${sht31}" "${2}" "${3}" "${sht19}" "${5}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
else
hp_car "${1}"
sht32="${R}"
atom_constzzQ "${sht32}"
sht33="${R}"
if [ "${sht33}" != NIL ]; then
hp_cdr "${1}"
sht34="${R}"
set -- "${sht34}" "${2}" "${3}" "${4}" "${5}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
else
hp_car "${1}"
sht35="${R}"
show "${sht35}"
sht36="${R}"
hp_cons "${sht36}" "NIL"
sht37="${R}"
append_lines "${3}" "${sht37}"
sht38="${R}"
hp_cdr "${1}"
sht39="${R}"
set -- "${sht39}" "${2}" "${3}" "${4}" "${5}" "${6}"
SP=${6}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
eval STK$SP='${4}'
SP=$((SP+1))
eval STK$SP='${5}'
SP=$((SP+1))
fi
fi
fi
done
}
atom_constzzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
def_lambdazzQ "${1}"
sht0="${R}"
if [ "${sht0}" != NIL ]; then
R="NIL"
SP=${2}
return
else
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht1="${R}"
if [ "${sht1}" = "S:define" ]; then
caddr "${1}"
sht2="${R}"
if [ "${sht2#P:}" != "${sht2}" ]; then
sht3="S:t"
else
sht3="NIL"
fi
not "${sht3}"
sht4="${R}"
R="${sht4}"
SP=${2}
return
else
R="NIL"
SP=${2}
return
fi
else
R="NIL"
SP=${2}
return
fi
fi
done
}
const_inits() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
atom_constzzQ "${sht0}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
hp_car "${1}"
sht2="${R}"
cadr "${sht2}"
sht3="${R}"
sht4="T:${sht3#??}"
hp_car "${1}"
sht5="${R}"
eval STK$SP='${sht4}'
SP=$((SP+1))
caddr "${sht5}"
sht6="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
cexpr "${sht6}" "NIL" "I:0" "NIL" "NIL"
sht7="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
cadr "${sht7}"
sht8="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
eval STK$SP='${sht4}'
SP=$((SP+1))
vref "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht4='${STK'$SP'}'
sht10="T:=${sht9#??}"
sht11="T:${sht4#??}${sht10#??}"
sht12="T:G_${sht11#??}"
qset "${sht12}"
sht13="${R}"
hp_cdr "${1}"
sht14="${R}"
eval STK$SP='${sht13}'
SP=$((SP+1))
const_inits "${sht14}"
sht15="${R}"
SP=$((SP-1))
eval sht13='${STK'$SP'}'
hp_cons "${sht13}" "${sht15}"
sht16="${R}"
R="${sht16}"
SP=${2}
return
else
hp_cdr "${1}"
sht17="${R}"
set -- "${sht17}" "${2}"
SP=${2}
eval STK$SP='${1}'
SP=$((SP+1))
fi
fi
done
}
memzzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${2}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${2}"
sht0="${R}"
if [ "${1}" = "${sht0}" ]; then
R="S:t"
SP=${3}
return
else
hp_cdr "${2}"
sht1="${R}"
set -- "${1}" "${sht1}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
fi
done
}
set_add() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
memzzQ "${1}" "${2}"
sht0="${R}"
if [ "${sht0}" != NIL ]; then
R="${2}"
SP=${3}
return
else
hp_cons "${1}" "${2}"
sht1="${R}"
R="${sht1}"
SP=${3}
return
fi
done
}
callees() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_car "${1}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then
R="${2}"
SP=${3}
return
else
hp_car "${1}"
sht1="${R}"
if [ "${sht1#S:}" != "${sht1}" ]; then
hp_car "${1}"
sht3="${R}"
set_add "${sht3}" "${2}"
sht4="${R}"
sht2="${sht4}"
else
sht2="${2}"
fi
sht5="${sht2}"
hp_cdr "${1}"
sht6="${R}"
hp_car "${1}"
sht7="${R}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht5}'
SP=$((SP+1))
callees "${sht7}" "${sht5}"
sht8="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht5}'
SP=$((SP+1))
callees_list "${sht6}" "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht5='${STK'$SP'}'
R="${sht9}"
SP=${3}
return
fi
else
R="${2}"
SP=${3}
return
fi
done
}
callees_list() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1#P:}" != "${1}" ]; then
hp_cdr "${1}"
sht0="${R}"
hp_car "${1}"
sht1="${R}"
eval STK$SP='${sht0}'
SP=$((SP+1))
callees "${sht1}" "${2}"
sht2="${R}"
SP=$((SP-1))
eval sht0='${STK'$SP'}'
set -- "${sht0}" "${sht2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
else
R="${2}"
SP=${3}
return
fi
done
}
defnames() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_car "${1}"
sht0="${R}"
def_lambdazzQ "${sht0}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
hp_car "${1}"
sht2="${R}"
cadr "${sht2}"
sht3="${R}"
hp_cdr "${1}"
sht4="${R}"
eval STK$SP='${sht3}'
SP=$((SP+1))
defnames "${sht4}"
sht5="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
hp_cons "${sht3}" "${sht5}"
sht6="${R}"
R="${sht6}"
SP=${2}
return
else
hp_cdr "${1}"
sht7="${R}"
set -- "${sht7}" "${2}"
SP=${2}
eval STK$SP='${1}'
SP=$((SP+1))
fi
fi
done
}
keep_defined() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
memzzQ "${sht0}" "${2}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
hp_car "${1}"
sht2="${R}"
hp_cdr "${1}"
sht3="${R}"
eval STK$SP='${sht2}'
SP=$((SP+1))
keep_defined "${sht3}" "${2}"
sht4="${R}"
SP=$((SP-1))
eval sht2='${STK'$SP'}'
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
R="${sht5}"
SP=${3}
return
else
hp_cdr "${1}"
sht6="${R}"
set -- "${sht6}" "${2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
fi
done
}
fn_body() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
caddr "${1}"
sht0="${R}"
caddr "${sht0}"
sht1="${R}"
R="${sht1}"
SP=${2}
return
done
}
build_adj() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="NIL"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
def_lambdazzQ "${sht0}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
hp_car "${1}"
sht2="${R}"
cadr "${sht2}"
sht3="${R}"
hp_car "${1}"
sht4="${R}"
eval STK$SP='${sht3}'
SP=$((SP+1))
fn_body "${sht4}"
sht5="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
callees "${sht5}" "NIL"
sht6="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
keep_defined "${sht6}" "${2}"
sht7="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
hp_cons "${sht3}" "${sht7}"
sht8="${R}"
hp_cdr "${1}"
sht9="${R}"
eval STK$SP='${sht8}'
SP=$((SP+1))
build_adj "${sht9}" "${2}"
sht10="${R}"
SP=$((SP-1))
eval sht8='${STK'$SP'}'
hp_cons "${sht8}" "${sht10}"
sht11="${R}"
R="${sht11}"
SP=${3}
return
else
hp_cdr "${1}"
sht12="${R}"
set -- "${sht12}" "${2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
fi
fi
done
}
all_inzzQ() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
R="S:t"
SP=${3}
return
else
hp_car "${1}"
sht0="${R}"
memzzQ "${sht0}" "${2}"
sht1="${R}"
if [ "${sht1}" != NIL ]; then
hp_cdr "${1}"
sht2="${R}"
set -- "${sht2}" "${2}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
else
R="NIL"
SP=${3}
return
fi
fi
done
}
clean_pass() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
while :; do
if [ "${1}" = NIL ]; then
hp_cons "${2}" "${3}"
sht0="${R}"
R="${sht0}"
SP=${4}
return
else
hp_car "${1}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
sht3="${sht2}"
hp_car "${1}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
sht6="${sht5}"
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
memzzQ "${sht3}" "${2}"
sht7="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
if [ "${sht7}" != NIL ]; then
hp_cdr "${1}"
sht8="${R}"
set -- "${sht8}" "${2}" "${3}" "${4}"
SP=${4}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
else
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
all_inzzQ "${sht6}" "${2}"
sht9="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
if [ "${sht9}" != NIL ]; then
hp_cdr "${1}"
sht10="${R}"
eval STK$SP='${sht10}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
hp_cons "${sht3}" "${2}"
sht11="${R}"
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht10='${STK'$SP'}'
set -- "${sht10}" "${sht11}" "S:t" "${4}"
SP=${4}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
else
hp_cdr "${1}"
sht12="${R}"
set -- "${sht12}" "${2}" "${3}" "${4}"
SP=${4}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
fi
fi
fi
done
}
clean_fix() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
while :; do
clean_pass "${1}" "${2}" "NIL"
sht0="${R}"
sht1="${sht0}"
hp_cdr "${sht1}"
sht2="${R}"
if [ "${sht2}" != NIL ]; then
hp_car "${sht1}"
sht3="${R}"
set -- "${1}" "${sht3}" "${3}"
SP=${3}
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
else
hp_car "${sht1}"
sht4="${R}"
R="${sht4}"
SP=${3}
return
fi
done
}
elide_of() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
while :; do
assoc "T:\$ELIDE" "${1}"
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then
R="NIL"
SP=${2}
return
else
hp_cdr "${sht1}"
sht2="${R}"
R="${sht2}"
SP=${2}
return
fi
done
}
compile_program() {
set -- "$@" "$SP"
eval STK$SP='${1}'
SP=$((SP+1))
eval STK$SP='${2}'
SP=$((SP+1))
eval STK$SP='${3}'
SP=$((SP+1))
while :; do
mexpand_program "${1}"
sht0="${R}"
sht1="${sht0}"
eval STK$SP='${sht1}'
SP=$((SP+1))
defnames "${sht1}"
sht2="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
sht3="${sht2}"
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
build_adj "${sht1}" "${sht3}"
sht4="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
clean_fix "${sht4}" "NIL"
sht5="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
sht6="${sht5}"
sht7="T:${2#??}/_consts.cmd"
eval STK$SP='${sht7}'
SP=$((SP+1))
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
const_inits "${sht1}"
sht8="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
SP=$((SP-1))
eval sht7='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
write_lines "${sht7}" "${sht8}"
sht9="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
write_lines "${3}" "NIL"
sht10="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
eval STK$SP='${sht6}'
SP=$((SP+1))
eval STK$SP='${sht3}'
SP=$((SP+1))
eval STK$SP='${sht1}'
SP=$((SP+1))
cp "${sht1}" "${2}" "${3}" "I:0" "${sht6}"
sht11="${R}"
SP=$((SP-1))
eval sht1='${STK'$SP'}'
SP=$((SP-1))
eval sht3='${STK'$SP'}'
SP=$((SP-1))
eval sht6='${STK'$SP'}'
R="${sht11}"
SP=${4}
return
done
}

# ---- native comp driver ----------------------------------------------------------------
ulimit -s 65500 2>/dev/null || true   # deep non-tail recursion is host-stack-bound (Phase 2: trampoline)
GLOBAL=NIL                            # gc_run marks $GLOBAL; compiled comp ignores the global env
G_DQ='T:"'                            # the (dq) primitive's value, referenced by compiled code
SP=0                                  # caller-save / frame-mirror stack pointer (gc roots = STK0..SP-1)
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
SRC=$(cat "$1"); rd_expr; _forms=$R
compile_program "$_forms" "T:$2" "T:$3"
