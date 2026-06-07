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
  # COMPILED-code roots (trampoline): native functions hold live cells in the frame stack
  # F[0..FP+SIZE_<CURFN>). Frames stack contiguously (callee base = caller base + caller SIZE),
  # so this single range covers EVERY suspended caller's frame too. CURFN is unset under the
  # plain interpreter / the reader phase (rd_expr runs before the driver) -> no F scan.
  if [ -n "${CURFN-}" ] && [ "${CURFN-}" != HALT ]; then
    eval "gs_sz=\${SIZE_${CURFN}-0}"
    gs_top=$((FP + gs_sz)); gs_i=0
    while [ "$gs_i" -lt "$gs_top" ]; do
      eval "gr_v=\${F$gs_i-}"
      gc_mark "$gr_v"
      gs_i=$((gs_i + 1))
    done
  fi
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
# by the Lisp->sh backend (src/compile-sh.lisp). GENERATED by tools/bootstrap-comp.sh.
# Assembled into a runnable compiler by build-comp.sh -> comp.sh.
SIZE_not=1
not() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_not))
NP=1
case $PC in
0)
if [ "${p0}" != NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
R="S:t"; ACTION=ret; return
;;
esac; }
SIZE_cadr=1
cadr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cadr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_caddr=1
caddr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_caddr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_caar=1
caar() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_caar))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_append=3
append() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_append))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_reverse=2
reverse() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_reverse))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=reverse
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_car "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht2}" "NIL"
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_assoc=2
assoc() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_assoc))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=caar
RPC=3; ACTION=call; return
;;
3)
sht0="${R}"
if [ "${p0}" = "${sht0}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p1}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
5)
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_cadddr=1
cadddr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cadddr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_op_zzGbatch=1
op_zzGbatch() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_op_zzGbatch))
NP=1
case $PC in
0)
if [ "${p0}" = "S:+" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:+"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:-" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:-"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:*" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:*"; ACTION=ret; return
;;
6)
R="T:?"; ACTION=ret; return
;;
esac; }
SIZE_cmp_zzGbatch=1
cmp_zzGbatch() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cmp_zzGbatch))
NP=1
case $PC in
0)
if [ "${p0}" = "S:<" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:LSS"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:=" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:EQU"; ACTION=ret; return
;;
4)
R="T:?"; ACTION=ret; return
;;
esac; }
SIZE_arithzzQ=1
arithzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_arithzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:+" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:-" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:*" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_tpredzzQ=1
tpredzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tpredzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:eq?" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:null?" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:pair?" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="S:t"; ACTION=ret; return
;;
6)
if [ "${p0}" = "S:number?" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="S:t"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:string?" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="S:t"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:symbol?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="S:t"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:<" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="S:t"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:=" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="S:t"; ACTION=ret; return
;;
16)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_iszzQ=2
iszzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_iszzQ))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "${p1}" ]; then
sht1="S:t"
else
sht1="NIL"
fi
R="${sht1}"; ACTION=ret; return
;;
2)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_aref=1
aref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_aref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:cst" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
6)
hp_cdr "${p0}"
sht6="${R}"
sht7="T:${sht6#??}:~2!"
sht8="T:!${sht7#??}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_iref=1
iref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_iref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
sht4="T:${sht3#??}!"
sht5="T:!${sht4#??}"
R="${sht5}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht6="${R}"
if [ "${sht6}" = "S:cst" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
6)
hp_cdr "${p0}"
sht8="${R}"
sht9="T:${sht8#??}:~2!"
sht10="T:!${sht9#??}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_vref=1
vref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_vref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:lit" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
sht2="T:I:${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht3="${R}"
if [ "${sht3}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht4="${R}"
sht5="T:${sht4#??}!"
sht6="T:I:!${sht5#??}"
R="${sht6}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht7="${R}"
if [ "${sht7}" = "S:cst" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
6)
hp_cdr "${p0}"
sht9="${R}"
sht10="T:${sht9#??}!"
sht11="T:!${sht10#??}"
R="${sht11}"; ACTION=ret; return
;;
esac; }
SIZE_cref=1
cref() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cref))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:cst" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
sht3="I:$(( ${#sht2} - 2 ))"
sht4="I:$(( ${sht3#??} - 2 ))"
sht5="T:$(printf '%s' "${sht1#??}" | cut -c$(( 2 + 1 ))-$(( 2 + ${sht4#??} )))"
R="${sht5}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht6="${R}"
sht7="T:${sht6#??}:~2!"
sht8="T:!${sht7#??}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
G_B1='T:!'
G_B2='T:%'
G_B7='T:^'
G_BLT='T:<'
G_BGT='T:>'
G_BAMP='T:&'
G_BPIPE='T:|'
SIZE_mc_at=1
mc_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mc_at))
NP=1
case $PC in
0)
if [ "${p0}" = "${G_B1}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:!BANG!"; ACTION=ret; return
;;
2)
if [ "${p0}" = "${G_B2}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:!BANG2!"; ACTION=ret; return
;;
4)
if [ "${p0}" = "${G_B7}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:!BANG7!"; ACTION=ret; return
;;
6)
if [ "${p0}" = "${G_BLT}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:!LT!"; ACTION=ret; return
;;
8)
if [ "${p0}" = "${G_BGT}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:!GT!"; ACTION=ret; return
;;
10)
if [ "${p0}" = "${G_BAMP}" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:!AMP!"; ACTION=ret; return
;;
12)
if [ "${p0}" = "${G_BPIPE}" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="T:!PIPE!"; ACTION=ret; return
;;
14)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_enc_mc_go=8
enc_mc_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_enc_mc_go))
NP=4
case $PC in
0)
if [ ${p1#??} -eq ${p2#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p3}"; ACTION=ret; return
;;
2)
sht0="I:$(( ${p1#??} + 1 ))"
sht1="T:$(printf '%s' "${p0#??}" | cut -c$(( ${p1#??} + 1 ))-$(( ${p1#??} + 1 )))"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=mc_at
RPC=3; ACTION=call; return
;;
3)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht2="${R}"
sht3="T:${p3#??}${sht2#??}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht0}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_enc_mc=1
enc_mc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_enc_mc))
NP=1
case $PC in
0)
sht0="I:$(( ${#p0} - 2 ))"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht0}\""
STGV="T:"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=enc_mc_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
G_BST='T:*'
SIZE_mangle_at=1
mangle_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mangle_at))
NP=1
case $PC in
0)
if [ "${p0}" = "${G_BGT}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:zzG"; ACTION=ret; return
;;
2)
if [ "${p0}" = "${G_BLT}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:zzL"; ACTION=ret; return
;;
4)
if [ "${p0}" = "${G_BAMP}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:zzA"; ACTION=ret; return
;;
6)
if [ "${p0}" = "${G_BPIPE}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:zzP"; ACTION=ret; return
;;
8)
if [ "${p0}" = "${G_BST}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:zzS"; ACTION=ret; return
;;
10)
if [ "${p0}" = "T:?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:zzQ"; ACTION=ret; return
;;
12)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_mangle_go=8
mangle_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_mangle_go))
NP=4
case $PC in
0)
if [ ${p1#??} -eq ${p2#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p3}"; ACTION=ret; return
;;
2)
sht0="I:$(( ${p1#??} + 1 ))"
sht1="T:$(printf '%s' "${p0#??}" | cut -c$(( ${p1#??} + 1 ))-$(( ${p1#??} + 1 )))"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=mangle_at
RPC=3; ACTION=call; return
;;
3)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht2="${R}"
sht3="T:${p3#??}${sht2#??}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht0}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_mangle=1
mangle() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mangle))
NP=1
case $PC in
0)
sht0="I:$(( ${#p0} - 2 ))"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht0}\""
STGV="T:"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=mangle_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_rev=3
rev() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_rev))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${sht1}" "${p1}"
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_qset=1
qset() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_qset))
NP=1
case $PC in
0)
sht0="T:${p0#??}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:set ${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_lookup=2
lookup() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lookup))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_cdr "${p1}"
sht4="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lenl=1
lenl() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_lenl))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="I:0"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=lenl
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
sht2="I:$(( 1 + ${sht1#??} ))"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_maxi=2
maxi() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_maxi))
NP=2
case $PC in
0)
if [ ${p0#??} -lt ${p1#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_qset=1
qset() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_qset))
NP=1
case $PC in
0)
sht0="T:${p0#??}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:set ${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_b_blk=1
b_blk() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_blk))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_b_cur=1
b_cur() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_cur))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_b_pc=1
b_pc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_pc))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_b_npc=1
b_npc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_npc))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_b_k=1
b_k() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_k))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_b_smax=1
b_smax() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_b_smax))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_cdr "${sht3}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_mkb=11
mkb() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_mkb))
NP=6
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p4}\""
eval "F$((FP+NP+1))=\"\${p3}\""
eval "F$((FP+NP+2))=\"\${p2}\""
eval "F$((FP+NP+3))=\"\${p1}\""
eval "F$((FP+NP+4))=\"\${p0}\""
hp_cons "${p5}" "NIL"
eval "p4=\"\$F$((FP+NP+0))\""
eval "p3=\"\$F$((FP+NP+1))\""
eval "p2=\"\$F$((FP+NP+2))\""
eval "p1=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${p0}\""
hp_cons "${p4}" "${sht0}"
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${p0}\""
hp_cons "${p3}" "${sht1}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
hp_cons "${p2}" "${sht2}"
eval "p1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p1}" "${sht3}"
eval "p0=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${p0}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_emit=7
emit() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_emit))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${p1}" "${sht1}"
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht2}\""
eval "F$((NFP+2))=\"\${sht3}\""
eval "F$((NFP+3))=\"\${sht4}\""
eval "F$((NFP+4))=\"\${sht5}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_bkzzP=6
bkzzP() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_bkzzP))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht4="${R}"
sht5="I:$(( ${sht4#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
eval "F$((NFP+2))=\"\${sht2}\""
eval "F$((NFP+3))=\"\${sht3}\""
eval "F$((NFP+4))=\"\${sht5}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_bsm=7
bsm() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_bsm))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=maxi
RPC=7; ACTION=call; return
;;
7)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
eval "F$((NFP+2))=\"\${sht2}\""
eval "F$((NFP+3))=\"\${sht3}\""
eval "F$((NFP+4))=\"\${sht4}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=8; ACTION=call; return
;;
8)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_bnpczzP=6
bnpczzP() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_bnpczzP))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
sht3="${R}"
sht4="I:$(( ${sht3#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=5; ACTION=call; return
;;
5)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
eval "F$((FP+NP+4))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=6; ACTION=call; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
eval "sht0=\"\$F$((FP+NP+4))\""
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
eval "F$((NFP+2))=\"\${sht2}\""
eval "F$((NFP+3))=\"\${sht4}\""
eval "F$((NFP+4))=\"\${sht5}\""
eval "F$((NFP+5))=\"\${sht6}\""
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_switch=6
switch() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_switch))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_pc
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_cur
RPC=2; ACTION=call; return
;;
2)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_blk
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht3}" "${sht4}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_npc
RPC=5; ACTION=call; return
;;
5)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_smax
RPC=7; ACTION=call; return
;;
7)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${sht6}\""
eval "F$((NFP+4))=\"\${sht7}\""
eval "F$((NFP+5))=\"\${sht8}\""
CALLEE=mkb
RPC=8; ACTION=call; return
;;
8)
sht9="${R}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_tmpn=1
tmpn() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tmpn))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=b_k
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="T:${sht0#??}"
sht2="T:zt${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_fval=1
fval() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_fval))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=vref
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_spill=3
spill() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_spill))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
sht2="T:!${G_DQ#??}"
sht3="T:${sht1#??}${sht2#??}"
sht4="T:F!_i!=!${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T: & set ${sht5#??}"
sht7="T:${sht0#??}${sht6#??}"
sht8="T:set /a _i=!FP!+!NP!+${sht7#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=emit
RPC=3; ACTION=call; return
;;
3)
sht9="${R}"
hp_cdr "${p1}"
sht10="${R}"
sht11="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht9}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_unspill=3
unspill() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_unspill))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
sht2="T:=%%F!_i!%%${G_DQ#??}"
sht3="T:${sht1#??}${sht2#??}"
sht4="T:${G_DQ#??}${sht3#??}"
sht5="T: & call set ${sht4#??}"
sht6="T:${sht0#??}${sht5#??}"
sht7="T:set /a _i=!FP!+!NP!+${sht6#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=emit
RPC=3; ACTION=call; return
;;
3)
sht8="${R}"
hp_cdr "${p1}"
sht9="${R}"
sht10="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${sht9}\""
eval "F$((FP+2))=\"\${sht10}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_stage=6
stage() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_stage))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=fval
RPC=3; ACTION=call; return
;;
3)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht2="${R}"
sht3="T:${sht2#??}${G_DQ#??}"
sht4="T:F!_i!=${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T: & set ${sht5#??}"
sht7="T:${sht0#??}${sht6#??}"
sht8="T:set /a _i=!NFP!+${sht7#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=emit
RPC=4; ACTION=call; return
;;
4)
sht9="${R}"
hp_cdr "${p1}"
sht10="${R}"
sht11="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht9}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_setparams=6
setparams() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_setparams))
NP=3
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
hp_car "${p1}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=fval
RPC=3; ACTION=call; return
;;
3)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht2="${R}"
sht3="T:${sht2#??}${G_DQ#??}"
sht4="T:F!_i!=${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T: & set ${sht5#??}"
sht7="T:${sht0#??}${sht6#??}"
sht8="T:set /a _i=!FP!+${sht7#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=emit
RPC=4; ACTION=call; return
;;
4)
sht9="${R}"
hp_cdr "${p1}"
sht10="${R}"
sht11="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht9}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_rvar=1
rvar() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_rvar))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:val" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
if [ "${sht2}" = "S:raw" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_addlive=3
addlive() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_addlive))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=rvar
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht1}" "${p1}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_largs=8
largs() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_largs))
NP=4
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "${p2}" "NIL"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
sht2="${R}"
sht3="${sht2}"
hp_cdr "${p0}"
sht4="${R}"
hp_car "${sht3}"
sht5="${R}"
hp_cdr "${sht3}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht4}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=4; ACTION=call; return
;;
4)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht4=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht5}\""
eval "F$((NFP+3))=\"\${sht7}\""
CALLEE=largs
RPC=5; ACTION=call; return
;;
5)
eval "sht3=\"\$F$((FP+NP+0))\""
sht8="${R}"
sht9="${sht8}"
hp_car "${sht9}"
sht10="${R}"
hp_cdr "${sht3}"
sht11="${R}"
hp_cdr "${sht9}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "${sht11}" "${sht12}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht10}" "${sht13}"
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht14="${R}"
R="${sht14}"; ACTION=ret; return
;;
esac; }
SIZE_bargs=2
bargs() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_bargs))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=vref
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=bargs
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
sht4="T:${sht1#??}${sht3#??}"
sht5="T: ${sht4#??}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_lcell=11
lcell() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_lcell))
NP=5
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_car "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=b_k
RPC=2; ACTION=call; return
;;
2)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="T:${sht5#??}"
sht7="T:zi${sht6#??}"
sht8="${sht7}"
hp_car "${sht3}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=tmpn
RPC=3; ACTION=call; return
;;
3)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht10="${R}"
sht11="${sht10}"
hp_car "${sht3}"
sht12="${R}"
hp_cdr "${sht3}"
sht13="${R}"
hp_cdr "${sht13}"
sht14="${R}"
sht15="T:${sht14#??}:~2!"
sht16="T:=!${sht15#??}"
sht17="T:${sht8#??}${sht16#??}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
eval "F$((NFP+1))=\"\${sht18}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht19="${R}"
sht20="${sht19}"
sht21="T:${sht8#??}!"
sht22="T: !${sht21#??}"
sht23="T:${p1#??}${sht22#??}"
sht24="T:call rdfield.cmd ${sht23#??}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht25="${R}"
sht26="${sht25}"
sht27="T:${sht11#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
CALLEE=qset
RPC=7; ACTION=call; return
;;
7)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht28}\""
CALLEE=emit
RPC=8; ACTION=call; return
;;
8)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
CALLEE=bkzzP
RPC=9; ACTION=call; return
;;
9)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
hp_cons "S:val" "${sht11}"
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
hp_cons "${sht30}" "${sht31}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht32="${R}"
R="${sht32}"; ACTION=ret; return
;;
esac; }
SIZE_ltagtest=10
ltagtest() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_ltagtest))
NP=6
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_car "${sht1}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=b_k
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
sht4="T:${sht3#??}"
sht5="T:zp${sht4#??}"
sht6="${sht5}"
hp_car "${sht1}"
sht7="${R}"
hp_cdr "${sht1}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=vref
RPC=3; ACTION=call; return
;;
3)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht9="${R}"
sht10="T:=${sht9#??}"
sht11="T:${sht6#??}${sht10#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht13="${R}"
sht14="T:${sht6#??}:~0,1!"
sht15="T:=!${sht14#??}"
sht16="T:${sht6#??}${sht15#??}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=qset
RPC=6; ACTION=call; return
;;
6)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
eval "F$((NFP+1))=\"\${sht17}\""
CALLEE=emit
RPC=7; ACTION=call; return
;;
7)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht18="${R}"
sht19="${sht18}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=bkzzP
RPC=8; ACTION=call; return
;;
8)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht20="${R}"
if [ "${p5}" != NIL ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
sht21="T:not "
PC=11; ACTION=jump; return
;;
10)
sht21="T:"
PC=11; ACTION=jump; return
;;
11)
sht22="T:!==${p1#??}"
sht23="T:${sht6#??}${sht22#??}"
sht24="T:!${sht23#??}"
sht25="T:${sht21#??}${sht24#??}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht20}" "${sht25}"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht26="${R}"
R="${sht26}"; ACTION=ret; return
;;
esac; }
SIZE_ctest=11
ctest() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_ctest))
NP=4
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=tpredzzQ
RPC=4; ACTION=call; return
;;
2)
sht0="NIL"
PC=3; ACTION=jump; return
;;
3)
if [ "${sht0}" != NIL ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
4)
sht2="${R}"
sht0="${sht2}"
PC=3; ACTION=jump; return
;;
5)
hp_car "${p0}"
sht3="${R}"
if [ "${sht3}" = "S:null?" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=37; ACTION=call; return
;;
7)
hp_cdr "${p0}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=9; ACTION=call; return
;;
8)
hp_car "${p0}"
sht18="${R}"
if [ "${sht18}" = "S:eq?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
9)
sht6="${R}"
sht7="${sht6}"
hp_car "${sht7}"
sht8="${R}"
hp_cdr "${sht7}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=vref
RPC=10; ACTION=call; return
;;
10)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht10="${R}"
sht11="T:NIL${G_DQ#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:==${sht12#??}"
sht14="T:${G_DQ#??}${sht13#??}"
sht15="T:${sht10#??}${sht14#??}"
sht16="T:${G_DQ#??}${sht15#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
hp_cons "${sht8}" "${sht16}"
eval "sht7=\"\$F$((FP+NP+0))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
11)
hp_cdr "${p0}"
sht19="${R}"
hp_car "${sht19}"
sht20="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=13; ACTION=call; return
;;
12)
hp_car "${p0}"
sht41="${R}"
if [ "${sht41}" = "S:pair?" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
13)
sht21="${R}"
sht22="${sht21}"
hp_cdr "${p0}"
sht23="${R}"
hp_cdr "${sht23}"
sht24="${R}"
hp_car "${sht24}"
sht25="${R}"
hp_car "${sht22}"
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht25}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht26}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=14; ACTION=call; return
;;
14)
eval "sht22=\"\$F$((FP+NP+0))\""
sht27="${R}"
sht28="${sht27}"
hp_car "${sht28}"
sht29="${R}"
hp_cdr "${sht22}"
sht30="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht28}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
CALLEE=vref
RPC=15; ACTION=call; return
;;
15)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht28=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
sht31="${R}"
hp_cdr "${sht28}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht28}\""
eval "F$((FP+NP+6))=\"\${sht22}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
CALLEE=vref
RPC=16; ACTION=call; return
;;
16)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht28=\"\$F$((FP+NP+5))\""
eval "sht22=\"\$F$((FP+NP+6))\""
sht33="${R}"
sht34="T:${sht33#??}${G_DQ#??}"
sht35="T:${G_DQ#??}${sht34#??}"
sht36="T:==${sht35#??}"
sht37="T:${G_DQ#??}${sht36#??}"
sht38="T:${sht31#??}${sht37#??}"
sht39="T:${G_DQ#??}${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
hp_cons "${sht29}" "${sht39}"
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
sht40="${R}"
R="${sht40}"; ACTION=ret; return
;;
17)
hp_cdr "${p0}"
sht42="${R}"
hp_car "${sht42}"
sht43="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
STGV="T:P"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=19; ACTION=call; return
;;
18)
hp_car "${p0}"
sht45="${R}"
if [ "${sht45}" = "S:atom?" ]; then PC=20; else PC=21; fi
ACTION=jump; return
;;
19)
sht44="${R}"
R="${sht44}"; ACTION=ret; return
;;
20)
hp_cdr "${p0}"
sht46="${R}"
hp_car "${sht46}"
sht47="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
STGV="T:P"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="S:t"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=22; ACTION=call; return
;;
21)
hp_car "${p0}"
sht49="${R}"
if [ "${sht49}" = "S:number?" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
22)
sht48="${R}"
R="${sht48}"; ACTION=ret; return
;;
23)
hp_cdr "${p0}"
sht50="${R}"
hp_car "${sht50}"
sht51="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
STGV="T:I"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=25; ACTION=call; return
;;
24)
hp_car "${p0}"
sht53="${R}"
if [ "${sht53}" = "S:string?" ]; then PC=26; else PC=27; fi
ACTION=jump; return
;;
25)
sht52="${R}"
R="${sht52}"; ACTION=ret; return
;;
26)
hp_cdr "${p0}"
sht54="${R}"
hp_car "${sht54}"
sht55="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht55}\""
STGV="T:T"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=28; ACTION=call; return
;;
27)
hp_car "${p0}"
sht57="${R}"
if [ "${sht57}" = "S:symbol?" ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
28)
sht56="${R}"
R="${sht56}"; ACTION=ret; return
;;
29)
hp_cdr "${p0}"
sht58="${R}"
hp_car "${sht58}"
sht59="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht59}\""
STGV="T:S"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltagtest
RPC=31; ACTION=call; return
;;
30)
hp_cdr "${p0}"
sht61="${R}"
hp_car "${sht61}"
sht62="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht62}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=32; ACTION=call; return
;;
31)
sht60="${R}"
R="${sht60}"; ACTION=ret; return
;;
32)
sht63="${R}"
sht64="${sht63}"
hp_cdr "${p0}"
sht65="${R}"
hp_cdr "${sht65}"
sht66="${R}"
hp_car "${sht66}"
sht67="${R}"
hp_car "${sht64}"
sht68="${R}"
eval "F$((FP+NP+0))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht67}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht68}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=33; ACTION=call; return
;;
33)
eval "sht64=\"\$F$((FP+NP+0))\""
sht69="${R}"
sht70="${sht69}"
hp_car "${sht70}"
sht71="${R}"
hp_cdr "${sht64}"
sht72="${R}"
eval "F$((FP+NP+0))=\"\${sht71}\""
eval "F$((FP+NP+1))=\"\${sht70}\""
eval "F$((FP+NP+2))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht72}\""
CALLEE=iref
RPC=34; ACTION=call; return
;;
34)
eval "sht71=\"\$F$((FP+NP+0))\""
eval "sht70=\"\$F$((FP+NP+1))\""
eval "sht64=\"\$F$((FP+NP+2))\""
sht73="${R}"
hp_car "${p0}"
sht74="${R}"
eval "F$((FP+NP+0))=\"\${sht73}\""
eval "F$((FP+NP+1))=\"\${sht71}\""
eval "F$((FP+NP+2))=\"\${sht70}\""
eval "F$((FP+NP+3))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht74}\""
CALLEE=cmp_zzGbatch
RPC=35; ACTION=call; return
;;
35)
eval "sht73=\"\$F$((FP+NP+0))\""
eval "sht71=\"\$F$((FP+NP+1))\""
eval "sht70=\"\$F$((FP+NP+2))\""
eval "sht64=\"\$F$((FP+NP+3))\""
sht75="${R}"
hp_cdr "${sht70}"
sht76="${R}"
eval "F$((FP+NP+0))=\"\${sht75}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht71}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht64}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht76}\""
CALLEE=iref
RPC=36; ACTION=call; return
;;
36)
eval "sht75=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht71=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht64=\"\$F$((FP+NP+4))\""
sht77="${R}"
sht78="T: ${sht77#??}"
sht79="T:${sht75#??}${sht78#??}"
sht80="T: ${sht79#??}"
sht81="T:${sht73#??}${sht80#??}"
eval "F$((FP+NP+0))=\"\${sht70}\""
eval "F$((FP+NP+1))=\"\${sht64}\""
hp_cons "${sht71}" "${sht81}"
eval "sht70=\"\$F$((FP+NP+0))\""
eval "sht64=\"\$F$((FP+NP+1))\""
sht82="${R}"
R="${sht82}"; ACTION=ret; return
;;
37)
sht83="${R}"
sht84="${sht83}"
hp_car "${sht84}"
sht85="${R}"
hp_cdr "${sht84}"
sht86="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht84}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht86}\""
CALLEE=vref
RPC=38; ACTION=call; return
;;
38)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht84=\"\$F$((FP+NP+2))\""
sht87="${R}"
sht88="T:NIL${G_DQ#??}"
sht89="T:${G_DQ#??}${sht88#??}"
sht90="T:==${sht89#??}"
sht91="T:${G_DQ#??}${sht90#??}"
sht92="T:${sht87#??}${sht91#??}"
sht93="T:${G_DQ#??}${sht92#??}"
sht94="T:not ${sht93#??}"
eval "F$((FP+NP+0))=\"\${sht84}\""
hp_cons "${sht85}" "${sht94}"
eval "sht84=\"\$F$((FP+NP+0))\""
sht95="${R}"
R="${sht95}"; ACTION=ret; return
;;
esac; }
SIZE_jumpto=1
jumpto() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_jumpto))
NP=1
case $PC in
0)
sht0="T:${p0#??}"
sht1="T:${G_DQ#??} & goto :eof"
sht2="T:ACTION=jump${sht1#??}"
sht3="T:${G_DQ#??}${sht2#??}"
sht4="T: & set ${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T:${sht0#??}${sht5#??}"
sht7="T:PC=${sht6#??}"
sht8="T:${G_DQ#??}${sht7#??}"
sht9="T:set ${sht8#??}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_ifjump=2
ifjump() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_ifjump))
NP=2
case $PC in
0)
sht0="T:${p1#??}"
sht1="T:${G_DQ#??} & goto :eof)"
sht2="T:ACTION=jump${sht1#??}"
sht3="T:${G_DQ#??}${sht2#??}"
sht4="T: & set ${sht3#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T:${sht0#??}${sht5#??}"
sht7="T:PC=${sht6#??}"
sht8="T:${G_DQ#??}${sht7#??}"
sht9="T: (set ${sht8#??}"
sht10="T:${p0#??}${sht9#??}"
sht11="T:if ${sht10#??}"
R="${sht11}"; ACTION=ret; return
;;
esac; }
SIZE_seg_files=7
seg_files() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_seg_files))
NP=5
case $PC in
0)
if [ ${p2#??} -eq ${p3#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p2#??}"
sht1="T:_pc${sht0#??}"
sht2="T:${p4#??}${sht1#??}"
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=blkget
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
sht6="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht6}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
CALLEE=seg_files
RPC=5; ACTION=call; return
;;
5)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${sht5}" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_write_segs=2
write_segs() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_write_segs))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:done"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
sht2="T:${sht1#??}.cmd"
sht3="T:/${sht2#??}"
sht4="T:${p1#??}${sht3#??}"
hp_car "${p0}"
sht5="${R}"
hp_cdr "${sht5}"
sht6="${R}"
write_lines "${sht4}" "${sht6}"
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lif_val=17
lif_val() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_lif_val))
NP=6
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=ctest
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_car "${sht1}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=b_npc
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
sht4="${sht3}"
hp_car "${sht1}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=b_npc
RPC=3; ACTION=call; return
;;
3)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht6="${R}"
sht7="I:$(( ${sht6#??} + 1 ))"
sht8="${sht7}"
hp_car "${sht1}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=b_npc
RPC=4; ACTION=call; return
;;
4)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht10="${R}"
sht11="I:$(( ${sht10#??} + 2 ))"
sht12="${sht11}"
hp_car "${sht1}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht4}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=tmpn
RPC=5; ACTION=call; return
;;
5)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht4=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht14="${R}"
sht15="${sht14}"
hp_car "${sht1}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=bnpczzP
RPC=6; ACTION=call; return
;;
6)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
CALLEE=bnpczzP
RPC=7; ACTION=call; return
;;
7)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
CALLEE=bnpczzP
RPC=8; ACTION=call; return
;;
8)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=bkzzP
RPC=9; ACTION=call; return
;;
9)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht20="${R}"
hp_cdr "${sht1}"
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
eval "F$((NFP+1))=\"\${sht4}\""
CALLEE=ifjump
RPC=10; ACTION=call; return
;;
10)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht22}\""
CALLEE=emit
RPC=11; ACTION=call; return
;;
11)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=jumpto
RPC=12; ACTION=call; return
;;
12)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=emit
RPC=13; ACTION=call; return
;;
13)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht25="${R}"
sht26="${sht25}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht4}\""
CALLEE=switch
RPC=14; ACTION=call; return
;;
14)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${sht27}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=15; ACTION=call; return
;;
15)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht28="${R}"
sht29="${sht28}"
hp_car "${sht29}"
sht30="${R}"
hp_cdr "${sht29}"
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht31}\""
CALLEE=vref
RPC=16; ACTION=call; return
;;
16)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht32="${R}"
sht33="T:=${sht32#??}"
sht34="T:${sht15#??}${sht33#??}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
CALLEE=qset
RPC=17; ACTION=call; return
;;
17)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht4}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
eval "F$((NFP+1))=\"\${sht35}\""
CALLEE=emit
RPC=18; ACTION=call; return
;;
18)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht4=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=jumpto
RPC=19; ACTION=call; return
;;
19)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht4}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
eval "F$((NFP+1))=\"\${sht37}\""
CALLEE=emit
RPC=20; ACTION=call; return
;;
20)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht4=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht38="${R}"
sht39="${sht38}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=switch
RPC=21; ACTION=call; return
;;
21)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${sht40}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=22; ACTION=call; return
;;
22)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht41="${R}"
sht42="${sht41}"
hp_car "${sht42}"
sht43="${R}"
hp_cdr "${sht42}"
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht43}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht4}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht44}\""
CALLEE=vref
RPC=23; ACTION=call; return
;;
23)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht43=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht4=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht45="${R}"
sht46="T:=${sht45#??}"
sht47="T:${sht15#??}${sht46#??}"
eval "F$((FP+NP+0))=\"\${sht43}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=qset
RPC=24; ACTION=call; return
;;
24)
eval "sht43=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
eval "F$((NFP+1))=\"\${sht48}\""
CALLEE=emit
RPC=25; ACTION=call; return
;;
25)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht49}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=jumpto
RPC=26; ACTION=call; return
;;
26)
eval "sht49=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht49}\""
eval "F$((NFP+1))=\"\${sht50}\""
CALLEE=emit
RPC=27; ACTION=call; return
;;
27)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht51="${R}"
sht52="${sht51}"
eval "F$((FP+NP+0))=\"\${sht52}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht52}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=switch
RPC=28; ACTION=call; return
;;
28)
eval "sht52=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht53="${R}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht52}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht4}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
hp_cons "S:val" "${sht15}"
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht52=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht4=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht54="${R}"
eval "F$((FP+NP+0))=\"\${sht52}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
hp_cons "${sht53}" "${sht54}"
eval "sht52=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht55="${R}"
R="${sht55}"; ACTION=ret; return
;;
esac; }
SIZE_lbinds=10
lbinds() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lbinds))
NP=4
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "${p1}" "${p3}"
eval "p2=\"\$F$((FP+NP+0))\""
sht0="${R}"
hp_cons "${p2}" "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
sht5="${R}"
sht6="${sht5}"
hp_car "${sht6}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=tmpn
RPC=4; ACTION=call; return
;;
4)
eval "sht6=\"\$F$((FP+NP+0))\""
sht8="${R}"
sht9="${sht8}"
hp_cdr "${p0}"
sht10="${R}"
hp_car "${p0}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
hp_cons "${sht12}" "${sht9}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
hp_cons "${sht13}" "${p1}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht14="${R}"
hp_car "${sht6}"
sht15="${R}"
hp_cdr "${sht6}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht10}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=vref
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht10=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
sht17="${R}"
sht18="T:=${sht17#??}"
sht19="T:${sht9#??}${sht18#??}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=qset
RPC=6; ACTION=call; return
;;
6)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=emit
RPC=7; ACTION=call; return
;;
7)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=bkzzP
RPC=8; ACTION=call; return
;;
8)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
hp_cons "${sht9}" "${p3}"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
sht23="${R}"
eval "F$((FP+0))=\"\${sht10}\""
eval "F$((FP+1))=\"\${sht14}\""
eval "F$((FP+2))=\"\${sht22}\""
eval "F$((FP+3))=\"\${sht23}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_llet=6
llet() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_llet))
NP=5
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
eval "F$((NFP+2))=\"\${p3}\""
eval "F$((NFP+3))=\"\${p4}\""
CALLEE=lbinds
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
hp_car "${sht1}"
sht4="${R}"
hp_cdr "${sht1}"
sht5="${R}"
hp_cdr "${sht5}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${sht4}\""
eval "F$((NFP+3))=\"\${sht6}\""
CALLEE=lval
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_lbegin=4
lbegin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lbegin))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
2)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=4; ACTION=call; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht4="${R}"
sht5="${sht4}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${sht5}"
sht7="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${sht7}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lquote=3
lquote() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lquote))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:cst" "T:NIL"
eval "p1=\"\$F$((FP+NP+0))\""
sht0="${R}"
hp_cons "${p1}" "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
if [ "${p0#I:}" != "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht2="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:lit" "${sht2}"
eval "p1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${p1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
if [ "${p0#T:}" != "${p0}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
eval "F$((FP+NP+0))=\"\${p1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=enc_mc
RPC=7; ACTION=call; return
;;
6)
if [ "${p0#S:}" != "${p0}" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
eval "p1=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="T:T:${sht5#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:cst" "${sht6}"
eval "p1=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${p1}" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
8)
sht9="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=enc_mc
RPC=10; ACTION=call; return
;;
9)
hp_car "${p0}"
sht14="${R}"
hp_cons "${sht14}" "NIL"
sht15="${R}"
hp_cons "S:quote" "${sht15}"
sht16="${R}"
hp_cdr "${p0}"
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "${sht17}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "S:quote" "${sht18}"
eval "sht16=\"\$F$((FP+NP+0))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "${sht19}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
sht20="${R}"
hp_cons "${sht16}" "${sht20}"
sht21="${R}"
hp_cons "S:cons" "${sht21}"
sht22="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
STGV="NIL"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=lval
RPC=11; ACTION=call; return
;;
10)
eval "p1=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="T:S:${sht10#??}"
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "S:cst" "${sht11}"
eval "p1=\"\$F$((FP+NP+0))\""
sht12="${R}"
hp_cons "${p1}" "${sht12}"
sht13="${R}"
R="${sht13}"; ACTION=ret; return
;;
11)
sht23="${R}"
R="${sht23}"; ACTION=ret; return
;;
esac; }
SIZE_lretag=8
lretag() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lretag))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_car "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=tmpn
RPC=2; ACTION=call; return
;;
2)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="${sht5}"
hp_car "${sht3}"
sht7="${R}"
hp_cdr "${sht3}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=cref
RPC=3; ACTION=call; return
;;
3)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht9="${R}"
sht10="T:=T:${sht9#??}"
sht11="T:${sht6#??}${sht10#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=bkzzP
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "S:val" "${sht6}"
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht14}" "${sht15}"
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht16="${R}"
R="${sht16}"; ACTION=ret; return
;;
esac; }
SIZE_lstrlen=13
lstrlen() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lstrlen))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_car "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=b_k
RPC=2; ACTION=call; return
;;
2)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="T:${sht5#??}"
sht7="${sht6}"
sht8="T:zc${sht7#??}"
sht9="${sht8}"
hp_car "${sht3}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=tmpn
RPC=3; ACTION=call; return
;;
3)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht11="${R}"
sht12="${sht11}"
sht13="T:zSL${sht7#??}"
sht14="${sht13}"
hp_car "${sht3}"
sht15="${R}"
hp_cdr "${sht3}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
eval "F$((FP+NP+6))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=cref
RPC=4; ACTION=call; return
;;
4)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
eval "sht3=\"\$F$((FP+NP+6))\""
sht17="${R}"
sht18="T:=${sht17#??}"
sht19="T:${sht9#??}${sht18#??}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=qset
RPC=5; ACTION=call; return
;;
5)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht21="${R}"
sht22="${sht21}"
sht23="T:${sht12#??}=0"
sht24="T:set /a ${sht23#??}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=emit
RPC=7; ACTION=call; return
;;
7)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht25="${R}"
sht26="${sht25}"
sht27="T::${sht14#??}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
eval "F$((FP+NP+6))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht27}\""
CALLEE=emit
RPC=8; ACTION=call; return
;;
8)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
eval "sht3=\"\$F$((FP+NP+6))\""
sht28="${R}"
sht29="${sht28}"
sht30="T:${sht14#??})"
sht31="T:+=1& goto ${sht30#??}"
sht32="T:${sht12#??}${sht31#??}"
sht33="T::~1!& set /a ${sht32#??}"
sht34="T:${sht9#??}${sht33#??}"
sht35="T:=!${sht34#??}"
sht36="T:${sht9#??}${sht35#??}"
sht37="T: (set ${sht36#??}"
sht38="T:${sht9#??}${sht37#??}"
sht39="T:if defined ${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht14}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${sht39}\""
CALLEE=emit
RPC=9; ACTION=call; return
;;
9)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht14=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht14}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
CALLEE=bkzzP
RPC=10; ACTION=call; return
;;
10)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht14=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht41}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht14}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht7}\""
eval "F$((FP+NP+8))=\"\${sht3}\""
hp_cons "S:raw" "${sht12}"
eval "sht41=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht14=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht7=\"\$F$((FP+NP+7))\""
eval "sht3=\"\$F$((FP+NP+8))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht14}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
hp_cons "${sht41}" "${sht42}"
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht14=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht43="${R}"
R="${sht43}"; ACTION=ret; return
;;
esac; }
SIZE_lsubstr=24
lsubstr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lsubstr))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
sht3="${sht2}"
hp_cdr "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
hp_car "${sht3}"
sht7="${R}"
hp_cdr "${sht3}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=2; ACTION=call; return
;;
2)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht7}\""
eval "F$((NFP+3))=\"\${sht9}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
eval "sht3=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="${sht10}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=4; ACTION=call; return
;;
4)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht12="${R}"
hp_car "${sht11}"
sht13="${R}"
hp_cdr "${sht11}"
sht14="${R}"
hp_cdr "${sht3}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht11}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=5; ACTION=call; return
;;
5)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht11=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${sht16}\""
CALLEE=addlive
RPC=6; ACTION=call; return
;;
6)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht13}\""
eval "F$((NFP+3))=\"\${sht17}\""
CALLEE=lval
RPC=7; ACTION=call; return
;;
7)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht18="${R}"
sht19="${sht18}"
hp_car "${sht19}"
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
CALLEE=b_k
RPC=8; ACTION=call; return
;;
8)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht21="${R}"
sht22="T:${sht21#??}"
sht23="${sht22}"
sht24="T:zc${sht23#??}"
sht25="${sht24}"
sht26="T:zsk${sht23#??}"
sht27="${sht26}"
sht28="T:ztk${sht23#??}"
sht29="${sht28}"
sht30="T:zr${sht23#??}"
sht31="${sht30}"
hp_car "${sht19}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht27}\""
eval "F$((FP+NP+3))=\"\${sht25}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht19}\""
eval "F$((FP+NP+6))=\"\${sht11}\""
eval "F$((FP+NP+7))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
CALLEE=tmpn
RPC=9; ACTION=call; return
;;
9)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht27=\"\$F$((FP+NP+2))\""
eval "sht25=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht19=\"\$F$((FP+NP+5))\""
eval "sht11=\"\$F$((FP+NP+6))\""
eval "sht3=\"\$F$((FP+NP+7))\""
sht33="${R}"
sht34="${sht33}"
sht35="T:zSK${sht23#??}"
sht36="${sht35}"
sht37="T:zTK${sht23#??}"
sht38="${sht37}"
hp_car "${sht19}"
sht39="${R}"
hp_cdr "${sht3}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht38}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
eval "F$((FP+NP+4))=\"\${sht34}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
eval "F$((FP+NP+6))=\"\${sht29}\""
eval "F$((FP+NP+7))=\"\${sht27}\""
eval "F$((FP+NP+8))=\"\${sht25}\""
eval "F$((FP+NP+9))=\"\${sht23}\""
eval "F$((FP+NP+10))=\"\${sht19}\""
eval "F$((FP+NP+11))=\"\${sht11}\""
eval "F$((FP+NP+12))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
CALLEE=cref
RPC=10; ACTION=call; return
;;
10)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht38=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
eval "sht34=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
eval "sht29=\"\$F$((FP+NP+6))\""
eval "sht27=\"\$F$((FP+NP+7))\""
eval "sht25=\"\$F$((FP+NP+8))\""
eval "sht23=\"\$F$((FP+NP+9))\""
eval "sht19=\"\$F$((FP+NP+10))\""
eval "sht11=\"\$F$((FP+NP+11))\""
eval "sht3=\"\$F$((FP+NP+12))\""
sht41="${R}"
sht42="T:=${sht41#??}"
sht43="T:${sht25#??}${sht42#??}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht34}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
eval "F$((FP+NP+5))=\"\${sht29}\""
eval "F$((FP+NP+6))=\"\${sht27}\""
eval "F$((FP+NP+7))=\"\${sht25}\""
eval "F$((FP+NP+8))=\"\${sht23}\""
eval "F$((FP+NP+9))=\"\${sht19}\""
eval "F$((FP+NP+10))=\"\${sht11}\""
eval "F$((FP+NP+11))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht34=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
eval "sht29=\"\$F$((FP+NP+5))\""
eval "sht27=\"\$F$((FP+NP+6))\""
eval "sht25=\"\$F$((FP+NP+7))\""
eval "sht23=\"\$F$((FP+NP+8))\""
eval "sht19=\"\$F$((FP+NP+9))\""
eval "sht11=\"\$F$((FP+NP+10))\""
eval "sht3=\"\$F$((FP+NP+11))\""
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht38}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht34}\""
eval "F$((FP+NP+3))=\"\${sht31}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht27}\""
eval "F$((FP+NP+6))=\"\${sht25}\""
eval "F$((FP+NP+7))=\"\${sht23}\""
eval "F$((FP+NP+8))=\"\${sht19}\""
eval "F$((FP+NP+9))=\"\${sht11}\""
eval "F$((FP+NP+10))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht44}\""
CALLEE=emit
RPC=12; ACTION=call; return
;;
12)
eval "sht38=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht34=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht27=\"\$F$((FP+NP+5))\""
eval "sht25=\"\$F$((FP+NP+6))\""
eval "sht23=\"\$F$((FP+NP+7))\""
eval "sht19=\"\$F$((FP+NP+8))\""
eval "sht11=\"\$F$((FP+NP+9))\""
eval "sht3=\"\$F$((FP+NP+10))\""
sht45="${R}"
sht46="${sht45}"
hp_cdr "${sht11}"
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht46}\""
eval "F$((FP+NP+2))=\"\${sht46}\""
eval "F$((FP+NP+3))=\"\${sht38}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
eval "F$((FP+NP+5))=\"\${sht34}\""
eval "F$((FP+NP+6))=\"\${sht31}\""
eval "F$((FP+NP+7))=\"\${sht29}\""
eval "F$((FP+NP+8))=\"\${sht27}\""
eval "F$((FP+NP+9))=\"\${sht25}\""
eval "F$((FP+NP+10))=\"\${sht23}\""
eval "F$((FP+NP+11))=\"\${sht19}\""
eval "F$((FP+NP+12))=\"\${sht11}\""
eval "F$((FP+NP+13))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=aref
RPC=13; ACTION=call; return
;;
13)
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht46=\"\$F$((FP+NP+1))\""
eval "sht46=\"\$F$((FP+NP+2))\""
eval "sht38=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
eval "sht34=\"\$F$((FP+NP+5))\""
eval "sht31=\"\$F$((FP+NP+6))\""
eval "sht29=\"\$F$((FP+NP+7))\""
eval "sht27=\"\$F$((FP+NP+8))\""
eval "sht25=\"\$F$((FP+NP+9))\""
eval "sht23=\"\$F$((FP+NP+10))\""
eval "sht19=\"\$F$((FP+NP+11))\""
eval "sht11=\"\$F$((FP+NP+12))\""
eval "sht3=\"\$F$((FP+NP+13))\""
sht48="${R}"
sht49="T:=${sht48#??}"
sht50="T:${sht27#??}${sht49#??}"
sht51="T:set /a ${sht50#??}"
eval "F$((FP+NP+0))=\"\${sht46}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht34}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
eval "F$((FP+NP+5))=\"\${sht29}\""
eval "F$((FP+NP+6))=\"\${sht27}\""
eval "F$((FP+NP+7))=\"\${sht25}\""
eval "F$((FP+NP+8))=\"\${sht23}\""
eval "F$((FP+NP+9))=\"\${sht19}\""
eval "F$((FP+NP+10))=\"\${sht11}\""
eval "F$((FP+NP+11))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht46}\""
eval "F$((NFP+1))=\"\${sht51}\""
CALLEE=emit
RPC=14; ACTION=call; return
;;
14)
eval "sht46=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht34=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
eval "sht29=\"\$F$((FP+NP+5))\""
eval "sht27=\"\$F$((FP+NP+6))\""
eval "sht25=\"\$F$((FP+NP+7))\""
eval "sht23=\"\$F$((FP+NP+8))\""
eval "sht19=\"\$F$((FP+NP+9))\""
eval "sht11=\"\$F$((FP+NP+10))\""
eval "sht3=\"\$F$((FP+NP+11))\""
sht52="${R}"
sht53="${sht52}"
sht54="T::${sht36#??}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht46}\""
eval "F$((FP+NP+2))=\"\${sht38}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
eval "F$((FP+NP+4))=\"\${sht34}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
eval "F$((FP+NP+6))=\"\${sht29}\""
eval "F$((FP+NP+7))=\"\${sht27}\""
eval "F$((FP+NP+8))=\"\${sht25}\""
eval "F$((FP+NP+9))=\"\${sht23}\""
eval "F$((FP+NP+10))=\"\${sht19}\""
eval "F$((FP+NP+11))=\"\${sht11}\""
eval "F$((FP+NP+12))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
eval "F$((NFP+1))=\"\${sht54}\""
CALLEE=emit
RPC=15; ACTION=call; return
;;
15)
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht46=\"\$F$((FP+NP+1))\""
eval "sht38=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
eval "sht34=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
eval "sht29=\"\$F$((FP+NP+6))\""
eval "sht27=\"\$F$((FP+NP+7))\""
eval "sht25=\"\$F$((FP+NP+8))\""
eval "sht23=\"\$F$((FP+NP+9))\""
eval "sht19=\"\$F$((FP+NP+10))\""
eval "sht11=\"\$F$((FP+NP+11))\""
eval "sht3=\"\$F$((FP+NP+12))\""
sht55="${R}"
sht56="${sht55}"
sht57="T:${sht36#??})"
sht58="T:-=1& goto ${sht57#??}"
sht59="T:${sht27#??}${sht58#??}"
sht60="T::~1!& set /a ${sht59#??}"
sht61="T:${sht25#??}${sht60#??}"
sht62="T:=!${sht61#??}"
sht63="T:${sht25#??}${sht62#??}"
sht64="T:! gtr 0 (set ${sht63#??}"
sht65="T:${sht27#??}${sht64#??}"
sht66="T: if !${sht65#??}"
sht67="T:${sht25#??}${sht66#??}"
sht68="T:if defined ${sht67#??}"
eval "F$((FP+NP+0))=\"\${sht56}\""
eval "F$((FP+NP+1))=\"\${sht53}\""
eval "F$((FP+NP+2))=\"\${sht46}\""
eval "F$((FP+NP+3))=\"\${sht38}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
eval "F$((FP+NP+5))=\"\${sht34}\""
eval "F$((FP+NP+6))=\"\${sht31}\""
eval "F$((FP+NP+7))=\"\${sht29}\""
eval "F$((FP+NP+8))=\"\${sht27}\""
eval "F$((FP+NP+9))=\"\${sht25}\""
eval "F$((FP+NP+10))=\"\${sht23}\""
eval "F$((FP+NP+11))=\"\${sht19}\""
eval "F$((FP+NP+12))=\"\${sht11}\""
eval "F$((FP+NP+13))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht56}\""
eval "F$((NFP+1))=\"\${sht68}\""
CALLEE=emit
RPC=16; ACTION=call; return
;;
16)
eval "sht56=\"\$F$((FP+NP+0))\""
eval "sht53=\"\$F$((FP+NP+1))\""
eval "sht46=\"\$F$((FP+NP+2))\""
eval "sht38=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
eval "sht34=\"\$F$((FP+NP+5))\""
eval "sht31=\"\$F$((FP+NP+6))\""
eval "sht29=\"\$F$((FP+NP+7))\""
eval "sht27=\"\$F$((FP+NP+8))\""
eval "sht25=\"\$F$((FP+NP+9))\""
eval "sht23=\"\$F$((FP+NP+10))\""
eval "sht19=\"\$F$((FP+NP+11))\""
eval "sht11=\"\$F$((FP+NP+12))\""
eval "sht3=\"\$F$((FP+NP+13))\""
sht69="${R}"
sht70="${sht69}"
sht71="T:${sht31#??}="
eval "F$((FP+NP+0))=\"\${sht70}\""
eval "F$((FP+NP+1))=\"\${sht70}\""
eval "F$((FP+NP+2))=\"\${sht56}\""
eval "F$((FP+NP+3))=\"\${sht53}\""
eval "F$((FP+NP+4))=\"\${sht46}\""
eval "F$((FP+NP+5))=\"\${sht38}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
eval "F$((FP+NP+7))=\"\${sht34}\""
eval "F$((FP+NP+8))=\"\${sht31}\""
eval "F$((FP+NP+9))=\"\${sht29}\""
eval "F$((FP+NP+10))=\"\${sht27}\""
eval "F$((FP+NP+11))=\"\${sht25}\""
eval "F$((FP+NP+12))=\"\${sht23}\""
eval "F$((FP+NP+13))=\"\${sht19}\""
eval "F$((FP+NP+14))=\"\${sht11}\""
eval "F$((FP+NP+15))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht71}\""
CALLEE=qset
RPC=17; ACTION=call; return
;;
17)
eval "sht70=\"\$F$((FP+NP+0))\""
eval "sht70=\"\$F$((FP+NP+1))\""
eval "sht56=\"\$F$((FP+NP+2))\""
eval "sht53=\"\$F$((FP+NP+3))\""
eval "sht46=\"\$F$((FP+NP+4))\""
eval "sht38=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
eval "sht34=\"\$F$((FP+NP+7))\""
eval "sht31=\"\$F$((FP+NP+8))\""
eval "sht29=\"\$F$((FP+NP+9))\""
eval "sht27=\"\$F$((FP+NP+10))\""
eval "sht25=\"\$F$((FP+NP+11))\""
eval "sht23=\"\$F$((FP+NP+12))\""
eval "sht19=\"\$F$((FP+NP+13))\""
eval "sht11=\"\$F$((FP+NP+14))\""
eval "sht3=\"\$F$((FP+NP+15))\""
sht72="${R}"
eval "F$((FP+NP+0))=\"\${sht70}\""
eval "F$((FP+NP+1))=\"\${sht56}\""
eval "F$((FP+NP+2))=\"\${sht53}\""
eval "F$((FP+NP+3))=\"\${sht46}\""
eval "F$((FP+NP+4))=\"\${sht38}\""
eval "F$((FP+NP+5))=\"\${sht36}\""
eval "F$((FP+NP+6))=\"\${sht34}\""
eval "F$((FP+NP+7))=\"\${sht31}\""
eval "F$((FP+NP+8))=\"\${sht29}\""
eval "F$((FP+NP+9))=\"\${sht27}\""
eval "F$((FP+NP+10))=\"\${sht25}\""
eval "F$((FP+NP+11))=\"\${sht23}\""
eval "F$((FP+NP+12))=\"\${sht19}\""
eval "F$((FP+NP+13))=\"\${sht11}\""
eval "F$((FP+NP+14))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht70}\""
eval "F$((NFP+1))=\"\${sht72}\""
CALLEE=emit
RPC=18; ACTION=call; return
;;
18)
eval "sht70=\"\$F$((FP+NP+0))\""
eval "sht56=\"\$F$((FP+NP+1))\""
eval "sht53=\"\$F$((FP+NP+2))\""
eval "sht46=\"\$F$((FP+NP+3))\""
eval "sht38=\"\$F$((FP+NP+4))\""
eval "sht36=\"\$F$((FP+NP+5))\""
eval "sht34=\"\$F$((FP+NP+6))\""
eval "sht31=\"\$F$((FP+NP+7))\""
eval "sht29=\"\$F$((FP+NP+8))\""
eval "sht27=\"\$F$((FP+NP+9))\""
eval "sht25=\"\$F$((FP+NP+10))\""
eval "sht23=\"\$F$((FP+NP+11))\""
eval "sht19=\"\$F$((FP+NP+12))\""
eval "sht11=\"\$F$((FP+NP+13))\""
eval "sht3=\"\$F$((FP+NP+14))\""
sht73="${R}"
sht74="${sht73}"
hp_cdr "${sht19}"
sht75="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht74}\""
eval "F$((FP+NP+2))=\"\${sht74}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht56}\""
eval "F$((FP+NP+5))=\"\${sht53}\""
eval "F$((FP+NP+6))=\"\${sht46}\""
eval "F$((FP+NP+7))=\"\${sht38}\""
eval "F$((FP+NP+8))=\"\${sht36}\""
eval "F$((FP+NP+9))=\"\${sht34}\""
eval "F$((FP+NP+10))=\"\${sht31}\""
eval "F$((FP+NP+11))=\"\${sht29}\""
eval "F$((FP+NP+12))=\"\${sht27}\""
eval "F$((FP+NP+13))=\"\${sht25}\""
eval "F$((FP+NP+14))=\"\${sht23}\""
eval "F$((FP+NP+15))=\"\${sht19}\""
eval "F$((FP+NP+16))=\"\${sht11}\""
eval "F$((FP+NP+17))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht75}\""
CALLEE=aref
RPC=19; ACTION=call; return
;;
19)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht74=\"\$F$((FP+NP+1))\""
eval "sht74=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht56=\"\$F$((FP+NP+4))\""
eval "sht53=\"\$F$((FP+NP+5))\""
eval "sht46=\"\$F$((FP+NP+6))\""
eval "sht38=\"\$F$((FP+NP+7))\""
eval "sht36=\"\$F$((FP+NP+8))\""
eval "sht34=\"\$F$((FP+NP+9))\""
eval "sht31=\"\$F$((FP+NP+10))\""
eval "sht29=\"\$F$((FP+NP+11))\""
eval "sht27=\"\$F$((FP+NP+12))\""
eval "sht25=\"\$F$((FP+NP+13))\""
eval "sht23=\"\$F$((FP+NP+14))\""
eval "sht19=\"\$F$((FP+NP+15))\""
eval "sht11=\"\$F$((FP+NP+16))\""
eval "sht3=\"\$F$((FP+NP+17))\""
sht76="${R}"
sht77="T:=${sht76#??}"
sht78="T:${sht29#??}${sht77#??}"
sht79="T:set /a ${sht78#??}"
eval "F$((FP+NP+0))=\"\${sht74}\""
eval "F$((FP+NP+1))=\"\${sht70}\""
eval "F$((FP+NP+2))=\"\${sht56}\""
eval "F$((FP+NP+3))=\"\${sht53}\""
eval "F$((FP+NP+4))=\"\${sht46}\""
eval "F$((FP+NP+5))=\"\${sht38}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
eval "F$((FP+NP+7))=\"\${sht34}\""
eval "F$((FP+NP+8))=\"\${sht31}\""
eval "F$((FP+NP+9))=\"\${sht29}\""
eval "F$((FP+NP+10))=\"\${sht27}\""
eval "F$((FP+NP+11))=\"\${sht25}\""
eval "F$((FP+NP+12))=\"\${sht23}\""
eval "F$((FP+NP+13))=\"\${sht19}\""
eval "F$((FP+NP+14))=\"\${sht11}\""
eval "F$((FP+NP+15))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht74}\""
eval "F$((NFP+1))=\"\${sht79}\""
CALLEE=emit
RPC=20; ACTION=call; return
;;
20)
eval "sht74=\"\$F$((FP+NP+0))\""
eval "sht70=\"\$F$((FP+NP+1))\""
eval "sht56=\"\$F$((FP+NP+2))\""
eval "sht53=\"\$F$((FP+NP+3))\""
eval "sht46=\"\$F$((FP+NP+4))\""
eval "sht38=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
eval "sht34=\"\$F$((FP+NP+7))\""
eval "sht31=\"\$F$((FP+NP+8))\""
eval "sht29=\"\$F$((FP+NP+9))\""
eval "sht27=\"\$F$((FP+NP+10))\""
eval "sht25=\"\$F$((FP+NP+11))\""
eval "sht23=\"\$F$((FP+NP+12))\""
eval "sht19=\"\$F$((FP+NP+13))\""
eval "sht11=\"\$F$((FP+NP+14))\""
eval "sht3=\"\$F$((FP+NP+15))\""
sht80="${R}"
sht81="${sht80}"
sht82="T::${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht81}\""
eval "F$((FP+NP+1))=\"\${sht74}\""
eval "F$((FP+NP+2))=\"\${sht70}\""
eval "F$((FP+NP+3))=\"\${sht56}\""
eval "F$((FP+NP+4))=\"\${sht53}\""
eval "F$((FP+NP+5))=\"\${sht46}\""
eval "F$((FP+NP+6))=\"\${sht38}\""
eval "F$((FP+NP+7))=\"\${sht36}\""
eval "F$((FP+NP+8))=\"\${sht34}\""
eval "F$((FP+NP+9))=\"\${sht31}\""
eval "F$((FP+NP+10))=\"\${sht29}\""
eval "F$((FP+NP+11))=\"\${sht27}\""
eval "F$((FP+NP+12))=\"\${sht25}\""
eval "F$((FP+NP+13))=\"\${sht23}\""
eval "F$((FP+NP+14))=\"\${sht19}\""
eval "F$((FP+NP+15))=\"\${sht11}\""
eval "F$((FP+NP+16))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht81}\""
eval "F$((NFP+1))=\"\${sht82}\""
CALLEE=emit
RPC=21; ACTION=call; return
;;
21)
eval "sht81=\"\$F$((FP+NP+0))\""
eval "sht74=\"\$F$((FP+NP+1))\""
eval "sht70=\"\$F$((FP+NP+2))\""
eval "sht56=\"\$F$((FP+NP+3))\""
eval "sht53=\"\$F$((FP+NP+4))\""
eval "sht46=\"\$F$((FP+NP+5))\""
eval "sht38=\"\$F$((FP+NP+6))\""
eval "sht36=\"\$F$((FP+NP+7))\""
eval "sht34=\"\$F$((FP+NP+8))\""
eval "sht31=\"\$F$((FP+NP+9))\""
eval "sht29=\"\$F$((FP+NP+10))\""
eval "sht27=\"\$F$((FP+NP+11))\""
eval "sht25=\"\$F$((FP+NP+12))\""
eval "sht23=\"\$F$((FP+NP+13))\""
eval "sht19=\"\$F$((FP+NP+14))\""
eval "sht11=\"\$F$((FP+NP+15))\""
eval "sht3=\"\$F$((FP+NP+16))\""
sht83="${R}"
sht84="${sht83}"
sht85="T:${sht38#??})"
sht86="T:-=1& goto ${sht85#??}"
sht87="T:${sht29#??}${sht86#??}"
sht88="T::~1!& set /a ${sht87#??}"
sht89="T:${sht25#??}${sht88#??}"
sht90="T:=!${sht89#??}"
sht91="T:${sht25#??}${sht90#??}"
sht92="T::~0,1!& set ${sht91#??}"
sht93="T:${sht25#??}${sht92#??}"
sht94="T:!!${sht93#??}"
sht95="T:${sht31#??}${sht94#??}"
sht96="T:=!${sht95#??}"
sht97="T:${sht31#??}${sht96#??}"
sht98="T:! gtr 0 (set ${sht97#??}"
sht99="T:${sht29#??}${sht98#??}"
sht100="T: if !${sht99#??}"
sht101="T:${sht25#??}${sht100#??}"
sht102="T:if defined ${sht101#??}"
eval "F$((FP+NP+0))=\"\${sht84}\""
eval "F$((FP+NP+1))=\"\${sht81}\""
eval "F$((FP+NP+2))=\"\${sht74}\""
eval "F$((FP+NP+3))=\"\${sht70}\""
eval "F$((FP+NP+4))=\"\${sht56}\""
eval "F$((FP+NP+5))=\"\${sht53}\""
eval "F$((FP+NP+6))=\"\${sht46}\""
eval "F$((FP+NP+7))=\"\${sht38}\""
eval "F$((FP+NP+8))=\"\${sht36}\""
eval "F$((FP+NP+9))=\"\${sht34}\""
eval "F$((FP+NP+10))=\"\${sht31}\""
eval "F$((FP+NP+11))=\"\${sht29}\""
eval "F$((FP+NP+12))=\"\${sht27}\""
eval "F$((FP+NP+13))=\"\${sht25}\""
eval "F$((FP+NP+14))=\"\${sht23}\""
eval "F$((FP+NP+15))=\"\${sht19}\""
eval "F$((FP+NP+16))=\"\${sht11}\""
eval "F$((FP+NP+17))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht84}\""
eval "F$((NFP+1))=\"\${sht102}\""
CALLEE=emit
RPC=22; ACTION=call; return
;;
22)
eval "sht84=\"\$F$((FP+NP+0))\""
eval "sht81=\"\$F$((FP+NP+1))\""
eval "sht74=\"\$F$((FP+NP+2))\""
eval "sht70=\"\$F$((FP+NP+3))\""
eval "sht56=\"\$F$((FP+NP+4))\""
eval "sht53=\"\$F$((FP+NP+5))\""
eval "sht46=\"\$F$((FP+NP+6))\""
eval "sht38=\"\$F$((FP+NP+7))\""
eval "sht36=\"\$F$((FP+NP+8))\""
eval "sht34=\"\$F$((FP+NP+9))\""
eval "sht31=\"\$F$((FP+NP+10))\""
eval "sht29=\"\$F$((FP+NP+11))\""
eval "sht27=\"\$F$((FP+NP+12))\""
eval "sht25=\"\$F$((FP+NP+13))\""
eval "sht23=\"\$F$((FP+NP+14))\""
eval "sht19=\"\$F$((FP+NP+15))\""
eval "sht11=\"\$F$((FP+NP+16))\""
eval "sht3=\"\$F$((FP+NP+17))\""
sht103="${R}"
sht104="${sht103}"
sht105="T:${sht31#??}!"
sht106="T:=T:!${sht105#??}"
sht107="T:${sht34#??}${sht106#??}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht84}\""
eval "F$((FP+NP+3))=\"\${sht81}\""
eval "F$((FP+NP+4))=\"\${sht74}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht56}\""
eval "F$((FP+NP+7))=\"\${sht53}\""
eval "F$((FP+NP+8))=\"\${sht46}\""
eval "F$((FP+NP+9))=\"\${sht38}\""
eval "F$((FP+NP+10))=\"\${sht36}\""
eval "F$((FP+NP+11))=\"\${sht34}\""
eval "F$((FP+NP+12))=\"\${sht31}\""
eval "F$((FP+NP+13))=\"\${sht29}\""
eval "F$((FP+NP+14))=\"\${sht27}\""
eval "F$((FP+NP+15))=\"\${sht25}\""
eval "F$((FP+NP+16))=\"\${sht23}\""
eval "F$((FP+NP+17))=\"\${sht19}\""
eval "F$((FP+NP+18))=\"\${sht11}\""
eval "F$((FP+NP+19))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht107}\""
CALLEE=qset
RPC=23; ACTION=call; return
;;
23)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht84=\"\$F$((FP+NP+2))\""
eval "sht81=\"\$F$((FP+NP+3))\""
eval "sht74=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht56=\"\$F$((FP+NP+6))\""
eval "sht53=\"\$F$((FP+NP+7))\""
eval "sht46=\"\$F$((FP+NP+8))\""
eval "sht38=\"\$F$((FP+NP+9))\""
eval "sht36=\"\$F$((FP+NP+10))\""
eval "sht34=\"\$F$((FP+NP+11))\""
eval "sht31=\"\$F$((FP+NP+12))\""
eval "sht29=\"\$F$((FP+NP+13))\""
eval "sht27=\"\$F$((FP+NP+14))\""
eval "sht25=\"\$F$((FP+NP+15))\""
eval "sht23=\"\$F$((FP+NP+16))\""
eval "sht19=\"\$F$((FP+NP+17))\""
eval "sht11=\"\$F$((FP+NP+18))\""
eval "sht3=\"\$F$((FP+NP+19))\""
sht108="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht84}\""
eval "F$((FP+NP+2))=\"\${sht81}\""
eval "F$((FP+NP+3))=\"\${sht74}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht56}\""
eval "F$((FP+NP+6))=\"\${sht53}\""
eval "F$((FP+NP+7))=\"\${sht46}\""
eval "F$((FP+NP+8))=\"\${sht38}\""
eval "F$((FP+NP+9))=\"\${sht36}\""
eval "F$((FP+NP+10))=\"\${sht34}\""
eval "F$((FP+NP+11))=\"\${sht31}\""
eval "F$((FP+NP+12))=\"\${sht29}\""
eval "F$((FP+NP+13))=\"\${sht27}\""
eval "F$((FP+NP+14))=\"\${sht25}\""
eval "F$((FP+NP+15))=\"\${sht23}\""
eval "F$((FP+NP+16))=\"\${sht19}\""
eval "F$((FP+NP+17))=\"\${sht11}\""
eval "F$((FP+NP+18))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht104}\""
eval "F$((NFP+1))=\"\${sht108}\""
CALLEE=emit
RPC=24; ACTION=call; return
;;
24)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht84=\"\$F$((FP+NP+1))\""
eval "sht81=\"\$F$((FP+NP+2))\""
eval "sht74=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht56=\"\$F$((FP+NP+5))\""
eval "sht53=\"\$F$((FP+NP+6))\""
eval "sht46=\"\$F$((FP+NP+7))\""
eval "sht38=\"\$F$((FP+NP+8))\""
eval "sht36=\"\$F$((FP+NP+9))\""
eval "sht34=\"\$F$((FP+NP+10))\""
eval "sht31=\"\$F$((FP+NP+11))\""
eval "sht29=\"\$F$((FP+NP+12))\""
eval "sht27=\"\$F$((FP+NP+13))\""
eval "sht25=\"\$F$((FP+NP+14))\""
eval "sht23=\"\$F$((FP+NP+15))\""
eval "sht19=\"\$F$((FP+NP+16))\""
eval "sht11=\"\$F$((FP+NP+17))\""
eval "sht3=\"\$F$((FP+NP+18))\""
sht109="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht84}\""
eval "F$((FP+NP+2))=\"\${sht81}\""
eval "F$((FP+NP+3))=\"\${sht74}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht56}\""
eval "F$((FP+NP+6))=\"\${sht53}\""
eval "F$((FP+NP+7))=\"\${sht46}\""
eval "F$((FP+NP+8))=\"\${sht38}\""
eval "F$((FP+NP+9))=\"\${sht36}\""
eval "F$((FP+NP+10))=\"\${sht34}\""
eval "F$((FP+NP+11))=\"\${sht31}\""
eval "F$((FP+NP+12))=\"\${sht29}\""
eval "F$((FP+NP+13))=\"\${sht27}\""
eval "F$((FP+NP+14))=\"\${sht25}\""
eval "F$((FP+NP+15))=\"\${sht23}\""
eval "F$((FP+NP+16))=\"\${sht19}\""
eval "F$((FP+NP+17))=\"\${sht11}\""
eval "F$((FP+NP+18))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht109}\""
CALLEE=bkzzP
RPC=25; ACTION=call; return
;;
25)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht84=\"\$F$((FP+NP+1))\""
eval "sht81=\"\$F$((FP+NP+2))\""
eval "sht74=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht56=\"\$F$((FP+NP+5))\""
eval "sht53=\"\$F$((FP+NP+6))\""
eval "sht46=\"\$F$((FP+NP+7))\""
eval "sht38=\"\$F$((FP+NP+8))\""
eval "sht36=\"\$F$((FP+NP+9))\""
eval "sht34=\"\$F$((FP+NP+10))\""
eval "sht31=\"\$F$((FP+NP+11))\""
eval "sht29=\"\$F$((FP+NP+12))\""
eval "sht27=\"\$F$((FP+NP+13))\""
eval "sht25=\"\$F$((FP+NP+14))\""
eval "sht23=\"\$F$((FP+NP+15))\""
eval "sht19=\"\$F$((FP+NP+16))\""
eval "sht11=\"\$F$((FP+NP+17))\""
eval "sht3=\"\$F$((FP+NP+18))\""
sht110="${R}"
eval "F$((FP+NP+0))=\"\${sht110}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht84}\""
eval "F$((FP+NP+3))=\"\${sht81}\""
eval "F$((FP+NP+4))=\"\${sht74}\""
eval "F$((FP+NP+5))=\"\${sht70}\""
eval "F$((FP+NP+6))=\"\${sht56}\""
eval "F$((FP+NP+7))=\"\${sht53}\""
eval "F$((FP+NP+8))=\"\${sht46}\""
eval "F$((FP+NP+9))=\"\${sht38}\""
eval "F$((FP+NP+10))=\"\${sht36}\""
eval "F$((FP+NP+11))=\"\${sht34}\""
eval "F$((FP+NP+12))=\"\${sht31}\""
eval "F$((FP+NP+13))=\"\${sht29}\""
eval "F$((FP+NP+14))=\"\${sht27}\""
eval "F$((FP+NP+15))=\"\${sht25}\""
eval "F$((FP+NP+16))=\"\${sht23}\""
eval "F$((FP+NP+17))=\"\${sht19}\""
eval "F$((FP+NP+18))=\"\${sht11}\""
eval "F$((FP+NP+19))=\"\${sht3}\""
hp_cons "S:val" "${sht34}"
eval "sht110=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht84=\"\$F$((FP+NP+2))\""
eval "sht81=\"\$F$((FP+NP+3))\""
eval "sht74=\"\$F$((FP+NP+4))\""
eval "sht70=\"\$F$((FP+NP+5))\""
eval "sht56=\"\$F$((FP+NP+6))\""
eval "sht53=\"\$F$((FP+NP+7))\""
eval "sht46=\"\$F$((FP+NP+8))\""
eval "sht38=\"\$F$((FP+NP+9))\""
eval "sht36=\"\$F$((FP+NP+10))\""
eval "sht34=\"\$F$((FP+NP+11))\""
eval "sht31=\"\$F$((FP+NP+12))\""
eval "sht29=\"\$F$((FP+NP+13))\""
eval "sht27=\"\$F$((FP+NP+14))\""
eval "sht25=\"\$F$((FP+NP+15))\""
eval "sht23=\"\$F$((FP+NP+16))\""
eval "sht19=\"\$F$((FP+NP+17))\""
eval "sht11=\"\$F$((FP+NP+18))\""
eval "sht3=\"\$F$((FP+NP+19))\""
sht111="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht84}\""
eval "F$((FP+NP+2))=\"\${sht81}\""
eval "F$((FP+NP+3))=\"\${sht74}\""
eval "F$((FP+NP+4))=\"\${sht70}\""
eval "F$((FP+NP+5))=\"\${sht56}\""
eval "F$((FP+NP+6))=\"\${sht53}\""
eval "F$((FP+NP+7))=\"\${sht46}\""
eval "F$((FP+NP+8))=\"\${sht38}\""
eval "F$((FP+NP+9))=\"\${sht36}\""
eval "F$((FP+NP+10))=\"\${sht34}\""
eval "F$((FP+NP+11))=\"\${sht31}\""
eval "F$((FP+NP+12))=\"\${sht29}\""
eval "F$((FP+NP+13))=\"\${sht27}\""
eval "F$((FP+NP+14))=\"\${sht25}\""
eval "F$((FP+NP+15))=\"\${sht23}\""
eval "F$((FP+NP+16))=\"\${sht19}\""
eval "F$((FP+NP+17))=\"\${sht11}\""
eval "F$((FP+NP+18))=\"\${sht3}\""
hp_cons "${sht110}" "${sht111}"
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht84=\"\$F$((FP+NP+1))\""
eval "sht81=\"\$F$((FP+NP+2))\""
eval "sht74=\"\$F$((FP+NP+3))\""
eval "sht70=\"\$F$((FP+NP+4))\""
eval "sht56=\"\$F$((FP+NP+5))\""
eval "sht53=\"\$F$((FP+NP+6))\""
eval "sht46=\"\$F$((FP+NP+7))\""
eval "sht38=\"\$F$((FP+NP+8))\""
eval "sht36=\"\$F$((FP+NP+9))\""
eval "sht34=\"\$F$((FP+NP+10))\""
eval "sht31=\"\$F$((FP+NP+11))\""
eval "sht29=\"\$F$((FP+NP+12))\""
eval "sht27=\"\$F$((FP+NP+13))\""
eval "sht25=\"\$F$((FP+NP+14))\""
eval "sht23=\"\$F$((FP+NP+15))\""
eval "sht19=\"\$F$((FP+NP+16))\""
eval "sht11=\"\$F$((FP+NP+17))\""
eval "sht3=\"\$F$((FP+NP+18))\""
sht112="${R}"
R="${sht112}"; ACTION=ret; return
;;
esac; }
SIZE_builtinzzQ=1
builtinzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_builtinzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:write-lines" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:append-lines" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:gc" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="S:t"; ACTION=ret; return
;;
6)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_aas=3
aas() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_aas))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p1#??}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=vref
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
sht3="T:=${sht2#??}"
sht4="T:${sht0#??}${sht3#??}"
sht5="T:A${sht4#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
sht6="${R}"
hp_cdr "${p0}"
sht7="${R}"
sht8="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=aas
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_cons "${sht6}" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_emit_list=2
emit_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_emit_list))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht0}\""
CALLEE=emit
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${sht1}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_lbuiltin=10
lbuiltin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lbuiltin))
NP=4
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
sht2="${sht1}"
hp_car "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=tmpn
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
sht5="${sht4}"
hp_car "${p0}"
sht6="${R}"
sht7="T:${sht6#??}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=mangle
RPC=3; ACTION=call; return
;;
3)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht8="${R}"
sht9="${sht8}"
hp_car "${sht2}"
sht10="${R}"
hp_cdr "${sht2}"
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"I:1\""
CALLEE=aas
RPC=4; ACTION=call; return
;;
4)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=emit_list
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht13="${R}"
sht14="${sht13}"
sht15="T:${sht9#??}.cmd"
sht16="T:call ${sht15#??}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${sht16}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht17="${R}"
sht18="${sht17}"
sht19="T:${sht5#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=qset
RPC=7; ACTION=call; return
;;
7)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=emit
RPC=8; ACTION=call; return
;;
8)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=bkzzP
RPC=9; ACTION=call; return
;;
9)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht14}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "S:val" "${sht5}"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht14=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
hp_cons "${sht22}" "${sht23}"
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht24="${R}"
R="${sht24}"; ACTION=ret; return
;;
esac; }
SIZE_lval=15
lval() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_lval))
NP=4
case $PC in
0)
if [ "${p0#I:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
sht0="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:lit" "${sht0}"
eval "p2=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cons "${p2}" "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:nil" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:cst" "T:NIL"
eval "p2=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${p2}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:t" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:cst" "T:S:t"
eval "p2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${p2}" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
6)
if [ "${p0#T:}" != "${p0}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
eval "F$((FP+NP+0))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=enc_mc
RPC=9; ACTION=call; return
;;
8)
if [ "${p0#S:}" != "${p0}" ]; then PC=10; else PC=11; fi
ACTION=jump; return
;;
9)
eval "p2=\"\$F$((FP+NP+0))\""
sht7="${R}"
sht8="T:T:${sht7#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:cst" "${sht8}"
eval "p2=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_cons "${p2}" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
10)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=12; ACTION=call; return
;;
11)
hp_car "${p0}"
sht19="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
CALLEE=arithzzQ
RPC=15; ACTION=call; return
;;
12)
sht11="${R}"
sht12="${sht11}"
if [ "${sht12}" = NIL ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
sht13="T:${p0#??}"
sht14="T:G_${sht13#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:val" "${sht14}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht15}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht16="${R}"
R="${sht16}"; ACTION=ret; return
;;
14)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:val" "${sht12}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht17}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht18="${R}"
R="${sht18}"; ACTION=ret; return
;;
15)
sht20="${R}"
if [ "${sht20}" != NIL ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
16)
hp_cdr "${p0}"
sht21="${R}"
hp_car "${sht21}"
sht22="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=18; ACTION=call; return
;;
17)
hp_car "${p0}"
sht52="${R}"
if [ "${sht52}" = "S:cons" ]; then PC=27; else PC=28; fi
ACTION=jump; return
;;
18)
sht23="${R}"
sht24="${sht23}"
hp_cdr "${p0}"
sht25="${R}"
hp_cdr "${sht25}"
sht26="${R}"
hp_car "${sht26}"
sht27="${R}"
hp_car "${sht24}"
sht28="${R}"
hp_cdr "${sht24}"
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht27}\""
eval "F$((FP+NP+3))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=19; ACTION=call; return
;;
19)
eval "sht28=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht27=\"\$F$((FP+NP+2))\""
eval "sht24=\"\$F$((FP+NP+3))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht28}\""
eval "F$((NFP+3))=\"\${sht30}\""
CALLEE=lval
RPC=20; ACTION=call; return
;;
20)
eval "sht24=\"\$F$((FP+NP+0))\""
sht31="${R}"
sht32="${sht31}"
hp_car "${sht32}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
CALLEE=tmpn
RPC=21; ACTION=call; return
;;
21)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
sht34="${R}"
sht35="${sht34}"
hp_car "${sht32}"
sht36="${R}"
hp_cdr "${sht24}"
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht35}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
CALLEE=aref
RPC=22; ACTION=call; return
;;
22)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht35=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht24=\"\$F$((FP+NP+4))\""
sht38="${R}"
hp_car "${p0}"
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht38}\""
eval "F$((FP+NP+1))=\"\${sht35}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht35}\""
eval "F$((FP+NP+4))=\"\${sht32}\""
eval "F$((FP+NP+5))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
CALLEE=op_zzGbatch
RPC=23; ACTION=call; return
;;
23)
eval "sht38=\"\$F$((FP+NP+0))\""
eval "sht35=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht35=\"\$F$((FP+NP+3))\""
eval "sht32=\"\$F$((FP+NP+4))\""
eval "sht24=\"\$F$((FP+NP+5))\""
sht40="${R}"
hp_cdr "${sht32}"
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht40}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht35}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
eval "F$((FP+NP+4))=\"\${sht35}\""
eval "F$((FP+NP+5))=\"\${sht32}\""
eval "F$((FP+NP+6))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht41}\""
CALLEE=aref
RPC=24; ACTION=call; return
;;
24)
eval "sht40=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht35=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
eval "sht35=\"\$F$((FP+NP+4))\""
eval "sht32=\"\$F$((FP+NP+5))\""
eval "sht24=\"\$F$((FP+NP+6))\""
sht42="${R}"
sht43="T:${sht40#??}${sht42#??}"
sht44="T:${sht38#??}${sht43#??}"
sht45="T:=${sht44#??}"
sht46="T:${sht35#??}${sht45#??}"
sht47="T:set /a ${sht46#??}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
eval "F$((NFP+1))=\"\${sht47}\""
CALLEE=emit
RPC=25; ACTION=call; return
;;
25)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht24=\"\$F$((FP+NP+2))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht24}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
CALLEE=bkzzP
RPC=26; ACTION=call; return
;;
26)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht24=\"\$F$((FP+NP+2))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht49}\""
eval "F$((FP+NP+1))=\"\${sht35}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht24}\""
hp_cons "S:raw" "${sht35}"
eval "sht49=\"\$F$((FP+NP+0))\""
eval "sht35=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht24=\"\$F$((FP+NP+3))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht24}\""
hp_cons "${sht49}" "${sht50}"
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht24=\"\$F$((FP+NP+2))\""
sht51="${R}"
R="${sht51}"; ACTION=ret; return
;;
27)
hp_cdr "${p0}"
sht53="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=29; ACTION=call; return
;;
28)
hp_car "${p0}"
sht85="${R}"
if [ "${sht85}" = "S:string-append" ]; then PC=39; else PC=40; fi
ACTION=jump; return
;;
29)
sht54="${R}"
sht55="${sht54}"
hp_car "${sht55}"
sht56="${R}"
eval "F$((FP+NP+0))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht56}\""
CALLEE=tmpn
RPC=30; ACTION=call; return
;;
30)
eval "sht55=\"\$F$((FP+NP+0))\""
sht57="${R}"
sht58="${sht57}"
hp_cdr "${sht55}"
sht59="${R}"
hp_car "${sht59}"
sht60="${R}"
sht61="${sht60}"
hp_cdr "${sht55}"
sht62="${R}"
hp_cdr "${sht62}"
sht63="${R}"
hp_car "${sht63}"
sht64="${R}"
sht65="${sht64}"
hp_car "${sht55}"
sht66="${R}"
eval "F$((FP+NP+0))=\"\${sht65}\""
eval "F$((FP+NP+1))=\"\${sht61}\""
eval "F$((FP+NP+2))=\"\${sht58}\""
eval "F$((FP+NP+3))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht66}\""
STGV="T:set /a HN+=1"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=31; ACTION=call; return
;;
31)
eval "sht65=\"\$F$((FP+NP+0))\""
eval "sht61=\"\$F$((FP+NP+1))\""
eval "sht58=\"\$F$((FP+NP+2))\""
eval "sht55=\"\$F$((FP+NP+3))\""
sht67="${R}"
sht68="${sht67}"
eval "F$((FP+NP+0))=\"\${sht68}\""
eval "F$((FP+NP+1))=\"\${sht68}\""
eval "F$((FP+NP+2))=\"\${sht65}\""
eval "F$((FP+NP+3))=\"\${sht61}\""
eval "F$((FP+NP+4))=\"\${sht58}\""
eval "F$((FP+NP+5))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht61}\""
CALLEE=vref
RPC=32; ACTION=call; return
;;
32)
eval "sht68=\"\$F$((FP+NP+0))\""
eval "sht68=\"\$F$((FP+NP+1))\""
eval "sht65=\"\$F$((FP+NP+2))\""
eval "sht61=\"\$F$((FP+NP+3))\""
eval "sht58=\"\$F$((FP+NP+4))\""
eval "sht55=\"\$F$((FP+NP+5))\""
sht69="${R}"
sht70="T:${sht69#??}#"
sht71="T:>%HD%\car%HN% echo(${sht70#??}"
eval "F$((FP+NP+0))=\"\${sht68}\""
eval "F$((FP+NP+1))=\"\${sht65}\""
eval "F$((FP+NP+2))=\"\${sht61}\""
eval "F$((FP+NP+3))=\"\${sht58}\""
eval "F$((FP+NP+4))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht68}\""
eval "F$((NFP+1))=\"\${sht71}\""
CALLEE=emit
RPC=33; ACTION=call; return
;;
33)
eval "sht68=\"\$F$((FP+NP+0))\""
eval "sht65=\"\$F$((FP+NP+1))\""
eval "sht61=\"\$F$((FP+NP+2))\""
eval "sht58=\"\$F$((FP+NP+3))\""
eval "sht55=\"\$F$((FP+NP+4))\""
sht72="${R}"
sht73="${sht72}"
eval "F$((FP+NP+0))=\"\${sht73}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht68}\""
eval "F$((FP+NP+3))=\"\${sht65}\""
eval "F$((FP+NP+4))=\"\${sht61}\""
eval "F$((FP+NP+5))=\"\${sht58}\""
eval "F$((FP+NP+6))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht65}\""
CALLEE=vref
RPC=34; ACTION=call; return
;;
34)
eval "sht73=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht68=\"\$F$((FP+NP+2))\""
eval "sht65=\"\$F$((FP+NP+3))\""
eval "sht61=\"\$F$((FP+NP+4))\""
eval "sht58=\"\$F$((FP+NP+5))\""
eval "sht55=\"\$F$((FP+NP+6))\""
sht74="${R}"
sht75="T:${sht74#??}#"
sht76="T:>%HD%\cdr%HN% echo(${sht75#??}"
eval "F$((FP+NP+0))=\"\${sht73}\""
eval "F$((FP+NP+1))=\"\${sht68}\""
eval "F$((FP+NP+2))=\"\${sht65}\""
eval "F$((FP+NP+3))=\"\${sht61}\""
eval "F$((FP+NP+4))=\"\${sht58}\""
eval "F$((FP+NP+5))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht73}\""
eval "F$((NFP+1))=\"\${sht76}\""
CALLEE=emit
RPC=35; ACTION=call; return
;;
35)
eval "sht73=\"\$F$((FP+NP+0))\""
eval "sht68=\"\$F$((FP+NP+1))\""
eval "sht65=\"\$F$((FP+NP+2))\""
eval "sht61=\"\$F$((FP+NP+3))\""
eval "sht58=\"\$F$((FP+NP+4))\""
eval "sht55=\"\$F$((FP+NP+5))\""
sht77="${R}"
sht78="${sht77}"
sht79="T:${sht58#??}=P:!HN!"
eval "F$((FP+NP+0))=\"\${sht78}\""
eval "F$((FP+NP+1))=\"\${sht78}\""
eval "F$((FP+NP+2))=\"\${sht73}\""
eval "F$((FP+NP+3))=\"\${sht68}\""
eval "F$((FP+NP+4))=\"\${sht65}\""
eval "F$((FP+NP+5))=\"\${sht61}\""
eval "F$((FP+NP+6))=\"\${sht58}\""
eval "F$((FP+NP+7))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht79}\""
CALLEE=qset
RPC=36; ACTION=call; return
;;
36)
eval "sht78=\"\$F$((FP+NP+0))\""
eval "sht78=\"\$F$((FP+NP+1))\""
eval "sht73=\"\$F$((FP+NP+2))\""
eval "sht68=\"\$F$((FP+NP+3))\""
eval "sht65=\"\$F$((FP+NP+4))\""
eval "sht61=\"\$F$((FP+NP+5))\""
eval "sht58=\"\$F$((FP+NP+6))\""
eval "sht55=\"\$F$((FP+NP+7))\""
sht80="${R}"
eval "F$((FP+NP+0))=\"\${sht78}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht68}\""
eval "F$((FP+NP+3))=\"\${sht65}\""
eval "F$((FP+NP+4))=\"\${sht61}\""
eval "F$((FP+NP+5))=\"\${sht58}\""
eval "F$((FP+NP+6))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht78}\""
eval "F$((NFP+1))=\"\${sht80}\""
CALLEE=emit
RPC=37; ACTION=call; return
;;
37)
eval "sht78=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht68=\"\$F$((FP+NP+2))\""
eval "sht65=\"\$F$((FP+NP+3))\""
eval "sht61=\"\$F$((FP+NP+4))\""
eval "sht58=\"\$F$((FP+NP+5))\""
eval "sht55=\"\$F$((FP+NP+6))\""
sht81="${R}"
eval "F$((FP+NP+0))=\"\${sht78}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht68}\""
eval "F$((FP+NP+3))=\"\${sht65}\""
eval "F$((FP+NP+4))=\"\${sht61}\""
eval "F$((FP+NP+5))=\"\${sht58}\""
eval "F$((FP+NP+6))=\"\${sht55}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht81}\""
CALLEE=bkzzP
RPC=38; ACTION=call; return
;;
38)
eval "sht78=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht68=\"\$F$((FP+NP+2))\""
eval "sht65=\"\$F$((FP+NP+3))\""
eval "sht61=\"\$F$((FP+NP+4))\""
eval "sht58=\"\$F$((FP+NP+5))\""
eval "sht55=\"\$F$((FP+NP+6))\""
sht82="${R}"
eval "F$((FP+NP+0))=\"\${sht82}\""
eval "F$((FP+NP+1))=\"\${sht78}\""
eval "F$((FP+NP+2))=\"\${sht73}\""
eval "F$((FP+NP+3))=\"\${sht68}\""
eval "F$((FP+NP+4))=\"\${sht65}\""
eval "F$((FP+NP+5))=\"\${sht61}\""
eval "F$((FP+NP+6))=\"\${sht58}\""
eval "F$((FP+NP+7))=\"\${sht55}\""
hp_cons "S:val" "${sht58}"
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht78=\"\$F$((FP+NP+1))\""
eval "sht73=\"\$F$((FP+NP+2))\""
eval "sht68=\"\$F$((FP+NP+3))\""
eval "sht65=\"\$F$((FP+NP+4))\""
eval "sht61=\"\$F$((FP+NP+5))\""
eval "sht58=\"\$F$((FP+NP+6))\""
eval "sht55=\"\$F$((FP+NP+7))\""
sht83="${R}"
eval "F$((FP+NP+0))=\"\${sht78}\""
eval "F$((FP+NP+1))=\"\${sht73}\""
eval "F$((FP+NP+2))=\"\${sht68}\""
eval "F$((FP+NP+3))=\"\${sht65}\""
eval "F$((FP+NP+4))=\"\${sht61}\""
eval "F$((FP+NP+5))=\"\${sht58}\""
eval "F$((FP+NP+6))=\"\${sht55}\""
hp_cons "${sht82}" "${sht83}"
eval "sht78=\"\$F$((FP+NP+0))\""
eval "sht73=\"\$F$((FP+NP+1))\""
eval "sht68=\"\$F$((FP+NP+2))\""
eval "sht65=\"\$F$((FP+NP+3))\""
eval "sht61=\"\$F$((FP+NP+4))\""
eval "sht58=\"\$F$((FP+NP+5))\""
eval "sht55=\"\$F$((FP+NP+6))\""
sht84="${R}"
R="${sht84}"; ACTION=ret; return
;;
39)
hp_cdr "${p0}"
sht86="${R}"
hp_car "${sht86}"
sht87="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht87}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=41; ACTION=call; return
;;
40)
hp_car "${p0}"
sht114="${R}"
if [ "${sht114}" = "S:car" ]; then PC=50; else PC=51; fi
ACTION=jump; return
;;
41)
sht88="${R}"
sht89="${sht88}"
hp_cdr "${p0}"
sht90="${R}"
hp_cdr "${sht90}"
sht91="${R}"
hp_car "${sht91}"
sht92="${R}"
hp_car "${sht89}"
sht93="${R}"
hp_cdr "${sht89}"
sht94="${R}"
eval "F$((FP+NP+0))=\"\${sht93}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht92}\""
eval "F$((FP+NP+3))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht94}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=42; ACTION=call; return
;;
42)
eval "sht93=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht92=\"\$F$((FP+NP+2))\""
eval "sht89=\"\$F$((FP+NP+3))\""
sht95="${R}"
eval "F$((FP+NP+0))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht92}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht93}\""
eval "F$((NFP+3))=\"\${sht95}\""
CALLEE=lval
RPC=43; ACTION=call; return
;;
43)
eval "sht89=\"\$F$((FP+NP+0))\""
sht96="${R}"
sht97="${sht96}"
hp_car "${sht97}"
sht98="${R}"
eval "F$((FP+NP+0))=\"\${sht97}\""
eval "F$((FP+NP+1))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht98}\""
CALLEE=tmpn
RPC=44; ACTION=call; return
;;
44)
eval "sht97=\"\$F$((FP+NP+0))\""
eval "sht89=\"\$F$((FP+NP+1))\""
sht99="${R}"
sht100="${sht99}"
hp_car "${sht97}"
sht101="${R}"
hp_cdr "${sht89}"
sht102="${R}"
eval "F$((FP+NP+0))=\"\${sht100}\""
eval "F$((FP+NP+1))=\"\${sht101}\""
eval "F$((FP+NP+2))=\"\${sht100}\""
eval "F$((FP+NP+3))=\"\${sht97}\""
eval "F$((FP+NP+4))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht102}\""
CALLEE=cref
RPC=45; ACTION=call; return
;;
45)
eval "sht100=\"\$F$((FP+NP+0))\""
eval "sht101=\"\$F$((FP+NP+1))\""
eval "sht100=\"\$F$((FP+NP+2))\""
eval "sht97=\"\$F$((FP+NP+3))\""
eval "sht89=\"\$F$((FP+NP+4))\""
sht103="${R}"
hp_cdr "${sht97}"
sht104="${R}"
eval "F$((FP+NP+0))=\"\${sht103}\""
eval "F$((FP+NP+1))=\"\${sht100}\""
eval "F$((FP+NP+2))=\"\${sht101}\""
eval "F$((FP+NP+3))=\"\${sht100}\""
eval "F$((FP+NP+4))=\"\${sht97}\""
eval "F$((FP+NP+5))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht104}\""
CALLEE=cref
RPC=46; ACTION=call; return
;;
46)
eval "sht103=\"\$F$((FP+NP+0))\""
eval "sht100=\"\$F$((FP+NP+1))\""
eval "sht101=\"\$F$((FP+NP+2))\""
eval "sht100=\"\$F$((FP+NP+3))\""
eval "sht97=\"\$F$((FP+NP+4))\""
eval "sht89=\"\$F$((FP+NP+5))\""
sht105="${R}"
sht106="T:${sht103#??}${sht105#??}"
sht107="T:=T:${sht106#??}"
sht108="T:${sht100#??}${sht107#??}"
eval "F$((FP+NP+0))=\"\${sht101}\""
eval "F$((FP+NP+1))=\"\${sht100}\""
eval "F$((FP+NP+2))=\"\${sht97}\""
eval "F$((FP+NP+3))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht108}\""
CALLEE=qset
RPC=47; ACTION=call; return
;;
47)
eval "sht101=\"\$F$((FP+NP+0))\""
eval "sht100=\"\$F$((FP+NP+1))\""
eval "sht97=\"\$F$((FP+NP+2))\""
eval "sht89=\"\$F$((FP+NP+3))\""
sht109="${R}"
eval "F$((FP+NP+0))=\"\${sht100}\""
eval "F$((FP+NP+1))=\"\${sht97}\""
eval "F$((FP+NP+2))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht101}\""
eval "F$((NFP+1))=\"\${sht109}\""
CALLEE=emit
RPC=48; ACTION=call; return
;;
48)
eval "sht100=\"\$F$((FP+NP+0))\""
eval "sht97=\"\$F$((FP+NP+1))\""
eval "sht89=\"\$F$((FP+NP+2))\""
sht110="${R}"
eval "F$((FP+NP+0))=\"\${sht100}\""
eval "F$((FP+NP+1))=\"\${sht97}\""
eval "F$((FP+NP+2))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht110}\""
CALLEE=bkzzP
RPC=49; ACTION=call; return
;;
49)
eval "sht100=\"\$F$((FP+NP+0))\""
eval "sht97=\"\$F$((FP+NP+1))\""
eval "sht89=\"\$F$((FP+NP+2))\""
sht111="${R}"
eval "F$((FP+NP+0))=\"\${sht111}\""
eval "F$((FP+NP+1))=\"\${sht100}\""
eval "F$((FP+NP+2))=\"\${sht97}\""
eval "F$((FP+NP+3))=\"\${sht89}\""
hp_cons "S:val" "${sht100}"
eval "sht111=\"\$F$((FP+NP+0))\""
eval "sht100=\"\$F$((FP+NP+1))\""
eval "sht97=\"\$F$((FP+NP+2))\""
eval "sht89=\"\$F$((FP+NP+3))\""
sht112="${R}"
eval "F$((FP+NP+0))=\"\${sht100}\""
eval "F$((FP+NP+1))=\"\${sht97}\""
eval "F$((FP+NP+2))=\"\${sht89}\""
hp_cons "${sht111}" "${sht112}"
eval "sht100=\"\$F$((FP+NP+0))\""
eval "sht97=\"\$F$((FP+NP+1))\""
eval "sht89=\"\$F$((FP+NP+2))\""
sht113="${R}"
R="${sht113}"; ACTION=ret; return
;;
50)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:car"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lcell
RPC=52; ACTION=call; return
;;
51)
hp_car "${p0}"
sht116="${R}"
if [ "${sht116}" = "S:cdr" ]; then PC=53; else PC=54; fi
ACTION=jump; return
;;
52)
sht115="${R}"
R="${sht115}"; ACTION=ret; return
;;
53)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:cdr"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lcell
RPC=55; ACTION=call; return
;;
54)
hp_car "${p0}"
sht118="${R}"
if [ "${sht118}" = "S:if" ]; then PC=56; else PC=57; fi
ACTION=jump; return
;;
55)
sht117="${R}"
R="${sht117}"; ACTION=ret; return
;;
56)
hp_cdr "${p0}"
sht119="${R}"
hp_car "${sht119}"
sht120="${R}"
hp_cdr "${p0}"
sht121="${R}"
hp_cdr "${sht121}"
sht122="${R}"
hp_car "${sht122}"
sht123="${R}"
eval "F$((FP+NP+0))=\"\${sht123}\""
eval "F$((FP+NP+1))=\"\${sht120}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=58; ACTION=call; return
;;
57)
hp_car "${p0}"
sht126="${R}"
if [ "${sht126}" = "S:cond" ]; then PC=60; else PC=61; fi
ACTION=jump; return
;;
58)
eval "sht123=\"\$F$((FP+NP+0))\""
eval "sht120=\"\$F$((FP+NP+1))\""
sht124="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht120}\""
eval "F$((NFP+1))=\"\${sht123}\""
eval "F$((NFP+2))=\"\${sht124}\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=59; ACTION=call; return
;;
59)
sht125="${R}"
R="${sht125}"; ACTION=ret; return
;;
60)
hp_cdr "${p0}"
sht127="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht127}\""
CALLEE=cond_zzGif
RPC=62; ACTION=call; return
;;
61)
hp_car "${p0}"
sht129="${R}"
if [ "${sht129}" = "S:let" ]; then PC=63; else PC=64; fi
ACTION=jump; return
;;
62)
sht128="${R}"
eval "F$((FP+0))=\"\${sht128}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
63)
hp_cdr "${p0}"
sht130="${R}"
hp_car "${sht130}"
sht131="${R}"
hp_cdr "${p0}"
sht132="${R}"
hp_cdr "${sht132}"
sht133="${R}"
hp_car "${sht133}"
sht134="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht131}\""
eval "F$((NFP+1))=\"\${sht134}\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=llet
RPC=65; ACTION=call; return
;;
64)
hp_car "${p0}"
sht136="${R}"
if [ "${sht136}" = "S:begin" ]; then PC=66; else PC=67; fi
ACTION=jump; return
;;
65)
sht135="${R}"
R="${sht135}"; ACTION=ret; return
;;
66)
hp_cdr "${p0}"
sht137="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht137}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbegin
RPC=68; ACTION=call; return
;;
67)
hp_car "${p0}"
sht139="${R}"
if [ "${sht139}" = "S:quote" ]; then PC=69; else PC=70; fi
ACTION=jump; return
;;
68)
sht138="${R}"
R="${sht138}"; ACTION=ret; return
;;
69)
hp_cdr "${p0}"
sht140="${R}"
hp_car "${sht140}"
sht141="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht141}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=lquote
RPC=71; ACTION=call; return
;;
70)
hp_car "${p0}"
sht143="${R}"
if [ "${sht143}" = "S:string-length" ]; then PC=72; else PC=73; fi
ACTION=jump; return
;;
71)
sht142="${R}"
R="${sht142}"; ACTION=ret; return
;;
72)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lstrlen
RPC=74; ACTION=call; return
;;
73)
hp_car "${p0}"
sht145="${R}"
if [ "${sht145}" = "S:substring" ]; then PC=75; else PC=76; fi
ACTION=jump; return
;;
74)
sht144="${R}"
R="${sht144}"; ACTION=ret; return
;;
75)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lsubstr
RPC=77; ACTION=call; return
;;
76)
hp_car "${p0}"
sht147="${R}"
if [ "${sht147}" = "S:symbol->string" ]; then PC=78; else PC=79; fi
ACTION=jump; return
;;
77)
sht146="${R}"
R="${sht146}"; ACTION=ret; return
;;
78)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lretag
RPC=80; ACTION=call; return
;;
79)
hp_car "${p0}"
sht149="${R}"
if [ "${sht149}" = "S:number->string" ]; then PC=81; else PC=82; fi
ACTION=jump; return
;;
80)
sht148="${R}"
R="${sht148}"; ACTION=ret; return
;;
81)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lretag
RPC=83; ACTION=call; return
;;
82)
hp_car "${p0}"
sht151="${R}"
if [ "${sht151}" = "S:dq" ]; then PC=84; else PC=85; fi
ACTION=jump; return
;;
83)
sht150="${R}"
R="${sht150}"; ACTION=ret; return
;;
84)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
CALLEE=tmpn
RPC=86; ACTION=call; return
;;
85)
hp_car "${p0}"
sht160="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht160}\""
CALLEE=builtinzzQ
RPC=90; ACTION=call; return
;;
86)
sht152="${R}"
sht153="${sht152}"
sht154="T:${sht153#??}=T:!BANG8!"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht153}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht154}\""
CALLEE=qset
RPC=87; ACTION=call; return
;;
87)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht153=\"\$F$((FP+NP+1))\""
sht155="${R}"
eval "F$((FP+NP+0))=\"\${sht153}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht155}\""
CALLEE=emit
RPC=88; ACTION=call; return
;;
88)
eval "sht153=\"\$F$((FP+NP+0))\""
sht156="${R}"
eval "F$((FP+NP+0))=\"\${sht153}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht156}\""
CALLEE=bkzzP
RPC=89; ACTION=call; return
;;
89)
eval "sht153=\"\$F$((FP+NP+0))\""
sht157="${R}"
eval "F$((FP+NP+0))=\"\${sht157}\""
eval "F$((FP+NP+1))=\"\${sht153}\""
hp_cons "S:val" "${sht153}"
eval "sht157=\"\$F$((FP+NP+0))\""
eval "sht153=\"\$F$((FP+NP+1))\""
sht158="${R}"
eval "F$((FP+NP+0))=\"\${sht153}\""
hp_cons "${sht157}" "${sht158}"
eval "sht153=\"\$F$((FP+NP+0))\""
sht159="${R}"
R="${sht159}"; ACTION=ret; return
;;
90)
sht161="${R}"
if [ "${sht161}" != NIL ]; then PC=91; else PC=92; fi
ACTION=jump; return
;;
91)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbuiltin
RPC=93; ACTION=call; return
;;
92)
hp_car "${p0}"
sht163="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht163}\""
CALLEE=tpredzzQ
RPC=94; ACTION=call; return
;;
93)
sht162="${R}"
R="${sht162}"; ACTION=ret; return
;;
94)
sht164="${R}"
if [ "${sht164}" != NIL ]; then PC=95; else PC=96; fi
ACTION=jump; return
;;
95)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="S:t"
eval "F$((NFP+1))=\"\$STGV\""
STGV="S:nil"
eval "F$((NFP+2))=\"\$STGV\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=97; ACTION=call; return
;;
96)
hp_cdr "${p0}"
sht166="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht166}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=98; ACTION=call; return
;;
97)
sht165="${R}"
R="${sht165}"; ACTION=ret; return
;;
98)
sht167="${R}"
sht168="${sht167}"
hp_car "${sht168}"
sht169="${R}"
eval "F$((FP+NP+0))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht169}\""
CALLEE=b_npc
RPC=99; ACTION=call; return
;;
99)
eval "sht168=\"\$F$((FP+NP+0))\""
sht170="${R}"
sht171="${sht170}"
hp_car "${p0}"
sht172="${R}"
sht173="T:${sht172#??}"
eval "F$((FP+NP+0))=\"\${sht171}\""
eval "F$((FP+NP+1))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht173}\""
CALLEE=mangle
RPC=100; ACTION=call; return
;;
100)
eval "sht171=\"\$F$((FP+NP+0))\""
eval "sht168=\"\$F$((FP+NP+1))\""
sht174="${R}"
sht175="${sht174}"
hp_car "${sht168}"
sht176="${R}"
eval "F$((FP+NP+0))=\"\${sht175}\""
eval "F$((FP+NP+1))=\"\${sht171}\""
eval "F$((FP+NP+2))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht176}\""
CALLEE=bnpczzP
RPC=101; ACTION=call; return
;;
101)
eval "sht175=\"\$F$((FP+NP+0))\""
eval "sht171=\"\$F$((FP+NP+1))\""
eval "sht168=\"\$F$((FP+NP+2))\""
sht177="${R}"
eval "F$((FP+NP+0))=\"\${sht175}\""
eval "F$((FP+NP+1))=\"\${sht171}\""
eval "F$((FP+NP+2))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht177}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=102; ACTION=call; return
;;
102)
eval "sht175=\"\$F$((FP+NP+0))\""
eval "sht171=\"\$F$((FP+NP+1))\""
eval "sht168=\"\$F$((FP+NP+2))\""
sht178="${R}"
eval "F$((FP+NP+0))=\"\${sht175}\""
eval "F$((FP+NP+1))=\"\${sht171}\""
eval "F$((FP+NP+2))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht178}\""
STGV="T:set /a NFP=!FT!"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=103; ACTION=call; return
;;
103)
eval "sht175=\"\$F$((FP+NP+0))\""
eval "sht171=\"\$F$((FP+NP+1))\""
eval "sht168=\"\$F$((FP+NP+2))\""
sht179="${R}"
sht180="${sht179}"
hp_cdr "${sht168}"
sht181="${R}"
eval "F$((FP+NP+0))=\"\${sht180}\""
eval "F$((FP+NP+1))=\"\${sht175}\""
eval "F$((FP+NP+2))=\"\${sht171}\""
eval "F$((FP+NP+3))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht180}\""
eval "F$((NFP+1))=\"\${sht181}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=104; ACTION=call; return
;;
104)
eval "sht180=\"\$F$((FP+NP+0))\""
eval "sht175=\"\$F$((FP+NP+1))\""
eval "sht171=\"\$F$((FP+NP+2))\""
eval "sht168=\"\$F$((FP+NP+3))\""
sht182="${R}"
sht183="${sht182}"
sht184="T:${sht175#??}${G_DQ#??}"
sht185="T:CALLEE=${sht184#??}"
sht186="T:${G_DQ#??}${sht185#??}"
sht187="T:set ${sht186#??}"
eval "F$((FP+NP+0))=\"\${sht183}\""
eval "F$((FP+NP+1))=\"\${sht180}\""
eval "F$((FP+NP+2))=\"\${sht175}\""
eval "F$((FP+NP+3))=\"\${sht171}\""
eval "F$((FP+NP+4))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht183}\""
eval "F$((NFP+1))=\"\${sht187}\""
CALLEE=emit
RPC=105; ACTION=call; return
;;
105)
eval "sht183=\"\$F$((FP+NP+0))\""
eval "sht180=\"\$F$((FP+NP+1))\""
eval "sht175=\"\$F$((FP+NP+2))\""
eval "sht171=\"\$F$((FP+NP+3))\""
eval "sht168=\"\$F$((FP+NP+4))\""
sht188="${R}"
sht189="${sht188}"
sht190="T:${sht171#??}"
sht191="T:${sht190#??}${G_DQ#??}"
sht192="T:RPC=${sht191#??}"
sht193="T:${G_DQ#??}${sht192#??}"
sht194="T:set ${sht193#??}"
eval "F$((FP+NP+0))=\"\${sht189}\""
eval "F$((FP+NP+1))=\"\${sht183}\""
eval "F$((FP+NP+2))=\"\${sht180}\""
eval "F$((FP+NP+3))=\"\${sht175}\""
eval "F$((FP+NP+4))=\"\${sht171}\""
eval "F$((FP+NP+5))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht189}\""
eval "F$((NFP+1))=\"\${sht194}\""
CALLEE=emit
RPC=106; ACTION=call; return
;;
106)
eval "sht189=\"\$F$((FP+NP+0))\""
eval "sht183=\"\$F$((FP+NP+1))\""
eval "sht180=\"\$F$((FP+NP+2))\""
eval "sht175=\"\$F$((FP+NP+3))\""
eval "sht171=\"\$F$((FP+NP+4))\""
eval "sht168=\"\$F$((FP+NP+5))\""
sht195="${R}"
sht196="${sht195}"
sht197="T:${G_DQ#??} & goto :eof"
sht198="T:ACTION=call${sht197#??}"
sht199="T:${G_DQ#??}${sht198#??}"
sht200="T:set ${sht199#??}"
eval "F$((FP+NP+0))=\"\${sht196}\""
eval "F$((FP+NP+1))=\"\${sht189}\""
eval "F$((FP+NP+2))=\"\${sht183}\""
eval "F$((FP+NP+3))=\"\${sht180}\""
eval "F$((FP+NP+4))=\"\${sht175}\""
eval "F$((FP+NP+5))=\"\${sht171}\""
eval "F$((FP+NP+6))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht196}\""
eval "F$((NFP+1))=\"\${sht200}\""
CALLEE=emit
RPC=107; ACTION=call; return
;;
107)
eval "sht196=\"\$F$((FP+NP+0))\""
eval "sht189=\"\$F$((FP+NP+1))\""
eval "sht183=\"\$F$((FP+NP+2))\""
eval "sht180=\"\$F$((FP+NP+3))\""
eval "sht175=\"\$F$((FP+NP+4))\""
eval "sht171=\"\$F$((FP+NP+5))\""
eval "sht168=\"\$F$((FP+NP+6))\""
sht201="${R}"
sht202="${sht201}"
eval "F$((FP+NP+0))=\"\${sht202}\""
eval "F$((FP+NP+1))=\"\${sht196}\""
eval "F$((FP+NP+2))=\"\${sht189}\""
eval "F$((FP+NP+3))=\"\${sht183}\""
eval "F$((FP+NP+4))=\"\${sht180}\""
eval "F$((FP+NP+5))=\"\${sht175}\""
eval "F$((FP+NP+6))=\"\${sht171}\""
eval "F$((FP+NP+7))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht202}\""
eval "F$((NFP+1))=\"\${sht171}\""
CALLEE=switch
RPC=108; ACTION=call; return
;;
108)
eval "sht202=\"\$F$((FP+NP+0))\""
eval "sht196=\"\$F$((FP+NP+1))\""
eval "sht189=\"\$F$((FP+NP+2))\""
eval "sht183=\"\$F$((FP+NP+3))\""
eval "sht180=\"\$F$((FP+NP+4))\""
eval "sht175=\"\$F$((FP+NP+5))\""
eval "sht171=\"\$F$((FP+NP+6))\""
eval "sht168=\"\$F$((FP+NP+7))\""
sht203="${R}"
sht204="${sht203}"
eval "F$((FP+NP+0))=\"\${sht204}\""
eval "F$((FP+NP+1))=\"\${sht202}\""
eval "F$((FP+NP+2))=\"\${sht196}\""
eval "F$((FP+NP+3))=\"\${sht189}\""
eval "F$((FP+NP+4))=\"\${sht183}\""
eval "F$((FP+NP+5))=\"\${sht180}\""
eval "F$((FP+NP+6))=\"\${sht175}\""
eval "F$((FP+NP+7))=\"\${sht171}\""
eval "F$((FP+NP+8))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht204}\""
CALLEE=tmpn
RPC=109; ACTION=call; return
;;
109)
eval "sht204=\"\$F$((FP+NP+0))\""
eval "sht202=\"\$F$((FP+NP+1))\""
eval "sht196=\"\$F$((FP+NP+2))\""
eval "sht189=\"\$F$((FP+NP+3))\""
eval "sht183=\"\$F$((FP+NP+4))\""
eval "sht180=\"\$F$((FP+NP+5))\""
eval "sht175=\"\$F$((FP+NP+6))\""
eval "sht171=\"\$F$((FP+NP+7))\""
eval "sht168=\"\$F$((FP+NP+8))\""
sht205="${R}"
sht206="${sht205}"
eval "F$((FP+NP+0))=\"\${sht206}\""
eval "F$((FP+NP+1))=\"\${sht204}\""
eval "F$((FP+NP+2))=\"\${sht202}\""
eval "F$((FP+NP+3))=\"\${sht196}\""
eval "F$((FP+NP+4))=\"\${sht189}\""
eval "F$((FP+NP+5))=\"\${sht183}\""
eval "F$((FP+NP+6))=\"\${sht180}\""
eval "F$((FP+NP+7))=\"\${sht175}\""
eval "F$((FP+NP+8))=\"\${sht171}\""
eval "F$((FP+NP+9))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht204}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=110; ACTION=call; return
;;
110)
eval "sht206=\"\$F$((FP+NP+0))\""
eval "sht204=\"\$F$((FP+NP+1))\""
eval "sht202=\"\$F$((FP+NP+2))\""
eval "sht196=\"\$F$((FP+NP+3))\""
eval "sht189=\"\$F$((FP+NP+4))\""
eval "sht183=\"\$F$((FP+NP+5))\""
eval "sht180=\"\$F$((FP+NP+6))\""
eval "sht175=\"\$F$((FP+NP+7))\""
eval "sht171=\"\$F$((FP+NP+8))\""
eval "sht168=\"\$F$((FP+NP+9))\""
sht207="${R}"
sht208="T:${sht206#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht207}\""
eval "F$((FP+NP+1))=\"\${sht206}\""
eval "F$((FP+NP+2))=\"\${sht204}\""
eval "F$((FP+NP+3))=\"\${sht202}\""
eval "F$((FP+NP+4))=\"\${sht196}\""
eval "F$((FP+NP+5))=\"\${sht189}\""
eval "F$((FP+NP+6))=\"\${sht183}\""
eval "F$((FP+NP+7))=\"\${sht180}\""
eval "F$((FP+NP+8))=\"\${sht175}\""
eval "F$((FP+NP+9))=\"\${sht171}\""
eval "F$((FP+NP+10))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht208}\""
CALLEE=qset
RPC=111; ACTION=call; return
;;
111)
eval "sht207=\"\$F$((FP+NP+0))\""
eval "sht206=\"\$F$((FP+NP+1))\""
eval "sht204=\"\$F$((FP+NP+2))\""
eval "sht202=\"\$F$((FP+NP+3))\""
eval "sht196=\"\$F$((FP+NP+4))\""
eval "sht189=\"\$F$((FP+NP+5))\""
eval "sht183=\"\$F$((FP+NP+6))\""
eval "sht180=\"\$F$((FP+NP+7))\""
eval "sht175=\"\$F$((FP+NP+8))\""
eval "sht171=\"\$F$((FP+NP+9))\""
eval "sht168=\"\$F$((FP+NP+10))\""
sht209="${R}"
eval "F$((FP+NP+0))=\"\${sht206}\""
eval "F$((FP+NP+1))=\"\${sht204}\""
eval "F$((FP+NP+2))=\"\${sht202}\""
eval "F$((FP+NP+3))=\"\${sht196}\""
eval "F$((FP+NP+4))=\"\${sht189}\""
eval "F$((FP+NP+5))=\"\${sht183}\""
eval "F$((FP+NP+6))=\"\${sht180}\""
eval "F$((FP+NP+7))=\"\${sht175}\""
eval "F$((FP+NP+8))=\"\${sht171}\""
eval "F$((FP+NP+9))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht207}\""
eval "F$((NFP+1))=\"\${sht209}\""
CALLEE=emit
RPC=112; ACTION=call; return
;;
112)
eval "sht206=\"\$F$((FP+NP+0))\""
eval "sht204=\"\$F$((FP+NP+1))\""
eval "sht202=\"\$F$((FP+NP+2))\""
eval "sht196=\"\$F$((FP+NP+3))\""
eval "sht189=\"\$F$((FP+NP+4))\""
eval "sht183=\"\$F$((FP+NP+5))\""
eval "sht180=\"\$F$((FP+NP+6))\""
eval "sht175=\"\$F$((FP+NP+7))\""
eval "sht171=\"\$F$((FP+NP+8))\""
eval "sht168=\"\$F$((FP+NP+9))\""
sht210="${R}"
eval "F$((FP+NP+0))=\"\${sht210}\""
eval "F$((FP+NP+1))=\"\${sht206}\""
eval "F$((FP+NP+2))=\"\${sht204}\""
eval "F$((FP+NP+3))=\"\${sht202}\""
eval "F$((FP+NP+4))=\"\${sht196}\""
eval "F$((FP+NP+5))=\"\${sht189}\""
eval "F$((FP+NP+6))=\"\${sht183}\""
eval "F$((FP+NP+7))=\"\${sht180}\""
eval "F$((FP+NP+8))=\"\${sht175}\""
eval "F$((FP+NP+9))=\"\${sht171}\""
eval "F$((FP+NP+10))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=113; ACTION=call; return
;;
113)
eval "sht210=\"\$F$((FP+NP+0))\""
eval "sht206=\"\$F$((FP+NP+1))\""
eval "sht204=\"\$F$((FP+NP+2))\""
eval "sht202=\"\$F$((FP+NP+3))\""
eval "sht196=\"\$F$((FP+NP+4))\""
eval "sht189=\"\$F$((FP+NP+5))\""
eval "sht183=\"\$F$((FP+NP+6))\""
eval "sht180=\"\$F$((FP+NP+7))\""
eval "sht175=\"\$F$((FP+NP+8))\""
eval "sht171=\"\$F$((FP+NP+9))\""
eval "sht168=\"\$F$((FP+NP+10))\""
sht211="${R}"
eval "F$((FP+NP+0))=\"\${sht206}\""
eval "F$((FP+NP+1))=\"\${sht204}\""
eval "F$((FP+NP+2))=\"\${sht202}\""
eval "F$((FP+NP+3))=\"\${sht196}\""
eval "F$((FP+NP+4))=\"\${sht189}\""
eval "F$((FP+NP+5))=\"\${sht183}\""
eval "F$((FP+NP+6))=\"\${sht180}\""
eval "F$((FP+NP+7))=\"\${sht175}\""
eval "F$((FP+NP+8))=\"\${sht171}\""
eval "F$((FP+NP+9))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht210}\""
eval "F$((NFP+1))=\"\${sht211}\""
CALLEE=bsm
RPC=114; ACTION=call; return
;;
114)
eval "sht206=\"\$F$((FP+NP+0))\""
eval "sht204=\"\$F$((FP+NP+1))\""
eval "sht202=\"\$F$((FP+NP+2))\""
eval "sht196=\"\$F$((FP+NP+3))\""
eval "sht189=\"\$F$((FP+NP+4))\""
eval "sht183=\"\$F$((FP+NP+5))\""
eval "sht180=\"\$F$((FP+NP+6))\""
eval "sht175=\"\$F$((FP+NP+7))\""
eval "sht171=\"\$F$((FP+NP+8))\""
eval "sht168=\"\$F$((FP+NP+9))\""
sht212="${R}"
eval "F$((FP+NP+0))=\"\${sht206}\""
eval "F$((FP+NP+1))=\"\${sht204}\""
eval "F$((FP+NP+2))=\"\${sht202}\""
eval "F$((FP+NP+3))=\"\${sht196}\""
eval "F$((FP+NP+4))=\"\${sht189}\""
eval "F$((FP+NP+5))=\"\${sht183}\""
eval "F$((FP+NP+6))=\"\${sht180}\""
eval "F$((FP+NP+7))=\"\${sht175}\""
eval "F$((FP+NP+8))=\"\${sht171}\""
eval "F$((FP+NP+9))=\"\${sht168}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht212}\""
CALLEE=bkzzP
RPC=115; ACTION=call; return
;;
115)
eval "sht206=\"\$F$((FP+NP+0))\""
eval "sht204=\"\$F$((FP+NP+1))\""
eval "sht202=\"\$F$((FP+NP+2))\""
eval "sht196=\"\$F$((FP+NP+3))\""
eval "sht189=\"\$F$((FP+NP+4))\""
eval "sht183=\"\$F$((FP+NP+5))\""
eval "sht180=\"\$F$((FP+NP+6))\""
eval "sht175=\"\$F$((FP+NP+7))\""
eval "sht171=\"\$F$((FP+NP+8))\""
eval "sht168=\"\$F$((FP+NP+9))\""
sht213="${R}"
eval "F$((FP+NP+0))=\"\${sht213}\""
eval "F$((FP+NP+1))=\"\${sht206}\""
eval "F$((FP+NP+2))=\"\${sht204}\""
eval "F$((FP+NP+3))=\"\${sht202}\""
eval "F$((FP+NP+4))=\"\${sht196}\""
eval "F$((FP+NP+5))=\"\${sht189}\""
eval "F$((FP+NP+6))=\"\${sht183}\""
eval "F$((FP+NP+7))=\"\${sht180}\""
eval "F$((FP+NP+8))=\"\${sht175}\""
eval "F$((FP+NP+9))=\"\${sht171}\""
eval "F$((FP+NP+10))=\"\${sht168}\""
hp_cons "S:val" "${sht206}"
eval "sht213=\"\$F$((FP+NP+0))\""
eval "sht206=\"\$F$((FP+NP+1))\""
eval "sht204=\"\$F$((FP+NP+2))\""
eval "sht202=\"\$F$((FP+NP+3))\""
eval "sht196=\"\$F$((FP+NP+4))\""
eval "sht189=\"\$F$((FP+NP+5))\""
eval "sht183=\"\$F$((FP+NP+6))\""
eval "sht180=\"\$F$((FP+NP+7))\""
eval "sht175=\"\$F$((FP+NP+8))\""
eval "sht171=\"\$F$((FP+NP+9))\""
eval "sht168=\"\$F$((FP+NP+10))\""
sht214="${R}"
eval "F$((FP+NP+0))=\"\${sht206}\""
eval "F$((FP+NP+1))=\"\${sht204}\""
eval "F$((FP+NP+2))=\"\${sht202}\""
eval "F$((FP+NP+3))=\"\${sht196}\""
eval "F$((FP+NP+4))=\"\${sht189}\""
eval "F$((FP+NP+5))=\"\${sht183}\""
eval "F$((FP+NP+6))=\"\${sht180}\""
eval "F$((FP+NP+7))=\"\${sht175}\""
eval "F$((FP+NP+8))=\"\${sht171}\""
eval "F$((FP+NP+9))=\"\${sht168}\""
hp_cons "${sht213}" "${sht214}"
eval "sht206=\"\$F$((FP+NP+0))\""
eval "sht204=\"\$F$((FP+NP+1))\""
eval "sht202=\"\$F$((FP+NP+2))\""
eval "sht196=\"\$F$((FP+NP+3))\""
eval "sht189=\"\$F$((FP+NP+4))\""
eval "sht183=\"\$F$((FP+NP+5))\""
eval "sht180=\"\$F$((FP+NP+6))\""
eval "sht175=\"\$F$((FP+NP+7))\""
eval "sht171=\"\$F$((FP+NP+8))\""
eval "sht168=\"\$F$((FP+NP+9))\""
sht215="${R}"
R="${sht215}"; ACTION=ret; return
;;
esac; }
SIZE_ltbegin=6
ltbegin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_ltbegin))
NP=6
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltail
RPC=3; ACTION=call; return
;;
2)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=4; ACTION=call; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht4="${R}"
sht5="${sht4}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${sht5}"
sht7="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht7}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_ltail=15
ltail() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_ltail))
NP=6
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:begin" ]; then
sht2="S:t"
else
sht2="NIL"
fi
sht0="${sht2}"
PC=3; ACTION=jump; return
;;
2)
sht0="NIL"
PC=3; ACTION=jump; return
;;
3)
if [ "${sht0}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltbegin
RPC=6; ACTION=call; return
;;
5)
if [ "${p0#P:}" != "${p0}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
6)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
7)
hp_car "${p0}"
sht6="${R}"
if [ "${sht6}" = "${p2}" ]; then
sht7="S:t"
else
sht7="NIL"
fi
sht5="${sht7}"
PC=9; ACTION=jump; return
;;
8)
sht5="NIL"
PC=9; ACTION=jump; return
;;
9)
if [ "${sht5}" != NIL ]; then PC=10; else PC=11; fi
ACTION=jump; return
;;
10)
hp_cdr "${p0}"
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=largs
RPC=12; ACTION=call; return
;;
11)
if [ "${p0#P:}" != "${p0}" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
12)
sht9="${R}"
sht10="${sht9}"
hp_car "${sht10}"
sht11="${R}"
hp_cdr "${sht10}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"\${sht12}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=setparams
RPC=13; ACTION=call; return
;;
13)
eval "sht10=\"\$F$((FP+NP+0))\""
sht13="${R}"
sht14="T:${G_DQ#??} & goto :eof"
sht15="T:ACTION=tail${sht14#??}"
sht16="T:${G_DQ#??}${sht15#??}"
sht17="T: & set ${sht16#??}"
sht18="T:${G_DQ#??}${sht17#??}"
sht19="T:PC=0${sht18#??}"
sht20="T:${G_DQ#??}${sht19#??}"
sht21="T:set ${sht20#??}"
eval "F$((FP+NP+0))=\"\${sht10}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
eval "F$((NFP+1))=\"\${sht21}\""
CALLEE=emit
RPC=14; ACTION=call; return
;;
14)
eval "sht10=\"\$F$((FP+NP+0))\""
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
15)
hp_car "${p0}"
sht24="${R}"
if [ "${sht24}" = "S:if" ]; then
sht25="S:t"
else
sht25="NIL"
fi
sht23="${sht25}"
PC=17; ACTION=jump; return
;;
16)
sht23="NIL"
PC=17; ACTION=jump; return
;;
17)
if [ "${sht23}" != NIL ]; then PC=18; else PC=19; fi
ACTION=jump; return
;;
18)
hp_cdr "${p0}"
sht26="${R}"
hp_car "${sht26}"
sht27="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=ctest
RPC=20; ACTION=call; return
;;
19)
if [ "${p0#P:}" != "${p0}" ]; then PC=33; else PC=34; fi
ACTION=jump; return
;;
20)
sht28="${R}"
sht29="${sht28}"
hp_car "${sht29}"
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
CALLEE=b_npc
RPC=21; ACTION=call; return
;;
21)
eval "sht29=\"\$F$((FP+NP+0))\""
sht31="${R}"
sht32="${sht31}"
hp_car "${sht29}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
CALLEE=b_npc
RPC=22; ACTION=call; return
;;
22)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
sht34="${R}"
sht35="I:$(( ${sht34#??} + 1 ))"
sht36="${sht35}"
hp_car "${sht29}"
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
CALLEE=bnpczzP
RPC=23; ACTION=call; return
;;
23)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht38}\""
CALLEE=bnpczzP
RPC=24; ACTION=call; return
;;
24)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht39="${R}"
hp_cdr "${sht29}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
eval "F$((NFP+1))=\"\${sht32}\""
CALLEE=ifjump
RPC=25; ACTION=call; return
;;
25)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht41}\""
CALLEE=emit
RPC=26; ACTION=call; return
;;
26)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
CALLEE=jumpto
RPC=27; ACTION=call; return
;;
27)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht36}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
eval "F$((NFP+1))=\"\${sht43}\""
CALLEE=emit
RPC=28; ACTION=call; return
;;
28)
eval "sht36=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
sht44="${R}"
sht45="${sht44}"
hp_cdr "${p0}"
sht46="${R}"
hp_cdr "${sht46}"
sht47="${R}"
hp_car "${sht47}"
sht48="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht48}\""
eval "F$((FP+NP+4))=\"\${sht45}\""
eval "F$((FP+NP+5))=\"\${sht36}\""
eval "F$((FP+NP+6))=\"\${sht32}\""
eval "F$((FP+NP+7))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht45}\""
eval "F$((NFP+1))=\"\${sht32}\""
CALLEE=switch
RPC=29; ACTION=call; return
;;
29)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht48=\"\$F$((FP+NP+3))\""
eval "sht45=\"\$F$((FP+NP+4))\""
eval "sht36=\"\$F$((FP+NP+5))\""
eval "sht32=\"\$F$((FP+NP+6))\""
eval "sht29=\"\$F$((FP+NP+7))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht45}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${sht49}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltail
RPC=30; ACTION=call; return
;;
30)
eval "sht45=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht50="${R}"
sht51="${sht50}"
eval "F$((FP+NP+0))=\"\${sht51}\""
eval "F$((FP+NP+1))=\"\${sht45}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=31; ACTION=call; return
;;
31)
eval "sht51=\"\$F$((FP+NP+0))\""
eval "sht45=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
sht52="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht52}\""
eval "F$((FP+NP+4))=\"\${sht51}\""
eval "F$((FP+NP+5))=\"\${sht45}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
eval "F$((FP+NP+7))=\"\${sht32}\""
eval "F$((FP+NP+8))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
eval "F$((NFP+1))=\"\${sht36}\""
CALLEE=switch
RPC=32; ACTION=call; return
;;
32)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht52=\"\$F$((FP+NP+3))\""
eval "sht51=\"\$F$((FP+NP+4))\""
eval "sht45=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
eval "sht32=\"\$F$((FP+NP+7))\""
eval "sht29=\"\$F$((FP+NP+8))\""
sht53="${R}"
eval "F$((FP+0))=\"\${sht52}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht53}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
33)
hp_car "${p0}"
sht55="${R}"
if [ "${sht55}" = "S:cond" ]; then
sht56="S:t"
else
sht56="NIL"
fi
sht54="${sht56}"
PC=35; ACTION=jump; return
;;
34)
sht54="NIL"
PC=35; ACTION=jump; return
;;
35)
if [ "${sht54}" != NIL ]; then PC=36; else PC=37; fi
ACTION=jump; return
;;
36)
hp_cdr "${p0}"
sht57="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht57}\""
CALLEE=cond_zzGif
RPC=38; ACTION=call; return
;;
37)
if [ "${p0#P:}" != "${p0}" ]; then PC=39; else PC=40; fi
ACTION=jump; return
;;
38)
sht58="${R}"
eval "F$((FP+0))=\"\${sht58}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
39)
hp_car "${p0}"
sht60="${R}"
if [ "${sht60}" = "S:let" ]; then
sht61="S:t"
else
sht61="NIL"
fi
sht59="${sht61}"
PC=41; ACTION=jump; return
;;
40)
sht59="NIL"
PC=41; ACTION=jump; return
;;
41)
if [ "${sht59}" != NIL ]; then PC=42; else PC=43; fi
ACTION=jump; return
;;
42)
hp_cdr "${p0}"
sht62="${R}"
hp_car "${sht62}"
sht63="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht63}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lbinds
RPC=44; ACTION=call; return
;;
43)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=45; ACTION=call; return
;;
44)
sht64="${R}"
sht65="${sht64}"
hp_cdr "${p0}"
sht66="${R}"
hp_cdr "${sht66}"
sht67="${R}"
hp_car "${sht67}"
sht68="${R}"
hp_cdr "${sht65}"
sht69="${R}"
hp_car "${sht69}"
sht70="${R}"
hp_car "${sht65}"
sht71="${R}"
hp_cdr "${sht65}"
sht72="${R}"
hp_cdr "${sht72}"
sht73="${R}"
eval "F$((FP+0))=\"\${sht68}\""
eval "F$((FP+1))=\"\${sht70}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht71}\""
eval "F$((FP+5))=\"\${sht73}\""
PC=0; ACTION=tail; return
;;
45)
sht74="${R}"
sht75="${sht74}"
hp_car "${sht75}"
sht76="${R}"
hp_cdr "${sht75}"
sht77="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht76}\""
eval "F$((FP+NP+2))=\"\${sht75}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht77}\""
CALLEE=vref
RPC=46; ACTION=call; return
;;
46)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht76=\"\$F$((FP+NP+1))\""
eval "sht75=\"\$F$((FP+NP+2))\""
sht78="${R}"
sht79="T:${G_DQ#??} & goto :eof"
sht80="T:ACTION=ret${sht79#??}"
sht81="T:${G_DQ#??}${sht80#??}"
sht82="T: & set ${sht81#??}"
sht83="T:${G_DQ#??}${sht82#??}"
sht84="T:${sht78#??}${sht83#??}"
sht85="T:R=${sht84#??}"
sht86="T:${G_DQ#??}${sht85#??}"
sht87="T:set ${sht86#??}"
eval "F$((FP+NP+0))=\"\${sht75}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht76}\""
eval "F$((NFP+1))=\"\${sht87}\""
CALLEE=emit
RPC=47; ACTION=call; return
;;
47)
eval "sht75=\"\$F$((FP+NP+0))\""
sht88="${R}"
R="${sht88}"; ACTION=ret; return
;;
esac; }
SIZE_pmap_fr=3
pmap_fr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_pmap_fr))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
sht1="T:${p1#??}"
sht2="T:p${sht1#??}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
sht5="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${sht5}\""
CALLEE=pmap_fr
RPC=3; ACTION=call; return
;;
3)
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_ploads=3
ploads() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_ploads))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
if [ ${p1#??} -eq 0 ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht0="T:p0=%%F!FP!%%${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:call set ${sht1#??}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"I:1\""
CALLEE=ploads
RPC=5; ACTION=call; return
;;
4)
sht6="T:${p1#??}"
sht7="T:${p1#??}"
sht8="T:=%%F!_i!%%${G_DQ#??}"
sht9="T:${sht7#??}${sht8#??}"
sht10="T:p${sht9#??}"
sht11="T:${G_DQ#??}${sht10#??}"
sht12="T: & call set ${sht11#??}"
sht13="T:${sht6#??}${sht12#??}"
sht14="T:set /a _i=!FP!+${sht13#??}"
hp_cdr "${p0}"
sht15="${R}"
sht16="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht16}\""
CALLEE=ploads
RPC=6; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
6)
eval "sht14=\"\$F$((FP+NP+0))\""
sht17="${R}"
hp_cons "${sht14}" "${sht17}"
sht18="${R}"
R="${sht18}"; ACTION=ret; return
;;
esac; }
SIZE_blkget=2
blkget() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_blkget))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "${p1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht4="${R}"
eval "F$((FP+0))=\"\${sht4}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_caseblocks=4
caseblocks() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_caseblocks))
NP=3
case $PC in
0)
if [ ${p1#??} -eq ${p2#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
sht0="T:${p1#??}"
sht1="T::_pc${sht0#??}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=blkget
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht1}" "${sht2}"
sht3="${R}"
sht4="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht4}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=caseblocks
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${sht5}\""
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_compile_fn=14
compile_fn() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_compile_fn))
NP=6
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
CALLEE=lenl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=pmap_fr
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
sht3="${sht2}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${p3}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
CALLEE=mkb
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "p3=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht1}\""
eval "F$((NFP+4))=\"\${sht4}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltail
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht5="${R}"
sht6="${sht5}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=b_pc
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=b_cur
RPC=6; ACTION=call; return
;;
6)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=7; ACTION=call; return
;;
7)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht7}" "${sht9}"
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=b_blk
RPC=8; ACTION=call; return
;;
8)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht10}" "${sht11}"
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht12="${R}"
sht13="${sht12}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=b_smax
RPC=9; ACTION=call; return
;;
9)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht14="${R}"
sht15="I:$(( ${sht1#??} + ${sht14#??} ))"
sht16="${sht15}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=10; ACTION=call; return
;;
10)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht17="${R}"
sht18="T:${sht16#??}"
sht19="T:set /a FT=!FP!+${sht18#??}"
sht20="T:${sht1#??}"
sht21="T:NP=${sht20#??}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht17}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht13}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht17=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht13=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht17}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht13}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht22}" "NIL"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht17=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht13=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht13}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht19}" "${sht23}"
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht13=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
eval "F$((NFP+1))=\"\${sht24}\""
CALLEE=append
RPC=12; ACTION=call; return
;;
12)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht25="${R}"
sht26="${sht25}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht13}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht3}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=b_npc
RPC=13; ACTION=call; return
;;
13)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht13=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht3=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht13}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht13}\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"\${sht27}\""
eval "F$((NFP+4))=\"\${p1}\""
CALLEE=seg_files
RPC=14; ACTION=call; return
;;
14)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht13=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht13}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht28}" "${p4}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht13=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht29="${R}"
R="${sht29}"; ACTION=ret; return
;;
esac; }
SIZE_tst=2
tst() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tst))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:done"; ACTION=ret; return
;;
2)
if [ "${sht1#P:}" != "${sht1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
eval "F$((FP+NP+0))=\"\${sht1}\""
write_lines "T:out" "${sht1}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht3="I:$(( ${#sht1} - 2 ))"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_show_list=2
show_list() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_show_list))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=show
RPC=3; ACTION=call; return
;;
2)
hp_cdr "${p0}"
sht3="${R}"
if [ "${sht3#P:}" != "${sht3}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=show
RPC=6; ACTION=call; return
;;
5)
hp_car "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=show
RPC=8; ACTION=call; return
;;
6)
sht5="${R}"
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=show_list
RPC=7; ACTION=call; return
;;
7)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
sht8="T: ${sht7#??}"
sht9="T:${sht5#??}${sht8#??}"
R="${sht9}"; ACTION=ret; return
;;
8)
sht11="${R}"
hp_cdr "${p0}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=show
RPC=9; ACTION=call; return
;;
9)
eval "sht11=\"\$F$((FP+NP+0))\""
sht13="${R}"
sht14="T: . ${sht13#??}"
sht15="T:${sht11#??}${sht14#??}"
R="${sht15}"; ACTION=ret; return
;;
esac; }
SIZE_show=1
show() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_show))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:()"; ACTION=ret; return
;;
2)
if [ "${p0#I:}" != "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht0="T:${p0#??}"
R="${sht0}"; ACTION=ret; return
;;
4)
if [ "${p0#S:}" != "${p0}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
sht1="T:${p0#??}"
R="${sht1}"; ACTION=ret; return
;;
6)
if [ "${p0#T:}" != "${p0}" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
sht2="T:${p0#??}${G_DQ#??}"
sht3="T:${G_DQ#??}${sht2#??}"
R="${sht3}"; ACTION=ret; return
;;
8)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=show_list
RPC=9; ACTION=call; return
;;
9)
sht4="${R}"
sht5="T:${sht4#??})"
sht6="T:(${sht5#??}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_def_lambdazzQ=1
def_lambdazzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_def_lambdazzQ))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:define" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=5; ACTION=call; return
;;
4)
R="NIL"; ACTION=ret; return
;;
5)
sht1="${R}"
if [ "${sht1#P:}" != "${sht1}" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
7)
R="NIL"; ACTION=ret; return
;;
8)
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
if [ "${sht3}" = "S:lambda" ]; then
sht4="S:t"
else
sht4="NIL"
fi
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_resid_bind=2
resid_bind() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_resid_bind))
NP=1
case $PC in
0)
sht0="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=mangle
RPC=1; ACTION=call; return
;;
1)
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht1}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:make-compiled" "${sht2}"
eval "p0=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht3}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${p0}" "${sht4}"
sht5="${R}"
hp_cons "S:define" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_subst=4
subst() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_subst))
NP=3
case $PC in
0)
if [ "${p2}" = "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
if [ "${p2#P:}" != "${p2}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p2}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht0}\""
CALLEE=subst
RPC=5; ACTION=call; return
;;
4)
R="${p2}"; ACTION=ret; return
;;
5)
sht1="${R}"
hp_cdr "${p2}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht2}\""
CALLEE=subst
RPC=6; ACTION=call; return
;;
6)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_substzzS=5
substzzS() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_substzzS))
NP=3
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p2}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${p1}"
sht1="${R}"
hp_car "${p0}"
sht2="${R}"
hp_car "${p1}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=subst
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht1}\""
eval "F$((FP+2))=\"\${sht4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_refszzQ=2
refszzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_refszzQ))
NP=2
case $PC in
0)
if [ "${p1}" = "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p1#P:}" != "${p1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p1}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht0}\""
CALLEE=refszzQ
RPC=5; ACTION=call; return
;;
4)
R="NIL"; ACTION=ret; return
;;
5)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
R="S:t"; ACTION=ret; return
;;
7)
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_map_inline_expr=3
map_inline_expr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_map_inline_expr))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=inline_expr
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_expr
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_map_inline_form=3
map_inline_form() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_map_inline_form))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=inline_form
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_form
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_map_mexpand=2
map_mexpand() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_map_mexpand))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=mexpand
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=map_mexpand
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_map_show=2
map_show() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_map_show))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=show
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=map_show
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_inline_expr=5
inline_expr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_inline_expr))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=assoc
RPC=3; ACTION=call; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
3)
sht1="${R}"
sht2="${sht1}"
if [ "${sht2}" = NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_expr
RPC=6; ACTION=call; return
;;
5)
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=7; ACTION=call; return
;;
6)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht3}" "${sht5}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
7)
eval "sht2=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=map_inline_expr
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht9}\""
eval "F$((NFP+2))=\"\${sht10}\""
CALLEE=substzzS
RPC=10; ACTION=call; return
;;
10)
eval "sht2=\"\$F$((FP+NP+0))\""
sht11="${R}"
eval "F$((FP+0))=\"\${sht11}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_mk_tbl=3
mk_tbl() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mk_tbl))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=cadr
RPC=7; ACTION=call; return
;;
5)
sht2="NIL"
PC=6; ACTION=jump; return
;;
6)
if [ "${sht2}" != NIL ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
7)
sht4="${R}"
hp_car "${p0}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
8)
eval "sht4=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht4=\"\$F$((FP+NP+0))\""
sht7="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=refszzQ
RPC=10; ACTION=call; return
;;
10)
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=not
RPC=11; ACTION=call; return
;;
11)
sht9="${R}"
sht2="${sht9}"
PC=6; ACTION=jump; return
;;
12)
hp_car "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=cadr
RPC=14; ACTION=call; return
;;
13)
hp_cdr "${p0}"
sht24="${R}"
eval "F$((FP+0))=\"\${sht24}\""
PC=0; ACTION=tail; return
;;
14)
sht11="${R}"
hp_car "${p0}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=caddr
RPC=15; ACTION=call; return
;;
15)
eval "sht11=\"\$F$((FP+NP+0))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=cadr
RPC=16; ACTION=call; return
;;
16)
eval "sht11=\"\$F$((FP+NP+0))\""
sht14="${R}"
hp_car "${p0}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=caddr
RPC=17; ACTION=call; return
;;
17)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=caddr
RPC=18; ACTION=call; return
;;
18)
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
hp_cons "${sht17}" "NIL"
eval "sht14=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
hp_cons "${sht14}" "${sht18}"
eval "sht11=\"\$F$((FP+NP+0))\""
sht19="${R}"
hp_cons "${sht11}" "${sht19}"
sht20="${R}"
hp_cdr "${p0}"
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=mk_tbl
RPC=19; ACTION=call; return
;;
19)
eval "sht20=\"\$F$((FP+NP+0))\""
sht22="${R}"
hp_cons "${sht20}" "${sht22}"
sht23="${R}"
R="${sht23}"; ACTION=ret; return
;;
esac; }
SIZE_inline_form=4
inline_form() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_inline_form))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=def_lambdazzQ
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${sht0}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadr
RPC=4; ACTION=call; return
;;
3)
R="${p0}"; ACTION=ret; return
;;
4)
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=5; ACTION=call; return
;;
5)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
6)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=7; ACTION=call; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
8)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=inline_expr
RPC=9; ACTION=call; return
;;
9)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
hp_cons "${sht6}" "NIL"
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht3}" "${sht7}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "S:lambda" "${sht8}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht9}" "NIL"
eval "sht1=\"\$F$((FP+NP+0))\""
sht10="${R}"
hp_cons "${sht1}" "${sht10}"
sht11="${R}"
hp_cons "S:define" "${sht11}"
sht12="${R}"
R="${sht12}"; ACTION=ret; return
;;
esac; }
SIZE_inline_program=2
inline_program() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_inline_program))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=mk_tbl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht1}\""
CALLEE=map_inline_form
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_cond_zzGif=3
cond_zzGif() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cond_zzGif))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:nil"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "S:t" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=5; ACTION=call; return
;;
4)
hp_car "${p0}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
hp_car "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
6)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=cond_zzGif
RPC=7; ACTION=call; return
;;
7)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
hp_cons "${sht9}" "NIL"
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "${sht7}" "${sht10}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht11="${R}"
hp_cons "${sht5}" "${sht11}"
sht12="${R}"
hp_cons "S:if" "${sht12}"
sht13="${R}"
R="${sht13}"; ACTION=ret; return
;;
esac; }
SIZE_str_zzGapp=2
str_zzGapp() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_str_zzGapp))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=str_zzGapp
RPC=5; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:string-append" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_list_zzGcons=2
list_zzGcons() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_list_zzGcons))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:nil"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=list_zzGcons
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${sht2}" "NIL"
eval "sht0=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht0}" "${sht3}"
sht4="${R}"
hp_cons "S:cons" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_mexpand=3
mexpand() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mexpand))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
3)
R="${p0}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:cond" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cond_zzGif
RPC=7; ACTION=call; return
;;
6)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:str" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
sht3="${R}"
eval "F$((FP+0))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
8)
hp_cdr "${p0}"
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=map_mexpand
RPC=10; ACTION=call; return
;;
9)
hp_car "${p0}"
sht8="${R}"
if [ "${sht8}" = "S:list" ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
10)
sht6="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=str_zzGapp
RPC=11; ACTION=call; return
;;
11)
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
12)
hp_cdr "${p0}"
sht9="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=map_mexpand
RPC=14; ACTION=call; return
;;
13)
hp_car "${p0}"
sht12="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=mexpand
RPC=16; ACTION=call; return
;;
14)
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=list_zzGcons
RPC=15; ACTION=call; return
;;
15)
sht11="${R}"
R="${sht11}"; ACTION=ret; return
;;
16)
sht13="${R}"
sht14="${sht13}"
hp_cdr "${p0}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=mexpand
RPC=17; ACTION=call; return
;;
17)
eval "sht14=\"\$F$((FP+NP+0))\""
sht16="${R}"
sht17="${sht16}"
hp_car "${p0}"
sht18="${R}"
if [ "${sht14}" = "${sht18}" ]; then PC=18; else PC=19; fi
ACTION=jump; return
;;
18)
hp_cdr "${p0}"
sht20="${R}"
if [ "${sht17}" = "${sht20}" ]; then
sht21="S:t"
else
sht21="NIL"
fi
sht19="${sht21}"
PC=20; ACTION=jump; return
;;
19)
sht19="NIL"
PC=20; ACTION=jump; return
;;
20)
if [ "${sht19}" != NIL ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
R="${p0}"; ACTION=ret; return
;;
22)
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
hp_cons "${sht14}" "${sht17}"
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
esac; }
SIZE_mexpand_program=1
mexpand_program() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mexpand_program))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=map_mexpand
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_concat=2
concat() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_concat))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=concat
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht2}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_cp=9
cp() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_cp))
NP=5
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:done"; ACTION=ret; return
;;
2)
gc
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht2="${R}"
if [ "${sht2}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_car "${p0}"
sht29="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
CALLEE=atom_constzzQ
RPC=18; ACTION=call; return
;;
6)
sht4="${R}"
sht5="T:${sht4#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=mangle
RPC=7; ACTION=call; return
;;
7)
sht6="${R}"
sht7="${sht6}"
hp_car "${p0}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=cadr
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_car "${p0}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=cadr
RPC=10; ACTION=call; return
;;
10)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht12="${R}"
hp_car "${p0}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=caddr
RPC=11; ACTION=call; return
;;
11)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
CALLEE=caddr
RPC=12; ACTION=call; return
;;
12)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
eval "F$((NFP+1))=\"\${sht7}\""
eval "F$((NFP+2))=\"\${sht12}\""
eval "F$((NFP+3))=\"\${sht15}\""
eval "F$((NFP+4))=\"\${p3}\""
eval "F$((NFP+5))=\"\${p4}\""
CALLEE=compile_fn
RPC=13; ACTION=call; return
;;
13)
eval "sht7=\"\$F$((FP+NP+0))\""
sht16="${R}"
sht17="${sht16}"
hp_cdr "${sht17}"
sht18="${R}"
sht19="${sht18}"
hp_car "${sht17}"
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht17}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=write_segs
RPC=14; ACTION=call; return
;;
14)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht17=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht21="${R}"
hp_car "${p0}"
sht22="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht17}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
CALLEE=cadr
RPC=15; ACTION=call; return
;;
15)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht17=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht17}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=resid_bind
RPC=16; ACTION=call; return
;;
16)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht17=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht17}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
CALLEE=show
RPC=17; ACTION=call; return
;;
17)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht17=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht25="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht17}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht25}" "NIL"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht17=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht17}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
append_lines "${p2}" "${sht26}"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht17=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht27="${R}"
hp_cdr "${p0}"
sht28="${R}"
eval "F$((FP+0))=\"\${sht28}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht19}\""
eval "F$((FP+4))=\"\${p4}\""
PC=0; ACTION=tail; return
;;
18)
sht30="${R}"
if [ "${sht30}" != NIL ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
hp_cdr "${p0}"
sht31="${R}"
eval "F$((FP+0))=\"\${sht31}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
PC=0; ACTION=tail; return
;;
20)
hp_car "${p0}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
CALLEE=show
RPC=21; ACTION=call; return
;;
21)
eval "p2=\"\$F$((FP+NP+0))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "${sht33}" "NIL"
eval "p2=\"\$F$((FP+NP+0))\""
sht34="${R}"
append_lines "${p2}" "${sht34}"
sht35="${R}"
hp_cdr "${p0}"
sht36="${R}"
eval "F$((FP+0))=\"\${sht36}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_atom_constzzQ=1
atom_constzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_atom_constzzQ))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=def_lambdazzQ
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${sht0}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
if [ "${p0#P:}" != "${p0}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:define" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
5)
R="NIL"; ACTION=ret; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=8; ACTION=call; return
;;
7)
R="NIL"; ACTION=ret; return
;;
8)
sht2="${R}"
if [ "${sht2#P:}" != "${sht2}" ]; then
sht3="S:t"
else
sht3="NIL"
fi
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
CALLEE=not
RPC=9; ACTION=call; return
;;
9)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_const_inits=3
const_inits() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_const_inits))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=atom_constzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht18="${R}"
eval "F$((FP+0))=\"\${sht18}\""
PC=0; ACTION=tail; return
;;
6)
sht3="${R}"
sht4="T:${sht3#??}"
hp_car "${p0}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=caddr
RPC=7; ACTION=call; return
;;
7)
eval "sht4=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht4}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
CALLEE=mkb
RPC=8; ACTION=call; return
;;
8)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht4=\"\$F$((FP+NP+1))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${sht7}\""
STGV="NIL"
eval "F$((NFP+3))=\"\$STGV\""
CALLEE=lval
RPC=9; ACTION=call; return
;;
9)
eval "sht4=\"\$F$((FP+NP+0))\""
sht8="${R}"
hp_cdr "${sht8}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=vref
RPC=10; ACTION=call; return
;;
10)
eval "sht4=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="T:=${sht10#??}"
sht12="T:${sht4#??}${sht11#??}"
sht13="T:G_${sht12#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
sht14="${R}"
hp_cdr "${p0}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=const_inits
RPC=12; ACTION=call; return
;;
12)
eval "sht14=\"\$F$((FP+NP+0))\""
sht16="${R}"
hp_cons "${sht14}" "${sht16}"
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
esac; }
SIZE_memzzQ=2
memzzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_memzzQ))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht0="${R}"
if [ "${p0}" = "${sht0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
hp_cdr "${p1}"
sht1="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_set_add=2
set_add() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_set_add))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${sht0}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
hp_cons "${p0}" "${p1}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_callees=4
callees() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_callees))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:quote" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
R="${p1}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1#S:}" != "${sht1}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_car "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=set_add
RPC=8; ACTION=call; return
;;
6)
sht2="${p1}"
PC=7; ACTION=jump; return
;;
7)
sht5="${sht2}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${p0}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht5}\""
CALLEE=callees
RPC=9; ACTION=call; return
;;
8)
sht4="${R}"
sht2="${sht4}"
PC=7; ACTION=jump; return
;;
9)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=callees_list
RPC=10; ACTION=call; return
;;
10)
eval "sht5=\"\$F$((FP+NP+0))\""
sht9="${R}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_callees_list=3
callees_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_callees_list))
NP=2
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht0="${R}"
hp_car "${p0}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=callees
RPC=3; ACTION=call; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_defnames=2
defnames() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_defnames))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht7="${R}"
eval "F$((FP+0))=\"\${sht7}\""
PC=0; ACTION=tail; return
;;
6)
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=defnames
RPC=7; ACTION=call; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht3}" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_keep_defined=3
keep_defined() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_keep_defined))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_defined
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
6)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht2}" "${sht4}"
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_fn_body=1
fn_body() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_fn_body))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=caddr
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=caddr
RPC=2; ACTION=call; return
;;
2)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_build_adj=3
build_adj() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_build_adj))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=def_lambdazzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p0}"
sht2="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=cadr
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht12="${R}"
eval "F$((FP+0))=\"\${sht12}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
6)
sht3="${R}"
hp_car "${p0}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=fn_body
RPC=7; ACTION=call; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=callees
RPC=8; ACTION=call; return
;;
8)
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_defined
RPC=9; ACTION=call; return
;;
9)
eval "sht3=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${sht3}" "${sht7}"
sht8="${R}"
hp_cdr "${p0}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=build_adj
RPC=10; ACTION=call; return
;;
10)
eval "sht8=\"\$F$((FP+NP+0))\""
sht10="${R}"
hp_cons "${sht8}" "${sht10}"
sht11="${R}"
R="${sht11}"; ACTION=ret; return
;;
esac; }
SIZE_all_inzzQ=2
all_inzzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_all_inzzQ))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+0))=\"\${sht2}\""
eval "F$((FP+1))=\"\${p1}\""
PC=0; ACTION=tail; return
;;
5)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_clean_pass=6
clean_pass() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_clean_pass))
NP=3
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "${p1}" "${p2}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
sht3="${sht2}"
hp_car "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
sht6="${sht5}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=3; ACTION=call; return
;;
3)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht7="${R}"
if [ "${sht7}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
PC=0; ACTION=tail; return
;;
5)
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=all_inzzQ
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht9="${R}"
if [ "${sht9}" != NIL ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
hp_cdr "${p0}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "${sht3}" "${p1}"
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht11="${R}"
eval "F$((FP+0))=\"\${sht10}\""
eval "F$((FP+1))=\"\${sht11}\""
STGV="S:t"
eval "F$((FP+2))=\"\$STGV\""
PC=0; ACTION=tail; return
;;
8)
hp_cdr "${p0}"
sht12="${R}"
eval "F$((FP+0))=\"\${sht12}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_clean_fix=2
clean_fix() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_clean_fix))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
STGV="NIL"
eval "F$((NFP+2))=\"\$STGV\""
CALLEE=clean_pass
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_cdr "${sht1}"
sht2="${R}"
if [ "${sht2}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
hp_car "${sht1}"
sht3="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht3}\""
PC=0; ACTION=tail; return
;;
3)
hp_car "${sht1}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_elide_of=1
elide_of() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_elide_of))
NP=1
case $PC in
0)
NFP=$FTOP
STGV="T:\$ELIDE"
eval "F$((NFP+0))=\"\$STGV\""
eval "F$((NFP+1))=\"\${p0}\""
CALLEE=assoc
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
if [ "${sht1}" = NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
hp_cdr "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_compile_program=5
compile_program() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_compile_program))
NP=3
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=mexpand_program
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
sht2="T:${p1#??}/_consts.cmd"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=const_inits
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
write_lines "${sht2}" "${sht3}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
write_lines "${p2}" "NIL"
eval "sht1=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"I:0\""
STGV="NIL"
eval "F$((NFP+4))=\"\$STGV\""
CALLEE=cp
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }

