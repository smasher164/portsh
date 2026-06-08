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

# src/comp-compiled.sh — compile.lisp + stdlib deps, compiled to native sh by comp-sh.sh
# (the native Lisp->sh emitter). Regenerate via tools/regen-comp.sh; validate via tests/native-comp.sh.
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
SIZE_lretag=10
lretag() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_lretag))
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
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=cref
RPC=3; ACTION=call; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht9="${R}"
sht10="T:${p1#??}${sht9#??}"
sht11="T:=${sht10#??}"
sht12="T:${sht6#??}${sht11#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht13}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
CALLEE=bkzzP
RPC=6; ACTION=call; return
;;
6)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "S:val" "${sht6}"
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht15}" "${sht16}"
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
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
SIZE_lval=17
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
sht26="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
CALLEE=arithzzQ
RPC=20; ACTION=call; return
;;
12)
sht11="${R}"
sht12="${sht11}"
if [ "${sht12}" = NIL ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=gfns_of
RPC=15; ACTION=call; return
;;
14)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:val" "${sht12}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht24}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht25="${R}"
R="${sht25}"; ACTION=ret; return
;;
15)
eval "p0=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht13}\""
CALLEE=memzzQ
RPC=16; ACTION=call; return
;;
16)
eval "sht12=\"\$F$((FP+NP+0))\""
sht14="${R}"
if [ "${sht14}" != NIL ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
sht15="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=mangle
RPC=19; ACTION=call; return
;;
18)
sht20="T:${p0#??}"
sht21="T:G_${sht20#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:val" "${sht21}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht22}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht23="${R}"
R="${sht23}"; ACTION=ret; return
;;
19)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht16="${R}"
sht17="T:C:${sht16#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:cst" "${sht17}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht18}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht19="${R}"
R="${sht19}"; ACTION=ret; return
;;
20)
sht27="${R}"
if [ "${sht27}" != NIL ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
hp_cdr "${p0}"
sht28="${R}"
hp_car "${sht28}"
sht29="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=23; ACTION=call; return
;;
22)
hp_car "${p0}"
sht59="${R}"
if [ "${sht59}" = "S:cons" ]; then PC=32; else PC=33; fi
ACTION=jump; return
;;
23)
sht30="${R}"
sht31="${sht30}"
hp_cdr "${p0}"
sht32="${R}"
hp_cdr "${sht32}"
sht33="${R}"
hp_car "${sht33}"
sht34="${R}"
hp_car "${sht31}"
sht35="${R}"
hp_cdr "${sht31}"
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht34}\""
eval "F$((FP+NP+3))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=24; ACTION=call; return
;;
24)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht34=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht35}\""
eval "F$((NFP+3))=\"\${sht37}\""
CALLEE=lval
RPC=25; ACTION=call; return
;;
25)
eval "sht31=\"\$F$((FP+NP+0))\""
sht38="${R}"
sht39="${sht38}"
hp_car "${sht39}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
CALLEE=tmpn
RPC=26; ACTION=call; return
;;
26)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
sht41="${R}"
sht42="${sht41}"
hp_car "${sht39}"
sht43="${R}"
hp_cdr "${sht31}"
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht43}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht44}\""
CALLEE=aref
RPC=27; ACTION=call; return
;;
27)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht43=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
sht45="${R}"
hp_car "${p0}"
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht45}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht43}\""
eval "F$((FP+NP+3))=\"\${sht42}\""
eval "F$((FP+NP+4))=\"\${sht39}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht46}\""
CALLEE=op_zzGbatch
RPC=28; ACTION=call; return
;;
28)
eval "sht45=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht43=\"\$F$((FP+NP+2))\""
eval "sht42=\"\$F$((FP+NP+3))\""
eval "sht39=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
sht47="${R}"
hp_cdr "${sht39}"
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht47}\""
eval "F$((FP+NP+1))=\"\${sht45}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht43}\""
eval "F$((FP+NP+4))=\"\${sht42}\""
eval "F$((FP+NP+5))=\"\${sht39}\""
eval "F$((FP+NP+6))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
CALLEE=aref
RPC=29; ACTION=call; return
;;
29)
eval "sht47=\"\$F$((FP+NP+0))\""
eval "sht45=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht43=\"\$F$((FP+NP+3))\""
eval "sht42=\"\$F$((FP+NP+4))\""
eval "sht39=\"\$F$((FP+NP+5))\""
eval "sht31=\"\$F$((FP+NP+6))\""
sht49="${R}"
sht50="T:${sht47#??}${sht49#??}"
sht51="T:${sht45#??}${sht50#??}"
sht52="T:=${sht51#??}"
sht53="T:${sht42#??}${sht52#??}"
sht54="T:set /a ${sht53#??}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
eval "F$((NFP+1))=\"\${sht54}\""
CALLEE=emit
RPC=30; ACTION=call; return
;;
30)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
sht55="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht55}\""
CALLEE=bkzzP
RPC=31; ACTION=call; return
;;
31)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
sht56="${R}"
eval "F$((FP+NP+0))=\"\${sht56}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht31}\""
hp_cons "S:raw" "${sht42}"
eval "sht56=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
sht57="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
hp_cons "${sht56}" "${sht57}"
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
sht58="${R}"
R="${sht58}"; ACTION=ret; return
;;
32)
hp_cdr "${p0}"
sht60="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht60}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=34; ACTION=call; return
;;
33)
hp_car "${p0}"
sht92="${R}"
if [ "${sht92}" = "S:string-append" ]; then PC=44; else PC=45; fi
ACTION=jump; return
;;
34)
sht61="${R}"
sht62="${sht61}"
hp_car "${sht62}"
sht63="${R}"
eval "F$((FP+NP+0))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht63}\""
CALLEE=tmpn
RPC=35; ACTION=call; return
;;
35)
eval "sht62=\"\$F$((FP+NP+0))\""
sht64="${R}"
sht65="${sht64}"
hp_cdr "${sht62}"
sht66="${R}"
hp_car "${sht66}"
sht67="${R}"
sht68="${sht67}"
hp_cdr "${sht62}"
sht69="${R}"
hp_cdr "${sht69}"
sht70="${R}"
hp_car "${sht70}"
sht71="${R}"
sht72="${sht71}"
hp_car "${sht62}"
sht73="${R}"
eval "F$((FP+NP+0))=\"\${sht72}\""
eval "F$((FP+NP+1))=\"\${sht68}\""
eval "F$((FP+NP+2))=\"\${sht65}\""
eval "F$((FP+NP+3))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht73}\""
STGV="T:set /a HN+=1"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=36; ACTION=call; return
;;
36)
eval "sht72=\"\$F$((FP+NP+0))\""
eval "sht68=\"\$F$((FP+NP+1))\""
eval "sht65=\"\$F$((FP+NP+2))\""
eval "sht62=\"\$F$((FP+NP+3))\""
sht74="${R}"
sht75="${sht74}"
eval "F$((FP+NP+0))=\"\${sht75}\""
eval "F$((FP+NP+1))=\"\${sht75}\""
eval "F$((FP+NP+2))=\"\${sht72}\""
eval "F$((FP+NP+3))=\"\${sht68}\""
eval "F$((FP+NP+4))=\"\${sht65}\""
eval "F$((FP+NP+5))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht68}\""
CALLEE=vref
RPC=37; ACTION=call; return
;;
37)
eval "sht75=\"\$F$((FP+NP+0))\""
eval "sht75=\"\$F$((FP+NP+1))\""
eval "sht72=\"\$F$((FP+NP+2))\""
eval "sht68=\"\$F$((FP+NP+3))\""
eval "sht65=\"\$F$((FP+NP+4))\""
eval "sht62=\"\$F$((FP+NP+5))\""
sht76="${R}"
sht77="T:${sht76#??}#"
sht78="T:>%HD%\\car%HN% echo(${sht77#??}"
eval "F$((FP+NP+0))=\"\${sht75}\""
eval "F$((FP+NP+1))=\"\${sht72}\""
eval "F$((FP+NP+2))=\"\${sht68}\""
eval "F$((FP+NP+3))=\"\${sht65}\""
eval "F$((FP+NP+4))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht75}\""
eval "F$((NFP+1))=\"\${sht78}\""
CALLEE=emit
RPC=38; ACTION=call; return
;;
38)
eval "sht75=\"\$F$((FP+NP+0))\""
eval "sht72=\"\$F$((FP+NP+1))\""
eval "sht68=\"\$F$((FP+NP+2))\""
eval "sht65=\"\$F$((FP+NP+3))\""
eval "sht62=\"\$F$((FP+NP+4))\""
sht79="${R}"
sht80="${sht79}"
eval "F$((FP+NP+0))=\"\${sht80}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht75}\""
eval "F$((FP+NP+3))=\"\${sht72}\""
eval "F$((FP+NP+4))=\"\${sht68}\""
eval "F$((FP+NP+5))=\"\${sht65}\""
eval "F$((FP+NP+6))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht72}\""
CALLEE=vref
RPC=39; ACTION=call; return
;;
39)
eval "sht80=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht75=\"\$F$((FP+NP+2))\""
eval "sht72=\"\$F$((FP+NP+3))\""
eval "sht68=\"\$F$((FP+NP+4))\""
eval "sht65=\"\$F$((FP+NP+5))\""
eval "sht62=\"\$F$((FP+NP+6))\""
sht81="${R}"
sht82="T:${sht81#??}#"
sht83="T:>%HD%\\cdr%HN% echo(${sht82#??}"
eval "F$((FP+NP+0))=\"\${sht80}\""
eval "F$((FP+NP+1))=\"\${sht75}\""
eval "F$((FP+NP+2))=\"\${sht72}\""
eval "F$((FP+NP+3))=\"\${sht68}\""
eval "F$((FP+NP+4))=\"\${sht65}\""
eval "F$((FP+NP+5))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht80}\""
eval "F$((NFP+1))=\"\${sht83}\""
CALLEE=emit
RPC=40; ACTION=call; return
;;
40)
eval "sht80=\"\$F$((FP+NP+0))\""
eval "sht75=\"\$F$((FP+NP+1))\""
eval "sht72=\"\$F$((FP+NP+2))\""
eval "sht68=\"\$F$((FP+NP+3))\""
eval "sht65=\"\$F$((FP+NP+4))\""
eval "sht62=\"\$F$((FP+NP+5))\""
sht84="${R}"
sht85="${sht84}"
sht86="T:${sht65#??}=P:!HN!"
eval "F$((FP+NP+0))=\"\${sht85}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht80}\""
eval "F$((FP+NP+3))=\"\${sht75}\""
eval "F$((FP+NP+4))=\"\${sht72}\""
eval "F$((FP+NP+5))=\"\${sht68}\""
eval "F$((FP+NP+6))=\"\${sht65}\""
eval "F$((FP+NP+7))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht86}\""
CALLEE=qset
RPC=41; ACTION=call; return
;;
41)
eval "sht85=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht80=\"\$F$((FP+NP+2))\""
eval "sht75=\"\$F$((FP+NP+3))\""
eval "sht72=\"\$F$((FP+NP+4))\""
eval "sht68=\"\$F$((FP+NP+5))\""
eval "sht65=\"\$F$((FP+NP+6))\""
eval "sht62=\"\$F$((FP+NP+7))\""
sht87="${R}"
eval "F$((FP+NP+0))=\"\${sht85}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht75}\""
eval "F$((FP+NP+3))=\"\${sht72}\""
eval "F$((FP+NP+4))=\"\${sht68}\""
eval "F$((FP+NP+5))=\"\${sht65}\""
eval "F$((FP+NP+6))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht85}\""
eval "F$((NFP+1))=\"\${sht87}\""
CALLEE=emit
RPC=42; ACTION=call; return
;;
42)
eval "sht85=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht75=\"\$F$((FP+NP+2))\""
eval "sht72=\"\$F$((FP+NP+3))\""
eval "sht68=\"\$F$((FP+NP+4))\""
eval "sht65=\"\$F$((FP+NP+5))\""
eval "sht62=\"\$F$((FP+NP+6))\""
sht88="${R}"
eval "F$((FP+NP+0))=\"\${sht85}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht75}\""
eval "F$((FP+NP+3))=\"\${sht72}\""
eval "F$((FP+NP+4))=\"\${sht68}\""
eval "F$((FP+NP+5))=\"\${sht65}\""
eval "F$((FP+NP+6))=\"\${sht62}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht88}\""
CALLEE=bkzzP
RPC=43; ACTION=call; return
;;
43)
eval "sht85=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht75=\"\$F$((FP+NP+2))\""
eval "sht72=\"\$F$((FP+NP+3))\""
eval "sht68=\"\$F$((FP+NP+4))\""
eval "sht65=\"\$F$((FP+NP+5))\""
eval "sht62=\"\$F$((FP+NP+6))\""
sht89="${R}"
eval "F$((FP+NP+0))=\"\${sht89}\""
eval "F$((FP+NP+1))=\"\${sht85}\""
eval "F$((FP+NP+2))=\"\${sht80}\""
eval "F$((FP+NP+3))=\"\${sht75}\""
eval "F$((FP+NP+4))=\"\${sht72}\""
eval "F$((FP+NP+5))=\"\${sht68}\""
eval "F$((FP+NP+6))=\"\${sht65}\""
eval "F$((FP+NP+7))=\"\${sht62}\""
hp_cons "S:val" "${sht65}"
eval "sht89=\"\$F$((FP+NP+0))\""
eval "sht85=\"\$F$((FP+NP+1))\""
eval "sht80=\"\$F$((FP+NP+2))\""
eval "sht75=\"\$F$((FP+NP+3))\""
eval "sht72=\"\$F$((FP+NP+4))\""
eval "sht68=\"\$F$((FP+NP+5))\""
eval "sht65=\"\$F$((FP+NP+6))\""
eval "sht62=\"\$F$((FP+NP+7))\""
sht90="${R}"
eval "F$((FP+NP+0))=\"\${sht85}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht75}\""
eval "F$((FP+NP+3))=\"\${sht72}\""
eval "F$((FP+NP+4))=\"\${sht68}\""
eval "F$((FP+NP+5))=\"\${sht65}\""
eval "F$((FP+NP+6))=\"\${sht62}\""
hp_cons "${sht89}" "${sht90}"
eval "sht85=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht75=\"\$F$((FP+NP+2))\""
eval "sht72=\"\$F$((FP+NP+3))\""
eval "sht68=\"\$F$((FP+NP+4))\""
eval "sht65=\"\$F$((FP+NP+5))\""
eval "sht62=\"\$F$((FP+NP+6))\""
sht91="${R}"
R="${sht91}"; ACTION=ret; return
;;
44)
hp_cdr "${p0}"
sht93="${R}"
hp_car "${sht93}"
sht94="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht94}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=46; ACTION=call; return
;;
45)
hp_car "${p0}"
sht121="${R}"
if [ "${sht121}" = "S:car" ]; then PC=55; else PC=56; fi
ACTION=jump; return
;;
46)
sht95="${R}"
sht96="${sht95}"
hp_cdr "${p0}"
sht97="${R}"
hp_cdr "${sht97}"
sht98="${R}"
hp_car "${sht98}"
sht99="${R}"
hp_car "${sht96}"
sht100="${R}"
hp_cdr "${sht96}"
sht101="${R}"
eval "F$((FP+NP+0))=\"\${sht100}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht99}\""
eval "F$((FP+NP+3))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht101}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=47; ACTION=call; return
;;
47)
eval "sht100=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht99=\"\$F$((FP+NP+2))\""
eval "sht96=\"\$F$((FP+NP+3))\""
sht102="${R}"
eval "F$((FP+NP+0))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht99}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht100}\""
eval "F$((NFP+3))=\"\${sht102}\""
CALLEE=lval
RPC=48; ACTION=call; return
;;
48)
eval "sht96=\"\$F$((FP+NP+0))\""
sht103="${R}"
sht104="${sht103}"
hp_car "${sht104}"
sht105="${R}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht105}\""
CALLEE=tmpn
RPC=49; ACTION=call; return
;;
49)
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht96=\"\$F$((FP+NP+1))\""
sht106="${R}"
sht107="${sht106}"
hp_car "${sht104}"
sht108="${R}"
hp_cdr "${sht96}"
sht109="${R}"
eval "F$((FP+NP+0))=\"\${sht107}\""
eval "F$((FP+NP+1))=\"\${sht108}\""
eval "F$((FP+NP+2))=\"\${sht107}\""
eval "F$((FP+NP+3))=\"\${sht104}\""
eval "F$((FP+NP+4))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht109}\""
CALLEE=cref
RPC=50; ACTION=call; return
;;
50)
eval "sht107=\"\$F$((FP+NP+0))\""
eval "sht108=\"\$F$((FP+NP+1))\""
eval "sht107=\"\$F$((FP+NP+2))\""
eval "sht104=\"\$F$((FP+NP+3))\""
eval "sht96=\"\$F$((FP+NP+4))\""
sht110="${R}"
hp_cdr "${sht104}"
sht111="${R}"
eval "F$((FP+NP+0))=\"\${sht110}\""
eval "F$((FP+NP+1))=\"\${sht107}\""
eval "F$((FP+NP+2))=\"\${sht108}\""
eval "F$((FP+NP+3))=\"\${sht107}\""
eval "F$((FP+NP+4))=\"\${sht104}\""
eval "F$((FP+NP+5))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht111}\""
CALLEE=cref
RPC=51; ACTION=call; return
;;
51)
eval "sht110=\"\$F$((FP+NP+0))\""
eval "sht107=\"\$F$((FP+NP+1))\""
eval "sht108=\"\$F$((FP+NP+2))\""
eval "sht107=\"\$F$((FP+NP+3))\""
eval "sht104=\"\$F$((FP+NP+4))\""
eval "sht96=\"\$F$((FP+NP+5))\""
sht112="${R}"
sht113="T:${sht110#??}${sht112#??}"
sht114="T:=T:${sht113#??}"
sht115="T:${sht107#??}${sht114#??}"
eval "F$((FP+NP+0))=\"\${sht108}\""
eval "F$((FP+NP+1))=\"\${sht107}\""
eval "F$((FP+NP+2))=\"\${sht104}\""
eval "F$((FP+NP+3))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht115}\""
CALLEE=qset
RPC=52; ACTION=call; return
;;
52)
eval "sht108=\"\$F$((FP+NP+0))\""
eval "sht107=\"\$F$((FP+NP+1))\""
eval "sht104=\"\$F$((FP+NP+2))\""
eval "sht96=\"\$F$((FP+NP+3))\""
sht116="${R}"
eval "F$((FP+NP+0))=\"\${sht107}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht108}\""
eval "F$((NFP+1))=\"\${sht116}\""
CALLEE=emit
RPC=53; ACTION=call; return
;;
53)
eval "sht107=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht96=\"\$F$((FP+NP+2))\""
sht117="${R}"
eval "F$((FP+NP+0))=\"\${sht107}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht96}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht117}\""
CALLEE=bkzzP
RPC=54; ACTION=call; return
;;
54)
eval "sht107=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht96=\"\$F$((FP+NP+2))\""
sht118="${R}"
eval "F$((FP+NP+0))=\"\${sht118}\""
eval "F$((FP+NP+1))=\"\${sht107}\""
eval "F$((FP+NP+2))=\"\${sht104}\""
eval "F$((FP+NP+3))=\"\${sht96}\""
hp_cons "S:val" "${sht107}"
eval "sht118=\"\$F$((FP+NP+0))\""
eval "sht107=\"\$F$((FP+NP+1))\""
eval "sht104=\"\$F$((FP+NP+2))\""
eval "sht96=\"\$F$((FP+NP+3))\""
sht119="${R}"
eval "F$((FP+NP+0))=\"\${sht107}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht96}\""
hp_cons "${sht118}" "${sht119}"
eval "sht107=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht96=\"\$F$((FP+NP+2))\""
sht120="${R}"
R="${sht120}"; ACTION=ret; return
;;
55)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:car"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lcell
RPC=57; ACTION=call; return
;;
56)
hp_car "${p0}"
sht123="${R}"
if [ "${sht123}" = "S:cdr" ]; then PC=58; else PC=59; fi
ACTION=jump; return
;;
57)
sht122="${R}"
R="${sht122}"; ACTION=ret; return
;;
58)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:cdr"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lcell
RPC=60; ACTION=call; return
;;
59)
hp_car "${p0}"
sht125="${R}"
if [ "${sht125}" = "S:if" ]; then PC=61; else PC=62; fi
ACTION=jump; return
;;
60)
sht124="${R}"
R="${sht124}"; ACTION=ret; return
;;
61)
hp_cdr "${p0}"
sht126="${R}"
hp_car "${sht126}"
sht127="${R}"
hp_cdr "${p0}"
sht128="${R}"
hp_cdr "${sht128}"
sht129="${R}"
hp_car "${sht129}"
sht130="${R}"
eval "F$((FP+NP+0))=\"\${sht130}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=63; ACTION=call; return
;;
62)
hp_car "${p0}"
sht133="${R}"
if [ "${sht133}" = "S:cond" ]; then PC=65; else PC=66; fi
ACTION=jump; return
;;
63)
eval "sht130=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
sht131="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht127}\""
eval "F$((NFP+1))=\"\${sht130}\""
eval "F$((NFP+2))=\"\${sht131}\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=64; ACTION=call; return
;;
64)
sht132="${R}"
R="${sht132}"; ACTION=ret; return
;;
65)
hp_cdr "${p0}"
sht134="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht134}\""
CALLEE=cond_zzGif
RPC=67; ACTION=call; return
;;
66)
hp_car "${p0}"
sht136="${R}"
if [ "${sht136}" = "S:let" ]; then PC=68; else PC=69; fi
ACTION=jump; return
;;
67)
sht135="${R}"
eval "F$((FP+0))=\"\${sht135}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
68)
hp_cdr "${p0}"
sht137="${R}"
hp_car "${sht137}"
sht138="${R}"
hp_cdr "${p0}"
sht139="${R}"
hp_cdr "${sht139}"
sht140="${R}"
hp_car "${sht140}"
sht141="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht138}\""
eval "F$((NFP+1))=\"\${sht141}\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=llet
RPC=70; ACTION=call; return
;;
69)
hp_car "${p0}"
sht143="${R}"
if [ "${sht143}" = "S:begin" ]; then PC=71; else PC=72; fi
ACTION=jump; return
;;
70)
sht142="${R}"
R="${sht142}"; ACTION=ret; return
;;
71)
hp_cdr "${p0}"
sht144="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht144}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbegin
RPC=73; ACTION=call; return
;;
72)
hp_car "${p0}"
sht146="${R}"
if [ "${sht146}" = "S:quote" ]; then PC=74; else PC=75; fi
ACTION=jump; return
;;
73)
sht145="${R}"
R="${sht145}"; ACTION=ret; return
;;
74)
hp_cdr "${p0}"
sht147="${R}"
hp_car "${sht147}"
sht148="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht148}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=lquote
RPC=76; ACTION=call; return
;;
75)
hp_car "${p0}"
sht150="${R}"
if [ "${sht150}" = "S:string-length" ]; then PC=77; else PC=78; fi
ACTION=jump; return
;;
76)
sht149="${R}"
R="${sht149}"; ACTION=ret; return
;;
77)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lstrlen
RPC=79; ACTION=call; return
;;
78)
hp_car "${p0}"
sht152="${R}"
if [ "${sht152}" = "S:substring" ]; then PC=80; else PC=81; fi
ACTION=jump; return
;;
79)
sht151="${R}"
R="${sht151}"; ACTION=ret; return
;;
80)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lsubstr
RPC=82; ACTION=call; return
;;
81)
hp_car "${p0}"
sht154="${R}"
if [ "${sht154}" = "S:symbol->string" ]; then PC=83; else PC=84; fi
ACTION=jump; return
;;
82)
sht153="${R}"
R="${sht153}"; ACTION=ret; return
;;
83)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=85; ACTION=call; return
;;
84)
hp_car "${p0}"
sht156="${R}"
if [ "${sht156}" = "S:number->string" ]; then PC=86; else PC=87; fi
ACTION=jump; return
;;
85)
sht155="${R}"
R="${sht155}"; ACTION=ret; return
;;
86)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=88; ACTION=call; return
;;
87)
hp_car "${p0}"
sht158="${R}"
if [ "${sht158}" = "S:string->symbol" ]; then PC=89; else PC=90; fi
ACTION=jump; return
;;
88)
sht157="${R}"
R="${sht157}"; ACTION=ret; return
;;
89)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=91; ACTION=call; return
;;
90)
hp_car "${p0}"
sht160="${R}"
if [ "${sht160}" = "S:string->number" ]; then PC=92; else PC=93; fi
ACTION=jump; return
;;
91)
sht159="${R}"
R="${sht159}"; ACTION=ret; return
;;
92)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=94; ACTION=call; return
;;
93)
hp_car "${p0}"
sht162="${R}"
if [ "${sht162}" = "S:dq" ]; then PC=95; else PC=96; fi
ACTION=jump; return
;;
94)
sht161="${R}"
R="${sht161}"; ACTION=ret; return
;;
95)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
CALLEE=tmpn
RPC=97; ACTION=call; return
;;
96)
hp_car "${p0}"
sht171="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht171}\""
CALLEE=builtinzzQ
RPC=101; ACTION=call; return
;;
97)
sht163="${R}"
sht164="${sht163}"
sht165="T:${sht164#??}=T:!BANG8!"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht164}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht165}\""
CALLEE=qset
RPC=98; ACTION=call; return
;;
98)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht164=\"\$F$((FP+NP+1))\""
sht166="${R}"
eval "F$((FP+NP+0))=\"\${sht164}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht166}\""
CALLEE=emit
RPC=99; ACTION=call; return
;;
99)
eval "sht164=\"\$F$((FP+NP+0))\""
sht167="${R}"
eval "F$((FP+NP+0))=\"\${sht164}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht167}\""
CALLEE=bkzzP
RPC=100; ACTION=call; return
;;
100)
eval "sht164=\"\$F$((FP+NP+0))\""
sht168="${R}"
eval "F$((FP+NP+0))=\"\${sht168}\""
eval "F$((FP+NP+1))=\"\${sht164}\""
hp_cons "S:val" "${sht164}"
eval "sht168=\"\$F$((FP+NP+0))\""
eval "sht164=\"\$F$((FP+NP+1))\""
sht169="${R}"
eval "F$((FP+NP+0))=\"\${sht164}\""
hp_cons "${sht168}" "${sht169}"
eval "sht164=\"\$F$((FP+NP+0))\""
sht170="${R}"
R="${sht170}"; ACTION=ret; return
;;
101)
sht172="${R}"
if [ "${sht172}" != NIL ]; then PC=102; else PC=103; fi
ACTION=jump; return
;;
102)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbuiltin
RPC=104; ACTION=call; return
;;
103)
hp_car "${p0}"
sht174="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht174}\""
CALLEE=tpredzzQ
RPC=105; ACTION=call; return
;;
104)
sht173="${R}"
R="${sht173}"; ACTION=ret; return
;;
105)
sht175="${R}"
if [ "${sht175}" != NIL ]; then PC=106; else PC=107; fi
ACTION=jump; return
;;
106)
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
RPC=108; ACTION=call; return
;;
107)
hp_car "${p0}"
sht177="${R}"
if [ "${sht177}" = "S:make-closure" ]; then PC=109; else PC=110; fi
ACTION=jump; return
;;
108)
sht176="${R}"
R="${sht176}"; ACTION=ret; return
;;
109)
hp_cdr "${p0}"
sht178="${R}"
hp_car "${sht178}"
sht179="${R}"
hp_cdr "${p0}"
sht180="${R}"
hp_cdr "${sht180}"
sht181="${R}"
eval "F$((FP+NP+0))=\"\${sht179}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht181}\""
CALLEE=mkclo_caps
RPC=111; ACTION=call; return
;;
110)
hp_car "${p0}"
sht202="${R}"
if [ "${sht202#S:}" != "${sht202}" ]; then PC=117; else PC=118; fi
ACTION=jump; return
;;
111)
eval "sht179=\"\$F$((FP+NP+0))\""
sht182="${R}"
eval "F$((FP+NP+0))=\"\${sht179}\""
hp_cons "${sht182}" "NIL"
eval "sht179=\"\$F$((FP+NP+0))\""
sht183="${R}"
hp_cons "${sht179}" "${sht183}"
sht184="${R}"
hp_cons "S:cons" "${sht184}"
sht185="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht185}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=112; ACTION=call; return
;;
112)
sht186="${R}"
sht187="${sht186}"
hp_car "${sht187}"
sht188="${R}"
eval "F$((FP+NP+0))=\"\${sht187}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht188}\""
CALLEE=tmpn
RPC=113; ACTION=call; return
;;
113)
eval "sht187=\"\$F$((FP+NP+0))\""
sht189="${R}"
sht190="${sht189}"
hp_car "${sht187}"
sht191="${R}"
hp_cdr "${sht187}"
sht192="${R}"
hp_cdr "${sht192}"
sht193="${R}"
sht194="T:${sht193#??}:~2!"
sht195="T:=K:!${sht194#??}"
sht196="T:${sht190#??}${sht195#??}"
eval "F$((FP+NP+0))=\"\${sht191}\""
eval "F$((FP+NP+1))=\"\${sht190}\""
eval "F$((FP+NP+2))=\"\${sht187}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht196}\""
CALLEE=qset
RPC=114; ACTION=call; return
;;
114)
eval "sht191=\"\$F$((FP+NP+0))\""
eval "sht190=\"\$F$((FP+NP+1))\""
eval "sht187=\"\$F$((FP+NP+2))\""
sht197="${R}"
eval "F$((FP+NP+0))=\"\${sht190}\""
eval "F$((FP+NP+1))=\"\${sht187}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht191}\""
eval "F$((NFP+1))=\"\${sht197}\""
CALLEE=emit
RPC=115; ACTION=call; return
;;
115)
eval "sht190=\"\$F$((FP+NP+0))\""
eval "sht187=\"\$F$((FP+NP+1))\""
sht198="${R}"
eval "F$((FP+NP+0))=\"\${sht190}\""
eval "F$((FP+NP+1))=\"\${sht187}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht198}\""
CALLEE=bkzzP
RPC=116; ACTION=call; return
;;
116)
eval "sht190=\"\$F$((FP+NP+0))\""
eval "sht187=\"\$F$((FP+NP+1))\""
sht199="${R}"
eval "F$((FP+NP+0))=\"\${sht199}\""
eval "F$((FP+NP+1))=\"\${sht190}\""
eval "F$((FP+NP+2))=\"\${sht187}\""
hp_cons "S:val" "${sht190}"
eval "sht199=\"\$F$((FP+NP+0))\""
eval "sht190=\"\$F$((FP+NP+1))\""
eval "sht187=\"\$F$((FP+NP+2))\""
sht200="${R}"
eval "F$((FP+NP+0))=\"\${sht190}\""
eval "F$((FP+NP+1))=\"\${sht187}\""
hp_cons "${sht199}" "${sht200}"
eval "sht190=\"\$F$((FP+NP+0))\""
eval "sht187=\"\$F$((FP+NP+1))\""
sht201="${R}"
R="${sht201}"; ACTION=ret; return
;;
117)
hp_car "${p0}"
sht204="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht204}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=120; ACTION=call; return
;;
118)
sht203="NIL"
PC=119; ACTION=jump; return
;;
119)
if [ "${sht203}" != NIL ]; then PC=121; else PC=122; fi
ACTION=jump; return
;;
120)
sht205="${R}"
if [ "${sht205}" = NIL ]; then
sht206="S:t"
else
sht206="NIL"
fi
sht203="${sht206}"
PC=119; ACTION=jump; return
;;
121)
hp_cdr "${p0}"
sht207="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht207}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=123; ACTION=call; return
;;
122)
hp_car "${p0}"
sht257="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht257}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=141; ACTION=call; return
;;
123)
sht208="${R}"
sht209="${sht208}"
hp_car "${sht209}"
sht210="${R}"
eval "F$((FP+NP+0))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht210}\""
CALLEE=b_npc
RPC=124; ACTION=call; return
;;
124)
eval "sht209=\"\$F$((FP+NP+0))\""
sht211="${R}"
sht212="${sht211}"
hp_car "${p0}"
sht213="${R}"
sht214="T:${sht213#??}"
eval "F$((FP+NP+0))=\"\${sht212}\""
eval "F$((FP+NP+1))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht214}\""
CALLEE=mangle
RPC=125; ACTION=call; return
;;
125)
eval "sht212=\"\$F$((FP+NP+0))\""
eval "sht209=\"\$F$((FP+NP+1))\""
sht215="${R}"
sht216="${sht215}"
hp_car "${sht209}"
sht217="${R}"
eval "F$((FP+NP+0))=\"\${sht216}\""
eval "F$((FP+NP+1))=\"\${sht212}\""
eval "F$((FP+NP+2))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht217}\""
CALLEE=bnpczzP
RPC=126; ACTION=call; return
;;
126)
eval "sht216=\"\$F$((FP+NP+0))\""
eval "sht212=\"\$F$((FP+NP+1))\""
eval "sht209=\"\$F$((FP+NP+2))\""
sht218="${R}"
eval "F$((FP+NP+0))=\"\${sht216}\""
eval "F$((FP+NP+1))=\"\${sht212}\""
eval "F$((FP+NP+2))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht218}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=127; ACTION=call; return
;;
127)
eval "sht216=\"\$F$((FP+NP+0))\""
eval "sht212=\"\$F$((FP+NP+1))\""
eval "sht209=\"\$F$((FP+NP+2))\""
sht219="${R}"
eval "F$((FP+NP+0))=\"\${sht216}\""
eval "F$((FP+NP+1))=\"\${sht212}\""
eval "F$((FP+NP+2))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht219}\""
STGV="T:set /a NFP=!FT!"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=128; ACTION=call; return
;;
128)
eval "sht216=\"\$F$((FP+NP+0))\""
eval "sht212=\"\$F$((FP+NP+1))\""
eval "sht209=\"\$F$((FP+NP+2))\""
sht220="${R}"
sht221="${sht220}"
hp_cdr "${sht209}"
sht222="${R}"
eval "F$((FP+NP+0))=\"\${sht221}\""
eval "F$((FP+NP+1))=\"\${sht216}\""
eval "F$((FP+NP+2))=\"\${sht212}\""
eval "F$((FP+NP+3))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht221}\""
eval "F$((NFP+1))=\"\${sht222}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=129; ACTION=call; return
;;
129)
eval "sht221=\"\$F$((FP+NP+0))\""
eval "sht216=\"\$F$((FP+NP+1))\""
eval "sht212=\"\$F$((FP+NP+2))\""
eval "sht209=\"\$F$((FP+NP+3))\""
sht223="${R}"
sht224="${sht223}"
sht225="T:${sht216#??}${G_DQ#??}"
sht226="T:CALLEE=${sht225#??}"
sht227="T:${G_DQ#??}${sht226#??}"
sht228="T:set ${sht227#??}"
eval "F$((FP+NP+0))=\"\${sht224}\""
eval "F$((FP+NP+1))=\"\${sht221}\""
eval "F$((FP+NP+2))=\"\${sht216}\""
eval "F$((FP+NP+3))=\"\${sht212}\""
eval "F$((FP+NP+4))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht224}\""
eval "F$((NFP+1))=\"\${sht228}\""
CALLEE=emit
RPC=130; ACTION=call; return
;;
130)
eval "sht224=\"\$F$((FP+NP+0))\""
eval "sht221=\"\$F$((FP+NP+1))\""
eval "sht216=\"\$F$((FP+NP+2))\""
eval "sht212=\"\$F$((FP+NP+3))\""
eval "sht209=\"\$F$((FP+NP+4))\""
sht229="${R}"
sht230="${sht229}"
sht231="T:${sht212#??}"
sht232="T:${sht231#??}${G_DQ#??}"
sht233="T:RPC=${sht232#??}"
sht234="T:${G_DQ#??}${sht233#??}"
sht235="T:set ${sht234#??}"
eval "F$((FP+NP+0))=\"\${sht230}\""
eval "F$((FP+NP+1))=\"\${sht224}\""
eval "F$((FP+NP+2))=\"\${sht221}\""
eval "F$((FP+NP+3))=\"\${sht216}\""
eval "F$((FP+NP+4))=\"\${sht212}\""
eval "F$((FP+NP+5))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht230}\""
eval "F$((NFP+1))=\"\${sht235}\""
CALLEE=emit
RPC=131; ACTION=call; return
;;
131)
eval "sht230=\"\$F$((FP+NP+0))\""
eval "sht224=\"\$F$((FP+NP+1))\""
eval "sht221=\"\$F$((FP+NP+2))\""
eval "sht216=\"\$F$((FP+NP+3))\""
eval "sht212=\"\$F$((FP+NP+4))\""
eval "sht209=\"\$F$((FP+NP+5))\""
sht236="${R}"
sht237="${sht236}"
sht238="T:${G_DQ#??} & goto :eof"
sht239="T:ACTION=call${sht238#??}"
sht240="T:${G_DQ#??}${sht239#??}"
sht241="T:set ${sht240#??}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht230}\""
eval "F$((FP+NP+2))=\"\${sht224}\""
eval "F$((FP+NP+3))=\"\${sht221}\""
eval "F$((FP+NP+4))=\"\${sht216}\""
eval "F$((FP+NP+5))=\"\${sht212}\""
eval "F$((FP+NP+6))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht237}\""
eval "F$((NFP+1))=\"\${sht241}\""
CALLEE=emit
RPC=132; ACTION=call; return
;;
132)
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht230=\"\$F$((FP+NP+1))\""
eval "sht224=\"\$F$((FP+NP+2))\""
eval "sht221=\"\$F$((FP+NP+3))\""
eval "sht216=\"\$F$((FP+NP+4))\""
eval "sht212=\"\$F$((FP+NP+5))\""
eval "sht209=\"\$F$((FP+NP+6))\""
sht242="${R}"
sht243="${sht242}"
eval "F$((FP+NP+0))=\"\${sht243}\""
eval "F$((FP+NP+1))=\"\${sht237}\""
eval "F$((FP+NP+2))=\"\${sht230}\""
eval "F$((FP+NP+3))=\"\${sht224}\""
eval "F$((FP+NP+4))=\"\${sht221}\""
eval "F$((FP+NP+5))=\"\${sht216}\""
eval "F$((FP+NP+6))=\"\${sht212}\""
eval "F$((FP+NP+7))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht243}\""
eval "F$((NFP+1))=\"\${sht212}\""
CALLEE=switch
RPC=133; ACTION=call; return
;;
133)
eval "sht243=\"\$F$((FP+NP+0))\""
eval "sht237=\"\$F$((FP+NP+1))\""
eval "sht230=\"\$F$((FP+NP+2))\""
eval "sht224=\"\$F$((FP+NP+3))\""
eval "sht221=\"\$F$((FP+NP+4))\""
eval "sht216=\"\$F$((FP+NP+5))\""
eval "sht212=\"\$F$((FP+NP+6))\""
eval "sht209=\"\$F$((FP+NP+7))\""
sht244="${R}"
sht245="${sht244}"
eval "F$((FP+NP+0))=\"\${sht245}\""
eval "F$((FP+NP+1))=\"\${sht243}\""
eval "F$((FP+NP+2))=\"\${sht237}\""
eval "F$((FP+NP+3))=\"\${sht230}\""
eval "F$((FP+NP+4))=\"\${sht224}\""
eval "F$((FP+NP+5))=\"\${sht221}\""
eval "F$((FP+NP+6))=\"\${sht216}\""
eval "F$((FP+NP+7))=\"\${sht212}\""
eval "F$((FP+NP+8))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht245}\""
CALLEE=tmpn
RPC=134; ACTION=call; return
;;
134)
eval "sht245=\"\$F$((FP+NP+0))\""
eval "sht243=\"\$F$((FP+NP+1))\""
eval "sht237=\"\$F$((FP+NP+2))\""
eval "sht230=\"\$F$((FP+NP+3))\""
eval "sht224=\"\$F$((FP+NP+4))\""
eval "sht221=\"\$F$((FP+NP+5))\""
eval "sht216=\"\$F$((FP+NP+6))\""
eval "sht212=\"\$F$((FP+NP+7))\""
eval "sht209=\"\$F$((FP+NP+8))\""
sht246="${R}"
sht247="${sht246}"
eval "F$((FP+NP+0))=\"\${sht247}\""
eval "F$((FP+NP+1))=\"\${sht245}\""
eval "F$((FP+NP+2))=\"\${sht243}\""
eval "F$((FP+NP+3))=\"\${sht237}\""
eval "F$((FP+NP+4))=\"\${sht230}\""
eval "F$((FP+NP+5))=\"\${sht224}\""
eval "F$((FP+NP+6))=\"\${sht221}\""
eval "F$((FP+NP+7))=\"\${sht216}\""
eval "F$((FP+NP+8))=\"\${sht212}\""
eval "F$((FP+NP+9))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht245}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=135; ACTION=call; return
;;
135)
eval "sht247=\"\$F$((FP+NP+0))\""
eval "sht245=\"\$F$((FP+NP+1))\""
eval "sht243=\"\$F$((FP+NP+2))\""
eval "sht237=\"\$F$((FP+NP+3))\""
eval "sht230=\"\$F$((FP+NP+4))\""
eval "sht224=\"\$F$((FP+NP+5))\""
eval "sht221=\"\$F$((FP+NP+6))\""
eval "sht216=\"\$F$((FP+NP+7))\""
eval "sht212=\"\$F$((FP+NP+8))\""
eval "sht209=\"\$F$((FP+NP+9))\""
sht248="${R}"
sht249="T:${sht247#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht248}\""
eval "F$((FP+NP+1))=\"\${sht247}\""
eval "F$((FP+NP+2))=\"\${sht245}\""
eval "F$((FP+NP+3))=\"\${sht243}\""
eval "F$((FP+NP+4))=\"\${sht237}\""
eval "F$((FP+NP+5))=\"\${sht230}\""
eval "F$((FP+NP+6))=\"\${sht224}\""
eval "F$((FP+NP+7))=\"\${sht221}\""
eval "F$((FP+NP+8))=\"\${sht216}\""
eval "F$((FP+NP+9))=\"\${sht212}\""
eval "F$((FP+NP+10))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht249}\""
CALLEE=qset
RPC=136; ACTION=call; return
;;
136)
eval "sht248=\"\$F$((FP+NP+0))\""
eval "sht247=\"\$F$((FP+NP+1))\""
eval "sht245=\"\$F$((FP+NP+2))\""
eval "sht243=\"\$F$((FP+NP+3))\""
eval "sht237=\"\$F$((FP+NP+4))\""
eval "sht230=\"\$F$((FP+NP+5))\""
eval "sht224=\"\$F$((FP+NP+6))\""
eval "sht221=\"\$F$((FP+NP+7))\""
eval "sht216=\"\$F$((FP+NP+8))\""
eval "sht212=\"\$F$((FP+NP+9))\""
eval "sht209=\"\$F$((FP+NP+10))\""
sht250="${R}"
eval "F$((FP+NP+0))=\"\${sht247}\""
eval "F$((FP+NP+1))=\"\${sht245}\""
eval "F$((FP+NP+2))=\"\${sht243}\""
eval "F$((FP+NP+3))=\"\${sht237}\""
eval "F$((FP+NP+4))=\"\${sht230}\""
eval "F$((FP+NP+5))=\"\${sht224}\""
eval "F$((FP+NP+6))=\"\${sht221}\""
eval "F$((FP+NP+7))=\"\${sht216}\""
eval "F$((FP+NP+8))=\"\${sht212}\""
eval "F$((FP+NP+9))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht248}\""
eval "F$((NFP+1))=\"\${sht250}\""
CALLEE=emit
RPC=137; ACTION=call; return
;;
137)
eval "sht247=\"\$F$((FP+NP+0))\""
eval "sht245=\"\$F$((FP+NP+1))\""
eval "sht243=\"\$F$((FP+NP+2))\""
eval "sht237=\"\$F$((FP+NP+3))\""
eval "sht230=\"\$F$((FP+NP+4))\""
eval "sht224=\"\$F$((FP+NP+5))\""
eval "sht221=\"\$F$((FP+NP+6))\""
eval "sht216=\"\$F$((FP+NP+7))\""
eval "sht212=\"\$F$((FP+NP+8))\""
eval "sht209=\"\$F$((FP+NP+9))\""
sht251="${R}"
eval "F$((FP+NP+0))=\"\${sht251}\""
eval "F$((FP+NP+1))=\"\${sht247}\""
eval "F$((FP+NP+2))=\"\${sht245}\""
eval "F$((FP+NP+3))=\"\${sht243}\""
eval "F$((FP+NP+4))=\"\${sht237}\""
eval "F$((FP+NP+5))=\"\${sht230}\""
eval "F$((FP+NP+6))=\"\${sht224}\""
eval "F$((FP+NP+7))=\"\${sht221}\""
eval "F$((FP+NP+8))=\"\${sht216}\""
eval "F$((FP+NP+9))=\"\${sht212}\""
eval "F$((FP+NP+10))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=138; ACTION=call; return
;;
138)
eval "sht251=\"\$F$((FP+NP+0))\""
eval "sht247=\"\$F$((FP+NP+1))\""
eval "sht245=\"\$F$((FP+NP+2))\""
eval "sht243=\"\$F$((FP+NP+3))\""
eval "sht237=\"\$F$((FP+NP+4))\""
eval "sht230=\"\$F$((FP+NP+5))\""
eval "sht224=\"\$F$((FP+NP+6))\""
eval "sht221=\"\$F$((FP+NP+7))\""
eval "sht216=\"\$F$((FP+NP+8))\""
eval "sht212=\"\$F$((FP+NP+9))\""
eval "sht209=\"\$F$((FP+NP+10))\""
sht252="${R}"
eval "F$((FP+NP+0))=\"\${sht247}\""
eval "F$((FP+NP+1))=\"\${sht245}\""
eval "F$((FP+NP+2))=\"\${sht243}\""
eval "F$((FP+NP+3))=\"\${sht237}\""
eval "F$((FP+NP+4))=\"\${sht230}\""
eval "F$((FP+NP+5))=\"\${sht224}\""
eval "F$((FP+NP+6))=\"\${sht221}\""
eval "F$((FP+NP+7))=\"\${sht216}\""
eval "F$((FP+NP+8))=\"\${sht212}\""
eval "F$((FP+NP+9))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht251}\""
eval "F$((NFP+1))=\"\${sht252}\""
CALLEE=bsm
RPC=139; ACTION=call; return
;;
139)
eval "sht247=\"\$F$((FP+NP+0))\""
eval "sht245=\"\$F$((FP+NP+1))\""
eval "sht243=\"\$F$((FP+NP+2))\""
eval "sht237=\"\$F$((FP+NP+3))\""
eval "sht230=\"\$F$((FP+NP+4))\""
eval "sht224=\"\$F$((FP+NP+5))\""
eval "sht221=\"\$F$((FP+NP+6))\""
eval "sht216=\"\$F$((FP+NP+7))\""
eval "sht212=\"\$F$((FP+NP+8))\""
eval "sht209=\"\$F$((FP+NP+9))\""
sht253="${R}"
eval "F$((FP+NP+0))=\"\${sht247}\""
eval "F$((FP+NP+1))=\"\${sht245}\""
eval "F$((FP+NP+2))=\"\${sht243}\""
eval "F$((FP+NP+3))=\"\${sht237}\""
eval "F$((FP+NP+4))=\"\${sht230}\""
eval "F$((FP+NP+5))=\"\${sht224}\""
eval "F$((FP+NP+6))=\"\${sht221}\""
eval "F$((FP+NP+7))=\"\${sht216}\""
eval "F$((FP+NP+8))=\"\${sht212}\""
eval "F$((FP+NP+9))=\"\${sht209}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht253}\""
CALLEE=bkzzP
RPC=140; ACTION=call; return
;;
140)
eval "sht247=\"\$F$((FP+NP+0))\""
eval "sht245=\"\$F$((FP+NP+1))\""
eval "sht243=\"\$F$((FP+NP+2))\""
eval "sht237=\"\$F$((FP+NP+3))\""
eval "sht230=\"\$F$((FP+NP+4))\""
eval "sht224=\"\$F$((FP+NP+5))\""
eval "sht221=\"\$F$((FP+NP+6))\""
eval "sht216=\"\$F$((FP+NP+7))\""
eval "sht212=\"\$F$((FP+NP+8))\""
eval "sht209=\"\$F$((FP+NP+9))\""
sht254="${R}"
eval "F$((FP+NP+0))=\"\${sht254}\""
eval "F$((FP+NP+1))=\"\${sht247}\""
eval "F$((FP+NP+2))=\"\${sht245}\""
eval "F$((FP+NP+3))=\"\${sht243}\""
eval "F$((FP+NP+4))=\"\${sht237}\""
eval "F$((FP+NP+5))=\"\${sht230}\""
eval "F$((FP+NP+6))=\"\${sht224}\""
eval "F$((FP+NP+7))=\"\${sht221}\""
eval "F$((FP+NP+8))=\"\${sht216}\""
eval "F$((FP+NP+9))=\"\${sht212}\""
eval "F$((FP+NP+10))=\"\${sht209}\""
hp_cons "S:val" "${sht247}"
eval "sht254=\"\$F$((FP+NP+0))\""
eval "sht247=\"\$F$((FP+NP+1))\""
eval "sht245=\"\$F$((FP+NP+2))\""
eval "sht243=\"\$F$((FP+NP+3))\""
eval "sht237=\"\$F$((FP+NP+4))\""
eval "sht230=\"\$F$((FP+NP+5))\""
eval "sht224=\"\$F$((FP+NP+6))\""
eval "sht221=\"\$F$((FP+NP+7))\""
eval "sht216=\"\$F$((FP+NP+8))\""
eval "sht212=\"\$F$((FP+NP+9))\""
eval "sht209=\"\$F$((FP+NP+10))\""
sht255="${R}"
eval "F$((FP+NP+0))=\"\${sht247}\""
eval "F$((FP+NP+1))=\"\${sht245}\""
eval "F$((FP+NP+2))=\"\${sht243}\""
eval "F$((FP+NP+3))=\"\${sht237}\""
eval "F$((FP+NP+4))=\"\${sht230}\""
eval "F$((FP+NP+5))=\"\${sht224}\""
eval "F$((FP+NP+6))=\"\${sht221}\""
eval "F$((FP+NP+7))=\"\${sht216}\""
eval "F$((FP+NP+8))=\"\${sht212}\""
eval "F$((FP+NP+9))=\"\${sht209}\""
hp_cons "${sht254}" "${sht255}"
eval "sht247=\"\$F$((FP+NP+0))\""
eval "sht245=\"\$F$((FP+NP+1))\""
eval "sht243=\"\$F$((FP+NP+2))\""
eval "sht237=\"\$F$((FP+NP+3))\""
eval "sht230=\"\$F$((FP+NP+4))\""
eval "sht224=\"\$F$((FP+NP+5))\""
eval "sht221=\"\$F$((FP+NP+6))\""
eval "sht216=\"\$F$((FP+NP+7))\""
eval "sht212=\"\$F$((FP+NP+8))\""
eval "sht209=\"\$F$((FP+NP+9))\""
sht256="${R}"
R="${sht256}"; ACTION=ret; return
;;
141)
sht258="${R}"
sht259="${sht258}"
hp_cdr "${sht259}"
sht260="${R}"
hp_cdr "${sht260}"
sht261="${R}"
sht262="${sht261}"
hp_cdr "${sht259}"
sht263="${R}"
eval "F$((FP+NP+0))=\"\${sht262}\""
eval "F$((FP+NP+1))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht263}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=142; ACTION=call; return
;;
142)
eval "sht262=\"\$F$((FP+NP+0))\""
eval "sht259=\"\$F$((FP+NP+1))\""
sht264="${R}"
sht265="${sht264}"
hp_cdr "${p0}"
sht266="${R}"
hp_car "${sht259}"
sht267="${R}"
eval "F$((FP+NP+0))=\"\${sht265}\""
eval "F$((FP+NP+1))=\"\${sht262}\""
eval "F$((FP+NP+2))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht266}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht267}\""
eval "F$((NFP+3))=\"\${sht265}\""
CALLEE=largs
RPC=143; ACTION=call; return
;;
143)
eval "sht265=\"\$F$((FP+NP+0))\""
eval "sht262=\"\$F$((FP+NP+1))\""
eval "sht259=\"\$F$((FP+NP+2))\""
sht268="${R}"
sht269="${sht268}"
hp_car "${sht269}"
sht270="${R}"
eval "F$((FP+NP+0))=\"\${sht269}\""
eval "F$((FP+NP+1))=\"\${sht265}\""
eval "F$((FP+NP+2))=\"\${sht262}\""
eval "F$((FP+NP+3))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht270}\""
CALLEE=b_npc
RPC=144; ACTION=call; return
;;
144)
eval "sht269=\"\$F$((FP+NP+0))\""
eval "sht265=\"\$F$((FP+NP+1))\""
eval "sht262=\"\$F$((FP+NP+2))\""
eval "sht259=\"\$F$((FP+NP+3))\""
sht271="${R}"
sht272="${sht271}"
hp_car "${sht269}"
sht273="${R}"
eval "F$((FP+NP+0))=\"\${sht272}\""
eval "F$((FP+NP+1))=\"\${sht269}\""
eval "F$((FP+NP+2))=\"\${sht265}\""
eval "F$((FP+NP+3))=\"\${sht262}\""
eval "F$((FP+NP+4))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht273}\""
CALLEE=bnpczzP
RPC=145; ACTION=call; return
;;
145)
eval "sht272=\"\$F$((FP+NP+0))\""
eval "sht269=\"\$F$((FP+NP+1))\""
eval "sht265=\"\$F$((FP+NP+2))\""
eval "sht262=\"\$F$((FP+NP+3))\""
eval "sht259=\"\$F$((FP+NP+4))\""
sht274="${R}"
eval "F$((FP+NP+0))=\"\${sht272}\""
eval "F$((FP+NP+1))=\"\${sht269}\""
eval "F$((FP+NP+2))=\"\${sht265}\""
eval "F$((FP+NP+3))=\"\${sht262}\""
eval "F$((FP+NP+4))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht274}\""
eval "F$((NFP+1))=\"\${sht265}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=146; ACTION=call; return
;;
146)
eval "sht272=\"\$F$((FP+NP+0))\""
eval "sht269=\"\$F$((FP+NP+1))\""
eval "sht265=\"\$F$((FP+NP+2))\""
eval "sht262=\"\$F$((FP+NP+3))\""
eval "sht259=\"\$F$((FP+NP+4))\""
sht275="${R}"
eval "F$((FP+NP+0))=\"\${sht272}\""
eval "F$((FP+NP+1))=\"\${sht269}\""
eval "F$((FP+NP+2))=\"\${sht265}\""
eval "F$((FP+NP+3))=\"\${sht262}\""
eval "F$((FP+NP+4))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht275}\""
STGV="T:set /a NFP=!FT!"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=147; ACTION=call; return
;;
147)
eval "sht272=\"\$F$((FP+NP+0))\""
eval "sht269=\"\$F$((FP+NP+1))\""
eval "sht265=\"\$F$((FP+NP+2))\""
eval "sht262=\"\$F$((FP+NP+3))\""
eval "sht259=\"\$F$((FP+NP+4))\""
sht276="${R}"
sht277="${sht276}"
hp_cdr "${sht269}"
sht278="${R}"
eval "F$((FP+NP+0))=\"\${sht277}\""
eval "F$((FP+NP+1))=\"\${sht272}\""
eval "F$((FP+NP+2))=\"\${sht269}\""
eval "F$((FP+NP+3))=\"\${sht265}\""
eval "F$((FP+NP+4))=\"\${sht262}\""
eval "F$((FP+NP+5))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht277}\""
eval "F$((NFP+1))=\"\${sht278}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=148; ACTION=call; return
;;
148)
eval "sht277=\"\$F$((FP+NP+0))\""
eval "sht272=\"\$F$((FP+NP+1))\""
eval "sht269=\"\$F$((FP+NP+2))\""
eval "sht265=\"\$F$((FP+NP+3))\""
eval "sht262=\"\$F$((FP+NP+4))\""
eval "sht259=\"\$F$((FP+NP+5))\""
sht279="${R}"
sht280="${sht279}"
sht281="T:!${G_DQ#??}"
sht282="T:${sht262#??}${sht281#??}"
sht283="T:CALLEE=!${sht282#??}"
sht284="T:${G_DQ#??}${sht283#??}"
sht285="T:set ${sht284#??}"
eval "F$((FP+NP+0))=\"\${sht280}\""
eval "F$((FP+NP+1))=\"\${sht277}\""
eval "F$((FP+NP+2))=\"\${sht272}\""
eval "F$((FP+NP+3))=\"\${sht269}\""
eval "F$((FP+NP+4))=\"\${sht265}\""
eval "F$((FP+NP+5))=\"\${sht262}\""
eval "F$((FP+NP+6))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht280}\""
eval "F$((NFP+1))=\"\${sht285}\""
CALLEE=emit
RPC=149; ACTION=call; return
;;
149)
eval "sht280=\"\$F$((FP+NP+0))\""
eval "sht277=\"\$F$((FP+NP+1))\""
eval "sht272=\"\$F$((FP+NP+2))\""
eval "sht269=\"\$F$((FP+NP+3))\""
eval "sht265=\"\$F$((FP+NP+4))\""
eval "sht262=\"\$F$((FP+NP+5))\""
eval "sht259=\"\$F$((FP+NP+6))\""
sht286="${R}"
sht287="${sht286}"
sht288="T:${sht272#??}"
sht289="T:${sht288#??}${G_DQ#??}"
sht290="T:RPC=${sht289#??}"
sht291="T:${G_DQ#??}${sht290#??}"
sht292="T:set ${sht291#??}"
eval "F$((FP+NP+0))=\"\${sht287}\""
eval "F$((FP+NP+1))=\"\${sht280}\""
eval "F$((FP+NP+2))=\"\${sht277}\""
eval "F$((FP+NP+3))=\"\${sht272}\""
eval "F$((FP+NP+4))=\"\${sht269}\""
eval "F$((FP+NP+5))=\"\${sht265}\""
eval "F$((FP+NP+6))=\"\${sht262}\""
eval "F$((FP+NP+7))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht287}\""
eval "F$((NFP+1))=\"\${sht292}\""
CALLEE=emit
RPC=150; ACTION=call; return
;;
150)
eval "sht287=\"\$F$((FP+NP+0))\""
eval "sht280=\"\$F$((FP+NP+1))\""
eval "sht277=\"\$F$((FP+NP+2))\""
eval "sht272=\"\$F$((FP+NP+3))\""
eval "sht269=\"\$F$((FP+NP+4))\""
eval "sht265=\"\$F$((FP+NP+5))\""
eval "sht262=\"\$F$((FP+NP+6))\""
eval "sht259=\"\$F$((FP+NP+7))\""
sht293="${R}"
sht294="${sht293}"
sht295="T:${G_DQ#??} & goto :eof"
sht296="T:ACTION=call${sht295#??}"
sht297="T:${G_DQ#??}${sht296#??}"
sht298="T:set ${sht297#??}"
eval "F$((FP+NP+0))=\"\${sht294}\""
eval "F$((FP+NP+1))=\"\${sht287}\""
eval "F$((FP+NP+2))=\"\${sht280}\""
eval "F$((FP+NP+3))=\"\${sht277}\""
eval "F$((FP+NP+4))=\"\${sht272}\""
eval "F$((FP+NP+5))=\"\${sht269}\""
eval "F$((FP+NP+6))=\"\${sht265}\""
eval "F$((FP+NP+7))=\"\${sht262}\""
eval "F$((FP+NP+8))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht294}\""
eval "F$((NFP+1))=\"\${sht298}\""
CALLEE=emit
RPC=151; ACTION=call; return
;;
151)
eval "sht294=\"\$F$((FP+NP+0))\""
eval "sht287=\"\$F$((FP+NP+1))\""
eval "sht280=\"\$F$((FP+NP+2))\""
eval "sht277=\"\$F$((FP+NP+3))\""
eval "sht272=\"\$F$((FP+NP+4))\""
eval "sht269=\"\$F$((FP+NP+5))\""
eval "sht265=\"\$F$((FP+NP+6))\""
eval "sht262=\"\$F$((FP+NP+7))\""
eval "sht259=\"\$F$((FP+NP+8))\""
sht299="${R}"
sht300="${sht299}"
eval "F$((FP+NP+0))=\"\${sht300}\""
eval "F$((FP+NP+1))=\"\${sht294}\""
eval "F$((FP+NP+2))=\"\${sht287}\""
eval "F$((FP+NP+3))=\"\${sht280}\""
eval "F$((FP+NP+4))=\"\${sht277}\""
eval "F$((FP+NP+5))=\"\${sht272}\""
eval "F$((FP+NP+6))=\"\${sht269}\""
eval "F$((FP+NP+7))=\"\${sht265}\""
eval "F$((FP+NP+8))=\"\${sht262}\""
eval "F$((FP+NP+9))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht300}\""
eval "F$((NFP+1))=\"\${sht272}\""
CALLEE=switch
RPC=152; ACTION=call; return
;;
152)
eval "sht300=\"\$F$((FP+NP+0))\""
eval "sht294=\"\$F$((FP+NP+1))\""
eval "sht287=\"\$F$((FP+NP+2))\""
eval "sht280=\"\$F$((FP+NP+3))\""
eval "sht277=\"\$F$((FP+NP+4))\""
eval "sht272=\"\$F$((FP+NP+5))\""
eval "sht269=\"\$F$((FP+NP+6))\""
eval "sht265=\"\$F$((FP+NP+7))\""
eval "sht262=\"\$F$((FP+NP+8))\""
eval "sht259=\"\$F$((FP+NP+9))\""
sht301="${R}"
sht302="${sht301}"
eval "F$((FP+NP+0))=\"\${sht302}\""
eval "F$((FP+NP+1))=\"\${sht300}\""
eval "F$((FP+NP+2))=\"\${sht294}\""
eval "F$((FP+NP+3))=\"\${sht287}\""
eval "F$((FP+NP+4))=\"\${sht280}\""
eval "F$((FP+NP+5))=\"\${sht277}\""
eval "F$((FP+NP+6))=\"\${sht272}\""
eval "F$((FP+NP+7))=\"\${sht269}\""
eval "F$((FP+NP+8))=\"\${sht265}\""
eval "F$((FP+NP+9))=\"\${sht262}\""
eval "F$((FP+NP+10))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht302}\""
CALLEE=tmpn
RPC=153; ACTION=call; return
;;
153)
eval "sht302=\"\$F$((FP+NP+0))\""
eval "sht300=\"\$F$((FP+NP+1))\""
eval "sht294=\"\$F$((FP+NP+2))\""
eval "sht287=\"\$F$((FP+NP+3))\""
eval "sht280=\"\$F$((FP+NP+4))\""
eval "sht277=\"\$F$((FP+NP+5))\""
eval "sht272=\"\$F$((FP+NP+6))\""
eval "sht269=\"\$F$((FP+NP+7))\""
eval "sht265=\"\$F$((FP+NP+8))\""
eval "sht262=\"\$F$((FP+NP+9))\""
eval "sht259=\"\$F$((FP+NP+10))\""
sht303="${R}"
sht304="${sht303}"
eval "F$((FP+NP+0))=\"\${sht304}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht300}\""
eval "F$((FP+NP+3))=\"\${sht294}\""
eval "F$((FP+NP+4))=\"\${sht287}\""
eval "F$((FP+NP+5))=\"\${sht280}\""
eval "F$((FP+NP+6))=\"\${sht277}\""
eval "F$((FP+NP+7))=\"\${sht272}\""
eval "F$((FP+NP+8))=\"\${sht269}\""
eval "F$((FP+NP+9))=\"\${sht265}\""
eval "F$((FP+NP+10))=\"\${sht262}\""
eval "F$((FP+NP+11))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht302}\""
eval "F$((NFP+1))=\"\${sht265}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=154; ACTION=call; return
;;
154)
eval "sht304=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht300=\"\$F$((FP+NP+2))\""
eval "sht294=\"\$F$((FP+NP+3))\""
eval "sht287=\"\$F$((FP+NP+4))\""
eval "sht280=\"\$F$((FP+NP+5))\""
eval "sht277=\"\$F$((FP+NP+6))\""
eval "sht272=\"\$F$((FP+NP+7))\""
eval "sht269=\"\$F$((FP+NP+8))\""
eval "sht265=\"\$F$((FP+NP+9))\""
eval "sht262=\"\$F$((FP+NP+10))\""
eval "sht259=\"\$F$((FP+NP+11))\""
sht305="${R}"
sht306="T:${sht304#??}=!R!"
eval "F$((FP+NP+0))=\"\${sht305}\""
eval "F$((FP+NP+1))=\"\${sht304}\""
eval "F$((FP+NP+2))=\"\${sht302}\""
eval "F$((FP+NP+3))=\"\${sht300}\""
eval "F$((FP+NP+4))=\"\${sht294}\""
eval "F$((FP+NP+5))=\"\${sht287}\""
eval "F$((FP+NP+6))=\"\${sht280}\""
eval "F$((FP+NP+7))=\"\${sht277}\""
eval "F$((FP+NP+8))=\"\${sht272}\""
eval "F$((FP+NP+9))=\"\${sht269}\""
eval "F$((FP+NP+10))=\"\${sht265}\""
eval "F$((FP+NP+11))=\"\${sht262}\""
eval "F$((FP+NP+12))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht306}\""
CALLEE=qset
RPC=155; ACTION=call; return
;;
155)
eval "sht305=\"\$F$((FP+NP+0))\""
eval "sht304=\"\$F$((FP+NP+1))\""
eval "sht302=\"\$F$((FP+NP+2))\""
eval "sht300=\"\$F$((FP+NP+3))\""
eval "sht294=\"\$F$((FP+NP+4))\""
eval "sht287=\"\$F$((FP+NP+5))\""
eval "sht280=\"\$F$((FP+NP+6))\""
eval "sht277=\"\$F$((FP+NP+7))\""
eval "sht272=\"\$F$((FP+NP+8))\""
eval "sht269=\"\$F$((FP+NP+9))\""
eval "sht265=\"\$F$((FP+NP+10))\""
eval "sht262=\"\$F$((FP+NP+11))\""
eval "sht259=\"\$F$((FP+NP+12))\""
sht307="${R}"
eval "F$((FP+NP+0))=\"\${sht304}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht300}\""
eval "F$((FP+NP+3))=\"\${sht294}\""
eval "F$((FP+NP+4))=\"\${sht287}\""
eval "F$((FP+NP+5))=\"\${sht280}\""
eval "F$((FP+NP+6))=\"\${sht277}\""
eval "F$((FP+NP+7))=\"\${sht272}\""
eval "F$((FP+NP+8))=\"\${sht269}\""
eval "F$((FP+NP+9))=\"\${sht265}\""
eval "F$((FP+NP+10))=\"\${sht262}\""
eval "F$((FP+NP+11))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht305}\""
eval "F$((NFP+1))=\"\${sht307}\""
CALLEE=emit
RPC=156; ACTION=call; return
;;
156)
eval "sht304=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht300=\"\$F$((FP+NP+2))\""
eval "sht294=\"\$F$((FP+NP+3))\""
eval "sht287=\"\$F$((FP+NP+4))\""
eval "sht280=\"\$F$((FP+NP+5))\""
eval "sht277=\"\$F$((FP+NP+6))\""
eval "sht272=\"\$F$((FP+NP+7))\""
eval "sht269=\"\$F$((FP+NP+8))\""
eval "sht265=\"\$F$((FP+NP+9))\""
eval "sht262=\"\$F$((FP+NP+10))\""
eval "sht259=\"\$F$((FP+NP+11))\""
sht308="${R}"
eval "F$((FP+NP+0))=\"\${sht308}\""
eval "F$((FP+NP+1))=\"\${sht304}\""
eval "F$((FP+NP+2))=\"\${sht302}\""
eval "F$((FP+NP+3))=\"\${sht300}\""
eval "F$((FP+NP+4))=\"\${sht294}\""
eval "F$((FP+NP+5))=\"\${sht287}\""
eval "F$((FP+NP+6))=\"\${sht280}\""
eval "F$((FP+NP+7))=\"\${sht277}\""
eval "F$((FP+NP+8))=\"\${sht272}\""
eval "F$((FP+NP+9))=\"\${sht269}\""
eval "F$((FP+NP+10))=\"\${sht265}\""
eval "F$((FP+NP+11))=\"\${sht262}\""
eval "F$((FP+NP+12))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht265}\""
CALLEE=lenl
RPC=157; ACTION=call; return
;;
157)
eval "sht308=\"\$F$((FP+NP+0))\""
eval "sht304=\"\$F$((FP+NP+1))\""
eval "sht302=\"\$F$((FP+NP+2))\""
eval "sht300=\"\$F$((FP+NP+3))\""
eval "sht294=\"\$F$((FP+NP+4))\""
eval "sht287=\"\$F$((FP+NP+5))\""
eval "sht280=\"\$F$((FP+NP+6))\""
eval "sht277=\"\$F$((FP+NP+7))\""
eval "sht272=\"\$F$((FP+NP+8))\""
eval "sht269=\"\$F$((FP+NP+9))\""
eval "sht265=\"\$F$((FP+NP+10))\""
eval "sht262=\"\$F$((FP+NP+11))\""
eval "sht259=\"\$F$((FP+NP+12))\""
sht309="${R}"
eval "F$((FP+NP+0))=\"\${sht304}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht300}\""
eval "F$((FP+NP+3))=\"\${sht294}\""
eval "F$((FP+NP+4))=\"\${sht287}\""
eval "F$((FP+NP+5))=\"\${sht280}\""
eval "F$((FP+NP+6))=\"\${sht277}\""
eval "F$((FP+NP+7))=\"\${sht272}\""
eval "F$((FP+NP+8))=\"\${sht269}\""
eval "F$((FP+NP+9))=\"\${sht265}\""
eval "F$((FP+NP+10))=\"\${sht262}\""
eval "F$((FP+NP+11))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht308}\""
eval "F$((NFP+1))=\"\${sht309}\""
CALLEE=bsm
RPC=158; ACTION=call; return
;;
158)
eval "sht304=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht300=\"\$F$((FP+NP+2))\""
eval "sht294=\"\$F$((FP+NP+3))\""
eval "sht287=\"\$F$((FP+NP+4))\""
eval "sht280=\"\$F$((FP+NP+5))\""
eval "sht277=\"\$F$((FP+NP+6))\""
eval "sht272=\"\$F$((FP+NP+7))\""
eval "sht269=\"\$F$((FP+NP+8))\""
eval "sht265=\"\$F$((FP+NP+9))\""
eval "sht262=\"\$F$((FP+NP+10))\""
eval "sht259=\"\$F$((FP+NP+11))\""
sht310="${R}"
eval "F$((FP+NP+0))=\"\${sht304}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht300}\""
eval "F$((FP+NP+3))=\"\${sht294}\""
eval "F$((FP+NP+4))=\"\${sht287}\""
eval "F$((FP+NP+5))=\"\${sht280}\""
eval "F$((FP+NP+6))=\"\${sht277}\""
eval "F$((FP+NP+7))=\"\${sht272}\""
eval "F$((FP+NP+8))=\"\${sht269}\""
eval "F$((FP+NP+9))=\"\${sht265}\""
eval "F$((FP+NP+10))=\"\${sht262}\""
eval "F$((FP+NP+11))=\"\${sht259}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht310}\""
CALLEE=bkzzP
RPC=159; ACTION=call; return
;;
159)
eval "sht304=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht300=\"\$F$((FP+NP+2))\""
eval "sht294=\"\$F$((FP+NP+3))\""
eval "sht287=\"\$F$((FP+NP+4))\""
eval "sht280=\"\$F$((FP+NP+5))\""
eval "sht277=\"\$F$((FP+NP+6))\""
eval "sht272=\"\$F$((FP+NP+7))\""
eval "sht269=\"\$F$((FP+NP+8))\""
eval "sht265=\"\$F$((FP+NP+9))\""
eval "sht262=\"\$F$((FP+NP+10))\""
eval "sht259=\"\$F$((FP+NP+11))\""
sht311="${R}"
eval "F$((FP+NP+0))=\"\${sht311}\""
eval "F$((FP+NP+1))=\"\${sht304}\""
eval "F$((FP+NP+2))=\"\${sht302}\""
eval "F$((FP+NP+3))=\"\${sht300}\""
eval "F$((FP+NP+4))=\"\${sht294}\""
eval "F$((FP+NP+5))=\"\${sht287}\""
eval "F$((FP+NP+6))=\"\${sht280}\""
eval "F$((FP+NP+7))=\"\${sht277}\""
eval "F$((FP+NP+8))=\"\${sht272}\""
eval "F$((FP+NP+9))=\"\${sht269}\""
eval "F$((FP+NP+10))=\"\${sht265}\""
eval "F$((FP+NP+11))=\"\${sht262}\""
eval "F$((FP+NP+12))=\"\${sht259}\""
hp_cons "S:val" "${sht304}"
eval "sht311=\"\$F$((FP+NP+0))\""
eval "sht304=\"\$F$((FP+NP+1))\""
eval "sht302=\"\$F$((FP+NP+2))\""
eval "sht300=\"\$F$((FP+NP+3))\""
eval "sht294=\"\$F$((FP+NP+4))\""
eval "sht287=\"\$F$((FP+NP+5))\""
eval "sht280=\"\$F$((FP+NP+6))\""
eval "sht277=\"\$F$((FP+NP+7))\""
eval "sht272=\"\$F$((FP+NP+8))\""
eval "sht269=\"\$F$((FP+NP+9))\""
eval "sht265=\"\$F$((FP+NP+10))\""
eval "sht262=\"\$F$((FP+NP+11))\""
eval "sht259=\"\$F$((FP+NP+12))\""
sht312="${R}"
eval "F$((FP+NP+0))=\"\${sht304}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht300}\""
eval "F$((FP+NP+3))=\"\${sht294}\""
eval "F$((FP+NP+4))=\"\${sht287}\""
eval "F$((FP+NP+5))=\"\${sht280}\""
eval "F$((FP+NP+6))=\"\${sht277}\""
eval "F$((FP+NP+7))=\"\${sht272}\""
eval "F$((FP+NP+8))=\"\${sht269}\""
eval "F$((FP+NP+9))=\"\${sht265}\""
eval "F$((FP+NP+10))=\"\${sht262}\""
eval "F$((FP+NP+11))=\"\${sht259}\""
hp_cons "${sht311}" "${sht312}"
eval "sht304=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht300=\"\$F$((FP+NP+2))\""
eval "sht294=\"\$F$((FP+NP+3))\""
eval "sht287=\"\$F$((FP+NP+4))\""
eval "sht280=\"\$F$((FP+NP+5))\""
eval "sht277=\"\$F$((FP+NP+6))\""
eval "sht272=\"\$F$((FP+NP+7))\""
eval "sht269=\"\$F$((FP+NP+8))\""
eval "sht265=\"\$F$((FP+NP+9))\""
eval "sht262=\"\$F$((FP+NP+10))\""
eval "sht259=\"\$F$((FP+NP+11))\""
sht313="${R}"
R="${sht313}"; ACTION=ret; return
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
SIZE_compile_fn=15
compile_fn() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
eval "p6=\"\$F$((FP+6))\""
FTOP=$((FP + SIZE_compile_fn))
NP=7
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
hp_cons "T:\$GFNS" "${p6}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=pmap_fr
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht2}" "${sht3}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
sht5="${sht4}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${p3}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
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
eval "sht5=\"\$F$((FP+NP+2))\""
eval "p3=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht5}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht1}\""
eval "F$((NFP+4))=\"\${sht6}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltail
RPC=4; ACTION=call; return
;;
4)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht7="${R}"
sht8="${sht7}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_pc
RPC=5; ACTION=call; return
;;
5)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_cur
RPC=6; ACTION=call; return
;;
6)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=7; ACTION=call; return
;;
7)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht9}" "${sht11}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_blk
RPC=8; ACTION=call; return
;;
8)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht12}" "${sht13}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht14="${R}"
sht15="${sht14}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_smax
RPC=9; ACTION=call; return
;;
9)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht16="${R}"
sht17="I:$(( ${sht1#??} + ${sht16#??} ))"
sht18="${sht17}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=10; ACTION=call; return
;;
10)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht19="${R}"
sht20="T:${sht18#??}"
sht21="T:set /a FT=!FP!+${sht20#??}"
sht22="T:${sht1#??}"
sht23="T:NP=${sht22#??}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht18}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=qset
RPC=11; ACTION=call; return
;;
11)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht18=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht18}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht24}" "NIL"
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht18=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht25="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht21}" "${sht25}"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
eval "F$((NFP+1))=\"\${sht26}\""
CALLEE=append
RPC=12; ACTION=call; return
;;
12)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht27="${R}"
sht28="${sht27}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht28}\""
eval "F$((FP+NP+2))=\"\${sht28}\""
eval "F$((FP+NP+3))=\"\${sht18}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht5}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=b_npc
RPC=13; ACTION=call; return
;;
13)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht28=\"\$F$((FP+NP+1))\""
eval "sht28=\"\$F$((FP+NP+2))\""
eval "sht18=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht5=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht28}\""
eval "F$((NFP+1))=\"\${sht15}\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"\${sht29}\""
eval "F$((NFP+4))=\"\${p1}\""
CALLEE=seg_files
RPC=14; ACTION=call; return
;;
14)
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht30}" "${p4}"
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht31="${R}"
R="${sht31}"; ACTION=ret; return
;;
esac; }
SIZE_compile_clambda=14
compile_clambda() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_compile_clambda))
NP=5
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=lenl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "T:\$GFNS" "${p4}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=append
RPC=2; ACTION=call; return
;;
2)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=pmap_fr
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht2}" "${sht4}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="${sht5}"
sht7="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=mangle
RPC=4; ACTION=call; return
;;
4)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht8="${R}"
sht9="${sht8}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${p3}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
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
RPC=5; ACTION=call; return
;;
5)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "p3=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht6}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht1}\""
eval "F$((NFP+4))=\"\${sht10}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltail
RPC=6; ACTION=call; return
;;
6)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht11="${R}"
sht12="${sht11}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_pc
RPC=7; ACTION=call; return
;;
7)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_cur
RPC=8; ACTION=call; return
;;
8)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=9; ACTION=call; return
;;
9)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
hp_cons "${sht13}" "${sht15}"
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_blk
RPC=10; ACTION=call; return
;;
10)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
hp_cons "${sht16}" "${sht17}"
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht18="${R}"
sht19="${sht18}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_smax
RPC=11; ACTION=call; return
;;
11)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht20="${R}"
sht21="I:$(( ${sht1#??} + ${sht20#??} ))"
sht22="${sht21}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=12; ACTION=call; return
;;
12)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht1}\""
CALLEE=cap_loads
RPC=13; ACTION=call; return
;;
13)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht24="${R}"
sht25="T:${sht22#??}"
sht26="T:set /a FT=!FP!+${sht25#??}"
sht27="T:${sht1#??}"
sht28="T:NP=${sht27#??}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht28}\""
CALLEE=qset
RPC=14; ACTION=call; return
;;
14)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
hp_cons "${sht29}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${sht23}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht6}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
hp_cons "${sht26}" "${sht30}"
eval "sht24=\"\$F$((FP+NP+0))\""
eval "sht23=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht6=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
eval "F$((NFP+1))=\"\${sht31}\""
CALLEE=append
RPC=15; ACTION=call; return
;;
15)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
eval "F$((NFP+1))=\"\${sht32}\""
CALLEE=append
RPC=16; ACTION=call; return
;;
16)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht33="${R}"
sht34="${sht33}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht34}\""
eval "F$((FP+NP+2))=\"\${sht34}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_npc
RPC=17; ACTION=call; return
;;
17)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht34=\"\$F$((FP+NP+1))\""
eval "sht34=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht34}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${sht19}\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"\${sht35}\""
eval "F$((NFP+4))=\"\${sht9}\""
CALLEE=seg_files
RPC=18; ACTION=call; return
;;
18)
eval "sht34=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht36="${R}"
R="${sht36}"; ACTION=ret; return
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
SIZE_def_clambdazzQ=1
def_clambdazzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_def_clambdazzQ))
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
if [ "${sht3}" = "S:clambda" ]; then
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
hp_cdr "${sht2}"
sht3="${R}"
hp_cons "S:begin" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
hp_car "${p0}"
sht7="${R}"
hp_cdr "${sht7}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
hp_cons "S:begin" "${sht8}"
eval "sht6=\"\$F$((FP+NP+0))\""
sht9="${R}"
hp_cdr "${p0}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=cond_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
hp_cons "${sht11}" "NIL"
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
hp_cons "${sht9}" "${sht12}"
eval "sht6=\"\$F$((FP+NP+0))\""
sht13="${R}"
hp_cons "${sht6}" "${sht13}"
sht14="${R}"
hp_cons "S:if" "${sht14}"
sht15="${R}"
R="${sht15}"; ACTION=ret; return
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
SIZE_and_zzGif=3
and_zzGif() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_and_zzGif))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
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
CALLEE=and_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "S:nil" "NIL"
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "${sht5}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht2}" "${sht6}"
sht7="${R}"
hp_cons "S:if" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_or_zzGif=2
or_zzGif() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_or_zzGif))
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
hp_cons "${sht2}" "NIL"
sht3="${R}"
hp_cons "S:__or" "${sht3}"
sht4="${R}"
hp_cons "${sht4}" "NIL"
sht5="${R}"
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=or_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "${sht7}" "NIL"
eval "sht5=\"\$F$((FP+NP+0))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "S:__or" "${sht8}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "S:__or" "${sht9}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "S:if" "${sht10}"
eval "sht5=\"\$F$((FP+NP+0))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
hp_cons "${sht11}" "NIL"
eval "sht5=\"\$F$((FP+NP+0))\""
sht12="${R}"
hp_cons "${sht5}" "${sht12}"
sht13="${R}"
hp_cons "S:let" "${sht13}"
sht14="${R}"
R="${sht14}"; ACTION=ret; return
;;
esac; }
SIZE_when_zzGif=4
when_zzGif() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_when_zzGif))
NP=2
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:begin" "${p1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
eval "F$((FP+NP+1))=\"\${p0}\""
hp_cons "S:nil" "NIL"
eval "sht0=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht0}" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${p0}" "${sht2}"
sht3="${R}"
hp_cons "S:if" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_unless_zzGif=3
unless_zzGif() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_unless_zzGif))
NP=2
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:begin" "${p1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht0}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "S:nil" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${p0}" "${sht2}"
sht3="${R}"
hp_cons "S:if" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_case_clause=1
case_clause() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_case_clause))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:else" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
hp_cons "S:t" "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht3="${R}"
hp_cons "${sht3}" "NIL"
sht4="${R}"
hp_cons "S:quote" "${sht4}"
sht5="${R}"
hp_cons "${sht5}" "NIL"
sht6="${R}"
hp_cons "S:__case" "${sht6}"
sht7="${R}"
hp_cons "S:eq?" "${sht7}"
sht8="${R}"
hp_cdr "${p0}"
sht9="${R}"
hp_cons "${sht8}" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_case_clauses=2
case_clauses() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_case_clauses))
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
CALLEE=case_clause
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=case_clauses
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
SIZE_case_zzGcond=3
case_zzGcond() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_case_zzGcond))
NP=2
case $PC in
0)
hp_cons "${p0}" "NIL"
sht0="${R}"
hp_cons "S:__case" "${sht0}"
sht1="${R}"
hp_cons "${sht1}" "NIL"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
CALLEE=case_clauses
RPC=1; ACTION=call; return
;;
1)
eval "sht2=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "S:cond" "${sht3}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:let" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_letzzS_zzGlets=3
letzzS_zzGlets() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_letzzS_zzGlets))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "S:begin" "${p1}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
hp_cons "${sht1}" "NIL"
sht2="${R}"
hp_cdr "${p0}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=letzzS_zzGlets
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht4}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
hp_cons "S:let" "${sht6}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
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
if [ "${sht1}" = "S:lambda" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=map_mexpand
RPC=7; ACTION=call; return
;;
6)
hp_car "${p0}"
sht9="${R}"
if [ "${sht9}" = "S:cond" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
hp_cons "S:lambda" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
8)
hp_cdr "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
CALLEE=cond_zzGif
RPC=10; ACTION=call; return
;;
9)
hp_car "${p0}"
sht12="${R}"
if [ "${sht12}" = "S:and" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
10)
sht11="${R}"
eval "F$((FP+0))=\"\${sht11}\""
PC=0; ACTION=tail; return
;;
11)
hp_cdr "${p0}"
sht13="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=and_zzGif
RPC=13; ACTION=call; return
;;
12)
hp_car "${p0}"
sht15="${R}"
if [ "${sht15}" = "S:or" ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
13)
sht14="${R}"
eval "F$((FP+0))=\"\${sht14}\""
PC=0; ACTION=tail; return
;;
14)
hp_cdr "${p0}"
sht16="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=or_zzGif
RPC=16; ACTION=call; return
;;
15)
hp_car "${p0}"
sht18="${R}"
if [ "${sht18}" = "S:when" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
16)
sht17="${R}"
eval "F$((FP+0))=\"\${sht17}\""
PC=0; ACTION=tail; return
;;
17)
hp_cdr "${p0}"
sht19="${R}"
hp_car "${sht19}"
sht20="${R}"
hp_cdr "${p0}"
sht21="${R}"
hp_cdr "${sht21}"
sht22="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht22}\""
CALLEE=when_zzGif
RPC=19; ACTION=call; return
;;
18)
hp_car "${p0}"
sht24="${R}"
if [ "${sht24}" = "S:unless" ]; then PC=20; else PC=21; fi
ACTION=jump; return
;;
19)
sht23="${R}"
eval "F$((FP+0))=\"\${sht23}\""
PC=0; ACTION=tail; return
;;
20)
hp_cdr "${p0}"
sht25="${R}"
hp_car "${sht25}"
sht26="${R}"
hp_cdr "${p0}"
sht27="${R}"
hp_cdr "${sht27}"
sht28="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht28}\""
CALLEE=unless_zzGif
RPC=22; ACTION=call; return
;;
21)
hp_car "${p0}"
sht30="${R}"
if [ "${sht30}" = "S:case" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
22)
sht29="${R}"
eval "F$((FP+0))=\"\${sht29}\""
PC=0; ACTION=tail; return
;;
23)
hp_cdr "${p0}"
sht31="${R}"
hp_car "${sht31}"
sht32="${R}"
hp_cdr "${p0}"
sht33="${R}"
hp_cdr "${sht33}"
sht34="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht34}\""
CALLEE=case_zzGcond
RPC=25; ACTION=call; return
;;
24)
hp_car "${p0}"
sht36="${R}"
if [ "${sht36}" = "S:let*" ]; then PC=26; else PC=27; fi
ACTION=jump; return
;;
25)
sht35="${R}"
eval "F$((FP+0))=\"\${sht35}\""
PC=0; ACTION=tail; return
;;
26)
hp_cdr "${p0}"
sht37="${R}"
hp_car "${sht37}"
sht38="${R}"
hp_cdr "${p0}"
sht39="${R}"
hp_cdr "${sht39}"
sht40="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht38}\""
eval "F$((NFP+1))=\"\${sht40}\""
CALLEE=letzzS_zzGlets
RPC=28; ACTION=call; return
;;
27)
hp_car "${p0}"
sht42="${R}"
if [ "${sht42}" = "S:str" ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
28)
sht41="${R}"
eval "F$((FP+0))=\"\${sht41}\""
PC=0; ACTION=tail; return
;;
29)
hp_cdr "${p0}"
sht43="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
CALLEE=map_mexpand
RPC=31; ACTION=call; return
;;
30)
hp_car "${p0}"
sht46="${R}"
if [ "${sht46}" = "S:list" ]; then PC=33; else PC=34; fi
ACTION=jump; return
;;
31)
sht44="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht44}\""
CALLEE=str_zzGapp
RPC=32; ACTION=call; return
;;
32)
sht45="${R}"
R="${sht45}"; ACTION=ret; return
;;
33)
hp_cdr "${p0}"
sht47="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=map_mexpand
RPC=35; ACTION=call; return
;;
34)
hp_car "${p0}"
sht50="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht50}\""
CALLEE=mexpand
RPC=37; ACTION=call; return
;;
35)
sht48="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
CALLEE=list_zzGcons
RPC=36; ACTION=call; return
;;
36)
sht49="${R}"
R="${sht49}"; ACTION=ret; return
;;
37)
sht51="${R}"
sht52="${sht51}"
hp_cdr "${p0}"
sht53="${R}"
eval "F$((FP+NP+0))=\"\${sht52}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
CALLEE=mexpand
RPC=38; ACTION=call; return
;;
38)
eval "sht52=\"\$F$((FP+NP+0))\""
sht54="${R}"
sht55="${sht54}"
hp_car "${p0}"
sht56="${R}"
if [ "${sht52}" = "${sht56}" ]; then PC=39; else PC=40; fi
ACTION=jump; return
;;
39)
hp_cdr "${p0}"
sht58="${R}"
if [ "${sht55}" = "${sht58}" ]; then
sht59="S:t"
else
sht59="NIL"
fi
sht57="${sht59}"
PC=41; ACTION=jump; return
;;
40)
sht57="NIL"
PC=41; ACTION=jump; return
;;
41)
if [ "${sht57}" != NIL ]; then PC=42; else PC=43; fi
ACTION=jump; return
;;
42)
R="${p0}"; ACTION=ret; return
;;
43)
eval "F$((FP+NP+0))=\"\${sht55}\""
eval "F$((FP+NP+1))=\"\${sht52}\""
hp_cons "${sht52}" "${sht55}"
eval "sht55=\"\$F$((FP+NP+0))\""
eval "sht52=\"\$F$((FP+NP+1))\""
sht60="${R}"
R="${sht60}"; ACTION=ret; return
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
SIZE_cp=10
cp() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_cp))
NP=6
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
CALLEE=def_clambdazzQ
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
CALLEE=caddr
RPC=6; ACTION=call; return
;;
5)
hp_car "${p0}"
sht14="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
CALLEE=def_lambdazzQ
RPC=13; ACTION=call; return
;;
6)
sht4="${R}"
sht5="${sht4}"
hp_car "${p0}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=cadr
RPC=7; ACTION=call; return
;;
7)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=cadr
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=caddr
RPC=9; ACTION=call; return
;;
9)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
CALLEE=cadddr
RPC=10; ACTION=call; return
;;
10)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht8}\""
eval "F$((NFP+2))=\"\${sht9}\""
eval "F$((NFP+3))=\"\${sht10}\""
eval "F$((NFP+4))=\"\${p5}\""
CALLEE=compile_clambda
RPC=11; ACTION=call; return
;;
11)
eval "sht5=\"\$F$((FP+NP+0))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=write_segs
RPC=12; ACTION=call; return
;;
12)
eval "sht5=\"\$F$((FP+NP+0))\""
sht12="${R}"
hp_cdr "${p0}"
sht13="${R}"
eval "F$((FP+0))=\"\${sht13}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
13)
sht15="${R}"
if [ "${sht15}" != NIL ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
14)
hp_car "${p0}"
sht16="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
CALLEE=cadr
RPC=16; ACTION=call; return
;;
15)
hp_car "${p0}"
sht42="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
CALLEE=atom_constzzQ
RPC=28; ACTION=call; return
;;
16)
sht17="${R}"
sht18="T:${sht17#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
CALLEE=mangle
RPC=17; ACTION=call; return
;;
17)
sht19="${R}"
sht20="${sht19}"
hp_car "${p0}"
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht21}\""
CALLEE=cadr
RPC=18; ACTION=call; return
;;
18)
eval "sht20=\"\$F$((FP+NP+0))\""
sht22="${R}"
hp_car "${p0}"
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=caddr
RPC=19; ACTION=call; return
;;
19)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
CALLEE=cadr
RPC=20; ACTION=call; return
;;
20)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht25="${R}"
hp_car "${p0}"
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
CALLEE=caddr
RPC=21; ACTION=call; return
;;
21)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
CALLEE=caddr
RPC=22; ACTION=call; return
;;
22)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"\${sht20}\""
eval "F$((NFP+2))=\"\${sht25}\""
eval "F$((NFP+3))=\"\${sht28}\""
eval "F$((NFP+4))=\"\${p3}\""
eval "F$((NFP+5))=\"\${p4}\""
eval "F$((NFP+6))=\"\${p5}\""
CALLEE=compile_fn
RPC=23; ACTION=call; return
;;
23)
eval "sht20=\"\$F$((FP+NP+0))\""
sht29="${R}"
sht30="${sht29}"
hp_cdr "${sht30}"
sht31="${R}"
sht32="${sht31}"
hp_car "${sht30}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=write_segs
RPC=24; ACTION=call; return
;;
24)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht34="${R}"
hp_car "${p0}"
sht35="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht35}\""
CALLEE=cadr
RPC=25; ACTION=call; return
;;
25)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
CALLEE=resid_bind
RPC=26; ACTION=call; return
;;
26)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
CALLEE=show
RPC=27; ACTION=call; return
;;
27)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
hp_cons "${sht38}" "NIL"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht20}\""
append_lines "${p2}" "${sht39}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht20=\"\$F$((FP+NP+2))\""
sht40="${R}"
hp_cdr "${p0}"
sht41="${R}"
eval "F$((FP+0))=\"\${sht41}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${sht32}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
28)
sht43="${R}"
if [ "${sht43}" != NIL ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
29)
hp_cdr "${p0}"
sht44="${R}"
eval "F$((FP+0))=\"\${sht44}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
30)
hp_car "${p0}"
sht45="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht45}\""
CALLEE=show
RPC=31; ACTION=call; return
;;
31)
eval "p2=\"\$F$((FP+NP+0))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "${sht46}" "NIL"
eval "p2=\"\$F$((FP+NP+0))\""
sht47="${R}"
append_lines "${p2}" "${sht47}"
sht48="${R}"
hp_cdr "${p0}"
sht49="${R}"
eval "F$((FP+0))=\"\${sht49}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
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
SIZE_lv_names=2
lv_names() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_lv_names))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_car "${p0}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=lv_names
RPC=3; ACTION=call; return
;;
2)
R="NIL"; ACTION=ret; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht1}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_fv_binds=5
fv_binds() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_fv_binds))
NP=3
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
hp_cdr "${sht1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv
RPC=3; ACTION=call; return
;;
2)
R="${p2}"; ACTION=ret; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${sht4}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_fv_list=5
fv_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_fv_list))
NP=3
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
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv
RPC=3; ACTION=call; return
;;
2)
R="${p2}"; ACTION=ret; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_fv=5
fv() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_fv))
NP=3
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
if [ "${p0#S:}" != "${p0}" ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
3)
R="${p2}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
if [ "${sht1}" = "S:lambda" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
hp_cdr "${p0}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=7; ACTION=call; return
;;
6)
hp_car "${p0}"
sht8="${R}"
if [ "${sht8}" = "S:let" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
7)
eval "sht4=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+0))=\"\${sht4}\""
eval "F$((FP+1))=\"\${sht7}\""
eval "F$((FP+2))=\"\${p2}\""
PC=0; ACTION=tail; return
;;
8)
hp_cdr "${p0}"
sht9="${R}"
hp_cdr "${sht9}"
sht10="${R}"
hp_car "${sht10}"
sht11="${R}"
hp_cdr "${p0}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=lv_names
RPC=10; ACTION=call; return
;;
9)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv_list
RPC=13; ACTION=call; return
;;
10)
eval "sht11=\"\$F$((FP+NP+0))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=11; ACTION=call; return
;;
11)
eval "sht11=\"\$F$((FP+NP+0))\""
sht15="${R}"
hp_cdr "${p0}"
sht16="${R}"
hp_car "${sht16}"
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=fv_binds
RPC=12; ACTION=call; return
;;
12)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+0))=\"\${sht11}\""
eval "F$((FP+1))=\"\${sht15}\""
eval "F$((FP+2))=\"\${sht18}\""
PC=0; ACTION=tail; return
;;
13)
sht19="${R}"
R="${sht19}"; ACTION=ret; return
;;
14)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=memzzQ
RPC=16; ACTION=call; return
;;
15)
R="${p2}"; ACTION=ret; return
;;
16)
sht20="${R}"
if [ "${sht20}" != NIL ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="${p2}"; ACTION=ret; return
;;
18)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=set_add
RPC=19; ACTION=call; return
;;
19)
sht21="${R}"
R="${sht21}"; ACTION=ret; return
;;
esac; }
SIZE_keep_bound=3
keep_bound() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_keep_bound))
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
CALLEE=keep_bound
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
SIZE_lift_list=7
lift_list() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_lift_list))
NP=3
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
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=lift
RPC=3; ACTION=call; return
;;
2)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht23}"
eval "p0=\"\$F$((FP+NP+0))\""
sht24="${R}"
hp_cons "${p0}" "${sht24}"
sht25="${R}"
R="${sht25}"; ACTION=ret; return
;;
3)
sht1="${R}"
sht2="${sht1}"
hp_cdr "${p0}"
sht3="${R}"
hp_cdr "${sht2}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht6}\""
CALLEE=lift_list
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
sht7="${R}"
sht8="${sht7}"
hp_car "${sht2}"
sht9="${R}"
hp_car "${sht8}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht9}" "${sht10}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht11="${R}"
hp_cdr "${sht2}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
hp_cdr "${sht8}"
sht14="${R}"
hp_car "${sht14}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
eval "F$((NFP+1))=\"\${sht15}\""
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht16="${R}"
hp_cdr "${sht8}"
sht17="${R}"
hp_cdr "${sht17}"
sht18="${R}"
hp_car "${sht18}"
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
hp_cons "${sht19}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
hp_cons "${sht16}" "${sht20}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht11}" "${sht21}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
esac; }
SIZE_lift=12
lift() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_lift))
NP=3
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
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht51="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht51}"
eval "p0=\"\$F$((FP+NP+0))\""
sht52="${R}"
hp_cons "${p0}" "${sht52}"
sht53="${R}"
R="${sht53}"; ACTION=ret; return
;;
3)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${p0}" "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:lambda" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
sht7="${sht6}"
hp_cdr "${p0}"
sht8="${R}"
hp_cdr "${sht8}"
sht9="${R}"
hp_car "${sht9}"
sht10="${R}"
hp_cdr "${p0}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=append
RPC=7; ACTION=call; return
;;
6)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=lift_list
RPC=12; ACTION=call; return
;;
7)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
eval "F$((NFP+1))=\"\${sht13}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=lift
RPC=8; ACTION=call; return
;;
8)
eval "sht7=\"\$F$((FP+NP+0))\""
sht14="${R}"
sht15="${sht14}"
hp_car "${sht15}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
eval "F$((NFP+1))=\"\${sht7}\""
STGV="NIL"
eval "F$((NFP+2))=\"\$STGV\""
CALLEE=fv
RPC=9; ACTION=call; return
;;
9)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=keep_bound
RPC=10; ACTION=call; return
;;
10)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
sht18="${R}"
sht19="${sht18}"
hp_cdr "${sht15}"
sht20="${R}"
hp_cdr "${sht20}"
sht21="${R}"
hp_car "${sht21}"
sht22="${R}"
sht23="T:${sht22#??}"
sht24="T:__lam${sht23#??}"
sht25="S:${sht24#??}"
sht26="${sht25}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht26}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "S:quote" "${sht27}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht28}" "${sht19}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "S:make-closure" "${sht29}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht30="${R}"
hp_cdr "${sht15}"
sht31="${R}"
hp_car "${sht31}"
sht32="${R}"
hp_car "${sht15}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht7}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht30}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht19}\""
eval "F$((FP+NP+7))=\"\${sht15}\""
eval "F$((FP+NP+8))=\"\${sht7}\""
hp_cons "${sht33}" "NIL"
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht7=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht30=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht19=\"\$F$((FP+NP+6))\""
eval "sht15=\"\$F$((FP+NP+7))\""
eval "sht7=\"\$F$((FP+NP+8))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht19}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht7}\""
hp_cons "${sht19}" "${sht34}"
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht19=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht7=\"\$F$((FP+NP+7))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
hp_cons "${sht7}" "${sht35}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
hp_cons "S:clambda" "${sht36}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
hp_cons "${sht37}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "${sht26}" "${sht38}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "S:define" "${sht39}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "${sht40}" "NIL"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht41}\""
CALLEE=append
RPC=11; ACTION=call; return
;;
11)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
sht42="${R}"
hp_cdr "${sht15}"
sht43="${R}"
hp_cdr "${sht43}"
sht44="${R}"
hp_car "${sht44}"
sht45="${R}"
sht46="I:$(( ${sht45#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht7}\""
hp_cons "${sht46}" "NIL"
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht7=\"\$F$((FP+NP+5))\""
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
hp_cons "${sht42}" "${sht47}"
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
hp_cons "${sht30}" "${sht48}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht49="${R}"
R="${sht49}"; ACTION=ret; return
;;
12)
sht50="${R}"
R="${sht50}"; ACTION=ret; return
;;
esac; }
SIZE_lift_program=9
lift_program() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lift_program))
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
sht1="${sht0}"
if [ "${sht1#P:}" != "${sht1}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${sht1}"
sht3="${R}"
if [ "${sht3}" = "S:define" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
4)
sht2="NIL"
PC=5; ACTION=jump; return
;;
5)
if [ "${sht2}" != NIL ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
6)
hp_cdr "${sht1}"
sht5="${R}"
hp_cdr "${sht5}"
sht6="${R}"
hp_car "${sht6}"
sht7="${R}"
if [ "${sht7#P:}" != "${sht7}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
7)
sht4="NIL"
PC=8; ACTION=jump; return
;;
8)
sht2="${sht4}"
PC=5; ACTION=jump; return
;;
9)
hp_cdr "${sht1}"
sht9="${R}"
hp_cdr "${sht9}"
sht10="${R}"
hp_car "${sht10}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
if [ "${sht12}" = "S:lambda" ]; then
sht13="S:t"
else
sht13="NIL"
fi
sht8="${sht13}"
PC=11; ACTION=jump; return
;;
10)
sht8="NIL"
PC=11; ACTION=jump; return
;;
11)
sht4="${sht8}"
PC=8; ACTION=jump; return
;;
12)
hp_cdr "${sht1}"
sht14="${R}"
hp_car "${sht14}"
sht15="${R}"
sht16="${sht15}"
hp_cdr "${sht1}"
sht17="${R}"
hp_cdr "${sht17}"
sht18="${R}"
hp_car "${sht18}"
sht19="${R}"
hp_cdr "${sht19}"
sht20="${R}"
hp_car "${sht20}"
sht21="${R}"
sht22="${sht21}"
hp_cdr "${sht1}"
sht23="${R}"
hp_cdr "${sht23}"
sht24="${R}"
hp_car "${sht24}"
sht25="${R}"
hp_cdr "${sht25}"
sht26="${R}"
hp_cdr "${sht26}"
sht27="${R}"
hp_car "${sht27}"
sht28="${R}"
sht29="${sht28}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${sht22}\""
eval "F$((NFP+2))=\"\${p1}\""
CALLEE=lift
RPC=14; ACTION=call; return
;;
13)
hp_cdr "${p0}"
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lift_program
RPC=17; ACTION=call; return
;;
14)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht30="${R}"
sht31="${sht30}"
hp_car "${sht31}"
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht32}" "NIL"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht22}" "${sht33}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "S:lambda" "${sht34}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht35}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht16}" "${sht36}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "S:define" "${sht37}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht38="${R}"
hp_cdr "${sht31}"
sht39="${R}"
hp_car "${sht39}"
sht40="${R}"
hp_cdr "${p0}"
sht41="${R}"
hp_cdr "${sht31}"
sht42="${R}"
hp_cdr "${sht42}"
sht43="${R}"
hp_car "${sht43}"
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht40}\""
eval "F$((FP+NP+1))=\"\${sht38}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht41}\""
eval "F$((NFP+1))=\"\${sht44}\""
CALLEE=lift_program
RPC=15; ACTION=call; return
;;
15)
eval "sht40=\"\$F$((FP+NP+0))\""
eval "sht38=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht38}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht40}\""
eval "F$((NFP+1))=\"\${sht45}\""
CALLEE=append
RPC=16; ACTION=call; return
;;
16)
eval "sht38=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht38}" "${sht46}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht47="${R}"
R="${sht47}"; ACTION=ret; return
;;
17)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht1}" "${sht49}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht50="${R}"
R="${sht50}"; ACTION=ret; return
;;
esac; }
SIZE_mkclo_caps=2
mkclo_caps() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_mkclo_caps))
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
CALLEE=mkclo_caps
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
SIZE_cap_loads_go=3
cap_loads_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_cap_loads_go))
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
sht1="T:${sht0#??}=!R!"
sht2="T:p${sht1#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=qset
RPC=3; ACTION=call; return
;;
3)
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
STGV="T:_cl=!R:~2!"
eval "F$((NFP+0))=\"\$STGV\""
CALLEE=qset
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
hp_cons "${sht4}" "NIL"
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
hp_cons "T:call rdfield.cmd cdr !_cl!" "${sht5}"
eval "sht3=\"\$F$((FP+NP+0))\""
sht6="${R}"
hp_cons "${sht3}" "${sht6}"
sht7="${R}"
hp_cons "T:call rdfield.cmd car !_cl!" "${sht7}"
sht8="${R}"
hp_cdr "${p0}"
sht9="${R}"
sht10="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht8}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
eval "F$((NFP+1))=\"\${sht10}\""
CALLEE=cap_loads_go
RPC=5; ACTION=call; return
;;
5)
eval "sht8=\"\$F$((FP+NP+0))\""
sht11="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${sht11}\""
CALLEE=append
RPC=6; ACTION=call; return
;;
6)
sht12="${R}"
R="${sht12}"; ACTION=ret; return
;;
esac; }
SIZE_cap_loads=3
cap_loads() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_cap_loads))
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
NFP=$FTOP
STGV="T:_cl=!R:~2!"
eval "F$((NFP+0))=\"\$STGV\""
CALLEE=qset
RPC=3; ACTION=call; return
;;
3)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=cap_loads_go
RPC=4; ACTION=call; return
;;
4)
eval "sht0=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cons "${sht0}" "${sht1}"
sht2="${R}"
hp_cons "T:call rdfield.cmd cdr !CLO!" "${sht2}"
sht3="${R}"
R="${sht3}"; ACTION=ret; return
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
SIZE_gfns_of=1
gfns_of() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_gfns_of))
NP=1
case $PC in
0)
NFP=$FTOP
STGV="T:\$GFNS"
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
SIZE_compile_program=7
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
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=lift_program
RPC=2; ACTION=call; return
;;
2)
sht1="${R}"
sht2="${sht1}"
sht3="T:${p1#??}/_consts.cmd"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=const_inits
RPC=3; ACTION=call; return
;;
3)
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
write_lines "${sht3}" "${sht4}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
write_lines "${p2}" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=defnames
RPC=4; ACTION=call; return
;;
4)
eval "p2=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"I:0\""
STGV="NIL"
eval "F$((NFP+4))=\"\$STGV\""
eval "F$((NFP+5))=\"\${sht7}\""
CALLEE=cp
RPC=5; ACTION=call; return
;;
5)
eval "sht2=\"\$F$((FP+NP+0))\""
sht8="${R}"
R="${sht8}"; ACTION=ret; return
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