# ---- native comp driver (TRAMPOLINE) ----------------------------------------------------
# Compiled comp functions are resumable segment-machines. This driver loop runs the current
# function for one segment (eval "$CURFN"), which yields back via ACTION + return:
#   call -> push (CURFN,resume-PC,FP) on the return stack, set up callee frame, dispatch callee
#   ret  -> pop the return stack (R holds the value); empty stack -> HALT
#   tail -> self-tail-call: segment already rewrote F[FP..] + reset PC=0; just re-eval
#   jump -> intra-function branch: segment already set PC; just re-eval
# Host stack depth stays 2 (loop + the one eval'd segment) regardless of logical recursion
# depth -- so deep non-tail recursion no longer overflows the host stack (no ulimit needed).
GLOBAL=NIL                            # gc_run marks $GLOBAL; compiled comp ignores the global env
G_DQ='T:"'                            # the (dq) primitive's value, referenced by compiled code
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP"; RSP=$((RSP+1)); FP=$NFP; CURFN=$CALLEE; PC=0 ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP"; fi ;;
      tail|jump) ;;   # CURFN/PC/F already updated by the segment; just re-enter
    esac
  done
}
SRC=$(cat "$1"); rd_expr; _forms=$R
FP=0; F0=$_forms; F1="T:$2"; F2="T:$3"; RSP=0; CURFN=compile_program; PC=0
drive
