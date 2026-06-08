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

# src/comp-sh-compiled.sh — compile-sh.lisp self-compiled to native sh by comp-sh.sh.
# GENERATED by tools/regen-comp.sh. The native Lisp->sh emitter (see build-comp-sh.sh).
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
SIZE_shop=1
shop() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_shop))
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
SIZE_shcmp=1
shcmp() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_shcmp))
NP=1
case $PC in
0)
if [ "${p0}" = "S:<" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:-lt"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:=" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:-eq"; ACTION=ret; return
;;
4)
R="T:?"; ACTION=ret; return
;;
esac; }
SIZE_predzzQ=1
predzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_predzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:null?" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:eq?" ]; then PC=3; else PC=4; fi
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
if [ "${p0}" = "S:atom?" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="S:t"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:number?" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="S:t"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:string?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="S:t"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:symbol?" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="S:t"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:<" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="S:t"; ACTION=ret; return
;;
16)
if [ "${p0}" = "S:=" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="S:t"; ACTION=ret; return
;;
18)
R="NIL"; ACTION=ret; return
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
SIZE_prim_wrap=1
prim_wrap() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_prim_wrap))
NP=1
case $PC in
0)
if [ "${p0}" = "S:+" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:__p_add"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:-" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:__p_sub"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:*" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:__p_mul"; ACTION=ret; return
;;
6)
if [ "${p0}" = "S:<" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:__p_lt"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:=" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:__p_neq"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:cons" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:__p_cons"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:car" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="T:__p_car"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:cdr" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="T:__p_cdr"; ACTION=ret; return
;;
16)
if [ "${p0}" = "S:null?" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="T:__p_null"; ACTION=ret; return
;;
18)
if [ "${p0}" = "S:eq?" ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
R="T:__p_eq"; ACTION=ret; return
;;
20)
if [ "${p0}" = "S:pair?" ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
R="T:__p_pair"; ACTION=ret; return
;;
22)
if [ "${p0}" = "S:not" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
23)
R="T:__p_not"; ACTION=ret; return
;;
24)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_bargs=4
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
eval "F$((FP+NP+0))=\"\${G_DQ}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=shval
RPC=3; ACTION=call; return
;;
3)
eval "G_DQ=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
CALLEE=bargs
RPC=4; ACTION=call; return
;;
4)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
sht3="${R}"
sht4="T:${G_DQ#??}${sht3#??}"
sht5="T:${sht1#??}${sht4#??}"
sht6="T:${G_DQ#??}${sht5#??}"
sht7="T: ${sht6#??}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_sh_mangle_at=1
sh_mangle_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_sh_mangle_at))
NP=1
case $PC in
0)
if [ "${p0}" = "T:-" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:_"; ACTION=ret; return
;;
2)
if [ "${p0}" = "T:>" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:zzG"; ACTION=ret; return
;;
4)
if [ "${p0}" = "T:<" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:zzL"; ACTION=ret; return
;;
6)
if [ "${p0}" = "T:*" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="T:zzS"; ACTION=ret; return
;;
8)
if [ "${p0}" = "T:?" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:zzQ"; ACTION=ret; return
;;
10)
if [ "${p0}" = "T:!" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:zzB"; ACTION=ret; return
;;
12)
if [ "${p0}" = "T:=" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="T:zzE"; ACTION=ret; return
;;
14)
if [ "${p0}" = "T:+" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="T:zzP"; ACTION=ret; return
;;
16)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_sh_mangle_go=8
sh_mangle_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_sh_mangle_go))
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
CALLEE=sh_mangle_at
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
SIZE_sh_mangle=1
sh_mangle() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_sh_mangle))
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
CALLEE=sh_mangle_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_shval=1
shval() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_shval))
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
if [ "${sht3}" = "S:cst" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht5="${R}"
sht6="T:${sht5#??}}"
sht7="T:\${${sht6#??}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_shdet=1
shdet() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_shdet))
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
if [ "${sht2}" = "S:cst" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht3="${R}"
hp_cdr "${p0}"
sht4="${R}"
sht5="I:$(( ${#sht4} - 2 ))"
sht6="I:$(( ${sht5#??} - 2 ))"
sht7="T:$(printf '%s' "${sht3#??}" | cut -c$(( 2 + 1 ))-$(( 2 + ${sht6#??} )))"
R="${sht7}"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht8="${R}"
sht9="T:${sht8#??}#??}"
sht10="T:\${${sht9#??}"
R="${sht10}"; ACTION=ret; return
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
if [ "${sht0}" = "S:loc" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
2)
R="NIL"; ACTION=ret; return
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
sht2="T:sht${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_bsl=0
bsl() {
FTOP=$((FP + SIZE_bsl))
NP=0
case $PC in
0)
sht0="T:$(printf '%s' "\\\$" | cut -c$(( 0 + 1 ))-$(( 0 + 1 )))"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_eqt=0
eqt() {
FTOP=$((FP + SIZE_eqt))
NP=0
case $PC in
0)
NFP=$FTOP
CALLEE=bsl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="T:${sht0#??}${G_DQ#??}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_fval=1
fval() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_fval))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:loc" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
sht2="T:${sht1#??}}"
sht3="T:\\\${${sht2#??}"
R="${sht3}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:lit" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht5="${R}"
sht6="T:I:${sht5#??}"
R="${sht6}"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_refrhs=1
refrhs() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_refrhs))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
if [ "${sht0}" = "S:loc" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht1="${R}"
sht2="T:${sht1#??}}"
sht3="T:\${${sht2#??}"
R="${sht3}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht4="${R}"
if [ "${sht4}" = "S:lit" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${p0}"
sht5="${R}"
sht6="T:I:${sht5#??}"
R="${sht6}"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht7="${R}"
R="${sht7}"; ACTION=ret; return
;;
esac; }
SIZE_spill=8
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
eval "F$((FP+NP+0))=\"\${sht0}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht1="${R}"
hp_car "${p1}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht3="${R}"
sht4="T:${sht3#??}${G_DQ#??}"
sht5="T:}${sht4#??}"
sht6="T:${sht2#??}${sht5#??}"
sht7="T:\\\${${sht6#??}"
sht8="T:${sht1#??}${sht7#??}"
sht9="T:))=${sht8#??}"
sht10="T:${sht0#??}${sht9#??}"
sht11="T:F\$((FP+NP+${sht10#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:eval ${sht12#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht13}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
sht14="${R}"
hp_cdr "${p1}"
sht15="${R}"
sht16="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht14}\""
eval "F$((FP+1))=\"\${sht15}\""
eval "F$((FP+2))=\"\${sht16}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_unspill=8
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
hp_car "${p1}"
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht1="${R}"
sht2="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht3="${R}"
sht4="T:${sht3#??}${G_DQ#??}"
sht5="T:))${sht4#??}"
sht6="T:${sht2#??}${sht5#??}"
sht7="T:\\\$F\$((FP+NP+${sht6#??}"
sht8="T:${sht1#??}${sht7#??}"
sht9="T:=${sht8#??}"
sht10="T:${sht0#??}${sht9#??}"
sht11="T:${G_DQ#??}${sht10#??}"
sht12="T:eval ${sht11#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=emit
RPC=5; ACTION=call; return
;;
5)
sht13="${R}"
hp_cdr "${p1}"
sht14="${R}"
sht15="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht13}\""
eval "F$((FP+1))=\"\${sht14}\""
eval "F$((FP+2))=\"\${sht15}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_stage=8
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
hp_car "${p1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "S:cst" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p1}"
sht3="${R}"
hp_cdr "${sht3}"
sht4="${R}"
sht5="T:${sht4#??}${G_DQ#??}"
sht6="T:${G_DQ#??}${sht5#??}"
sht7="T:STGV=${sht6#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
4)
sht21="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=10; ACTION=call; return
;;
5)
hp_cdr "${p1}"
sht35="${R}"
sht36="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht2}\""
eval "F$((FP+1))=\"\${sht35}\""
eval "F$((FP+2))=\"\${sht36}\""
PC=0; ACTION=tail; return
;;
6)
sht8="${R}"
sht9="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
NFP=$FTOP
CALLEE=eqt
RPC=7; ACTION=call; return
;;
7)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
NFP=$FTOP
CALLEE=eqt
RPC=8; ACTION=call; return
;;
8)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
sht11="${R}"
sht12="T:${sht11#??}${G_DQ#??}"
sht13="T:\\\$STGV${sht12#??}"
sht14="T:${sht10#??}${sht13#??}"
sht15="T:))=${sht14#??}"
sht16="T:${sht9#??}${sht15#??}"
sht17="T:F\$((NFP+${sht16#??}"
sht18="T:${G_DQ#??}${sht17#??}"
sht19="T:eval ${sht18#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${sht19}\""
CALLEE=emit
RPC=9; ACTION=call; return
;;
9)
sht20="${R}"
sht2="${sht20}"
PC=5; ACTION=jump; return
;;
10)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht22="${R}"
hp_car "${p1}"
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht21}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=fval
RPC=11; ACTION=call; return
;;
11)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht21=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=12; ACTION=call; return
;;
12)
eval "sht24=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht25="${R}"
sht26="T:${sht25#??}${G_DQ#??}"
sht27="T:${sht24#??}${sht26#??}"
sht28="T:${sht22#??}${sht27#??}"
sht29="T:))=${sht28#??}"
sht30="T:${sht21#??}${sht29#??}"
sht31="T:F\$((NFP+${sht30#??}"
sht32="T:${G_DQ#??}${sht31#??}"
sht33="T:eval ${sht32#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht33}\""
CALLEE=emit
RPC=13; ACTION=call; return
;;
13)
sht34="${R}"
sht2="${sht34}"
PC=5; ACTION=jump; return
;;
esac; }
SIZE_setparams=8
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
hp_car "${p1}"
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
if [ "${sht1}" = "S:cst" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${p1}"
sht3="${R}"
hp_cdr "${sht3}"
sht4="${R}"
sht5="T:${sht4#??}${G_DQ#??}"
sht6="T:${G_DQ#??}${sht5#??}"
sht7="T:STGV=${sht6#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
4)
sht21="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=10; ACTION=call; return
;;
5)
hp_cdr "${p1}"
sht35="${R}"
sht36="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht2}\""
eval "F$((FP+1))=\"\${sht35}\""
eval "F$((FP+2))=\"\${sht36}\""
PC=0; ACTION=tail; return
;;
6)
sht8="${R}"
sht9="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
NFP=$FTOP
CALLEE=eqt
RPC=7; ACTION=call; return
;;
7)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
NFP=$FTOP
CALLEE=eqt
RPC=8; ACTION=call; return
;;
8)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
sht11="${R}"
sht12="T:${sht11#??}${G_DQ#??}"
sht13="T:\\\$STGV${sht12#??}"
sht14="T:${sht10#??}${sht13#??}"
sht15="T:))=${sht14#??}"
sht16="T:${sht9#??}${sht15#??}"
sht17="T:F\$((FP+${sht16#??}"
sht18="T:${G_DQ#??}${sht17#??}"
sht19="T:eval ${sht18#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
eval "F$((NFP+1))=\"\${sht19}\""
CALLEE=emit
RPC=9; ACTION=call; return
;;
9)
sht20="${R}"
sht2="${sht20}"
PC=5; ACTION=jump; return
;;
10)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht22="${R}"
hp_car "${p1}"
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht21}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=fval
RPC=11; ACTION=call; return
;;
11)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht21=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${p0}\""
NFP=$FTOP
CALLEE=eqt
RPC=12; ACTION=call; return
;;
12)
eval "sht24=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht25="${R}"
sht26="T:${sht25#??}${G_DQ#??}"
sht27="T:${sht24#??}${sht26#??}"
sht28="T:${sht22#??}${sht27#??}"
sht29="T:))=${sht28#??}"
sht30="T:${sht21#??}${sht29#??}"
sht31="T:F\$((FP+${sht30#??}"
sht32="T:${G_DQ#??}${sht31#??}"
sht33="T:eval ${sht32#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht33}\""
CALLEE=emit
RPC=13; ACTION=call; return
;;
13)
sht34="${R}"
sht2="${sht34}"
PC=5; ACTION=jump; return
;;
esac; }
SIZE_largs=9
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
hp_cdr "${sht3}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
CALLEE=rvar
RPC=4; ACTION=call; return
;;
4)
eval "sht3=\"\$F$((FP+NP+0))\""
sht5="${R}"
sht6="${sht5}"
hp_cdr "${p0}"
sht7="${R}"
hp_car "${sht3}"
sht8="${R}"
if [ "${sht6}" = NIL ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
sht9="${p3}"
PC=7; ACTION=jump; return
;;
6)
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
hp_cons "${sht6}" "${p3}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht10="${R}"
sht9="${sht10}"
PC=7; ACTION=jump; return
;;
7)
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht8}\""
eval "F$((NFP+3))=\"\${sht9}\""
CALLEE=largs
RPC=8; ACTION=call; return
;;
8)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht11="${R}"
sht12="${sht11}"
hp_car "${sht12}"
sht13="${R}"
hp_cdr "${sht3}"
sht14="${R}"
hp_cdr "${sht12}"
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
hp_cons "${sht14}" "${sht15}"
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "${sht13}" "${sht16}"
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
esac; }
SIZE_lval=16
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
CALLEE=sh_esc
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
sht31="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht31}\""
CALLEE=arithzzQ
RPC=24; ACTION=call; return
;;
12)
sht11="${R}"
sht12="${sht11}"
if [ "${sht12}" = NIL ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
eval "F$((FP+NP+0))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=prim_wrap
RPC=15; ACTION=call; return
;;
14)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:loc" "${sht12}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht29="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht29}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht30="${R}"
R="${sht30}"; ACTION=ret; return
;;
15)
eval "sht12=\"\$F$((FP+NP+0))\""
sht13="${R}"
if [ "${sht13}" != NIL ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
16)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=prim_wrap
RPC=18; ACTION=call; return
;;
17)
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
STGV="S:__gfns"
eval "F$((NFP+0))=\"\$STGV\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=19; ACTION=call; return
;;
18)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht14="${R}"
sht15="T:C:${sht14#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:cst" "${sht15}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht16}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht17="${R}"
R="${sht17}"; ACTION=ret; return
;;
19)
eval "p0=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht18}\""
CALLEE=memzzQ
RPC=20; ACTION=call; return
;;
20)
eval "sht12=\"\$F$((FP+NP+0))\""
sht19="${R}"
if [ "${sht19}" != NIL ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
sht20="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
CALLEE=sh_mangle
RPC=23; ACTION=call; return
;;
22)
sht25="T:${p0#??}"
sht26="T:G_${sht25#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:loc" "${sht26}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht27}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht28="${R}"
R="${sht28}"; ACTION=ret; return
;;
23)
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht21="${R}"
sht22="T:C:${sht21#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:cst" "${sht22}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht23}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht24="${R}"
R="${sht24}"; ACTION=ret; return
;;
24)
sht32="${R}"
if [ "${sht32}" != NIL ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
25)
hp_cdr "${p0}"
sht33="${R}"
hp_car "${sht33}"
sht34="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=27; ACTION=call; return
;;
26)
hp_car "${p0}"
sht72="${R}"
if [ "${sht72}" = "S:car" ]; then PC=39; else PC=40; fi
ACTION=jump; return
;;
27)
sht35="${R}"
sht36="${sht35}"
hp_cdr "${p0}"
sht37="${R}"
hp_cdr "${sht37}"
sht38="${R}"
hp_car "${sht38}"
sht39="${R}"
hp_car "${sht36}"
sht40="${R}"
hp_cdr "${sht36}"
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht40}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht41}\""
CALLEE=rvar
RPC=28; ACTION=call; return
;;
28)
eval "sht40=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
sht42="${R}"
sht43="${sht42}"
if [ "${sht43}" = NIL ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
29)
sht44="${p3}"
PC=31; ACTION=jump; return
;;
30)
eval "F$((FP+NP+0))=\"\${sht43}\""
eval "F$((FP+NP+1))=\"\${sht40}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
hp_cons "${sht43}" "${p3}"
eval "sht43=\"\$F$((FP+NP+0))\""
eval "sht40=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
sht45="${R}"
sht44="${sht45}"
PC=31; ACTION=jump; return
;;
31)
eval "F$((FP+NP+0))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht40}\""
eval "F$((NFP+3))=\"\${sht44}\""
CALLEE=lval
RPC=32; ACTION=call; return
;;
32)
eval "sht36=\"\$F$((FP+NP+0))\""
sht46="${R}"
sht47="${sht46}"
hp_car "${sht47}"
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht47}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
CALLEE=tmpn
RPC=33; ACTION=call; return
;;
33)
eval "sht47=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
sht49="${R}"
sht50="${sht49}"
hp_car "${sht47}"
sht51="${R}"
hp_cdr "${sht36}"
sht52="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht50}\""
eval "F$((FP+NP+2))=\"\${sht51}\""
eval "F$((FP+NP+3))=\"\${sht50}\""
eval "F$((FP+NP+4))=\"\${sht47}\""
eval "F$((FP+NP+5))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht52}\""
CALLEE=shdet
RPC=34; ACTION=call; return
;;
34)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht50=\"\$F$((FP+NP+1))\""
eval "sht51=\"\$F$((FP+NP+2))\""
eval "sht50=\"\$F$((FP+NP+3))\""
eval "sht47=\"\$F$((FP+NP+4))\""
eval "sht36=\"\$F$((FP+NP+5))\""
sht53="${R}"
hp_car "${p0}"
sht54="${R}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht50}\""
eval "F$((FP+NP+3))=\"\${sht51}\""
eval "F$((FP+NP+4))=\"\${sht50}\""
eval "F$((FP+NP+5))=\"\${sht47}\""
eval "F$((FP+NP+6))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht54}\""
CALLEE=shop
RPC=35; ACTION=call; return
;;
35)
eval "sht53=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht50=\"\$F$((FP+NP+2))\""
eval "sht51=\"\$F$((FP+NP+3))\""
eval "sht50=\"\$F$((FP+NP+4))\""
eval "sht47=\"\$F$((FP+NP+5))\""
eval "sht36=\"\$F$((FP+NP+6))\""
sht55="${R}"
hp_cdr "${sht47}"
sht56="${R}"
eval "F$((FP+NP+0))=\"\${sht55}\""
eval "F$((FP+NP+1))=\"\${sht53}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht50}\""
eval "F$((FP+NP+4))=\"\${sht51}\""
eval "F$((FP+NP+5))=\"\${sht50}\""
eval "F$((FP+NP+6))=\"\${sht47}\""
eval "F$((FP+NP+7))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht56}\""
CALLEE=shdet
RPC=36; ACTION=call; return
;;
36)
eval "sht55=\"\$F$((FP+NP+0))\""
eval "sht53=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht50=\"\$F$((FP+NP+3))\""
eval "sht51=\"\$F$((FP+NP+4))\""
eval "sht50=\"\$F$((FP+NP+5))\""
eval "sht47=\"\$F$((FP+NP+6))\""
eval "sht36=\"\$F$((FP+NP+7))\""
sht57="${R}"
sht58="T: ))${G_DQ#??}"
sht59="T:${sht57#??}${sht58#??}"
sht60="T: ${sht59#??}"
sht61="T:${sht55#??}${sht60#??}"
sht62="T: ${sht61#??}"
sht63="T:${sht53#??}${sht62#??}"
sht64="T:I:\$(( ${sht63#??}"
sht65="T:${G_DQ#??}${sht64#??}"
sht66="T:=${sht65#??}"
sht67="T:${sht50#??}${sht66#??}"
eval "F$((FP+NP+0))=\"\${sht50}\""
eval "F$((FP+NP+1))=\"\${sht47}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
eval "F$((NFP+1))=\"\${sht67}\""
CALLEE=emit
RPC=37; ACTION=call; return
;;
37)
eval "sht50=\"\$F$((FP+NP+0))\""
eval "sht47=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
sht68="${R}"
eval "F$((FP+NP+0))=\"\${sht50}\""
eval "F$((FP+NP+1))=\"\${sht47}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht68}\""
CALLEE=bkzzP
RPC=38; ACTION=call; return
;;
38)
eval "sht50=\"\$F$((FP+NP+0))\""
eval "sht47=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
sht69="${R}"
eval "F$((FP+NP+0))=\"\${sht69}\""
eval "F$((FP+NP+1))=\"\${sht50}\""
eval "F$((FP+NP+2))=\"\${sht47}\""
eval "F$((FP+NP+3))=\"\${sht36}\""
hp_cons "S:loc" "${sht50}"
eval "sht69=\"\$F$((FP+NP+0))\""
eval "sht50=\"\$F$((FP+NP+1))\""
eval "sht47=\"\$F$((FP+NP+2))\""
eval "sht36=\"\$F$((FP+NP+3))\""
sht70="${R}"
eval "F$((FP+NP+0))=\"\${sht50}\""
eval "F$((FP+NP+1))=\"\${sht47}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
hp_cons "${sht69}" "${sht70}"
eval "sht50=\"\$F$((FP+NP+0))\""
eval "sht47=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
sht71="${R}"
R="${sht71}"; ACTION=ret; return
;;
39)
hp_cdr "${p0}"
sht73="${R}"
hp_car "${sht73}"
sht74="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht74}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=41; ACTION=call; return
;;
40)
hp_car "${p0}"
sht95="${R}"
if [ "${sht95}" = "S:cdr" ]; then PC=47; else PC=48; fi
ACTION=jump; return
;;
41)
sht75="${R}"
sht76="${sht75}"
hp_car "${sht76}"
sht77="${R}"
eval "F$((FP+NP+0))=\"\${sht76}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht77}\""
CALLEE=tmpn
RPC=42; ACTION=call; return
;;
42)
eval "sht76=\"\$F$((FP+NP+0))\""
sht78="${R}"
sht79="${sht78}"
hp_car "${sht76}"
sht80="${R}"
hp_cdr "${sht76}"
sht81="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht80}\""
eval "F$((FP+NP+2))=\"\${sht79}\""
eval "F$((FP+NP+3))=\"\${sht76}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht81}\""
CALLEE=shval
RPC=43; ACTION=call; return
;;
43)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht80=\"\$F$((FP+NP+1))\""
eval "sht79=\"\$F$((FP+NP+2))\""
eval "sht76=\"\$F$((FP+NP+3))\""
sht82="${R}"
sht83="T:${sht82#??}${G_DQ#??}"
sht84="T:${G_DQ#??}${sht83#??}"
sht85="T:hp_car ${sht84#??}"
eval "F$((FP+NP+0))=\"\${sht79}\""
eval "F$((FP+NP+1))=\"\${sht76}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht80}\""
eval "F$((NFP+1))=\"\${sht85}\""
CALLEE=emit
RPC=44; ACTION=call; return
;;
44)
eval "sht79=\"\$F$((FP+NP+0))\""
eval "sht76=\"\$F$((FP+NP+1))\""
sht86="${R}"
sht87="T:\${R}${G_DQ#??}"
sht88="T:${G_DQ#??}${sht87#??}"
sht89="T:=${sht88#??}"
sht90="T:${sht79#??}${sht89#??}"
eval "F$((FP+NP+0))=\"\${sht79}\""
eval "F$((FP+NP+1))=\"\${sht76}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht86}\""
eval "F$((NFP+1))=\"\${sht90}\""
CALLEE=emit
RPC=45; ACTION=call; return
;;
45)
eval "sht79=\"\$F$((FP+NP+0))\""
eval "sht76=\"\$F$((FP+NP+1))\""
sht91="${R}"
eval "F$((FP+NP+0))=\"\${sht79}\""
eval "F$((FP+NP+1))=\"\${sht76}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht91}\""
CALLEE=bkzzP
RPC=46; ACTION=call; return
;;
46)
eval "sht79=\"\$F$((FP+NP+0))\""
eval "sht76=\"\$F$((FP+NP+1))\""
sht92="${R}"
eval "F$((FP+NP+0))=\"\${sht92}\""
eval "F$((FP+NP+1))=\"\${sht79}\""
eval "F$((FP+NP+2))=\"\${sht76}\""
hp_cons "S:loc" "${sht79}"
eval "sht92=\"\$F$((FP+NP+0))\""
eval "sht79=\"\$F$((FP+NP+1))\""
eval "sht76=\"\$F$((FP+NP+2))\""
sht93="${R}"
eval "F$((FP+NP+0))=\"\${sht79}\""
eval "F$((FP+NP+1))=\"\${sht76}\""
hp_cons "${sht92}" "${sht93}"
eval "sht79=\"\$F$((FP+NP+0))\""
eval "sht76=\"\$F$((FP+NP+1))\""
sht94="${R}"
R="${sht94}"; ACTION=ret; return
;;
47)
hp_cdr "${p0}"
sht96="${R}"
hp_car "${sht96}"
sht97="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht97}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=49; ACTION=call; return
;;
48)
hp_car "${p0}"
sht118="${R}"
if [ "${sht118}" = "S:cons" ]; then PC=55; else PC=56; fi
ACTION=jump; return
;;
49)
sht98="${R}"
sht99="${sht98}"
hp_car "${sht99}"
sht100="${R}"
eval "F$((FP+NP+0))=\"\${sht99}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht100}\""
CALLEE=tmpn
RPC=50; ACTION=call; return
;;
50)
eval "sht99=\"\$F$((FP+NP+0))\""
sht101="${R}"
sht102="${sht101}"
hp_car "${sht99}"
sht103="${R}"
hp_cdr "${sht99}"
sht104="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht103}\""
eval "F$((FP+NP+2))=\"\${sht102}\""
eval "F$((FP+NP+3))=\"\${sht99}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht104}\""
CALLEE=shval
RPC=51; ACTION=call; return
;;
51)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht103=\"\$F$((FP+NP+1))\""
eval "sht102=\"\$F$((FP+NP+2))\""
eval "sht99=\"\$F$((FP+NP+3))\""
sht105="${R}"
sht106="T:${sht105#??}${G_DQ#??}"
sht107="T:${G_DQ#??}${sht106#??}"
sht108="T:hp_cdr ${sht107#??}"
eval "F$((FP+NP+0))=\"\${sht102}\""
eval "F$((FP+NP+1))=\"\${sht99}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht103}\""
eval "F$((NFP+1))=\"\${sht108}\""
CALLEE=emit
RPC=52; ACTION=call; return
;;
52)
eval "sht102=\"\$F$((FP+NP+0))\""
eval "sht99=\"\$F$((FP+NP+1))\""
sht109="${R}"
sht110="T:\${R}${G_DQ#??}"
sht111="T:${G_DQ#??}${sht110#??}"
sht112="T:=${sht111#??}"
sht113="T:${sht102#??}${sht112#??}"
eval "F$((FP+NP+0))=\"\${sht102}\""
eval "F$((FP+NP+1))=\"\${sht99}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht109}\""
eval "F$((NFP+1))=\"\${sht113}\""
CALLEE=emit
RPC=53; ACTION=call; return
;;
53)
eval "sht102=\"\$F$((FP+NP+0))\""
eval "sht99=\"\$F$((FP+NP+1))\""
sht114="${R}"
eval "F$((FP+NP+0))=\"\${sht102}\""
eval "F$((FP+NP+1))=\"\${sht99}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht114}\""
CALLEE=bkzzP
RPC=54; ACTION=call; return
;;
54)
eval "sht102=\"\$F$((FP+NP+0))\""
eval "sht99=\"\$F$((FP+NP+1))\""
sht115="${R}"
eval "F$((FP+NP+0))=\"\${sht115}\""
eval "F$((FP+NP+1))=\"\${sht102}\""
eval "F$((FP+NP+2))=\"\${sht99}\""
hp_cons "S:loc" "${sht102}"
eval "sht115=\"\$F$((FP+NP+0))\""
eval "sht102=\"\$F$((FP+NP+1))\""
eval "sht99=\"\$F$((FP+NP+2))\""
sht116="${R}"
eval "F$((FP+NP+0))=\"\${sht102}\""
eval "F$((FP+NP+1))=\"\${sht99}\""
hp_cons "${sht115}" "${sht116}"
eval "sht102=\"\$F$((FP+NP+0))\""
eval "sht99=\"\$F$((FP+NP+1))\""
sht117="${R}"
R="${sht117}"; ACTION=ret; return
;;
55)
hp_cdr "${p0}"
sht119="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht119}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=57; ACTION=call; return
;;
56)
hp_car "${p0}"
sht155="${R}"
if [ "${sht155}" = "S:quote" ]; then PC=68; else PC=69; fi
ACTION=jump; return
;;
57)
sht120="${R}"
sht121="${sht120}"
hp_car "${sht121}"
sht122="${R}"
eval "F$((FP+NP+0))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht122}\""
CALLEE=tmpn
RPC=58; ACTION=call; return
;;
58)
eval "sht121=\"\$F$((FP+NP+0))\""
sht123="${R}"
sht124="${sht123}"
hp_cdr "${sht121}"
sht125="${R}"
hp_car "${sht125}"
sht126="${R}"
sht127="${sht126}"
hp_cdr "${sht121}"
sht128="${R}"
hp_cdr "${sht128}"
sht129="${R}"
hp_car "${sht129}"
sht130="${R}"
sht131="${sht130}"
hp_car "${sht121}"
sht132="${R}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht132}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=59; ACTION=call; return
;;
59)
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht133="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht133}\""
eval "F$((FP+NP+2))=\"\${sht131}\""
eval "F$((FP+NP+3))=\"\${sht127}\""
eval "F$((FP+NP+4))=\"\${sht124}\""
eval "F$((FP+NP+5))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht127}\""
CALLEE=shval
RPC=60; ACTION=call; return
;;
60)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht133=\"\$F$((FP+NP+1))\""
eval "sht131=\"\$F$((FP+NP+2))\""
eval "sht127=\"\$F$((FP+NP+3))\""
eval "sht124=\"\$F$((FP+NP+4))\""
eval "sht121=\"\$F$((FP+NP+5))\""
sht134="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht134}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht133}\""
eval "F$((FP+NP+5))=\"\${sht131}\""
eval "F$((FP+NP+6))=\"\${sht127}\""
eval "F$((FP+NP+7))=\"\${sht124}\""
eval "F$((FP+NP+8))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht131}\""
CALLEE=shval
RPC=61; ACTION=call; return
;;
61)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht134=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht133=\"\$F$((FP+NP+4))\""
eval "sht131=\"\$F$((FP+NP+5))\""
eval "sht127=\"\$F$((FP+NP+6))\""
eval "sht124=\"\$F$((FP+NP+7))\""
eval "sht121=\"\$F$((FP+NP+8))\""
sht135="${R}"
sht136="T:${sht135#??}${G_DQ#??}"
sht137="T:${G_DQ#??}${sht136#??}"
sht138="T: ${sht137#??}"
sht139="T:${G_DQ#??}${sht138#??}"
sht140="T:${sht134#??}${sht139#??}"
sht141="T:${G_DQ#??}${sht140#??}"
sht142="T:hp_cons ${sht141#??}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht133}\""
eval "F$((NFP+1))=\"\${sht142}\""
CALLEE=emit
RPC=62; ACTION=call; return
;;
62)
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht143="${R}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht143}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=63; ACTION=call; return
;;
63)
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht144="${R}"
sht145="T:\${R}${G_DQ#??}"
sht146="T:${G_DQ#??}${sht145#??}"
sht147="T:=${sht146#??}"
sht148="T:${sht124#??}${sht147#??}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht144}\""
eval "F$((NFP+1))=\"\${sht148}\""
CALLEE=emit
RPC=64; ACTION=call; return
;;
64)
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht149="${R}"
eval "F$((FP+NP+0))=\"\${sht149}\""
eval "F$((FP+NP+1))=\"\${sht131}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
eval "F$((FP+NP+4))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=65; ACTION=call; return
;;
65)
eval "sht149=\"\$F$((FP+NP+0))\""
eval "sht131=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
eval "sht121=\"\$F$((FP+NP+4))\""
sht150="${R}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht149}\""
eval "F$((NFP+1))=\"\${sht150}\""
CALLEE=bsm
RPC=66; ACTION=call; return
;;
66)
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht151="${R}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht151}\""
CALLEE=bkzzP
RPC=67; ACTION=call; return
;;
67)
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht152="${R}"
eval "F$((FP+NP+0))=\"\${sht152}\""
eval "F$((FP+NP+1))=\"\${sht131}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
eval "F$((FP+NP+4))=\"\${sht121}\""
hp_cons "S:loc" "${sht124}"
eval "sht152=\"\$F$((FP+NP+0))\""
eval "sht131=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
eval "sht121=\"\$F$((FP+NP+4))\""
sht153="${R}"
eval "F$((FP+NP+0))=\"\${sht131}\""
eval "F$((FP+NP+1))=\"\${sht127}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
eval "F$((FP+NP+3))=\"\${sht121}\""
hp_cons "${sht152}" "${sht153}"
eval "sht131=\"\$F$((FP+NP+0))\""
eval "sht127=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
eval "sht121=\"\$F$((FP+NP+3))\""
sht154="${R}"
R="${sht154}"; ACTION=ret; return
;;
68)
hp_cdr "${p0}"
sht156="${R}"
hp_car "${sht156}"
sht157="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht157}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=lquote
RPC=70; ACTION=call; return
;;
69)
hp_car "${p0}"
sht159="${R}"
if [ "${sht159}" = "S:cond" ]; then PC=71; else PC=72; fi
ACTION=jump; return
;;
70)
sht158="${R}"
R="${sht158}"; ACTION=ret; return
;;
71)
hp_cdr "${p0}"
sht160="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht160}\""
CALLEE=cond_zzGif
RPC=73; ACTION=call; return
;;
72)
hp_car "${p0}"
sht162="${R}"
if [ "${sht162}" = "S:and" ]; then PC=74; else PC=75; fi
ACTION=jump; return
;;
73)
sht161="${R}"
eval "F$((FP+0))=\"\${sht161}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
74)
hp_cdr "${p0}"
sht163="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht163}\""
CALLEE=dsg_and
RPC=76; ACTION=call; return
;;
75)
hp_car "${p0}"
sht165="${R}"
if [ "${sht165}" = "S:or" ]; then PC=77; else PC=78; fi
ACTION=jump; return
;;
76)
sht164="${R}"
eval "F$((FP+0))=\"\${sht164}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
77)
hp_cdr "${p0}"
sht166="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht166}\""
CALLEE=dsg_or
RPC=79; ACTION=call; return
;;
78)
hp_car "${p0}"
sht168="${R}"
if [ "${sht168}" = "S:str" ]; then PC=80; else PC=81; fi
ACTION=jump; return
;;
79)
sht167="${R}"
eval "F$((FP+0))=\"\${sht167}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
80)
hp_cdr "${p0}"
sht169="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht169}\""
CALLEE=dsg_str
RPC=82; ACTION=call; return
;;
81)
hp_car "${p0}"
sht171="${R}"
if [ "${sht171}" = "S:list" ]; then PC=83; else PC=84; fi
ACTION=jump; return
;;
82)
sht170="${R}"
eval "F$((FP+0))=\"\${sht170}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
83)
hp_cdr "${p0}"
sht172="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht172}\""
CALLEE=dsg_list
RPC=85; ACTION=call; return
;;
84)
hp_car "${p0}"
sht174="${R}"
if [ "${sht174}" = "S:when" ]; then PC=86; else PC=87; fi
ACTION=jump; return
;;
85)
sht173="${R}"
eval "F$((FP+0))=\"\${sht173}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
86)
hp_cdr "${p0}"
sht175="${R}"
hp_car "${sht175}"
sht176="${R}"
hp_cdr "${p0}"
sht177="${R}"
hp_cdr "${sht177}"
sht178="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht176}\""
eval "F$((NFP+1))=\"\${sht178}\""
CALLEE=when_zzGif
RPC=88; ACTION=call; return
;;
87)
hp_car "${p0}"
sht180="${R}"
if [ "${sht180}" = "S:unless" ]; then PC=89; else PC=90; fi
ACTION=jump; return
;;
88)
sht179="${R}"
eval "F$((FP+0))=\"\${sht179}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
89)
hp_cdr "${p0}"
sht181="${R}"
hp_car "${sht181}"
sht182="${R}"
hp_cdr "${p0}"
sht183="${R}"
hp_cdr "${sht183}"
sht184="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht182}\""
eval "F$((NFP+1))=\"\${sht184}\""
CALLEE=unless_zzGif
RPC=91; ACTION=call; return
;;
90)
hp_car "${p0}"
sht186="${R}"
if [ "${sht186}" = "S:case" ]; then PC=92; else PC=93; fi
ACTION=jump; return
;;
91)
sht185="${R}"
eval "F$((FP+0))=\"\${sht185}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
92)
hp_cdr "${p0}"
sht187="${R}"
hp_car "${sht187}"
sht188="${R}"
hp_cdr "${p0}"
sht189="${R}"
hp_cdr "${sht189}"
sht190="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht188}\""
eval "F$((NFP+1))=\"\${sht190}\""
CALLEE=case_zzGcond
RPC=94; ACTION=call; return
;;
93)
hp_car "${p0}"
sht192="${R}"
if [ "${sht192}" = "S:let*" ]; then PC=95; else PC=96; fi
ACTION=jump; return
;;
94)
sht191="${R}"
eval "F$((FP+0))=\"\${sht191}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
95)
hp_cdr "${p0}"
sht193="${R}"
hp_car "${sht193}"
sht194="${R}"
hp_cdr "${p0}"
sht195="${R}"
hp_cdr "${sht195}"
sht196="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht194}\""
eval "F$((NFP+1))=\"\${sht196}\""
CALLEE=letzzS_zzGlets
RPC=97; ACTION=call; return
;;
96)
hp_car "${p0}"
sht198="${R}"
if [ "${sht198}" = "S:begin" ]; then PC=98; else PC=99; fi
ACTION=jump; return
;;
97)
sht197="${R}"
eval "F$((FP+0))=\"\${sht197}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
98)
hp_cdr "${p0}"
sht199="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht199}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbegin
RPC=100; ACTION=call; return
;;
99)
hp_car "${p0}"
sht201="${R}"
if [ "${sht201}" = "S:let" ]; then PC=101; else PC=102; fi
ACTION=jump; return
;;
100)
sht200="${R}"
R="${sht200}"; ACTION=ret; return
;;
101)
hp_cdr "${p0}"
sht202="${R}"
hp_car "${sht202}"
sht203="${R}"
hp_cdr "${p0}"
sht204="${R}"
hp_cdr "${sht204}"
sht205="${R}"
hp_car "${sht205}"
sht206="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht203}\""
eval "F$((NFP+1))=\"\${sht206}\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=llet
RPC=103; ACTION=call; return
;;
102)
hp_car "${p0}"
sht208="${R}"
if [ "${sht208}" = "S:if" ]; then PC=104; else PC=105; fi
ACTION=jump; return
;;
103)
sht207="${R}"
R="${sht207}"; ACTION=ret; return
;;
104)
hp_cdr "${p0}"
sht209="${R}"
hp_car "${sht209}"
sht210="${R}"
hp_cdr "${p0}"
sht211="${R}"
hp_cdr "${sht211}"
sht212="${R}"
hp_car "${sht212}"
sht213="${R}"
eval "F$((FP+NP+0))=\"\${sht213}\""
eval "F$((FP+NP+1))=\"\${sht210}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=106; ACTION=call; return
;;
105)
hp_car "${p0}"
sht216="${R}"
if [ "${sht216}" = "S:dq" ]; then PC=108; else PC=109; fi
ACTION=jump; return
;;
106)
eval "sht213=\"\$F$((FP+NP+0))\""
eval "sht210=\"\$F$((FP+NP+1))\""
sht214="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht210}\""
eval "F$((NFP+1))=\"\${sht213}\""
eval "F$((NFP+2))=\"\${sht214}\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=107; ACTION=call; return
;;
107)
sht215="${R}"
R="${sht215}"; ACTION=ret; return
;;
108)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:loc" "T:G_DQ"
eval "p2=\"\$F$((FP+NP+0))\""
sht217="${R}"
hp_cons "${p2}" "${sht217}"
sht218="${R}"
R="${sht218}"; ACTION=ret; return
;;
109)
hp_car "${p0}"
sht219="${R}"
if [ "${sht219}" = "S:symbol->string" ]; then PC=110; else PC=111; fi
ACTION=jump; return
;;
110)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=112; ACTION=call; return
;;
111)
hp_car "${p0}"
sht221="${R}"
if [ "${sht221}" = "S:number->string" ]; then PC=113; else PC=114; fi
ACTION=jump; return
;;
112)
sht220="${R}"
R="${sht220}"; ACTION=ret; return
;;
113)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=115; ACTION=call; return
;;
114)
hp_car "${p0}"
sht223="${R}"
if [ "${sht223}" = "S:string->symbol" ]; then PC=116; else PC=117; fi
ACTION=jump; return
;;
115)
sht222="${R}"
R="${sht222}"; ACTION=ret; return
;;
116)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=118; ACTION=call; return
;;
117)
hp_car "${p0}"
sht225="${R}"
if [ "${sht225}" = "S:string->number" ]; then PC=119; else PC=120; fi
ACTION=jump; return
;;
118)
sht224="${R}"
R="${sht224}"; ACTION=ret; return
;;
119)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=121; ACTION=call; return
;;
120)
hp_car "${p0}"
sht227="${R}"
if [ "${sht227}" = "S:string-length" ]; then PC=122; else PC=123; fi
ACTION=jump; return
;;
121)
sht226="${R}"
R="${sht226}"; ACTION=ret; return
;;
122)
hp_cdr "${p0}"
sht228="${R}"
hp_car "${sht228}"
sht229="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht229}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=124; ACTION=call; return
;;
123)
hp_car "${p0}"
sht248="${R}"
if [ "${sht248}" = "S:string-append" ]; then PC=128; else PC=129; fi
ACTION=jump; return
;;
124)
sht230="${R}"
sht231="${sht230}"
hp_car "${sht231}"
sht232="${R}"
eval "F$((FP+NP+0))=\"\${sht231}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht232}\""
CALLEE=tmpn
RPC=125; ACTION=call; return
;;
125)
eval "sht231=\"\$F$((FP+NP+0))\""
sht233="${R}"
sht234="${sht233}"
hp_car "${sht231}"
sht235="${R}"
hp_cdr "${sht231}"
sht236="${R}"
hp_cdr "${sht236}"
sht237="${R}"
sht238="T:} - 2 ))${G_DQ#??}"
sht239="T:${sht237#??}${sht238#??}"
sht240="T:I:\$(( \${#${sht239#??}"
sht241="T:${G_DQ#??}${sht240#??}"
sht242="T:=${sht241#??}"
sht243="T:${sht234#??}${sht242#??}"
eval "F$((FP+NP+0))=\"\${sht234}\""
eval "F$((FP+NP+1))=\"\${sht231}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht235}\""
eval "F$((NFP+1))=\"\${sht243}\""
CALLEE=emit
RPC=126; ACTION=call; return
;;
126)
eval "sht234=\"\$F$((FP+NP+0))\""
eval "sht231=\"\$F$((FP+NP+1))\""
sht244="${R}"
eval "F$((FP+NP+0))=\"\${sht234}\""
eval "F$((FP+NP+1))=\"\${sht231}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht244}\""
CALLEE=bkzzP
RPC=127; ACTION=call; return
;;
127)
eval "sht234=\"\$F$((FP+NP+0))\""
eval "sht231=\"\$F$((FP+NP+1))\""
sht245="${R}"
eval "F$((FP+NP+0))=\"\${sht245}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
eval "F$((FP+NP+2))=\"\${sht231}\""
hp_cons "S:loc" "${sht234}"
eval "sht245=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
eval "sht231=\"\$F$((FP+NP+2))\""
sht246="${R}"
eval "F$((FP+NP+0))=\"\${sht234}\""
eval "F$((FP+NP+1))=\"\${sht231}\""
hp_cons "${sht245}" "${sht246}"
eval "sht234=\"\$F$((FP+NP+0))\""
eval "sht231=\"\$F$((FP+NP+1))\""
sht247="${R}"
R="${sht247}"; ACTION=ret; return
;;
128)
hp_cdr "${p0}"
sht249="${R}"
hp_car "${sht249}"
sht250="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht250}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=130; ACTION=call; return
;;
129)
hp_car "${p0}"
sht279="${R}"
if [ "${sht279}" = "S:substring" ]; then PC=138; else PC=139; fi
ACTION=jump; return
;;
130)
sht251="${R}"
sht252="${sht251}"
hp_cdr "${p0}"
sht253="${R}"
hp_cdr "${sht253}"
sht254="${R}"
hp_car "${sht254}"
sht255="${R}"
hp_car "${sht252}"
sht256="${R}"
hp_cdr "${sht252}"
sht257="${R}"
eval "F$((FP+NP+0))=\"\${sht256}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht255}\""
eval "F$((FP+NP+3))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht257}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=131; ACTION=call; return
;;
131)
eval "sht256=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht255=\"\$F$((FP+NP+2))\""
eval "sht252=\"\$F$((FP+NP+3))\""
sht258="${R}"
eval "F$((FP+NP+0))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht255}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht256}\""
eval "F$((NFP+3))=\"\${sht258}\""
CALLEE=lval
RPC=132; ACTION=call; return
;;
132)
eval "sht252=\"\$F$((FP+NP+0))\""
sht259="${R}"
sht260="${sht259}"
hp_car "${sht260}"
sht261="${R}"
eval "F$((FP+NP+0))=\"\${sht260}\""
eval "F$((FP+NP+1))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht261}\""
CALLEE=tmpn
RPC=133; ACTION=call; return
;;
133)
eval "sht260=\"\$F$((FP+NP+0))\""
eval "sht252=\"\$F$((FP+NP+1))\""
sht262="${R}"
sht263="${sht262}"
hp_car "${sht260}"
sht264="${R}"
hp_cdr "${sht252}"
sht265="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht263}\""
eval "F$((FP+NP+2))=\"\${sht264}\""
eval "F$((FP+NP+3))=\"\${sht263}\""
eval "F$((FP+NP+4))=\"\${sht260}\""
eval "F$((FP+NP+5))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht265}\""
CALLEE=shdet
RPC=134; ACTION=call; return
;;
134)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht263=\"\$F$((FP+NP+1))\""
eval "sht264=\"\$F$((FP+NP+2))\""
eval "sht263=\"\$F$((FP+NP+3))\""
eval "sht260=\"\$F$((FP+NP+4))\""
eval "sht252=\"\$F$((FP+NP+5))\""
sht266="${R}"
hp_cdr "${sht260}"
sht267="${R}"
eval "F$((FP+NP+0))=\"\${sht266}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht263}\""
eval "F$((FP+NP+3))=\"\${sht264}\""
eval "F$((FP+NP+4))=\"\${sht263}\""
eval "F$((FP+NP+5))=\"\${sht260}\""
eval "F$((FP+NP+6))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht267}\""
CALLEE=shdet
RPC=135; ACTION=call; return
;;
135)
eval "sht266=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht263=\"\$F$((FP+NP+2))\""
eval "sht264=\"\$F$((FP+NP+3))\""
eval "sht263=\"\$F$((FP+NP+4))\""
eval "sht260=\"\$F$((FP+NP+5))\""
eval "sht252=\"\$F$((FP+NP+6))\""
sht268="${R}"
sht269="T:${sht268#??}${G_DQ#??}"
sht270="T:${sht266#??}${sht269#??}"
sht271="T:T:${sht270#??}"
sht272="T:${G_DQ#??}${sht271#??}"
sht273="T:=${sht272#??}"
sht274="T:${sht263#??}${sht273#??}"
eval "F$((FP+NP+0))=\"\${sht263}\""
eval "F$((FP+NP+1))=\"\${sht260}\""
eval "F$((FP+NP+2))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht264}\""
eval "F$((NFP+1))=\"\${sht274}\""
CALLEE=emit
RPC=136; ACTION=call; return
;;
136)
eval "sht263=\"\$F$((FP+NP+0))\""
eval "sht260=\"\$F$((FP+NP+1))\""
eval "sht252=\"\$F$((FP+NP+2))\""
sht275="${R}"
eval "F$((FP+NP+0))=\"\${sht263}\""
eval "F$((FP+NP+1))=\"\${sht260}\""
eval "F$((FP+NP+2))=\"\${sht252}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht275}\""
CALLEE=bkzzP
RPC=137; ACTION=call; return
;;
137)
eval "sht263=\"\$F$((FP+NP+0))\""
eval "sht260=\"\$F$((FP+NP+1))\""
eval "sht252=\"\$F$((FP+NP+2))\""
sht276="${R}"
eval "F$((FP+NP+0))=\"\${sht276}\""
eval "F$((FP+NP+1))=\"\${sht263}\""
eval "F$((FP+NP+2))=\"\${sht260}\""
eval "F$((FP+NP+3))=\"\${sht252}\""
hp_cons "S:loc" "${sht263}"
eval "sht276=\"\$F$((FP+NP+0))\""
eval "sht263=\"\$F$((FP+NP+1))\""
eval "sht260=\"\$F$((FP+NP+2))\""
eval "sht252=\"\$F$((FP+NP+3))\""
sht277="${R}"
eval "F$((FP+NP+0))=\"\${sht263}\""
eval "F$((FP+NP+1))=\"\${sht260}\""
eval "F$((FP+NP+2))=\"\${sht252}\""
hp_cons "${sht276}" "${sht277}"
eval "sht263=\"\$F$((FP+NP+0))\""
eval "sht260=\"\$F$((FP+NP+1))\""
eval "sht252=\"\$F$((FP+NP+2))\""
sht278="${R}"
R="${sht278}"; ACTION=ret; return
;;
138)
hp_cdr "${p0}"
sht280="${R}"
hp_car "${sht280}"
sht281="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht281}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=140; ACTION=call; return
;;
139)
hp_car "${p0}"
sht330="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht330}\""
CALLEE=predzzQ
RPC=154; ACTION=call; return
;;
140)
sht282="${R}"
sht283="${sht282}"
hp_cdr "${p0}"
sht284="${R}"
hp_cdr "${sht284}"
sht285="${R}"
hp_car "${sht285}"
sht286="${R}"
hp_car "${sht283}"
sht287="${R}"
hp_cdr "${sht283}"
sht288="${R}"
eval "F$((FP+NP+0))=\"\${sht287}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht286}\""
eval "F$((FP+NP+3))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht288}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=141; ACTION=call; return
;;
141)
eval "sht287=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht286=\"\$F$((FP+NP+2))\""
eval "sht283=\"\$F$((FP+NP+3))\""
sht289="${R}"
eval "F$((FP+NP+0))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht286}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht287}\""
eval "F$((NFP+3))=\"\${sht289}\""
CALLEE=lval
RPC=142; ACTION=call; return
;;
142)
eval "sht283=\"\$F$((FP+NP+0))\""
sht290="${R}"
sht291="${sht290}"
eval "F$((FP+NP+0))=\"\${sht291}\""
eval "F$((FP+NP+1))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=143; ACTION=call; return
;;
143)
eval "sht291=\"\$F$((FP+NP+0))\""
eval "sht283=\"\$F$((FP+NP+1))\""
sht292="${R}"
hp_car "${sht291}"
sht293="${R}"
hp_cdr "${sht291}"
sht294="${R}"
hp_cdr "${sht283}"
sht295="${R}"
eval "F$((FP+NP+0))=\"\${sht294}\""
eval "F$((FP+NP+1))=\"\${sht293}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht292}\""
eval "F$((FP+NP+4))=\"\${sht291}\""
eval "F$((FP+NP+5))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht295}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=144; ACTION=call; return
;;
144)
eval "sht294=\"\$F$((FP+NP+0))\""
eval "sht293=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht292=\"\$F$((FP+NP+3))\""
eval "sht291=\"\$F$((FP+NP+4))\""
eval "sht283=\"\$F$((FP+NP+5))\""
sht296="${R}"
eval "F$((FP+NP+0))=\"\${sht293}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht292}\""
eval "F$((FP+NP+3))=\"\${sht291}\""
eval "F$((FP+NP+4))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht294}\""
eval "F$((NFP+1))=\"\${sht296}\""
CALLEE=addlive
RPC=145; ACTION=call; return
;;
145)
eval "sht293=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht292=\"\$F$((FP+NP+2))\""
eval "sht291=\"\$F$((FP+NP+3))\""
eval "sht283=\"\$F$((FP+NP+4))\""
sht297="${R}"
eval "F$((FP+NP+0))=\"\${sht291}\""
eval "F$((FP+NP+1))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht292}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht293}\""
eval "F$((NFP+3))=\"\${sht297}\""
CALLEE=lval
RPC=146; ACTION=call; return
;;
146)
eval "sht291=\"\$F$((FP+NP+0))\""
eval "sht283=\"\$F$((FP+NP+1))\""
sht298="${R}"
sht299="${sht298}"
hp_car "${sht299}"
sht300="${R}"
eval "F$((FP+NP+0))=\"\${sht299}\""
eval "F$((FP+NP+1))=\"\${sht291}\""
eval "F$((FP+NP+2))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht300}\""
CALLEE=tmpn
RPC=147; ACTION=call; return
;;
147)
eval "sht299=\"\$F$((FP+NP+0))\""
eval "sht291=\"\$F$((FP+NP+1))\""
eval "sht283=\"\$F$((FP+NP+2))\""
sht301="${R}"
sht302="${sht301}"
hp_car "${sht299}"
sht303="${R}"
hp_cdr "${sht283}"
sht304="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht302}\""
eval "F$((FP+NP+3))=\"\${sht303}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht299}\""
eval "F$((FP+NP+6))=\"\${sht291}\""
eval "F$((FP+NP+7))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht304}\""
CALLEE=shdet
RPC=148; ACTION=call; return
;;
148)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht302=\"\$F$((FP+NP+2))\""
eval "sht303=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht299=\"\$F$((FP+NP+5))\""
eval "sht291=\"\$F$((FP+NP+6))\""
eval "sht283=\"\$F$((FP+NP+7))\""
sht305="${R}"
hp_cdr "${sht291}"
sht306="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht305}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht302}\""
eval "F$((FP+NP+5))=\"\${sht303}\""
eval "F$((FP+NP+6))=\"\${sht302}\""
eval "F$((FP+NP+7))=\"\${sht299}\""
eval "F$((FP+NP+8))=\"\${sht291}\""
eval "F$((FP+NP+9))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht306}\""
CALLEE=shdet
RPC=149; ACTION=call; return
;;
149)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht305=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht302=\"\$F$((FP+NP+4))\""
eval "sht303=\"\$F$((FP+NP+5))\""
eval "sht302=\"\$F$((FP+NP+6))\""
eval "sht299=\"\$F$((FP+NP+7))\""
eval "sht291=\"\$F$((FP+NP+8))\""
eval "sht283=\"\$F$((FP+NP+9))\""
sht307="${R}"
hp_cdr "${sht291}"
sht308="${R}"
eval "F$((FP+NP+0))=\"\${sht307}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht305}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
eval "F$((FP+NP+5))=\"\${sht302}\""
eval "F$((FP+NP+6))=\"\${sht303}\""
eval "F$((FP+NP+7))=\"\${sht302}\""
eval "F$((FP+NP+8))=\"\${sht299}\""
eval "F$((FP+NP+9))=\"\${sht291}\""
eval "F$((FP+NP+10))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht308}\""
CALLEE=shdet
RPC=150; ACTION=call; return
;;
150)
eval "sht307=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht305=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
eval "sht302=\"\$F$((FP+NP+5))\""
eval "sht303=\"\$F$((FP+NP+6))\""
eval "sht302=\"\$F$((FP+NP+7))\""
eval "sht299=\"\$F$((FP+NP+8))\""
eval "sht291=\"\$F$((FP+NP+9))\""
eval "sht283=\"\$F$((FP+NP+10))\""
sht309="${R}"
hp_cdr "${sht299}"
sht310="${R}"
eval "F$((FP+NP+0))=\"\${sht309}\""
eval "F$((FP+NP+1))=\"\${sht307}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht305}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
eval "F$((FP+NP+5))=\"\${G_DQ}\""
eval "F$((FP+NP+6))=\"\${sht302}\""
eval "F$((FP+NP+7))=\"\${sht303}\""
eval "F$((FP+NP+8))=\"\${sht302}\""
eval "F$((FP+NP+9))=\"\${sht299}\""
eval "F$((FP+NP+10))=\"\${sht291}\""
eval "F$((FP+NP+11))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht310}\""
CALLEE=shdet
RPC=151; ACTION=call; return
;;
151)
eval "sht309=\"\$F$((FP+NP+0))\""
eval "sht307=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht305=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
eval "G_DQ=\"\$F$((FP+NP+5))\""
eval "sht302=\"\$F$((FP+NP+6))\""
eval "sht303=\"\$F$((FP+NP+7))\""
eval "sht302=\"\$F$((FP+NP+8))\""
eval "sht299=\"\$F$((FP+NP+9))\""
eval "sht291=\"\$F$((FP+NP+10))\""
eval "sht283=\"\$F$((FP+NP+11))\""
sht311="${R}"
sht312="T: )))${G_DQ#??}"
sht313="T:${sht311#??}${sht312#??}"
sht314="T: + ${sht313#??}"
sht315="T:${sht309#??}${sht314#??}"
sht316="T: + 1 ))-\$(( ${sht315#??}"
sht317="T:${sht307#??}${sht316#??}"
sht318="T: | cut -c\$(( ${sht317#??}"
sht319="T:${G_DQ#??}${sht318#??}"
sht320="T:${sht305#??}${sht319#??}"
sht321="T:${G_DQ#??}${sht320#??}"
sht322="T:T:\$(printf '%s' ${sht321#??}"
sht323="T:${G_DQ#??}${sht322#??}"
sht324="T:=${sht323#??}"
sht325="T:${sht302#??}${sht324#??}"
eval "F$((FP+NP+0))=\"\${sht302}\""
eval "F$((FP+NP+1))=\"\${sht299}\""
eval "F$((FP+NP+2))=\"\${sht291}\""
eval "F$((FP+NP+3))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht303}\""
eval "F$((NFP+1))=\"\${sht325}\""
CALLEE=emit
RPC=152; ACTION=call; return
;;
152)
eval "sht302=\"\$F$((FP+NP+0))\""
eval "sht299=\"\$F$((FP+NP+1))\""
eval "sht291=\"\$F$((FP+NP+2))\""
eval "sht283=\"\$F$((FP+NP+3))\""
sht326="${R}"
eval "F$((FP+NP+0))=\"\${sht302}\""
eval "F$((FP+NP+1))=\"\${sht299}\""
eval "F$((FP+NP+2))=\"\${sht291}\""
eval "F$((FP+NP+3))=\"\${sht283}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht326}\""
CALLEE=bkzzP
RPC=153; ACTION=call; return
;;
153)
eval "sht302=\"\$F$((FP+NP+0))\""
eval "sht299=\"\$F$((FP+NP+1))\""
eval "sht291=\"\$F$((FP+NP+2))\""
eval "sht283=\"\$F$((FP+NP+3))\""
sht327="${R}"
eval "F$((FP+NP+0))=\"\${sht327}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${sht299}\""
eval "F$((FP+NP+3))=\"\${sht291}\""
eval "F$((FP+NP+4))=\"\${sht283}\""
hp_cons "S:loc" "${sht302}"
eval "sht327=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "sht299=\"\$F$((FP+NP+2))\""
eval "sht291=\"\$F$((FP+NP+3))\""
eval "sht283=\"\$F$((FP+NP+4))\""
sht328="${R}"
eval "F$((FP+NP+0))=\"\${sht302}\""
eval "F$((FP+NP+1))=\"\${sht299}\""
eval "F$((FP+NP+2))=\"\${sht291}\""
eval "F$((FP+NP+3))=\"\${sht283}\""
hp_cons "${sht327}" "${sht328}"
eval "sht302=\"\$F$((FP+NP+0))\""
eval "sht299=\"\$F$((FP+NP+1))\""
eval "sht291=\"\$F$((FP+NP+2))\""
eval "sht283=\"\$F$((FP+NP+3))\""
sht329="${R}"
R="${sht329}"; ACTION=ret; return
;;
154)
sht331="${R}"
if [ "${sht331}" != NIL ]; then PC=155; else PC=156; fi
ACTION=jump; return
;;
155)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=ctest
RPC=157; ACTION=call; return
;;
156)
hp_car "${p0}"
sht357="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht357}\""
CALLEE=builtinzzQ
RPC=165; ACTION=call; return
;;
157)
sht332="${R}"
sht333="${sht332}"
hp_car "${sht333}"
sht334="${R}"
eval "F$((FP+NP+0))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht334}\""
CALLEE=tmpn
RPC=158; ACTION=call; return
;;
158)
eval "sht333=\"\$F$((FP+NP+0))\""
sht335="${R}"
sht336="${sht335}"
hp_car "${sht333}"
sht337="${R}"
hp_cdr "${sht333}"
sht338="${R}"
sht339="T:${sht338#??}; then"
sht340="T:if ${sht339#??}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht337}\""
eval "F$((NFP+1))=\"\${sht340}\""
CALLEE=emit
RPC=159; ACTION=call; return
;;
159)
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht341="${R}"
sht342="T:S:t${G_DQ#??}"
sht343="T:${G_DQ#??}${sht342#??}"
sht344="T:=${sht343#??}"
sht345="T:${sht336#??}${sht344#??}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht341}\""
eval "F$((NFP+1))=\"\${sht345}\""
CALLEE=emit
RPC=160; ACTION=call; return
;;
160)
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht346="${R}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht346}\""
STGV="T:else"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=161; ACTION=call; return
;;
161)
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht347="${R}"
sht348="T:NIL${G_DQ#??}"
sht349="T:${G_DQ#??}${sht348#??}"
sht350="T:=${sht349#??}"
sht351="T:${sht336#??}${sht350#??}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht347}\""
eval "F$((NFP+1))=\"\${sht351}\""
CALLEE=emit
RPC=162; ACTION=call; return
;;
162)
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht352="${R}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht352}\""
STGV="T:fi"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=163; ACTION=call; return
;;
163)
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht353="${R}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht353}\""
CALLEE=bkzzP
RPC=164; ACTION=call; return
;;
164)
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht354="${R}"
eval "F$((FP+NP+0))=\"\${sht354}\""
eval "F$((FP+NP+1))=\"\${sht336}\""
eval "F$((FP+NP+2))=\"\${sht333}\""
hp_cons "S:loc" "${sht336}"
eval "sht354=\"\$F$((FP+NP+0))\""
eval "sht336=\"\$F$((FP+NP+1))\""
eval "sht333=\"\$F$((FP+NP+2))\""
sht355="${R}"
eval "F$((FP+NP+0))=\"\${sht336}\""
eval "F$((FP+NP+1))=\"\${sht333}\""
hp_cons "${sht354}" "${sht355}"
eval "sht336=\"\$F$((FP+NP+0))\""
eval "sht333=\"\$F$((FP+NP+1))\""
sht356="${R}"
R="${sht356}"; ACTION=ret; return
;;
165)
sht358="${R}"
if [ "${sht358}" != NIL ]; then PC=166; else PC=167; fi
ACTION=jump; return
;;
166)
hp_cdr "${p0}"
sht359="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht359}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=168; ACTION=call; return
;;
167)
hp_car "${p0}"
sht386="${R}"
if [ "${sht386}" = "S:make-closure" ]; then PC=179; else PC=180; fi
ACTION=jump; return
;;
168)
sht360="${R}"
sht361="${sht360}"
hp_car "${p0}"
sht362="${R}"
sht363="T:${sht362#??}"
eval "F$((FP+NP+0))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht363}\""
CALLEE=sh_mangle
RPC=169; ACTION=call; return
;;
169)
eval "sht361=\"\$F$((FP+NP+0))\""
sht364="${R}"
sht365="${sht364}"
hp_car "${sht361}"
sht366="${R}"
eval "F$((FP+NP+0))=\"\${sht365}\""
eval "F$((FP+NP+1))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht366}\""
CALLEE=tmpn
RPC=170; ACTION=call; return
;;
170)
eval "sht365=\"\$F$((FP+NP+0))\""
eval "sht361=\"\$F$((FP+NP+1))\""
sht367="${R}"
sht368="${sht367}"
hp_car "${sht361}"
sht369="${R}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht369}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=171; ACTION=call; return
;;
171)
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht370="${R}"
hp_cdr "${sht361}"
sht371="${R}"
eval "F$((FP+NP+0))=\"\${sht365}\""
eval "F$((FP+NP+1))=\"\${sht370}\""
eval "F$((FP+NP+2))=\"\${sht368}\""
eval "F$((FP+NP+3))=\"\${sht365}\""
eval "F$((FP+NP+4))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht371}\""
CALLEE=bargs
RPC=172; ACTION=call; return
;;
172)
eval "sht365=\"\$F$((FP+NP+0))\""
eval "sht370=\"\$F$((FP+NP+1))\""
eval "sht368=\"\$F$((FP+NP+2))\""
eval "sht365=\"\$F$((FP+NP+3))\""
eval "sht361=\"\$F$((FP+NP+4))\""
sht372="${R}"
sht373="T:${sht365#??}${sht372#??}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht370}\""
eval "F$((NFP+1))=\"\${sht373}\""
CALLEE=emit
RPC=173; ACTION=call; return
;;
173)
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht374="${R}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht374}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=174; ACTION=call; return
;;
174)
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht375="${R}"
sht376="T:\${R}${G_DQ#??}"
sht377="T:${G_DQ#??}${sht376#??}"
sht378="T:=${sht377#??}"
sht379="T:${sht368#??}${sht378#??}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht375}\""
eval "F$((NFP+1))=\"\${sht379}\""
CALLEE=emit
RPC=175; ACTION=call; return
;;
175)
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht380="${R}"
eval "F$((FP+NP+0))=\"\${sht380}\""
eval "F$((FP+NP+1))=\"\${sht368}\""
eval "F$((FP+NP+2))=\"\${sht365}\""
eval "F$((FP+NP+3))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=176; ACTION=call; return
;;
176)
eval "sht380=\"\$F$((FP+NP+0))\""
eval "sht368=\"\$F$((FP+NP+1))\""
eval "sht365=\"\$F$((FP+NP+2))\""
eval "sht361=\"\$F$((FP+NP+3))\""
sht381="${R}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht380}\""
eval "F$((NFP+1))=\"\${sht381}\""
CALLEE=bsm
RPC=177; ACTION=call; return
;;
177)
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht382="${R}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht382}\""
CALLEE=bkzzP
RPC=178; ACTION=call; return
;;
178)
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht383="${R}"
eval "F$((FP+NP+0))=\"\${sht383}\""
eval "F$((FP+NP+1))=\"\${sht368}\""
eval "F$((FP+NP+2))=\"\${sht365}\""
eval "F$((FP+NP+3))=\"\${sht361}\""
hp_cons "S:loc" "${sht368}"
eval "sht383=\"\$F$((FP+NP+0))\""
eval "sht368=\"\$F$((FP+NP+1))\""
eval "sht365=\"\$F$((FP+NP+2))\""
eval "sht361=\"\$F$((FP+NP+3))\""
sht384="${R}"
eval "F$((FP+NP+0))=\"\${sht368}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht361}\""
hp_cons "${sht383}" "${sht384}"
eval "sht368=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht361=\"\$F$((FP+NP+2))\""
sht385="${R}"
R="${sht385}"; ACTION=ret; return
;;
179)
hp_cdr "${p0}"
sht387="${R}"
hp_car "${sht387}"
sht388="${R}"
hp_cdr "${p0}"
sht389="${R}"
hp_cdr "${sht389}"
sht390="${R}"
eval "F$((FP+NP+0))=\"\${sht388}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht390}\""
CALLEE=mkclo_caps
RPC=181; ACTION=call; return
;;
180)
hp_car "${p0}"
sht413="${R}"
if [ "${sht413}" = "S:apply" ]; then PC=186; else PC=187; fi
ACTION=jump; return
;;
181)
eval "sht388=\"\$F$((FP+NP+0))\""
sht391="${R}"
eval "F$((FP+NP+0))=\"\${sht388}\""
hp_cons "${sht391}" "NIL"
eval "sht388=\"\$F$((FP+NP+0))\""
sht392="${R}"
hp_cons "${sht388}" "${sht392}"
sht393="${R}"
hp_cons "S:cons" "${sht393}"
sht394="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht394}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=182; ACTION=call; return
;;
182)
sht395="${R}"
sht396="${sht395}"
hp_car "${sht396}"
sht397="${R}"
eval "F$((FP+NP+0))=\"\${sht396}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht397}\""
CALLEE=tmpn
RPC=183; ACTION=call; return
;;
183)
eval "sht396=\"\$F$((FP+NP+0))\""
sht398="${R}"
sht399="${sht398}"
hp_car "${sht396}"
sht400="${R}"
hp_cdr "${sht396}"
sht401="${R}"
hp_cdr "${sht401}"
sht402="${R}"
sht403="T:#P:}${G_DQ#??}"
sht404="T:${sht402#??}${sht403#??}"
sht405="T:K:\${${sht404#??}"
sht406="T:${G_DQ#??}${sht405#??}"
sht407="T:=${sht406#??}"
sht408="T:${sht399#??}${sht407#??}"
eval "F$((FP+NP+0))=\"\${sht399}\""
eval "F$((FP+NP+1))=\"\${sht396}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht400}\""
eval "F$((NFP+1))=\"\${sht408}\""
CALLEE=emit
RPC=184; ACTION=call; return
;;
184)
eval "sht399=\"\$F$((FP+NP+0))\""
eval "sht396=\"\$F$((FP+NP+1))\""
sht409="${R}"
eval "F$((FP+NP+0))=\"\${sht399}\""
eval "F$((FP+NP+1))=\"\${sht396}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht409}\""
CALLEE=bkzzP
RPC=185; ACTION=call; return
;;
185)
eval "sht399=\"\$F$((FP+NP+0))\""
eval "sht396=\"\$F$((FP+NP+1))\""
sht410="${R}"
eval "F$((FP+NP+0))=\"\${sht410}\""
eval "F$((FP+NP+1))=\"\${sht399}\""
eval "F$((FP+NP+2))=\"\${sht396}\""
hp_cons "S:loc" "${sht399}"
eval "sht410=\"\$F$((FP+NP+0))\""
eval "sht399=\"\$F$((FP+NP+1))\""
eval "sht396=\"\$F$((FP+NP+2))\""
sht411="${R}"
eval "F$((FP+NP+0))=\"\${sht399}\""
eval "F$((FP+NP+1))=\"\${sht396}\""
hp_cons "${sht410}" "${sht411}"
eval "sht399=\"\$F$((FP+NP+0))\""
eval "sht396=\"\$F$((FP+NP+1))\""
sht412="${R}"
R="${sht412}"; ACTION=ret; return
;;
186)
hp_cdr "${p0}"
sht414="${R}"
hp_car "${sht414}"
sht415="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht415}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=188; ACTION=call; return
;;
187)
hp_car "${p0}"
sht465="${R}"
if [ "${sht465#S:}" != "${sht465}" ]; then PC=208; else PC=209; fi
ACTION=jump; return
;;
188)
sht416="${R}"
sht417="${sht416}"
hp_cdr "${sht417}"
sht418="${R}"
eval "F$((FP+NP+0))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht418}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=189; ACTION=call; return
;;
189)
eval "sht417=\"\$F$((FP+NP+0))\""
sht419="${R}"
sht420="${sht419}"
hp_cdr "${p0}"
sht421="${R}"
hp_cdr "${sht421}"
sht422="${R}"
hp_car "${sht422}"
sht423="${R}"
hp_car "${sht417}"
sht424="${R}"
eval "F$((FP+NP+0))=\"\${sht420}\""
eval "F$((FP+NP+1))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht423}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht424}\""
eval "F$((NFP+3))=\"\${sht420}\""
CALLEE=lval
RPC=190; ACTION=call; return
;;
190)
eval "sht420=\"\$F$((FP+NP+0))\""
eval "sht417=\"\$F$((FP+NP+1))\""
sht425="${R}"
sht426="${sht425}"
hp_cdr "${sht426}"
sht427="${R}"
eval "F$((FP+NP+0))=\"\${sht426}\""
eval "F$((FP+NP+1))=\"\${sht420}\""
eval "F$((FP+NP+2))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht427}\""
eval "F$((NFP+1))=\"\${sht420}\""
CALLEE=addlive
RPC=191; ACTION=call; return
;;
191)
eval "sht426=\"\$F$((FP+NP+0))\""
eval "sht420=\"\$F$((FP+NP+1))\""
eval "sht417=\"\$F$((FP+NP+2))\""
sht428="${R}"
sht429="${sht428}"
hp_car "${sht426}"
sht430="${R}"
eval "F$((FP+NP+0))=\"\${sht429}\""
eval "F$((FP+NP+1))=\"\${sht426}\""
eval "F$((FP+NP+2))=\"\${sht420}\""
eval "F$((FP+NP+3))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht430}\""
CALLEE=b_npc
RPC=192; ACTION=call; return
;;
192)
eval "sht429=\"\$F$((FP+NP+0))\""
eval "sht426=\"\$F$((FP+NP+1))\""
eval "sht420=\"\$F$((FP+NP+2))\""
eval "sht417=\"\$F$((FP+NP+3))\""
sht431="${R}"
sht432="${sht431}"
hp_car "${sht426}"
sht433="${R}"
eval "F$((FP+NP+0))=\"\${sht432}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht426}\""
eval "F$((FP+NP+3))=\"\${sht420}\""
eval "F$((FP+NP+4))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht433}\""
CALLEE=bnpczzP
RPC=193; ACTION=call; return
;;
193)
eval "sht432=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht426=\"\$F$((FP+NP+2))\""
eval "sht420=\"\$F$((FP+NP+3))\""
eval "sht417=\"\$F$((FP+NP+4))\""
sht434="${R}"
eval "F$((FP+NP+0))=\"\${sht432}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht426}\""
eval "F$((FP+NP+3))=\"\${sht420}\""
eval "F$((FP+NP+4))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht434}\""
eval "F$((NFP+1))=\"\${sht429}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=194; ACTION=call; return
;;
194)
eval "sht432=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht426=\"\$F$((FP+NP+2))\""
eval "sht420=\"\$F$((FP+NP+3))\""
eval "sht417=\"\$F$((FP+NP+4))\""
sht435="${R}"
eval "F$((FP+NP+0))=\"\${sht432}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht426}\""
eval "F$((FP+NP+3))=\"\${sht420}\""
eval "F$((FP+NP+4))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht435}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=195; ACTION=call; return
;;
195)
eval "sht432=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht426=\"\$F$((FP+NP+2))\""
eval "sht420=\"\$F$((FP+NP+3))\""
eval "sht417=\"\$F$((FP+NP+4))\""
sht436="${R}"
hp_cdr "${sht417}"
sht437="${R}"
eval "F$((FP+NP+0))=\"\${sht436}\""
eval "F$((FP+NP+1))=\"\${sht432}\""
eval "F$((FP+NP+2))=\"\${sht429}\""
eval "F$((FP+NP+3))=\"\${sht426}\""
eval "F$((FP+NP+4))=\"\${sht420}\""
eval "F$((FP+NP+5))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht437}\""
CALLEE=refrhs
RPC=196; ACTION=call; return
;;
196)
eval "sht436=\"\$F$((FP+NP+0))\""
eval "sht432=\"\$F$((FP+NP+1))\""
eval "sht429=\"\$F$((FP+NP+2))\""
eval "sht426=\"\$F$((FP+NP+3))\""
eval "sht420=\"\$F$((FP+NP+4))\""
eval "sht417=\"\$F$((FP+NP+5))\""
sht438="${R}"
sht439="T:CALLEE=${sht438#??}"
eval "F$((FP+NP+0))=\"\${sht432}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht426}\""
eval "F$((FP+NP+3))=\"\${sht420}\""
eval "F$((FP+NP+4))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht436}\""
eval "F$((NFP+1))=\"\${sht439}\""
CALLEE=emit
RPC=197; ACTION=call; return
;;
197)
eval "sht432=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht426=\"\$F$((FP+NP+2))\""
eval "sht420=\"\$F$((FP+NP+3))\""
eval "sht417=\"\$F$((FP+NP+4))\""
sht440="${R}"
hp_cdr "${sht426}"
sht441="${R}"
eval "F$((FP+NP+0))=\"\${sht440}\""
eval "F$((FP+NP+1))=\"\${sht432}\""
eval "F$((FP+NP+2))=\"\${sht429}\""
eval "F$((FP+NP+3))=\"\${sht426}\""
eval "F$((FP+NP+4))=\"\${sht420}\""
eval "F$((FP+NP+5))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht441}\""
CALLEE=refrhs
RPC=198; ACTION=call; return
;;
198)
eval "sht440=\"\$F$((FP+NP+0))\""
eval "sht432=\"\$F$((FP+NP+1))\""
eval "sht429=\"\$F$((FP+NP+2))\""
eval "sht426=\"\$F$((FP+NP+3))\""
eval "sht420=\"\$F$((FP+NP+4))\""
eval "sht417=\"\$F$((FP+NP+5))\""
sht442="${R}"
sht443="T:APLIST=${sht442#??}"
eval "F$((FP+NP+0))=\"\${sht432}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht426}\""
eval "F$((FP+NP+3))=\"\${sht420}\""
eval "F$((FP+NP+4))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht440}\""
eval "F$((NFP+1))=\"\${sht443}\""
CALLEE=emit
RPC=199; ACTION=call; return
;;
199)
eval "sht432=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht426=\"\$F$((FP+NP+2))\""
eval "sht420=\"\$F$((FP+NP+3))\""
eval "sht417=\"\$F$((FP+NP+4))\""
sht444="${R}"
sht445="T:${sht432#??}"
sht446="T:${sht445#??}; ACTION=apply; return"
sht447="T:RPC=${sht446#??}"
eval "F$((FP+NP+0))=\"\${sht432}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht426}\""
eval "F$((FP+NP+3))=\"\${sht420}\""
eval "F$((FP+NP+4))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht444}\""
eval "F$((NFP+1))=\"\${sht447}\""
CALLEE=emit
RPC=200; ACTION=call; return
;;
200)
eval "sht432=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht426=\"\$F$((FP+NP+2))\""
eval "sht420=\"\$F$((FP+NP+3))\""
eval "sht417=\"\$F$((FP+NP+4))\""
sht448="${R}"
sht449="${sht448}"
eval "F$((FP+NP+0))=\"\${sht449}\""
eval "F$((FP+NP+1))=\"\${sht432}\""
eval "F$((FP+NP+2))=\"\${sht429}\""
eval "F$((FP+NP+3))=\"\${sht426}\""
eval "F$((FP+NP+4))=\"\${sht420}\""
eval "F$((FP+NP+5))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht449}\""
eval "F$((NFP+1))=\"\${sht432}\""
CALLEE=switch
RPC=201; ACTION=call; return
;;
201)
eval "sht449=\"\$F$((FP+NP+0))\""
eval "sht432=\"\$F$((FP+NP+1))\""
eval "sht429=\"\$F$((FP+NP+2))\""
eval "sht426=\"\$F$((FP+NP+3))\""
eval "sht420=\"\$F$((FP+NP+4))\""
eval "sht417=\"\$F$((FP+NP+5))\""
sht450="${R}"
sht451="${sht450}"
eval "F$((FP+NP+0))=\"\${sht451}\""
eval "F$((FP+NP+1))=\"\${sht449}\""
eval "F$((FP+NP+2))=\"\${sht432}\""
eval "F$((FP+NP+3))=\"\${sht429}\""
eval "F$((FP+NP+4))=\"\${sht426}\""
eval "F$((FP+NP+5))=\"\${sht420}\""
eval "F$((FP+NP+6))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht451}\""
CALLEE=tmpn
RPC=202; ACTION=call; return
;;
202)
eval "sht451=\"\$F$((FP+NP+0))\""
eval "sht449=\"\$F$((FP+NP+1))\""
eval "sht432=\"\$F$((FP+NP+2))\""
eval "sht429=\"\$F$((FP+NP+3))\""
eval "sht426=\"\$F$((FP+NP+4))\""
eval "sht420=\"\$F$((FP+NP+5))\""
eval "sht417=\"\$F$((FP+NP+6))\""
sht452="${R}"
sht453="${sht452}"
eval "F$((FP+NP+0))=\"\${sht453}\""
eval "F$((FP+NP+1))=\"\${sht451}\""
eval "F$((FP+NP+2))=\"\${sht449}\""
eval "F$((FP+NP+3))=\"\${sht432}\""
eval "F$((FP+NP+4))=\"\${sht429}\""
eval "F$((FP+NP+5))=\"\${sht426}\""
eval "F$((FP+NP+6))=\"\${sht420}\""
eval "F$((FP+NP+7))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht451}\""
eval "F$((NFP+1))=\"\${sht429}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=203; ACTION=call; return
;;
203)
eval "sht453=\"\$F$((FP+NP+0))\""
eval "sht451=\"\$F$((FP+NP+1))\""
eval "sht449=\"\$F$((FP+NP+2))\""
eval "sht432=\"\$F$((FP+NP+3))\""
eval "sht429=\"\$F$((FP+NP+4))\""
eval "sht426=\"\$F$((FP+NP+5))\""
eval "sht420=\"\$F$((FP+NP+6))\""
eval "sht417=\"\$F$((FP+NP+7))\""
sht454="${R}"
sht455="T:\${R}${G_DQ#??}"
sht456="T:${G_DQ#??}${sht455#??}"
sht457="T:=${sht456#??}"
sht458="T:${sht453#??}${sht457#??}"
eval "F$((FP+NP+0))=\"\${sht453}\""
eval "F$((FP+NP+1))=\"\${sht451}\""
eval "F$((FP+NP+2))=\"\${sht449}\""
eval "F$((FP+NP+3))=\"\${sht432}\""
eval "F$((FP+NP+4))=\"\${sht429}\""
eval "F$((FP+NP+5))=\"\${sht426}\""
eval "F$((FP+NP+6))=\"\${sht420}\""
eval "F$((FP+NP+7))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht454}\""
eval "F$((NFP+1))=\"\${sht458}\""
CALLEE=emit
RPC=204; ACTION=call; return
;;
204)
eval "sht453=\"\$F$((FP+NP+0))\""
eval "sht451=\"\$F$((FP+NP+1))\""
eval "sht449=\"\$F$((FP+NP+2))\""
eval "sht432=\"\$F$((FP+NP+3))\""
eval "sht429=\"\$F$((FP+NP+4))\""
eval "sht426=\"\$F$((FP+NP+5))\""
eval "sht420=\"\$F$((FP+NP+6))\""
eval "sht417=\"\$F$((FP+NP+7))\""
sht459="${R}"
eval "F$((FP+NP+0))=\"\${sht459}\""
eval "F$((FP+NP+1))=\"\${sht453}\""
eval "F$((FP+NP+2))=\"\${sht451}\""
eval "F$((FP+NP+3))=\"\${sht449}\""
eval "F$((FP+NP+4))=\"\${sht432}\""
eval "F$((FP+NP+5))=\"\${sht429}\""
eval "F$((FP+NP+6))=\"\${sht426}\""
eval "F$((FP+NP+7))=\"\${sht420}\""
eval "F$((FP+NP+8))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht429}\""
CALLEE=lenl
RPC=205; ACTION=call; return
;;
205)
eval "sht459=\"\$F$((FP+NP+0))\""
eval "sht453=\"\$F$((FP+NP+1))\""
eval "sht451=\"\$F$((FP+NP+2))\""
eval "sht449=\"\$F$((FP+NP+3))\""
eval "sht432=\"\$F$((FP+NP+4))\""
eval "sht429=\"\$F$((FP+NP+5))\""
eval "sht426=\"\$F$((FP+NP+6))\""
eval "sht420=\"\$F$((FP+NP+7))\""
eval "sht417=\"\$F$((FP+NP+8))\""
sht460="${R}"
eval "F$((FP+NP+0))=\"\${sht453}\""
eval "F$((FP+NP+1))=\"\${sht451}\""
eval "F$((FP+NP+2))=\"\${sht449}\""
eval "F$((FP+NP+3))=\"\${sht432}\""
eval "F$((FP+NP+4))=\"\${sht429}\""
eval "F$((FP+NP+5))=\"\${sht426}\""
eval "F$((FP+NP+6))=\"\${sht420}\""
eval "F$((FP+NP+7))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht459}\""
eval "F$((NFP+1))=\"\${sht460}\""
CALLEE=bsm
RPC=206; ACTION=call; return
;;
206)
eval "sht453=\"\$F$((FP+NP+0))\""
eval "sht451=\"\$F$((FP+NP+1))\""
eval "sht449=\"\$F$((FP+NP+2))\""
eval "sht432=\"\$F$((FP+NP+3))\""
eval "sht429=\"\$F$((FP+NP+4))\""
eval "sht426=\"\$F$((FP+NP+5))\""
eval "sht420=\"\$F$((FP+NP+6))\""
eval "sht417=\"\$F$((FP+NP+7))\""
sht461="${R}"
eval "F$((FP+NP+0))=\"\${sht453}\""
eval "F$((FP+NP+1))=\"\${sht451}\""
eval "F$((FP+NP+2))=\"\${sht449}\""
eval "F$((FP+NP+3))=\"\${sht432}\""
eval "F$((FP+NP+4))=\"\${sht429}\""
eval "F$((FP+NP+5))=\"\${sht426}\""
eval "F$((FP+NP+6))=\"\${sht420}\""
eval "F$((FP+NP+7))=\"\${sht417}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht461}\""
CALLEE=bkzzP
RPC=207; ACTION=call; return
;;
207)
eval "sht453=\"\$F$((FP+NP+0))\""
eval "sht451=\"\$F$((FP+NP+1))\""
eval "sht449=\"\$F$((FP+NP+2))\""
eval "sht432=\"\$F$((FP+NP+3))\""
eval "sht429=\"\$F$((FP+NP+4))\""
eval "sht426=\"\$F$((FP+NP+5))\""
eval "sht420=\"\$F$((FP+NP+6))\""
eval "sht417=\"\$F$((FP+NP+7))\""
sht462="${R}"
eval "F$((FP+NP+0))=\"\${sht462}\""
eval "F$((FP+NP+1))=\"\${sht453}\""
eval "F$((FP+NP+2))=\"\${sht451}\""
eval "F$((FP+NP+3))=\"\${sht449}\""
eval "F$((FP+NP+4))=\"\${sht432}\""
eval "F$((FP+NP+5))=\"\${sht429}\""
eval "F$((FP+NP+6))=\"\${sht426}\""
eval "F$((FP+NP+7))=\"\${sht420}\""
eval "F$((FP+NP+8))=\"\${sht417}\""
hp_cons "S:loc" "${sht453}"
eval "sht462=\"\$F$((FP+NP+0))\""
eval "sht453=\"\$F$((FP+NP+1))\""
eval "sht451=\"\$F$((FP+NP+2))\""
eval "sht449=\"\$F$((FP+NP+3))\""
eval "sht432=\"\$F$((FP+NP+4))\""
eval "sht429=\"\$F$((FP+NP+5))\""
eval "sht426=\"\$F$((FP+NP+6))\""
eval "sht420=\"\$F$((FP+NP+7))\""
eval "sht417=\"\$F$((FP+NP+8))\""
sht463="${R}"
eval "F$((FP+NP+0))=\"\${sht453}\""
eval "F$((FP+NP+1))=\"\${sht451}\""
eval "F$((FP+NP+2))=\"\${sht449}\""
eval "F$((FP+NP+3))=\"\${sht432}\""
eval "F$((FP+NP+4))=\"\${sht429}\""
eval "F$((FP+NP+5))=\"\${sht426}\""
eval "F$((FP+NP+6))=\"\${sht420}\""
eval "F$((FP+NP+7))=\"\${sht417}\""
hp_cons "${sht462}" "${sht463}"
eval "sht453=\"\$F$((FP+NP+0))\""
eval "sht451=\"\$F$((FP+NP+1))\""
eval "sht449=\"\$F$((FP+NP+2))\""
eval "sht432=\"\$F$((FP+NP+3))\""
eval "sht429=\"\$F$((FP+NP+4))\""
eval "sht426=\"\$F$((FP+NP+5))\""
eval "sht420=\"\$F$((FP+NP+6))\""
eval "sht417=\"\$F$((FP+NP+7))\""
sht464="${R}"
R="${sht464}"; ACTION=ret; return
;;
208)
hp_car "${p0}"
sht467="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht467}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=211; ACTION=call; return
;;
209)
sht466="NIL"
PC=210; ACTION=jump; return
;;
210)
if [ "${sht466}" != NIL ]; then PC=212; else PC=213; fi
ACTION=jump; return
;;
211)
sht468="${R}"
if [ "${sht468}" = NIL ]; then
sht469="S:t"
else
sht469="NIL"
fi
sht466="${sht469}"
PC=210; ACTION=jump; return
;;
212)
hp_cdr "${p0}"
sht470="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht470}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=214; ACTION=call; return
;;
213)
hp_car "${p0}"
sht508="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht508}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=230; ACTION=call; return
;;
214)
sht471="${R}"
sht472="${sht471}"
hp_car "${sht472}"
sht473="${R}"
eval "F$((FP+NP+0))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht473}\""
CALLEE=b_npc
RPC=215; ACTION=call; return
;;
215)
eval "sht472=\"\$F$((FP+NP+0))\""
sht474="${R}"
sht475="${sht474}"
hp_car "${p0}"
sht476="${R}"
sht477="T:${sht476#??}"
eval "F$((FP+NP+0))=\"\${sht475}\""
eval "F$((FP+NP+1))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht477}\""
CALLEE=sh_mangle
RPC=216; ACTION=call; return
;;
216)
eval "sht475=\"\$F$((FP+NP+0))\""
eval "sht472=\"\$F$((FP+NP+1))\""
sht478="${R}"
sht479="${sht478}"
hp_car "${sht472}"
sht480="${R}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht475}\""
eval "F$((FP+NP+2))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht480}\""
CALLEE=bnpczzP
RPC=217; ACTION=call; return
;;
217)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht475=\"\$F$((FP+NP+1))\""
eval "sht472=\"\$F$((FP+NP+2))\""
sht481="${R}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht475}\""
eval "F$((FP+NP+2))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht481}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=218; ACTION=call; return
;;
218)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht475=\"\$F$((FP+NP+1))\""
eval "sht472=\"\$F$((FP+NP+2))\""
sht482="${R}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht475}\""
eval "F$((FP+NP+2))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht482}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=219; ACTION=call; return
;;
219)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht475=\"\$F$((FP+NP+1))\""
eval "sht472=\"\$F$((FP+NP+2))\""
sht483="${R}"
hp_cdr "${sht472}"
sht484="${R}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht475}\""
eval "F$((FP+NP+2))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht483}\""
eval "F$((NFP+1))=\"\${sht484}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=220; ACTION=call; return
;;
220)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht475=\"\$F$((FP+NP+1))\""
eval "sht472=\"\$F$((FP+NP+2))\""
sht485="${R}"
sht486="T:CALLEE=${sht479#??}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht475}\""
eval "F$((FP+NP+2))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht485}\""
eval "F$((NFP+1))=\"\${sht486}\""
CALLEE=emit
RPC=221; ACTION=call; return
;;
221)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht475=\"\$F$((FP+NP+1))\""
eval "sht472=\"\$F$((FP+NP+2))\""
sht487="${R}"
sht488="T:${sht475#??}"
sht489="T:${sht488#??}; ACTION=call; return"
sht490="T:RPC=${sht489#??}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht475}\""
eval "F$((FP+NP+2))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht487}\""
eval "F$((NFP+1))=\"\${sht490}\""
CALLEE=emit
RPC=222; ACTION=call; return
;;
222)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht475=\"\$F$((FP+NP+1))\""
eval "sht472=\"\$F$((FP+NP+2))\""
sht491="${R}"
sht492="${sht491}"
eval "F$((FP+NP+0))=\"\${sht492}\""
eval "F$((FP+NP+1))=\"\${sht479}\""
eval "F$((FP+NP+2))=\"\${sht475}\""
eval "F$((FP+NP+3))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht492}\""
eval "F$((NFP+1))=\"\${sht475}\""
CALLEE=switch
RPC=223; ACTION=call; return
;;
223)
eval "sht492=\"\$F$((FP+NP+0))\""
eval "sht479=\"\$F$((FP+NP+1))\""
eval "sht475=\"\$F$((FP+NP+2))\""
eval "sht472=\"\$F$((FP+NP+3))\""
sht493="${R}"
sht494="${sht493}"
eval "F$((FP+NP+0))=\"\${sht494}\""
eval "F$((FP+NP+1))=\"\${sht492}\""
eval "F$((FP+NP+2))=\"\${sht479}\""
eval "F$((FP+NP+3))=\"\${sht475}\""
eval "F$((FP+NP+4))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht494}\""
CALLEE=tmpn
RPC=224; ACTION=call; return
;;
224)
eval "sht494=\"\$F$((FP+NP+0))\""
eval "sht492=\"\$F$((FP+NP+1))\""
eval "sht479=\"\$F$((FP+NP+2))\""
eval "sht475=\"\$F$((FP+NP+3))\""
eval "sht472=\"\$F$((FP+NP+4))\""
sht495="${R}"
sht496="${sht495}"
eval "F$((FP+NP+0))=\"\${sht496}\""
eval "F$((FP+NP+1))=\"\${sht494}\""
eval "F$((FP+NP+2))=\"\${sht492}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht475}\""
eval "F$((FP+NP+5))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht494}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=225; ACTION=call; return
;;
225)
eval "sht496=\"\$F$((FP+NP+0))\""
eval "sht494=\"\$F$((FP+NP+1))\""
eval "sht492=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht475=\"\$F$((FP+NP+4))\""
eval "sht472=\"\$F$((FP+NP+5))\""
sht497="${R}"
sht498="T:\${R}${G_DQ#??}"
sht499="T:${G_DQ#??}${sht498#??}"
sht500="T:=${sht499#??}"
sht501="T:${sht496#??}${sht500#??}"
eval "F$((FP+NP+0))=\"\${sht496}\""
eval "F$((FP+NP+1))=\"\${sht494}\""
eval "F$((FP+NP+2))=\"\${sht492}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht475}\""
eval "F$((FP+NP+5))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht497}\""
eval "F$((NFP+1))=\"\${sht501}\""
CALLEE=emit
RPC=226; ACTION=call; return
;;
226)
eval "sht496=\"\$F$((FP+NP+0))\""
eval "sht494=\"\$F$((FP+NP+1))\""
eval "sht492=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht475=\"\$F$((FP+NP+4))\""
eval "sht472=\"\$F$((FP+NP+5))\""
sht502="${R}"
eval "F$((FP+NP+0))=\"\${sht502}\""
eval "F$((FP+NP+1))=\"\${sht496}\""
eval "F$((FP+NP+2))=\"\${sht494}\""
eval "F$((FP+NP+3))=\"\${sht492}\""
eval "F$((FP+NP+4))=\"\${sht479}\""
eval "F$((FP+NP+5))=\"\${sht475}\""
eval "F$((FP+NP+6))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=227; ACTION=call; return
;;
227)
eval "sht502=\"\$F$((FP+NP+0))\""
eval "sht496=\"\$F$((FP+NP+1))\""
eval "sht494=\"\$F$((FP+NP+2))\""
eval "sht492=\"\$F$((FP+NP+3))\""
eval "sht479=\"\$F$((FP+NP+4))\""
eval "sht475=\"\$F$((FP+NP+5))\""
eval "sht472=\"\$F$((FP+NP+6))\""
sht503="${R}"
eval "F$((FP+NP+0))=\"\${sht496}\""
eval "F$((FP+NP+1))=\"\${sht494}\""
eval "F$((FP+NP+2))=\"\${sht492}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht475}\""
eval "F$((FP+NP+5))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht502}\""
eval "F$((NFP+1))=\"\${sht503}\""
CALLEE=bsm
RPC=228; ACTION=call; return
;;
228)
eval "sht496=\"\$F$((FP+NP+0))\""
eval "sht494=\"\$F$((FP+NP+1))\""
eval "sht492=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht475=\"\$F$((FP+NP+4))\""
eval "sht472=\"\$F$((FP+NP+5))\""
sht504="${R}"
eval "F$((FP+NP+0))=\"\${sht496}\""
eval "F$((FP+NP+1))=\"\${sht494}\""
eval "F$((FP+NP+2))=\"\${sht492}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht475}\""
eval "F$((FP+NP+5))=\"\${sht472}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht504}\""
CALLEE=bkzzP
RPC=229; ACTION=call; return
;;
229)
eval "sht496=\"\$F$((FP+NP+0))\""
eval "sht494=\"\$F$((FP+NP+1))\""
eval "sht492=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht475=\"\$F$((FP+NP+4))\""
eval "sht472=\"\$F$((FP+NP+5))\""
sht505="${R}"
eval "F$((FP+NP+0))=\"\${sht505}\""
eval "F$((FP+NP+1))=\"\${sht496}\""
eval "F$((FP+NP+2))=\"\${sht494}\""
eval "F$((FP+NP+3))=\"\${sht492}\""
eval "F$((FP+NP+4))=\"\${sht479}\""
eval "F$((FP+NP+5))=\"\${sht475}\""
eval "F$((FP+NP+6))=\"\${sht472}\""
hp_cons "S:loc" "${sht496}"
eval "sht505=\"\$F$((FP+NP+0))\""
eval "sht496=\"\$F$((FP+NP+1))\""
eval "sht494=\"\$F$((FP+NP+2))\""
eval "sht492=\"\$F$((FP+NP+3))\""
eval "sht479=\"\$F$((FP+NP+4))\""
eval "sht475=\"\$F$((FP+NP+5))\""
eval "sht472=\"\$F$((FP+NP+6))\""
sht506="${R}"
eval "F$((FP+NP+0))=\"\${sht496}\""
eval "F$((FP+NP+1))=\"\${sht494}\""
eval "F$((FP+NP+2))=\"\${sht492}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht475}\""
eval "F$((FP+NP+5))=\"\${sht472}\""
hp_cons "${sht505}" "${sht506}"
eval "sht496=\"\$F$((FP+NP+0))\""
eval "sht494=\"\$F$((FP+NP+1))\""
eval "sht492=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht475=\"\$F$((FP+NP+4))\""
eval "sht472=\"\$F$((FP+NP+5))\""
sht507="${R}"
R="${sht507}"; ACTION=ret; return
;;
230)
sht509="${R}"
sht510="${sht509}"
hp_cdr "${sht510}"
sht511="${R}"
hp_cdr "${sht511}"
sht512="${R}"
sht513="${sht512}"
hp_cdr "${sht510}"
sht514="${R}"
eval "F$((FP+NP+0))=\"\${sht513}\""
eval "F$((FP+NP+1))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht514}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=231; ACTION=call; return
;;
231)
eval "sht513=\"\$F$((FP+NP+0))\""
eval "sht510=\"\$F$((FP+NP+1))\""
sht515="${R}"
sht516="${sht515}"
hp_cdr "${p0}"
sht517="${R}"
hp_car "${sht510}"
sht518="${R}"
eval "F$((FP+NP+0))=\"\${sht516}\""
eval "F$((FP+NP+1))=\"\${sht513}\""
eval "F$((FP+NP+2))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht517}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht518}\""
eval "F$((NFP+3))=\"\${sht516}\""
CALLEE=largs
RPC=232; ACTION=call; return
;;
232)
eval "sht516=\"\$F$((FP+NP+0))\""
eval "sht513=\"\$F$((FP+NP+1))\""
eval "sht510=\"\$F$((FP+NP+2))\""
sht519="${R}"
sht520="${sht519}"
hp_car "${sht520}"
sht521="${R}"
eval "F$((FP+NP+0))=\"\${sht520}\""
eval "F$((FP+NP+1))=\"\${sht516}\""
eval "F$((FP+NP+2))=\"\${sht513}\""
eval "F$((FP+NP+3))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht521}\""
CALLEE=b_npc
RPC=233; ACTION=call; return
;;
233)
eval "sht520=\"\$F$((FP+NP+0))\""
eval "sht516=\"\$F$((FP+NP+1))\""
eval "sht513=\"\$F$((FP+NP+2))\""
eval "sht510=\"\$F$((FP+NP+3))\""
sht522="${R}"
sht523="${sht522}"
hp_car "${sht520}"
sht524="${R}"
eval "F$((FP+NP+0))=\"\${sht523}\""
eval "F$((FP+NP+1))=\"\${sht520}\""
eval "F$((FP+NP+2))=\"\${sht516}\""
eval "F$((FP+NP+3))=\"\${sht513}\""
eval "F$((FP+NP+4))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht524}\""
CALLEE=bnpczzP
RPC=234; ACTION=call; return
;;
234)
eval "sht523=\"\$F$((FP+NP+0))\""
eval "sht520=\"\$F$((FP+NP+1))\""
eval "sht516=\"\$F$((FP+NP+2))\""
eval "sht513=\"\$F$((FP+NP+3))\""
eval "sht510=\"\$F$((FP+NP+4))\""
sht525="${R}"
eval "F$((FP+NP+0))=\"\${sht523}\""
eval "F$((FP+NP+1))=\"\${sht520}\""
eval "F$((FP+NP+2))=\"\${sht516}\""
eval "F$((FP+NP+3))=\"\${sht513}\""
eval "F$((FP+NP+4))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht525}\""
eval "F$((NFP+1))=\"\${sht516}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=235; ACTION=call; return
;;
235)
eval "sht523=\"\$F$((FP+NP+0))\""
eval "sht520=\"\$F$((FP+NP+1))\""
eval "sht516=\"\$F$((FP+NP+2))\""
eval "sht513=\"\$F$((FP+NP+3))\""
eval "sht510=\"\$F$((FP+NP+4))\""
sht526="${R}"
eval "F$((FP+NP+0))=\"\${sht523}\""
eval "F$((FP+NP+1))=\"\${sht520}\""
eval "F$((FP+NP+2))=\"\${sht516}\""
eval "F$((FP+NP+3))=\"\${sht513}\""
eval "F$((FP+NP+4))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht526}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=236; ACTION=call; return
;;
236)
eval "sht523=\"\$F$((FP+NP+0))\""
eval "sht520=\"\$F$((FP+NP+1))\""
eval "sht516=\"\$F$((FP+NP+2))\""
eval "sht513=\"\$F$((FP+NP+3))\""
eval "sht510=\"\$F$((FP+NP+4))\""
sht527="${R}"
hp_cdr "${sht520}"
sht528="${R}"
eval "F$((FP+NP+0))=\"\${sht523}\""
eval "F$((FP+NP+1))=\"\${sht520}\""
eval "F$((FP+NP+2))=\"\${sht516}\""
eval "F$((FP+NP+3))=\"\${sht513}\""
eval "F$((FP+NP+4))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht527}\""
eval "F$((NFP+1))=\"\${sht528}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=237; ACTION=call; return
;;
237)
eval "sht523=\"\$F$((FP+NP+0))\""
eval "sht520=\"\$F$((FP+NP+1))\""
eval "sht516=\"\$F$((FP+NP+2))\""
eval "sht513=\"\$F$((FP+NP+3))\""
eval "sht510=\"\$F$((FP+NP+4))\""
sht529="${R}"
sht530="T:${sht513#??}}"
sht531="T:CALLEE=\${${sht530#??}"
eval "F$((FP+NP+0))=\"\${sht523}\""
eval "F$((FP+NP+1))=\"\${sht520}\""
eval "F$((FP+NP+2))=\"\${sht516}\""
eval "F$((FP+NP+3))=\"\${sht513}\""
eval "F$((FP+NP+4))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht529}\""
eval "F$((NFP+1))=\"\${sht531}\""
CALLEE=emit
RPC=238; ACTION=call; return
;;
238)
eval "sht523=\"\$F$((FP+NP+0))\""
eval "sht520=\"\$F$((FP+NP+1))\""
eval "sht516=\"\$F$((FP+NP+2))\""
eval "sht513=\"\$F$((FP+NP+3))\""
eval "sht510=\"\$F$((FP+NP+4))\""
sht532="${R}"
sht533="T:${sht523#??}"
sht534="T:${sht533#??}; ACTION=call; return"
sht535="T:RPC=${sht534#??}"
eval "F$((FP+NP+0))=\"\${sht523}\""
eval "F$((FP+NP+1))=\"\${sht520}\""
eval "F$((FP+NP+2))=\"\${sht516}\""
eval "F$((FP+NP+3))=\"\${sht513}\""
eval "F$((FP+NP+4))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht532}\""
eval "F$((NFP+1))=\"\${sht535}\""
CALLEE=emit
RPC=239; ACTION=call; return
;;
239)
eval "sht523=\"\$F$((FP+NP+0))\""
eval "sht520=\"\$F$((FP+NP+1))\""
eval "sht516=\"\$F$((FP+NP+2))\""
eval "sht513=\"\$F$((FP+NP+3))\""
eval "sht510=\"\$F$((FP+NP+4))\""
sht536="${R}"
sht537="${sht536}"
eval "F$((FP+NP+0))=\"\${sht537}\""
eval "F$((FP+NP+1))=\"\${sht523}\""
eval "F$((FP+NP+2))=\"\${sht520}\""
eval "F$((FP+NP+3))=\"\${sht516}\""
eval "F$((FP+NP+4))=\"\${sht513}\""
eval "F$((FP+NP+5))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht537}\""
eval "F$((NFP+1))=\"\${sht523}\""
CALLEE=switch
RPC=240; ACTION=call; return
;;
240)
eval "sht537=\"\$F$((FP+NP+0))\""
eval "sht523=\"\$F$((FP+NP+1))\""
eval "sht520=\"\$F$((FP+NP+2))\""
eval "sht516=\"\$F$((FP+NP+3))\""
eval "sht513=\"\$F$((FP+NP+4))\""
eval "sht510=\"\$F$((FP+NP+5))\""
sht538="${R}"
sht539="${sht538}"
eval "F$((FP+NP+0))=\"\${sht539}\""
eval "F$((FP+NP+1))=\"\${sht537}\""
eval "F$((FP+NP+2))=\"\${sht523}\""
eval "F$((FP+NP+3))=\"\${sht520}\""
eval "F$((FP+NP+4))=\"\${sht516}\""
eval "F$((FP+NP+5))=\"\${sht513}\""
eval "F$((FP+NP+6))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht539}\""
CALLEE=tmpn
RPC=241; ACTION=call; return
;;
241)
eval "sht539=\"\$F$((FP+NP+0))\""
eval "sht537=\"\$F$((FP+NP+1))\""
eval "sht523=\"\$F$((FP+NP+2))\""
eval "sht520=\"\$F$((FP+NP+3))\""
eval "sht516=\"\$F$((FP+NP+4))\""
eval "sht513=\"\$F$((FP+NP+5))\""
eval "sht510=\"\$F$((FP+NP+6))\""
sht540="${R}"
sht541="${sht540}"
eval "F$((FP+NP+0))=\"\${sht541}\""
eval "F$((FP+NP+1))=\"\${sht539}\""
eval "F$((FP+NP+2))=\"\${sht537}\""
eval "F$((FP+NP+3))=\"\${sht523}\""
eval "F$((FP+NP+4))=\"\${sht520}\""
eval "F$((FP+NP+5))=\"\${sht516}\""
eval "F$((FP+NP+6))=\"\${sht513}\""
eval "F$((FP+NP+7))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht539}\""
eval "F$((NFP+1))=\"\${sht516}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=242; ACTION=call; return
;;
242)
eval "sht541=\"\$F$((FP+NP+0))\""
eval "sht539=\"\$F$((FP+NP+1))\""
eval "sht537=\"\$F$((FP+NP+2))\""
eval "sht523=\"\$F$((FP+NP+3))\""
eval "sht520=\"\$F$((FP+NP+4))\""
eval "sht516=\"\$F$((FP+NP+5))\""
eval "sht513=\"\$F$((FP+NP+6))\""
eval "sht510=\"\$F$((FP+NP+7))\""
sht542="${R}"
sht543="T:\${R}${G_DQ#??}"
sht544="T:${G_DQ#??}${sht543#??}"
sht545="T:=${sht544#??}"
sht546="T:${sht541#??}${sht545#??}"
eval "F$((FP+NP+0))=\"\${sht541}\""
eval "F$((FP+NP+1))=\"\${sht539}\""
eval "F$((FP+NP+2))=\"\${sht537}\""
eval "F$((FP+NP+3))=\"\${sht523}\""
eval "F$((FP+NP+4))=\"\${sht520}\""
eval "F$((FP+NP+5))=\"\${sht516}\""
eval "F$((FP+NP+6))=\"\${sht513}\""
eval "F$((FP+NP+7))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht542}\""
eval "F$((NFP+1))=\"\${sht546}\""
CALLEE=emit
RPC=243; ACTION=call; return
;;
243)
eval "sht541=\"\$F$((FP+NP+0))\""
eval "sht539=\"\$F$((FP+NP+1))\""
eval "sht537=\"\$F$((FP+NP+2))\""
eval "sht523=\"\$F$((FP+NP+3))\""
eval "sht520=\"\$F$((FP+NP+4))\""
eval "sht516=\"\$F$((FP+NP+5))\""
eval "sht513=\"\$F$((FP+NP+6))\""
eval "sht510=\"\$F$((FP+NP+7))\""
sht547="${R}"
eval "F$((FP+NP+0))=\"\${sht547}\""
eval "F$((FP+NP+1))=\"\${sht541}\""
eval "F$((FP+NP+2))=\"\${sht539}\""
eval "F$((FP+NP+3))=\"\${sht537}\""
eval "F$((FP+NP+4))=\"\${sht523}\""
eval "F$((FP+NP+5))=\"\${sht520}\""
eval "F$((FP+NP+6))=\"\${sht516}\""
eval "F$((FP+NP+7))=\"\${sht513}\""
eval "F$((FP+NP+8))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht516}\""
CALLEE=lenl
RPC=244; ACTION=call; return
;;
244)
eval "sht547=\"\$F$((FP+NP+0))\""
eval "sht541=\"\$F$((FP+NP+1))\""
eval "sht539=\"\$F$((FP+NP+2))\""
eval "sht537=\"\$F$((FP+NP+3))\""
eval "sht523=\"\$F$((FP+NP+4))\""
eval "sht520=\"\$F$((FP+NP+5))\""
eval "sht516=\"\$F$((FP+NP+6))\""
eval "sht513=\"\$F$((FP+NP+7))\""
eval "sht510=\"\$F$((FP+NP+8))\""
sht548="${R}"
eval "F$((FP+NP+0))=\"\${sht541}\""
eval "F$((FP+NP+1))=\"\${sht539}\""
eval "F$((FP+NP+2))=\"\${sht537}\""
eval "F$((FP+NP+3))=\"\${sht523}\""
eval "F$((FP+NP+4))=\"\${sht520}\""
eval "F$((FP+NP+5))=\"\${sht516}\""
eval "F$((FP+NP+6))=\"\${sht513}\""
eval "F$((FP+NP+7))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht547}\""
eval "F$((NFP+1))=\"\${sht548}\""
CALLEE=bsm
RPC=245; ACTION=call; return
;;
245)
eval "sht541=\"\$F$((FP+NP+0))\""
eval "sht539=\"\$F$((FP+NP+1))\""
eval "sht537=\"\$F$((FP+NP+2))\""
eval "sht523=\"\$F$((FP+NP+3))\""
eval "sht520=\"\$F$((FP+NP+4))\""
eval "sht516=\"\$F$((FP+NP+5))\""
eval "sht513=\"\$F$((FP+NP+6))\""
eval "sht510=\"\$F$((FP+NP+7))\""
sht549="${R}"
eval "F$((FP+NP+0))=\"\${sht541}\""
eval "F$((FP+NP+1))=\"\${sht539}\""
eval "F$((FP+NP+2))=\"\${sht537}\""
eval "F$((FP+NP+3))=\"\${sht523}\""
eval "F$((FP+NP+4))=\"\${sht520}\""
eval "F$((FP+NP+5))=\"\${sht516}\""
eval "F$((FP+NP+6))=\"\${sht513}\""
eval "F$((FP+NP+7))=\"\${sht510}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht549}\""
CALLEE=bkzzP
RPC=246; ACTION=call; return
;;
246)
eval "sht541=\"\$F$((FP+NP+0))\""
eval "sht539=\"\$F$((FP+NP+1))\""
eval "sht537=\"\$F$((FP+NP+2))\""
eval "sht523=\"\$F$((FP+NP+3))\""
eval "sht520=\"\$F$((FP+NP+4))\""
eval "sht516=\"\$F$((FP+NP+5))\""
eval "sht513=\"\$F$((FP+NP+6))\""
eval "sht510=\"\$F$((FP+NP+7))\""
sht550="${R}"
eval "F$((FP+NP+0))=\"\${sht550}\""
eval "F$((FP+NP+1))=\"\${sht541}\""
eval "F$((FP+NP+2))=\"\${sht539}\""
eval "F$((FP+NP+3))=\"\${sht537}\""
eval "F$((FP+NP+4))=\"\${sht523}\""
eval "F$((FP+NP+5))=\"\${sht520}\""
eval "F$((FP+NP+6))=\"\${sht516}\""
eval "F$((FP+NP+7))=\"\${sht513}\""
eval "F$((FP+NP+8))=\"\${sht510}\""
hp_cons "S:loc" "${sht541}"
eval "sht550=\"\$F$((FP+NP+0))\""
eval "sht541=\"\$F$((FP+NP+1))\""
eval "sht539=\"\$F$((FP+NP+2))\""
eval "sht537=\"\$F$((FP+NP+3))\""
eval "sht523=\"\$F$((FP+NP+4))\""
eval "sht520=\"\$F$((FP+NP+5))\""
eval "sht516=\"\$F$((FP+NP+6))\""
eval "sht513=\"\$F$((FP+NP+7))\""
eval "sht510=\"\$F$((FP+NP+8))\""
sht551="${R}"
eval "F$((FP+NP+0))=\"\${sht541}\""
eval "F$((FP+NP+1))=\"\${sht539}\""
eval "F$((FP+NP+2))=\"\${sht537}\""
eval "F$((FP+NP+3))=\"\${sht523}\""
eval "F$((FP+NP+4))=\"\${sht520}\""
eval "F$((FP+NP+5))=\"\${sht516}\""
eval "F$((FP+NP+6))=\"\${sht513}\""
eval "F$((FP+NP+7))=\"\${sht510}\""
hp_cons "${sht550}" "${sht551}"
eval "sht541=\"\$F$((FP+NP+0))\""
eval "sht539=\"\$F$((FP+NP+1))\""
eval "sht537=\"\$F$((FP+NP+2))\""
eval "sht523=\"\$F$((FP+NP+3))\""
eval "sht520=\"\$F$((FP+NP+4))\""
eval "sht516=\"\$F$((FP+NP+5))\""
eval "sht513=\"\$F$((FP+NP+6))\""
eval "sht510=\"\$F$((FP+NP+7))\""
sht552="${R}"
R="${sht552}"; ACTION=ret; return
;;
esac; }
SIZE_sh_esc_at=2
sh_esc_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_sh_esc_at))
NP=1
case $PC in
0)
if [ "${p0}" = "T:\$" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:\\\$"; ACTION=ret; return
;;
2)
NFP=$FTOP
CALLEE=bsl
RPC=3; ACTION=call; return
;;
3)
sht0="${R}"
if [ "${p0}" = "${sht0}" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
NFP=$FTOP
CALLEE=bsl
RPC=6; ACTION=call; return
;;
5)
R="${p0}"; ACTION=ret; return
;;
6)
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
CALLEE=bsl
RPC=7; ACTION=call; return
;;
7)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
sht3="T:${sht1#??}${sht2#??}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_sh_esc_go=8
sh_esc_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_sh_esc_go))
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
CALLEE=sh_esc_at
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
SIZE_sh_esc=1
sh_esc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_sh_esc))
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
CALLEE=sh_esc_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_dsg_str=2
dsg_str() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_dsg_str))
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
CALLEE=dsg_str
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
SIZE_dsg_list=2
dsg_list() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_dsg_list))
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
CALLEE=dsg_list
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
SIZE_dsg_and=3
dsg_and() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_dsg_and))
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
CALLEE=dsg_and
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
SIZE_dsg_or=2
dsg_or() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_dsg_or))
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
CALLEE=dsg_or
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
SIZE_cond_zzGif=4
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
sht1="${sht0}"
hp_car "${sht1}"
sht2="${R}"
if [ "${sht2}" = "S:t" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${sht1}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "S:begin" "${sht3}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
4)
hp_car "${sht1}"
sht5="${R}"
hp_cdr "${sht1}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
hp_cons "S:begin" "${sht6}"
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=cond_zzGif
RPC=5; ACTION=call; return
;;
5)
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "${sht9}" "NIL"
eval "sht7=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
hp_cons "${sht7}" "${sht10}"
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht11="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht5}" "${sht11}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "S:if" "${sht12}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht13="${R}"
R="${sht13}"; ACTION=ret; return
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
CALLEE=sh_esc
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
CALLEE=sh_esc
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
SIZE_lbinds=11
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
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${p2}\""
hp_cons "${p3}" "NIL"
eval "p1=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "${p1}" "${sht0}"
eval "p2=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cons "${p2}" "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht3="${R}"
hp_cdr "${sht3}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=3; ACTION=call; return
;;
3)
sht6="${R}"
sht7="${sht6}"
hp_car "${sht7}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=tmpn
RPC=4; ACTION=call; return
;;
4)
eval "sht7=\"\$F$((FP+NP+0))\""
sht9="${R}"
sht10="${sht9}"
hp_cdr "${p0}"
sht11="${R}"
hp_car "${p0}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
hp_cons "${sht13}" "${sht10}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht7}\""
hp_cons "${sht14}" "${p1}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht15="${R}"
hp_car "${sht7}"
sht16="${R}"
hp_cdr "${sht7}"
sht17="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht11}\""
eval "F$((FP+NP+5))=\"\${sht10}\""
eval "F$((FP+NP+6))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
CALLEE=shval
RPC=5; ACTION=call; return
;;
5)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht11=\"\$F$((FP+NP+4))\""
eval "sht10=\"\$F$((FP+NP+5))\""
eval "sht7=\"\$F$((FP+NP+6))\""
sht18="${R}"
sht19="T:${sht18#??}${G_DQ#??}"
sht20="T:${G_DQ#??}${sht19#??}"
sht21="T:=${sht20#??}"
sht22="T:${sht10#??}${sht21#??}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
eval "F$((NFP+1))=\"\${sht22}\""
CALLEE=emit
RPC=6; ACTION=call; return
;;
6)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
CALLEE=bkzzP
RPC=7; ACTION=call; return
;;
7)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht10}\""
eval "F$((FP+NP+4))=\"\${sht7}\""
hp_cons "${sht10}" "${p3}"
eval "sht24=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht10=\"\$F$((FP+NP+3))\""
eval "sht7=\"\$F$((FP+NP+4))\""
sht25="${R}"
eval "F$((FP+0))=\"\${sht11}\""
eval "F$((FP+1))=\"\${sht15}\""
eval "F$((FP+2))=\"\${sht24}\""
eval "F$((FP+3))=\"\${sht25}\""
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
hp_car "${sht6}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${sht4}\""
eval "F$((NFP+3))=\"\${sht7}\""
CALLEE=lval
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_lif_val=18
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
sht22="T:${sht4#??}"
sht23="T:${sht8#??}"
sht24="T:${sht23#??}; fi"
sht25="T:; else PC=${sht24#??}"
sht26="T:${sht22#??}${sht25#??}"
sht27="T:; then PC=${sht26#??}"
sht28="T:${sht21#??}${sht27#??}"
sht29="T:if ${sht28#??}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${sht29}\""
CALLEE=emit
RPC=10; ACTION=call; return
;;
10)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht4}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
STGV="T:ACTION=jump; return"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=11; ACTION=call; return
;;
11)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht4=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht31="${R}"
sht32="${sht31}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht4}\""
CALLEE=switch
RPC=12; ACTION=call; return
;;
12)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht4}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${sht33}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=13; ACTION=call; return
;;
13)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht4=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht34="${R}"
sht35="${sht34}"
hp_car "${sht35}"
sht36="${R}"
hp_cdr "${sht35}"
sht37="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht36}\""
eval "F$((FP+NP+3))=\"\${sht35}\""
eval "F$((FP+NP+4))=\"\${sht32}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
CALLEE=shval
RPC=14; ACTION=call; return
;;
14)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht36=\"\$F$((FP+NP+2))\""
eval "sht35=\"\$F$((FP+NP+3))\""
eval "sht32=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht38="${R}"
sht39="T:${sht38#??}${G_DQ#??}"
sht40="T:${G_DQ#??}${sht39#??}"
sht41="T:=${sht40#??}"
sht42="T:${sht15#??}${sht41#??}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht4}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht36}\""
eval "F$((NFP+1))=\"\${sht42}\""
CALLEE=emit
RPC=15; ACTION=call; return
;;
15)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht4=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht43="${R}"
sht44="T:${sht12#??}"
sht45="T:${sht44#??}; ACTION=jump; return"
sht46="T:PC=${sht45#??}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht4}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
eval "F$((NFP+1))=\"\${sht46}\""
CALLEE=emit
RPC=16; ACTION=call; return
;;
16)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht4=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht47="${R}"
sht48="${sht47}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht48}\""
eval "F$((FP+NP+3))=\"\${sht35}\""
eval "F$((FP+NP+4))=\"\${sht32}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${sht8}\""
CALLEE=switch
RPC=17; ACTION=call; return
;;
17)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht48=\"\$F$((FP+NP+2))\""
eval "sht35=\"\$F$((FP+NP+3))\""
eval "sht32=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht48}\""
eval "F$((FP+NP+1))=\"\${sht35}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht4}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"\${sht49}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=18; ACTION=call; return
;;
18)
eval "sht48=\"\$F$((FP+NP+0))\""
eval "sht35=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht4=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht50="${R}"
sht51="${sht50}"
hp_car "${sht51}"
sht52="${R}"
hp_cdr "${sht51}"
sht53="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht52}\""
eval "F$((FP+NP+3))=\"\${sht51}\""
eval "F$((FP+NP+4))=\"\${sht48}\""
eval "F$((FP+NP+5))=\"\${sht35}\""
eval "F$((FP+NP+6))=\"\${sht32}\""
eval "F$((FP+NP+7))=\"\${sht15}\""
eval "F$((FP+NP+8))=\"\${sht12}\""
eval "F$((FP+NP+9))=\"\${sht8}\""
eval "F$((FP+NP+10))=\"\${sht4}\""
eval "F$((FP+NP+11))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
CALLEE=shval
RPC=19; ACTION=call; return
;;
19)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht52=\"\$F$((FP+NP+2))\""
eval "sht51=\"\$F$((FP+NP+3))\""
eval "sht48=\"\$F$((FP+NP+4))\""
eval "sht35=\"\$F$((FP+NP+5))\""
eval "sht32=\"\$F$((FP+NP+6))\""
eval "sht15=\"\$F$((FP+NP+7))\""
eval "sht12=\"\$F$((FP+NP+8))\""
eval "sht8=\"\$F$((FP+NP+9))\""
eval "sht4=\"\$F$((FP+NP+10))\""
eval "sht1=\"\$F$((FP+NP+11))\""
sht54="${R}"
sht55="T:${sht54#??}${G_DQ#??}"
sht56="T:${G_DQ#??}${sht55#??}"
sht57="T:=${sht56#??}"
sht58="T:${sht15#??}${sht57#??}"
eval "F$((FP+NP+0))=\"\${sht51}\""
eval "F$((FP+NP+1))=\"\${sht48}\""
eval "F$((FP+NP+2))=\"\${sht35}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht52}\""
eval "F$((NFP+1))=\"\${sht58}\""
CALLEE=emit
RPC=20; ACTION=call; return
;;
20)
eval "sht51=\"\$F$((FP+NP+0))\""
eval "sht48=\"\$F$((FP+NP+1))\""
eval "sht35=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht59="${R}"
sht60="T:${sht12#??}"
sht61="T:${sht60#??}; ACTION=jump; return"
sht62="T:PC=${sht61#??}"
eval "F$((FP+NP+0))=\"\${sht51}\""
eval "F$((FP+NP+1))=\"\${sht48}\""
eval "F$((FP+NP+2))=\"\${sht35}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht4}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht59}\""
eval "F$((NFP+1))=\"\${sht62}\""
CALLEE=emit
RPC=21; ACTION=call; return
;;
21)
eval "sht51=\"\$F$((FP+NP+0))\""
eval "sht48=\"\$F$((FP+NP+1))\""
eval "sht35=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht4=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht63="${R}"
sht64="${sht63}"
eval "F$((FP+NP+0))=\"\${sht64}\""
eval "F$((FP+NP+1))=\"\${sht51}\""
eval "F$((FP+NP+2))=\"\${sht48}\""
eval "F$((FP+NP+3))=\"\${sht35}\""
eval "F$((FP+NP+4))=\"\${sht32}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht64}\""
eval "F$((NFP+1))=\"\${sht12}\""
CALLEE=switch
RPC=22; ACTION=call; return
;;
22)
eval "sht64=\"\$F$((FP+NP+0))\""
eval "sht51=\"\$F$((FP+NP+1))\""
eval "sht48=\"\$F$((FP+NP+2))\""
eval "sht35=\"\$F$((FP+NP+3))\""
eval "sht32=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht65="${R}"
eval "F$((FP+NP+0))=\"\${sht65}\""
eval "F$((FP+NP+1))=\"\${sht64}\""
eval "F$((FP+NP+2))=\"\${sht51}\""
eval "F$((FP+NP+3))=\"\${sht48}\""
eval "F$((FP+NP+4))=\"\${sht35}\""
eval "F$((FP+NP+5))=\"\${sht32}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht4}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
hp_cons "S:loc" "${sht15}"
eval "sht65=\"\$F$((FP+NP+0))\""
eval "sht64=\"\$F$((FP+NP+1))\""
eval "sht51=\"\$F$((FP+NP+2))\""
eval "sht48=\"\$F$((FP+NP+3))\""
eval "sht35=\"\$F$((FP+NP+4))\""
eval "sht32=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht4=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht66="${R}"
eval "F$((FP+NP+0))=\"\${sht64}\""
eval "F$((FP+NP+1))=\"\${sht51}\""
eval "F$((FP+NP+2))=\"\${sht48}\""
eval "F$((FP+NP+3))=\"\${sht35}\""
eval "F$((FP+NP+4))=\"\${sht32}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht4}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
hp_cons "${sht65}" "${sht66}"
eval "sht64=\"\$F$((FP+NP+0))\""
eval "sht51=\"\$F$((FP+NP+1))\""
eval "sht48=\"\$F$((FP+NP+2))\""
eval "sht35=\"\$F$((FP+NP+3))\""
eval "sht32=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht4=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht67="${R}"
R="${sht67}"; ACTION=ret; return
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
SIZE_tagtest=7
tagtest() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_tagtest))
NP=2
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=shval
RPC=1; ACTION=call; return
;;
1)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
sht1="${R}"
sht2="T:${G_DQ#??} ]"
sht3="T:${sht1#??}${sht2#??}"
sht4="T:${G_DQ#??}${sht3#??}"
sht5="T: != ${sht4#??}"
sht6="T:${G_DQ#??}${sht5#??}"
sht7="T:}${sht6#??}"
sht8="T:${p1#??}${sht7#??}"
sht9="T:#${sht8#??}"
sht10="T:${sht0#??}${sht9#??}"
sht11="T:\${${sht10#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:[ ${sht12#??}"
R="${sht13}"; ACTION=ret; return
;;
esac; }
SIZE_natagtest=7
natagtest() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_natagtest))
NP=2
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht0}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=shval
RPC=1; ACTION=call; return
;;
1)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht0=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
sht1="${R}"
sht2="T:${G_DQ#??} ]"
sht3="T:${sht1#??}${sht2#??}"
sht4="T:${G_DQ#??}${sht3#??}"
sht5="T: = ${sht4#??}"
sht6="T:${G_DQ#??}${sht5#??}"
sht7="T:}${sht6#??}"
sht8="T:${p1#??}${sht7#??}"
sht9="T:#${sht8#??}"
sht10="T:${sht0#??}${sht9#??}"
sht11="T:\${${sht10#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:[ ${sht12#??}"
R="${sht13}"; ACTION=ret; return
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
SIZE_lretag=11
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
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
eval "F$((FP+NP+3))=\"\${sht7}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
CALLEE=shdet
RPC=3; ACTION=call; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
eval "sht7=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht3=\"\$F$((FP+NP+5))\""
sht9="${R}"
sht10="T:${sht9#??}${G_DQ#??}"
sht11="T:${p1#??}${sht10#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:=${sht12#??}"
sht14="T:${sht6#??}${sht13#??}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
eval "F$((NFP+1))=\"\${sht14}\""
CALLEE=emit
RPC=4; ACTION=call; return
;;
4)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
CALLEE=bkzzP
RPC=5; ACTION=call; return
;;
5)
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht6}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "S:loc" "${sht6}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht6=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht16}" "${sht17}"
eval "sht6=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht18="${R}"
R="${sht18}"; ACTION=ret; return
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
CALLEE=predzzQ
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
RPC=42; ACTION=call; return
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
sht16="${R}"
if [ "${sht16}" = "S:eq?" ]; then PC=11; else PC=12; fi
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
CALLEE=shval
RPC=10; ACTION=call; return
;;
10)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht7=\"\$F$((FP+NP+2))\""
sht10="${R}"
sht11="T:${G_DQ#??} = NIL ]"
sht12="T:${sht10#??}${sht11#??}"
sht13="T:${G_DQ#??}${sht12#??}"
sht14="T:[ ${sht13#??}"
eval "F$((FP+NP+0))=\"\${sht7}\""
hp_cons "${sht8}" "${sht14}"
eval "sht7=\"\$F$((FP+NP+0))\""
sht15="${R}"
R="${sht15}"; ACTION=ret; return
;;
11)
hp_cdr "${p0}"
sht17="${R}"
hp_car "${sht17}"
sht18="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
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
sht19="${R}"
sht20="${sht19}"
hp_cdr "${p0}"
sht21="${R}"
hp_cdr "${sht21}"
sht22="${R}"
hp_car "${sht22}"
sht23="${R}"
hp_car "${sht20}"
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht24}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=14; ACTION=call; return
;;
14)
eval "sht20=\"\$F$((FP+NP+0))\""
sht25="${R}"
sht26="${sht25}"
hp_car "${sht26}"
sht27="${R}"
hp_cdr "${sht20}"
sht28="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht27}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht28}\""
CALLEE=shval
RPC=15; ACTION=call; return
;;
15)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht27=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht20=\"\$F$((FP+NP+3))\""
sht29="${R}"
hp_cdr "${sht26}"
sht30="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht27}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht20}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
CALLEE=shval
RPC=16; ACTION=call; return
;;
16)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht27=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht20=\"\$F$((FP+NP+6))\""
sht31="${R}"
sht32="T:${G_DQ#??} ]"
sht33="T:${sht31#??}${sht32#??}"
sht34="T:${G_DQ#??}${sht33#??}"
sht35="T: = ${sht34#??}"
sht36="T:${G_DQ#??}${sht35#??}"
sht37="T:${sht29#??}${sht36#??}"
sht38="T:${G_DQ#??}${sht37#??}"
sht39="T:[ ${sht38#??}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht20}\""
hp_cons "${sht27}" "${sht39}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht20=\"\$F$((FP+NP+1))\""
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
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=19; ACTION=call; return
;;
18)
hp_car "${p0}"
sht50="${R}"
if [ "${sht50}" = "S:atom?" ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
19)
sht44="${R}"
sht45="${sht44}"
hp_car "${sht45}"
sht46="${R}"
hp_cdr "${sht45}"
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht46}\""
eval "F$((FP+NP+1))=\"\${sht45}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
STGV="T:P:"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=tagtest
RPC=20; ACTION=call; return
;;
20)
eval "sht46=\"\$F$((FP+NP+0))\""
eval "sht45=\"\$F$((FP+NP+1))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht45}\""
hp_cons "${sht46}" "${sht48}"
eval "sht45=\"\$F$((FP+NP+0))\""
sht49="${R}"
R="${sht49}"; ACTION=ret; return
;;
21)
hp_cdr "${p0}"
sht51="${R}"
hp_car "${sht51}"
sht52="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht52}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=23; ACTION=call; return
;;
22)
hp_car "${p0}"
sht59="${R}"
if [ "${sht59}" = "S:number?" ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
23)
sht53="${R}"
sht54="${sht53}"
hp_car "${sht54}"
sht55="${R}"
hp_cdr "${sht54}"
sht56="${R}"
eval "F$((FP+NP+0))=\"\${sht55}\""
eval "F$((FP+NP+1))=\"\${sht54}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht56}\""
STGV="T:P:"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=natagtest
RPC=24; ACTION=call; return
;;
24)
eval "sht55=\"\$F$((FP+NP+0))\""
eval "sht54=\"\$F$((FP+NP+1))\""
sht57="${R}"
eval "F$((FP+NP+0))=\"\${sht54}\""
hp_cons "${sht55}" "${sht57}"
eval "sht54=\"\$F$((FP+NP+0))\""
sht58="${R}"
R="${sht58}"; ACTION=ret; return
;;
25)
hp_cdr "${p0}"
sht60="${R}"
hp_car "${sht60}"
sht61="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht61}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=27; ACTION=call; return
;;
26)
hp_car "${p0}"
sht68="${R}"
if [ "${sht68}" = "S:string?" ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
27)
sht62="${R}"
sht63="${sht62}"
hp_car "${sht63}"
sht64="${R}"
hp_cdr "${sht63}"
sht65="${R}"
eval "F$((FP+NP+0))=\"\${sht64}\""
eval "F$((FP+NP+1))=\"\${sht63}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht65}\""
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=tagtest
RPC=28; ACTION=call; return
;;
28)
eval "sht64=\"\$F$((FP+NP+0))\""
eval "sht63=\"\$F$((FP+NP+1))\""
sht66="${R}"
eval "F$((FP+NP+0))=\"\${sht63}\""
hp_cons "${sht64}" "${sht66}"
eval "sht63=\"\$F$((FP+NP+0))\""
sht67="${R}"
R="${sht67}"; ACTION=ret; return
;;
29)
hp_cdr "${p0}"
sht69="${R}"
hp_car "${sht69}"
sht70="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht70}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=31; ACTION=call; return
;;
30)
hp_car "${p0}"
sht77="${R}"
if [ "${sht77}" = "S:symbol?" ]; then PC=33; else PC=34; fi
ACTION=jump; return
;;
31)
sht71="${R}"
sht72="${sht71}"
hp_car "${sht72}"
sht73="${R}"
hp_cdr "${sht72}"
sht74="${R}"
eval "F$((FP+NP+0))=\"\${sht73}\""
eval "F$((FP+NP+1))=\"\${sht72}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht74}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=tagtest
RPC=32; ACTION=call; return
;;
32)
eval "sht73=\"\$F$((FP+NP+0))\""
eval "sht72=\"\$F$((FP+NP+1))\""
sht75="${R}"
eval "F$((FP+NP+0))=\"\${sht72}\""
hp_cons "${sht73}" "${sht75}"
eval "sht72=\"\$F$((FP+NP+0))\""
sht76="${R}"
R="${sht76}"; ACTION=ret; return
;;
33)
hp_cdr "${p0}"
sht78="${R}"
hp_car "${sht78}"
sht79="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht79}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=35; ACTION=call; return
;;
34)
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
RPC=37; ACTION=call; return
;;
35)
sht80="${R}"
sht81="${sht80}"
hp_car "${sht81}"
sht82="${R}"
hp_cdr "${sht81}"
sht83="${R}"
eval "F$((FP+NP+0))=\"\${sht82}\""
eval "F$((FP+NP+1))=\"\${sht81}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht83}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=tagtest
RPC=36; ACTION=call; return
;;
36)
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht81=\"\$F$((FP+NP+1))\""
sht84="${R}"
eval "F$((FP+NP+0))=\"\${sht81}\""
hp_cons "${sht82}" "${sht84}"
eval "sht81=\"\$F$((FP+NP+0))\""
sht85="${R}"
R="${sht85}"; ACTION=ret; return
;;
37)
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
eval "F$((FP+NP+0))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht92}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht93}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=38; ACTION=call; return
;;
38)
eval "sht89=\"\$F$((FP+NP+0))\""
sht94="${R}"
sht95="${sht94}"
hp_car "${sht95}"
sht96="${R}"
hp_cdr "${sht89}"
sht97="${R}"
eval "F$((FP+NP+0))=\"\${sht96}\""
eval "F$((FP+NP+1))=\"\${sht95}\""
eval "F$((FP+NP+2))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht97}\""
CALLEE=shdet
RPC=39; ACTION=call; return
;;
39)
eval "sht96=\"\$F$((FP+NP+0))\""
eval "sht95=\"\$F$((FP+NP+1))\""
eval "sht89=\"\$F$((FP+NP+2))\""
sht98="${R}"
hp_car "${p0}"
sht99="${R}"
eval "F$((FP+NP+0))=\"\${sht98}\""
eval "F$((FP+NP+1))=\"\${sht96}\""
eval "F$((FP+NP+2))=\"\${sht95}\""
eval "F$((FP+NP+3))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht99}\""
CALLEE=shcmp
RPC=40; ACTION=call; return
;;
40)
eval "sht98=\"\$F$((FP+NP+0))\""
eval "sht96=\"\$F$((FP+NP+1))\""
eval "sht95=\"\$F$((FP+NP+2))\""
eval "sht89=\"\$F$((FP+NP+3))\""
sht100="${R}"
hp_cdr "${sht95}"
sht101="${R}"
eval "F$((FP+NP+0))=\"\${sht100}\""
eval "F$((FP+NP+1))=\"\${sht98}\""
eval "F$((FP+NP+2))=\"\${sht96}\""
eval "F$((FP+NP+3))=\"\${sht95}\""
eval "F$((FP+NP+4))=\"\${sht89}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht101}\""
CALLEE=shdet
RPC=41; ACTION=call; return
;;
41)
eval "sht100=\"\$F$((FP+NP+0))\""
eval "sht98=\"\$F$((FP+NP+1))\""
eval "sht96=\"\$F$((FP+NP+2))\""
eval "sht95=\"\$F$((FP+NP+3))\""
eval "sht89=\"\$F$((FP+NP+4))\""
sht102="${R}"
sht103="T:${sht102#??} ]"
sht104="T: ${sht103#??}"
sht105="T:${sht100#??}${sht104#??}"
sht106="T: ${sht105#??}"
sht107="T:${sht98#??}${sht106#??}"
sht108="T:[ ${sht107#??}"
eval "F$((FP+NP+0))=\"\${sht95}\""
eval "F$((FP+NP+1))=\"\${sht89}\""
hp_cons "${sht96}" "${sht108}"
eval "sht95=\"\$F$((FP+NP+0))\""
eval "sht89=\"\$F$((FP+NP+1))\""
sht109="${R}"
R="${sht109}"; ACTION=ret; return
;;
42)
sht110="${R}"
sht111="${sht110}"
hp_car "${sht111}"
sht112="${R}"
hp_cdr "${sht111}"
sht113="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht112}\""
eval "F$((FP+NP+2))=\"\${sht111}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht113}\""
CALLEE=shval
RPC=43; ACTION=call; return
;;
43)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht112=\"\$F$((FP+NP+1))\""
eval "sht111=\"\$F$((FP+NP+2))\""
sht114="${R}"
sht115="T:${G_DQ#??} != NIL ]"
sht116="T:${sht114#??}${sht115#??}"
sht117="T:${G_DQ#??}${sht116#??}"
sht118="T:[ ${sht117#??}"
eval "F$((FP+NP+0))=\"\${sht111}\""
hp_cons "${sht112}" "${sht118}"
eval "sht111=\"\$F$((FP+NP+0))\""
sht119="${R}"
R="${sht119}"; ACTION=ret; return
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
if [ "${sht1}" = "S:if" ]; then
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
hp_car "${sht3}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=ctest
RPC=6; ACTION=call; return
;;
5)
if [ "${p0#P:}" != "${p0}" ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
6)
sht5="${R}"
sht6="${sht5}"
hp_car "${sht6}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht7}\""
CALLEE=b_npc
RPC=7; ACTION=call; return
;;
7)
eval "sht6=\"\$F$((FP+NP+0))\""
sht8="${R}"
sht9="${sht8}"
sht10="I:$(( ${sht9#??} + 1 ))"
sht11="${sht10}"
hp_car "${sht6}"
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=bnpczzP
RPC=8; ACTION=call; return
;;
8)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=bnpczzP
RPC=9; ACTION=call; return
;;
9)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht14="${R}"
hp_cdr "${sht6}"
sht15="${R}"
sht16="T:${sht9#??}"
sht17="T:${sht11#??}"
sht18="T:${sht17#??}; fi"
sht19="T:; else PC=${sht18#??}"
sht20="T:${sht16#??}${sht19#??}"
sht21="T:; then PC=${sht20#??}"
sht22="T:${sht15#??}${sht21#??}"
sht23="T:if ${sht22#??}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${sht23}\""
CALLEE=emit
RPC=10; ACTION=call; return
;;
10)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
STGV="T:ACTION=jump; return"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=11; ACTION=call; return
;;
11)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht6=\"\$F$((FP+NP+2))\""
sht25="${R}"
sht26="${sht25}"
hp_cdr "${p0}"
sht27="${R}"
hp_cdr "${sht27}"
sht28="${R}"
hp_car "${sht28}"
sht29="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht11}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
eval "F$((NFP+1))=\"\${sht9}\""
CALLEE=switch
RPC=12; ACTION=call; return
;;
12)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht11=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${sht30}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltail
RPC=13; ACTION=call; return
;;
13)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht6=\"\$F$((FP+NP+3))\""
sht31="${R}"
sht32="${sht31}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=14; ACTION=call; return
;;
14)
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht32}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht11}\""
eval "F$((FP+NP+7))=\"\${sht9}\""
eval "F$((FP+NP+8))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht11}\""
CALLEE=switch
RPC=15; ACTION=call; return
;;
15)
eval "p3=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht32=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht11=\"\$F$((FP+NP+6))\""
eval "sht9=\"\$F$((FP+NP+7))\""
eval "sht6=\"\$F$((FP+NP+8))\""
sht34="${R}"
eval "F$((FP+0))=\"\${sht33}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht34}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
16)
hp_car "${p0}"
sht36="${R}"
if [ "${sht36}" = "S:cond" ]; then
sht37="S:t"
else
sht37="NIL"
fi
sht35="${sht37}"
PC=18; ACTION=jump; return
;;
17)
sht35="NIL"
PC=18; ACTION=jump; return
;;
18)
if [ "${sht35}" != NIL ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
hp_cdr "${p0}"
sht38="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht38}\""
CALLEE=cond_zzGif
RPC=21; ACTION=call; return
;;
20)
if [ "${p0#P:}" != "${p0}" ]; then PC=22; else PC=23; fi
ACTION=jump; return
;;
21)
sht39="${R}"
eval "F$((FP+0))=\"\${sht39}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
22)
hp_car "${p0}"
sht41="${R}"
if [ "${sht41}" = "S:and" ]; then
sht42="S:t"
else
sht42="NIL"
fi
sht40="${sht42}"
PC=24; ACTION=jump; return
;;
23)
sht40="NIL"
PC=24; ACTION=jump; return
;;
24)
if [ "${sht40}" != NIL ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
25)
hp_cdr "${p0}"
sht43="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
CALLEE=dsg_and
RPC=27; ACTION=call; return
;;
26)
if [ "${p0#P:}" != "${p0}" ]; then PC=28; else PC=29; fi
ACTION=jump; return
;;
27)
sht44="${R}"
eval "F$((FP+0))=\"\${sht44}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
28)
hp_car "${p0}"
sht46="${R}"
if [ "${sht46}" = "S:or" ]; then
sht47="S:t"
else
sht47="NIL"
fi
sht45="${sht47}"
PC=30; ACTION=jump; return
;;
29)
sht45="NIL"
PC=30; ACTION=jump; return
;;
30)
if [ "${sht45}" != NIL ]; then PC=31; else PC=32; fi
ACTION=jump; return
;;
31)
hp_cdr "${p0}"
sht48="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
CALLEE=dsg_or
RPC=33; ACTION=call; return
;;
32)
if [ "${p0#P:}" != "${p0}" ]; then PC=34; else PC=35; fi
ACTION=jump; return
;;
33)
sht49="${R}"
eval "F$((FP+0))=\"\${sht49}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
34)
hp_car "${p0}"
sht51="${R}"
if [ "${sht51}" = "S:str" ]; then
sht52="S:t"
else
sht52="NIL"
fi
sht50="${sht52}"
PC=36; ACTION=jump; return
;;
35)
sht50="NIL"
PC=36; ACTION=jump; return
;;
36)
if [ "${sht50}" != NIL ]; then PC=37; else PC=38; fi
ACTION=jump; return
;;
37)
hp_cdr "${p0}"
sht53="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht53}\""
CALLEE=dsg_str
RPC=39; ACTION=call; return
;;
38)
if [ "${p0#P:}" != "${p0}" ]; then PC=40; else PC=41; fi
ACTION=jump; return
;;
39)
sht54="${R}"
eval "F$((FP+0))=\"\${sht54}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
40)
hp_car "${p0}"
sht56="${R}"
if [ "${sht56}" = "S:list" ]; then
sht57="S:t"
else
sht57="NIL"
fi
sht55="${sht57}"
PC=42; ACTION=jump; return
;;
41)
sht55="NIL"
PC=42; ACTION=jump; return
;;
42)
if [ "${sht55}" != NIL ]; then PC=43; else PC=44; fi
ACTION=jump; return
;;
43)
hp_cdr "${p0}"
sht58="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht58}\""
CALLEE=dsg_list
RPC=45; ACTION=call; return
;;
44)
if [ "${p0#P:}" != "${p0}" ]; then PC=46; else PC=47; fi
ACTION=jump; return
;;
45)
sht59="${R}"
eval "F$((FP+0))=\"\${sht59}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
46)
hp_car "${p0}"
sht61="${R}"
if [ "${sht61}" = "S:when" ]; then
sht62="S:t"
else
sht62="NIL"
fi
sht60="${sht62}"
PC=48; ACTION=jump; return
;;
47)
sht60="NIL"
PC=48; ACTION=jump; return
;;
48)
if [ "${sht60}" != NIL ]; then PC=49; else PC=50; fi
ACTION=jump; return
;;
49)
hp_cdr "${p0}"
sht63="${R}"
hp_car "${sht63}"
sht64="${R}"
hp_cdr "${p0}"
sht65="${R}"
hp_cdr "${sht65}"
sht66="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht64}\""
eval "F$((NFP+1))=\"\${sht66}\""
CALLEE=when_zzGif
RPC=51; ACTION=call; return
;;
50)
if [ "${p0#P:}" != "${p0}" ]; then PC=52; else PC=53; fi
ACTION=jump; return
;;
51)
sht67="${R}"
eval "F$((FP+0))=\"\${sht67}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
52)
hp_car "${p0}"
sht69="${R}"
if [ "${sht69}" = "S:unless" ]; then
sht70="S:t"
else
sht70="NIL"
fi
sht68="${sht70}"
PC=54; ACTION=jump; return
;;
53)
sht68="NIL"
PC=54; ACTION=jump; return
;;
54)
if [ "${sht68}" != NIL ]; then PC=55; else PC=56; fi
ACTION=jump; return
;;
55)
hp_cdr "${p0}"
sht71="${R}"
hp_car "${sht71}"
sht72="${R}"
hp_cdr "${p0}"
sht73="${R}"
hp_cdr "${sht73}"
sht74="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht72}\""
eval "F$((NFP+1))=\"\${sht74}\""
CALLEE=unless_zzGif
RPC=57; ACTION=call; return
;;
56)
if [ "${p0#P:}" != "${p0}" ]; then PC=58; else PC=59; fi
ACTION=jump; return
;;
57)
sht75="${R}"
eval "F$((FP+0))=\"\${sht75}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
58)
hp_car "${p0}"
sht77="${R}"
if [ "${sht77}" = "S:case" ]; then
sht78="S:t"
else
sht78="NIL"
fi
sht76="${sht78}"
PC=60; ACTION=jump; return
;;
59)
sht76="NIL"
PC=60; ACTION=jump; return
;;
60)
if [ "${sht76}" != NIL ]; then PC=61; else PC=62; fi
ACTION=jump; return
;;
61)
hp_cdr "${p0}"
sht79="${R}"
hp_car "${sht79}"
sht80="${R}"
hp_cdr "${p0}"
sht81="${R}"
hp_cdr "${sht81}"
sht82="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht80}\""
eval "F$((NFP+1))=\"\${sht82}\""
CALLEE=case_zzGcond
RPC=63; ACTION=call; return
;;
62)
if [ "${p0#P:}" != "${p0}" ]; then PC=64; else PC=65; fi
ACTION=jump; return
;;
63)
sht83="${R}"
eval "F$((FP+0))=\"\${sht83}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
64)
hp_car "${p0}"
sht85="${R}"
if [ "${sht85}" = "S:let*" ]; then
sht86="S:t"
else
sht86="NIL"
fi
sht84="${sht86}"
PC=66; ACTION=jump; return
;;
65)
sht84="NIL"
PC=66; ACTION=jump; return
;;
66)
if [ "${sht84}" != NIL ]; then PC=67; else PC=68; fi
ACTION=jump; return
;;
67)
hp_cdr "${p0}"
sht87="${R}"
hp_car "${sht87}"
sht88="${R}"
hp_cdr "${p0}"
sht89="${R}"
hp_cdr "${sht89}"
sht90="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht88}\""
eval "F$((NFP+1))=\"\${sht90}\""
CALLEE=letzzS_zzGlets
RPC=69; ACTION=call; return
;;
68)
if [ "${p0#P:}" != "${p0}" ]; then PC=70; else PC=71; fi
ACTION=jump; return
;;
69)
sht91="${R}"
eval "F$((FP+0))=\"\${sht91}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${p4}\""
eval "F$((FP+5))=\"\${p5}\""
PC=0; ACTION=tail; return
;;
70)
hp_car "${p0}"
sht93="${R}"
if [ "${sht93}" = "S:begin" ]; then
sht94="S:t"
else
sht94="NIL"
fi
sht92="${sht94}"
PC=72; ACTION=jump; return
;;
71)
sht92="NIL"
PC=72; ACTION=jump; return
;;
72)
if [ "${sht92}" != NIL ]; then PC=73; else PC=74; fi
ACTION=jump; return
;;
73)
hp_cdr "${p0}"
sht95="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht95}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
eval "F$((NFP+4))=\"\${p4}\""
eval "F$((NFP+5))=\"\${p5}\""
CALLEE=ltbegin
RPC=75; ACTION=call; return
;;
74)
if [ "${p0#P:}" != "${p0}" ]; then PC=76; else PC=77; fi
ACTION=jump; return
;;
75)
sht96="${R}"
R="${sht96}"; ACTION=ret; return
;;
76)
hp_car "${p0}"
sht98="${R}"
if [ "${sht98}" = "S:let" ]; then
sht99="S:t"
else
sht99="NIL"
fi
sht97="${sht99}"
PC=78; ACTION=jump; return
;;
77)
sht97="NIL"
PC=78; ACTION=jump; return
;;
78)
if [ "${sht97}" != NIL ]; then PC=79; else PC=80; fi
ACTION=jump; return
;;
79)
hp_cdr "${p0}"
sht100="${R}"
hp_car "${sht100}"
sht101="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht101}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lbinds
RPC=81; ACTION=call; return
;;
80)
if [ "${p0#P:}" != "${p0}" ]; then PC=82; else PC=83; fi
ACTION=jump; return
;;
81)
sht102="${R}"
sht103="${sht102}"
hp_cdr "${p0}"
sht104="${R}"
hp_cdr "${sht104}"
sht105="${R}"
hp_car "${sht105}"
sht106="${R}"
hp_cdr "${sht103}"
sht107="${R}"
hp_car "${sht107}"
sht108="${R}"
hp_car "${sht103}"
sht109="${R}"
hp_cdr "${sht103}"
sht110="${R}"
hp_cdr "${sht110}"
sht111="${R}"
hp_car "${sht111}"
sht112="${R}"
eval "F$((FP+0))=\"\${sht106}\""
eval "F$((FP+1))=\"\${sht108}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
eval "F$((FP+4))=\"\${sht109}\""
eval "F$((FP+5))=\"\${sht112}\""
PC=0; ACTION=tail; return
;;
82)
hp_car "${p0}"
sht114="${R}"
if [ "${sht114}" = "${p2}" ]; then
sht115="S:t"
else
sht115="NIL"
fi
sht113="${sht115}"
PC=84; ACTION=jump; return
;;
83)
sht113="NIL"
PC=84; ACTION=jump; return
;;
84)
if [ "${sht113}" != NIL ]; then PC=85; else PC=86; fi
ACTION=jump; return
;;
85)
hp_cdr "${p0}"
sht116="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht116}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=largs
RPC=87; ACTION=call; return
;;
86)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
CALLEE=lval
RPC=90; ACTION=call; return
;;
87)
sht117="${R}"
sht118="${sht117}"
hp_car "${sht118}"
sht119="${R}"
hp_cdr "${sht118}"
sht120="${R}"
eval "F$((FP+NP+0))=\"\${sht118}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht119}\""
eval "F$((NFP+1))=\"\${sht120}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=setparams
RPC=88; ACTION=call; return
;;
88)
eval "sht118=\"\$F$((FP+NP+0))\""
sht121="${R}"
eval "F$((FP+NP+0))=\"\${sht118}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht121}\""
STGV="T:PC=0; ACTION=tail; return"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=89; ACTION=call; return
;;
89)
eval "sht118=\"\$F$((FP+NP+0))\""
sht122="${R}"
R="${sht122}"; ACTION=ret; return
;;
90)
sht123="${R}"
sht124="${sht123}"
hp_car "${sht124}"
sht125="${R}"
hp_cdr "${sht124}"
sht126="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht125}\""
eval "F$((FP+NP+2))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht126}\""
CALLEE=shval
RPC=91; ACTION=call; return
;;
91)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht125=\"\$F$((FP+NP+1))\""
eval "sht124=\"\$F$((FP+NP+2))\""
sht127="${R}"
sht128="T:${G_DQ#??}; ACTION=ret; return"
sht129="T:${sht127#??}${sht128#??}"
sht130="T:${G_DQ#??}${sht129#??}"
sht131="T:R=${sht130#??}"
eval "F$((FP+NP+0))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht125}\""
eval "F$((NFP+1))=\"\${sht131}\""
CALLEE=emit
RPC=92; ACTION=call; return
;;
92)
eval "sht124=\"\$F$((FP+NP+0))\""
sht132="${R}"
R="${sht132}"; ACTION=ret; return
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
SIZE_ploads=6
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
sht0="T:${p1#??}"
eval "F$((FP+NP+0))=\"\${sht0}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
NFP=$FTOP
CALLEE=eqt
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
sht1="${R}"
sht2="T:${p1#??}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht0}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
NFP=$FTOP
CALLEE=eqt
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht0=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
sht3="${R}"
sht4="T:${sht3#??}${G_DQ#??}"
sht5="T:))${sht4#??}"
sht6="T:${sht2#??}${sht5#??}"
sht7="T:\\\$F\$((FP+${sht6#??}"
sht8="T:${sht1#??}${sht7#??}"
sht9="T:=${sht8#??}"
sht10="T:${sht0#??}${sht9#??}"
sht11="T:p${sht10#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:eval ${sht12#??}"
hp_cdr "${p0}"
sht14="${R}"
sht15="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht13}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${sht15}\""
CALLEE=ploads
RPC=5; ACTION=call; return
;;
5)
eval "sht13=\"\$F$((FP+NP+0))\""
sht16="${R}"
hp_cons "${sht13}" "${sht16}"
sht17="${R}"
R="${sht17}"; ACTION=ret; return
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
SIZE_caseblocks=5
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
sht1="T:${sht0#??})"
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
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
hp_cons "T:;;" "NIL"
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
hp_cons "${sht1}" "${sht4}"
sht5="${R}"
sht6="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht5}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht6}\""
eval "F$((NFP+2))=\"\${p2}\""
CALLEE=caseblocks
RPC=5; ACTION=call; return
;;
5)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${sht7}\""
CALLEE=append
RPC=6; ACTION=call; return
;;
6)
sht8="${R}"
R="${sht8}"; ACTION=ret; return
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
SIZE_cap_loads_go=5
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
sht0="T:\${_cl}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:hp_car ${sht1#??}"
sht3="T:${p1#??}"
sht4="T:\${R}${G_DQ#??}"
sht5="T:${G_DQ#??}${sht4#??}"
sht6="T:=${sht5#??}"
sht7="T:${sht3#??}${sht6#??}"
sht8="T:p${sht7#??}"
sht9="T:\${_cl}${G_DQ#??}"
sht10="T:${G_DQ#??}${sht9#??}"
sht11="T:hp_cdr ${sht10#??}"
sht12="T:\${R}${G_DQ#??}"
sht13="T:${G_DQ#??}${sht12#??}"
sht14="T:_cl=${sht13#??}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
hp_cons "${sht14}" "NIL"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht11}" "${sht15}"
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht8}" "${sht16}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht17="${R}"
hp_cons "${sht2}" "${sht17}"
sht18="${R}"
hp_cdr "${p0}"
sht19="${R}"
sht20="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht18}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
eval "F$((NFP+1))=\"\${sht20}\""
CALLEE=cap_loads_go
RPC=3; ACTION=call; return
;;
3)
eval "sht18=\"\$F$((FP+NP+0))\""
sht21="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
eval "F$((NFP+1))=\"\${sht21}\""
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
esac; }
SIZE_cap_loads=4
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
sht0="T:P:\${CLO}${G_DQ#??}"
sht1="T:${G_DQ#??}${sht0#??}"
sht2="T:hp_cdr ${sht1#??}"
sht3="T:\${R}${G_DQ#??}"
sht4="T:${G_DQ#??}${sht3#??}"
sht5="T:_cl=${sht4#??}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=cap_loads_go
RPC=3; ACTION=call; return
;;
3)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht5}" "${sht6}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${sht2}" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_compile_clambda=18
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
hp_cons "S:__gfns" "${p4}"
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
CALLEE=sh_mangle
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
sht23="T:${sht22#??}"
sht24="T:=${sht23#??}"
sht25="T:${sht9#??}${sht24#??}"
sht26="T:SIZE_${sht25#??}"
sht27="T:${sht9#??}() {"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht6}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=12; ACTION=call; return
;;
12)
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht6=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht27}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht1}\""
CALLEE=cap_loads
RPC=13; ACTION=call; return
;;
13)
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht27=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht29="${R}"
sht30="T:${sht9#??}))"
sht31="T:FTOP=\$((FP + SIZE_${sht30#??}"
sht32="T:${sht1#??}"
sht33="T:NP=${sht32#??}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht28}\""
eval "F$((FP+NP+5))=\"\${sht27}\""
eval "F$((FP+NP+6))=\"\${sht26}\""
eval "F$((FP+NP+7))=\"\${sht22}\""
eval "F$((FP+NP+8))=\"\${sht19}\""
eval "F$((FP+NP+9))=\"\${sht12}\""
eval "F$((FP+NP+10))=\"\${sht9}\""
eval "F$((FP+NP+11))=\"\${sht6}\""
eval "F$((FP+NP+12))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
CALLEE=b_npc
RPC=14; ACTION=call; return
;;
14)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht28=\"\$F$((FP+NP+4))\""
eval "sht27=\"\$F$((FP+NP+5))\""
eval "sht26=\"\$F$((FP+NP+6))\""
eval "sht22=\"\$F$((FP+NP+7))\""
eval "sht19=\"\$F$((FP+NP+8))\""
eval "sht12=\"\$F$((FP+NP+9))\""
eval "sht9=\"\$F$((FP+NP+10))\""
eval "sht6=\"\$F$((FP+NP+11))\""
eval "sht1=\"\$F$((FP+NP+12))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht28}\""
eval "F$((FP+NP+4))=\"\${sht27}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht22}\""
eval "F$((FP+NP+7))=\"\${sht19}\""
eval "F$((FP+NP+8))=\"\${sht12}\""
eval "F$((FP+NP+9))=\"\${sht9}\""
eval "F$((FP+NP+10))=\"\${sht6}\""
eval "F$((FP+NP+11))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht19}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht34}\""
CALLEE=caseblocks
RPC=15; ACTION=call; return
;;
15)
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht28=\"\$F$((FP+NP+3))\""
eval "sht27=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht22=\"\$F$((FP+NP+6))\""
eval "sht19=\"\$F$((FP+NP+7))\""
eval "sht12=\"\$F$((FP+NP+8))\""
eval "sht9=\"\$F$((FP+NP+9))\""
eval "sht6=\"\$F$((FP+NP+10))\""
eval "sht1=\"\$F$((FP+NP+11))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht28}\""
eval "F$((FP+NP+4))=\"\${sht27}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht22}\""
eval "F$((FP+NP+7))=\"\${sht19}\""
eval "F$((FP+NP+8))=\"\${sht12}\""
eval "F$((FP+NP+9))=\"\${sht9}\""
eval "F$((FP+NP+10))=\"\${sht6}\""
eval "F$((FP+NP+11))=\"\${sht1}\""
hp_cons "T:case \$PC in" "${sht35}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht28=\"\$F$((FP+NP+3))\""
eval "sht27=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht22=\"\$F$((FP+NP+6))\""
eval "sht19=\"\$F$((FP+NP+7))\""
eval "sht12=\"\$F$((FP+NP+8))\""
eval "sht9=\"\$F$((FP+NP+9))\""
eval "sht6=\"\$F$((FP+NP+10))\""
eval "sht1=\"\$F$((FP+NP+11))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht28}\""
eval "F$((FP+NP+3))=\"\${sht27}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht22}\""
eval "F$((FP+NP+6))=\"\${sht19}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht9}\""
eval "F$((FP+NP+9))=\"\${sht6}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
hp_cons "${sht33}" "${sht36}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht28=\"\$F$((FP+NP+2))\""
eval "sht27=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht22=\"\$F$((FP+NP+5))\""
eval "sht19=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht9=\"\$F$((FP+NP+8))\""
eval "sht6=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht28}\""
eval "F$((FP+NP+2))=\"\${sht27}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht19}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht9}\""
eval "F$((FP+NP+8))=\"\${sht6}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
hp_cons "${sht31}" "${sht37}"
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht28=\"\$F$((FP+NP+1))\""
eval "sht27=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht19=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht9=\"\$F$((FP+NP+7))\""
eval "sht6=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht28}\""
eval "F$((FP+NP+1))=\"\${sht27}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht19}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht6}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${sht38}\""
CALLEE=append
RPC=16; ACTION=call; return
;;
16)
eval "sht28=\"\$F$((FP+NP+0))\""
eval "sht27=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht19=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht6=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht19}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht6}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht28}\""
eval "F$((NFP+1))=\"\${sht39}\""
CALLEE=append
RPC=17; ACTION=call; return
;;
17)
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht19=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht6=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht27}" "${sht40}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht26}" "${sht41}"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht19}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht6}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "T:esac; }" "NIL"
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht19=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht6=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht19}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht6}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
eval "F$((NFP+1))=\"\${sht43}\""
CALLEE=append
RPC=18; ACTION=call; return
;;
18)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht19=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht6=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht44="${R}"
R="${sht44}"; ACTION=ret; return
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
SIZE_compile_fn_bb=16
compile_fn_bb() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_compile_fn_bb))
NP=4
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
hp_cons "S:__gfns" "${p3}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
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
sht6="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
CALLEE=sh_mangle
RPC=3; ACTION=call; return
;;
3)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht7="${R}"
sht8="${sht7}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${p2}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
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
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "p2=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht5}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht1}\""
eval "F$((NFP+4))=\"\${sht9}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
CALLEE=ltail
RPC=5; ACTION=call; return
;;
5)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht10="${R}"
sht11="${sht10}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=b_pc
RPC=6; ACTION=call; return
;;
6)
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=b_cur
RPC=7; ACTION=call; return
;;
7)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=rev
RPC=8; ACTION=call; return
;;
8)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
hp_cons "${sht12}" "${sht14}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=b_blk
RPC=9; ACTION=call; return
;;
9)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
hp_cons "${sht15}" "${sht16}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht17="${R}"
sht18="${sht17}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=b_smax
RPC=10; ACTION=call; return
;;
10)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht19="${R}"
sht20="I:$(( ${sht1#??} + ${sht19#??} ))"
sht21="${sht20}"
sht22="T:${sht21#??}"
sht23="T:=${sht22#??}"
sht24="T:${sht8#??}${sht23#??}"
sht25="T:SIZE_${sht24#??}"
sht26="T:${sht8#??}() {"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht25}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht18}\""
eval "F$((FP+NP+4))=\"\${sht11}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht5}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=ploads
RPC=11; ACTION=call; return
;;
11)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht25=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht18=\"\$F$((FP+NP+3))\""
eval "sht11=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht5=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht27="${R}"
sht28="T:${sht8#??}))"
sht29="T:FTOP=\$((FP + SIZE_${sht28#??}"
sht30="T:${sht1#??}"
sht31="T:NP=${sht30#??}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht27}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht25}\""
eval "F$((FP+NP+6))=\"\${sht21}\""
eval "F$((FP+NP+7))=\"\${sht18}\""
eval "F$((FP+NP+8))=\"\${sht11}\""
eval "F$((FP+NP+9))=\"\${sht8}\""
eval "F$((FP+NP+10))=\"\${sht5}\""
eval "F$((FP+NP+11))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
CALLEE=b_npc
RPC=12; ACTION=call; return
;;
12)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht27=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht25=\"\$F$((FP+NP+5))\""
eval "sht21=\"\$F$((FP+NP+6))\""
eval "sht18=\"\$F$((FP+NP+7))\""
eval "sht11=\"\$F$((FP+NP+8))\""
eval "sht8=\"\$F$((FP+NP+9))\""
eval "sht5=\"\$F$((FP+NP+10))\""
eval "sht1=\"\$F$((FP+NP+11))\""
sht32="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht27}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht25}\""
eval "F$((FP+NP+5))=\"\${sht21}\""
eval "F$((FP+NP+6))=\"\${sht18}\""
eval "F$((FP+NP+7))=\"\${sht11}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht5}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht32}\""
CALLEE=caseblocks
RPC=13; ACTION=call; return
;;
13)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht27=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht25=\"\$F$((FP+NP+4))\""
eval "sht21=\"\$F$((FP+NP+5))\""
eval "sht18=\"\$F$((FP+NP+6))\""
eval "sht11=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht5=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht27}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht25}\""
eval "F$((FP+NP+5))=\"\${sht21}\""
eval "F$((FP+NP+6))=\"\${sht18}\""
eval "F$((FP+NP+7))=\"\${sht11}\""
eval "F$((FP+NP+8))=\"\${sht8}\""
eval "F$((FP+NP+9))=\"\${sht5}\""
eval "F$((FP+NP+10))=\"\${sht1}\""
hp_cons "T:case \$PC in" "${sht33}"
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht27=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht25=\"\$F$((FP+NP+4))\""
eval "sht21=\"\$F$((FP+NP+5))\""
eval "sht18=\"\$F$((FP+NP+6))\""
eval "sht11=\"\$F$((FP+NP+7))\""
eval "sht8=\"\$F$((FP+NP+8))\""
eval "sht5=\"\$F$((FP+NP+9))\""
eval "sht1=\"\$F$((FP+NP+10))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht27}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht25}\""
eval "F$((FP+NP+4))=\"\${sht21}\""
eval "F$((FP+NP+5))=\"\${sht18}\""
eval "F$((FP+NP+6))=\"\${sht11}\""
eval "F$((FP+NP+7))=\"\${sht8}\""
eval "F$((FP+NP+8))=\"\${sht5}\""
eval "F$((FP+NP+9))=\"\${sht1}\""
hp_cons "${sht31}" "${sht34}"
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht27=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht25=\"\$F$((FP+NP+3))\""
eval "sht21=\"\$F$((FP+NP+4))\""
eval "sht18=\"\$F$((FP+NP+5))\""
eval "sht11=\"\$F$((FP+NP+6))\""
eval "sht8=\"\$F$((FP+NP+7))\""
eval "sht5=\"\$F$((FP+NP+8))\""
eval "sht1=\"\$F$((FP+NP+9))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht25}\""
eval "F$((FP+NP+3))=\"\${sht21}\""
eval "F$((FP+NP+4))=\"\${sht18}\""
eval "F$((FP+NP+5))=\"\${sht11}\""
eval "F$((FP+NP+6))=\"\${sht8}\""
eval "F$((FP+NP+7))=\"\${sht5}\""
eval "F$((FP+NP+8))=\"\${sht1}\""
hp_cons "${sht29}" "${sht35}"
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht25=\"\$F$((FP+NP+2))\""
eval "sht21=\"\$F$((FP+NP+3))\""
eval "sht18=\"\$F$((FP+NP+4))\""
eval "sht11=\"\$F$((FP+NP+5))\""
eval "sht8=\"\$F$((FP+NP+6))\""
eval "sht5=\"\$F$((FP+NP+7))\""
eval "sht1=\"\$F$((FP+NP+8))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht25}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht18}\""
eval "F$((FP+NP+4))=\"\${sht11}\""
eval "F$((FP+NP+5))=\"\${sht8}\""
eval "F$((FP+NP+6))=\"\${sht5}\""
eval "F$((FP+NP+7))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
eval "F$((NFP+1))=\"\${sht36}\""
CALLEE=append
RPC=14; ACTION=call; return
;;
14)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht25=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht18=\"\$F$((FP+NP+3))\""
eval "sht11=\"\$F$((FP+NP+4))\""
eval "sht8=\"\$F$((FP+NP+5))\""
eval "sht5=\"\$F$((FP+NP+6))\""
eval "sht1=\"\$F$((FP+NP+7))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht21}\""
eval "F$((FP+NP+2))=\"\${sht18}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht26}" "${sht37}"
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht21=\"\$F$((FP+NP+1))\""
eval "sht18=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht25}" "${sht38}"
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht39="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht21}\""
eval "F$((FP+NP+2))=\"\${sht18}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
eval "F$((FP+NP+4))=\"\${sht8}\""
eval "F$((FP+NP+5))=\"\${sht5}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "T:esac; }" "NIL"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht21=\"\$F$((FP+NP+1))\""
eval "sht18=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
eval "sht8=\"\$F$((FP+NP+4))\""
eval "sht5=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht18}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
eval "F$((FP+NP+3))=\"\${sht8}\""
eval "F$((FP+NP+4))=\"\${sht5}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht40}\""
CALLEE=append
RPC=15; ACTION=call; return
;;
15)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht18=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
eval "sht8=\"\$F$((FP+NP+3))\""
eval "sht5=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht41="${R}"
R="${sht41}"; ACTION=ret; return
;;
esac; }
SIZE_compile_def_sh=2
compile_def_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_compile_def_sh))
NP=2
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
if [ "${sht2#P:}" != "${sht2}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cdr "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
hp_car "${sht6}"
sht7="${R}"
if [ "${sht7}" = "S:clambda" ]; then
sht8="S:t"
else
sht8="NIL"
fi
sht3="${sht8}"
PC=3; ACTION=jump; return
;;
2)
sht3="NIL"
PC=3; ACTION=jump; return
;;
3)
if [ "${sht3}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_cdr "${p0}"
sht9="${R}"
hp_car "${sht9}"
sht10="${R}"
hp_cdr "${p0}"
sht11="${R}"
hp_cdr "${sht11}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
hp_cdr "${sht13}"
sht14="${R}"
hp_car "${sht14}"
sht15="${R}"
hp_cdr "${p0}"
sht16="${R}"
hp_cdr "${sht16}"
sht17="${R}"
hp_car "${sht17}"
sht18="${R}"
hp_cdr "${sht18}"
sht19="${R}"
hp_cdr "${sht19}"
sht20="${R}"
hp_car "${sht20}"
sht21="${R}"
hp_cdr "${p0}"
sht22="${R}"
hp_cdr "${sht22}"
sht23="${R}"
hp_car "${sht23}"
sht24="${R}"
hp_cdr "${sht24}"
sht25="${R}"
hp_cdr "${sht25}"
sht26="${R}"
hp_cdr "${sht26}"
sht27="${R}"
hp_car "${sht27}"
sht28="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
eval "F$((NFP+1))=\"\${sht15}\""
eval "F$((NFP+2))=\"\${sht21}\""
eval "F$((NFP+3))=\"\${sht28}\""
eval "F$((NFP+4))=\"\${p1}\""
CALLEE=compile_clambda
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht30="${R}"
hp_car "${sht30}"
sht31="${R}"
hp_cdr "${p0}"
sht32="${R}"
hp_cdr "${sht32}"
sht33="${R}"
hp_car "${sht33}"
sht34="${R}"
hp_cdr "${sht34}"
sht35="${R}"
hp_car "${sht35}"
sht36="${R}"
hp_cdr "${p0}"
sht37="${R}"
hp_cdr "${sht37}"
sht38="${R}"
hp_car "${sht38}"
sht39="${R}"
hp_cdr "${sht39}"
sht40="${R}"
hp_cdr "${sht40}"
sht41="${R}"
hp_car "${sht41}"
sht42="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht31}\""
eval "F$((NFP+1))=\"\${sht36}\""
eval "F$((NFP+2))=\"\${sht42}\""
eval "F$((NFP+3))=\"\${p1}\""
CALLEE=compile_fn_bb
RPC=7; ACTION=call; return
;;
6)
sht29="${R}"
R="${sht29}"; ACTION=ret; return
;;
7)
sht43="${R}"
R="${sht43}"; ACTION=ret; return
;;
esac; }
SIZE_gfn_names=3
gfn_names() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_gfn_names))
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
sht1="${sht0}"
hp_cdr "${sht1}"
sht2="${R}"
hp_cdr "${sht2}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
if [ "${sht4#P:}" != "${sht4}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_cdr "${sht1}"
sht6="${R}"
hp_cdr "${sht6}"
sht7="${R}"
hp_car "${sht7}"
sht8="${R}"
hp_car "${sht8}"
sht9="${R}"
if [ "${sht9}" = "S:lambda" ]; then
sht10="S:t"
else
sht10="NIL"
fi
sht5="${sht10}"
PC=5; ACTION=jump; return
;;
4)
sht5="NIL"
PC=5; ACTION=jump; return
;;
5)
if [ "${sht5}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
hp_cdr "${sht1}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
hp_cdr "${p0}"
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
CALLEE=gfn_names
RPC=8; ACTION=call; return
;;
7)
hp_cdr "${p0}"
sht16="${R}"
eval "F$((FP+0))=\"\${sht16}\""
PC=0; ACTION=tail; return
;;
8)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht12}" "${sht14}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht15="${R}"
R="${sht15}"; ACTION=ret; return
;;
esac; }
SIZE_cval_sh=1
cval_sh() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cval_sh))
NP=1
case $PC in
0)
if [ "${p0#T:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
sht0="T:T:${p0#??}"
R="${sht0}"; ACTION=ret; return
;;
2)
if [ "${p0#I:}" != "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
sht1="T:${p0#??}"
sht2="T:I:${sht1#??}"
R="${sht2}"; ACTION=ret; return
;;
4)
sht3="T:${p0#??}"
sht4="T:S:${sht3#??}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_gen1_sh=3
gen1_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_gen1_sh))
NP=2
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
if [ "${sht2#P:}" != "${sht2}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=compile_def_sh
RPC=3; ACTION=call; return
;;
2)
hp_cdr "${p0}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
sht6="T:${sht5#??}"
hp_cdr "${p0}"
sht7="${R}"
hp_cdr "${sht7}"
sht8="${R}"
hp_car "${sht8}"
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
CALLEE=cval_sh
RPC=4; ACTION=call; return
;;
3)
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
eval "sht6=\"\$F$((FP+NP+0))\""
sht10="${R}"
sht11="T:${sht10#??}'"
sht12="T:='${sht11#??}"
sht13="T:${sht6#??}${sht12#??}"
sht14="T:G_${sht13#??}"
hp_cons "${sht14}" "NIL"
sht15="${R}"
R="${sht15}"; ACTION=ret; return
;;
esac; }
SIZE_compile_all_sh=3
compile_all_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_compile_all_sh))
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
CALLEE=gen1_sh
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
CALLEE=compile_all_sh
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_compile_program_sh=5
compile_program_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_compile_program_sh))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"I:0\""
CALLEE=lift_program
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
CALLEE=gfn_names
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht2}\""
CALLEE=compile_all_sh
RPC=3; ACTION=call; return
;;
3)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
write_lines "${p1}" "${sht3}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
# src/prims-aot.sh -- primitive value-wrappers (src/prims.lisp) compiled to native sh by
# comp-sh.sh. GENERATED by tools/build-prims-aot.sh. Embedded in eval/load so value-position
# primitives ((foldr + 0 xs), (map car ps), ...) resolve to C:__p_<op> fns.
SIZE___p_add=2
__p_add() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_add))
NP=2
case $PC in
0)
sht0="I:$(( ${p0#??} + ${p1#??} ))"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_sub=2
__p_sub() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_sub))
NP=2
case $PC in
0)
sht0="I:$(( ${p0#??} - ${p1#??} ))"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_mul=2
__p_mul() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_mul))
NP=2
case $PC in
0)
sht0="I:$(( ${p0#??} * ${p1#??} ))"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_lt=2
__p_lt() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_lt))
NP=2
case $PC in
0)
if [ ${p0#??} -lt ${p1#??} ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_neq=2
__p_neq() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_neq))
NP=2
case $PC in
0)
if [ ${p0#??} -eq ${p1#??} ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_cons=2
__p_cons() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_cons))
NP=2
case $PC in
0)
hp_cons "${p0}" "${p1}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_car=1
__p_car() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE___p_car))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_cdr=1
__p_cdr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE___p_cdr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_null=1
__p_null() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE___p_null))
NP=1
case $PC in
0)
if [ "${p0}" = NIL ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_eq=2
__p_eq() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___p_eq))
NP=2
case $PC in
0)
if [ "${p0}" = "${p1}" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_pair=1
__p_pair() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE___p_pair))
NP=1
case $PC in
0)
if [ "${p0#P:}" != "${p0}" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE___p_not=1
__p_not() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE___p_not))
NP=1
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=not
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
# src/stdlib-aot.sh -- AOT-compiled applicative stdlib (native sh), GENERATED by
# tools/build-stdlib-aot.sh from src/stdlib.lisp via comp-sh.sh. Embedded in the eval/load runtimes.
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
SIZE_cddr=1
cddr() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cddr))
NP=1
case $PC in
0)
hp_cdr "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_cdar=1
cdar() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cdar))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
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
SIZE_cadar=1
cadar() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cadar))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${sht0}"
sht1="${R}"
hp_car "${sht1}"
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE_last=1
last() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_last))
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
R="${sht1}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+0))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_length=1
length() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_length))
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
CALLEE=length
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
sht2="I:$(( 1 + ${sht1#??} ))"
R="${sht2}"; ACTION=ret; return
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
SIZE_list_tail=2
list_tail() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_list_tail))
NP=2
case $PC in
0)
if [ ${p1#??} -eq 0 ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
hp_cdr "${p0}"
sht0="${R}"
sht1="I:$(( ${p1#??} - 1 ))"
eval "F$((FP+0))=\"\${sht0}\""
eval "F$((FP+1))=\"\${sht1}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_nth=2
nth() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_nth))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=list_tail
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
hp_car "${sht0}"
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_take=3
take() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_take))
NP=2
case $PC in
0)
if [ ${p1#??} -eq 0 ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
if [ "${p0}" = NIL ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="NIL"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht0="${R}"
hp_cdr "${p0}"
sht1="${R}"
sht2="I:$(( ${p1#??} - 1 ))"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht2}\""
CALLEE=take
RPC=5; ACTION=call; return
;;
5)
eval "sht0=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cons "${sht0}" "${sht3}"
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_drop=2
drop() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_drop))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=list_tail
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_memberzzQ=2
memberzzQ() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_memberzzQ))
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
SIZE_map=3
map() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_map))
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
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=${p0}
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht2}\""
CALLEE=map
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
SIZE_map2=4
map2() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_map2))
NP=3
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
hp_car "${p2}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht1}\""
CALLEE=${p0}
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cdr "${p1}"
sht3="${R}"
hp_cdr "${p2}"
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${sht4}\""
CALLEE=map2
RPC=4; ACTION=call; return
;;
4)
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_zip=2
zip() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_zip))
NP=2
case $PC in
0)
hp_cons "S:__sl0" "NIL"
sht0="${R}"
sht1="K:${sht0#P:}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p0}\""
eval "F$((NFP+2))=\"\${p1}\""
CALLEE=map2
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE___sl0=2
__sl0() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___sl0))
NP=2
case $PC in
0)
hp_cons "${p0}" "${p1}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_filter=3
filter() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_filter))
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
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=${p0}
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
4)
hp_car "${p1}"
sht2="${R}"
hp_cdr "${p1}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht3}\""
CALLEE=filter
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p1}"
sht6="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht6}\""
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
SIZE_foldl=5
foldl() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_foldl))
NP=3
case $PC in
0)
if [ "${p2}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
hp_car "${p2}"
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${sht0}\""
CALLEE=${p0}
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht1="${R}"
hp_cdr "${p2}"
sht2="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht1}\""
eval "F$((FP+2))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_foldr=5
foldr() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_foldr))
NP=3
case $PC in
0)
if [ "${p2}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p1}"; ACTION=ret; return
;;
2)
hp_car "${p2}"
sht0="${R}"
hp_cdr "${p2}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
eval "F$((FP+NP+1))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht1}\""
CALLEE=foldr
RPC=3; ACTION=call; return
;;
3)
eval "sht0=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
eval "F$((NFP+1))=\"\${sht2}\""
CALLEE=${p0}
RPC=4; ACTION=call; return
;;
4)
eval "p0=\"\$F$((FP+NP+0))\""
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE_for_each=3
for_each() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_for_each))
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
eval "F$((FP+NP+0))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=${p0}
RPC=3; ACTION=call; return
;;
3)
eval "p0=\"\$F$((FP+NP+0))\""
sht1="${R}"
hp_cdr "${p1}"
sht2="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht2}\""
PC=0; ACTION=tail; return
;;
esac; }
SIZE_compose=3
compose() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_compose))
NP=2
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p1}\""
hp_cons "${p0}" "NIL"
eval "p1=\"\$F$((FP+NP+0))\""
sht0="${R}"
hp_cons "${p1}" "${sht0}"
sht1="${R}"
hp_cons "S:__sl1" "${sht1}"
sht2="${R}"
sht3="K:${sht2#P:}"
R="${sht3}"; ACTION=ret; return
;;
esac; }
SIZE___sl1=3
__sl1() {
eval "p0=\"\$F$((FP+0))\""
hp_cdr "P:${CLO}"
_cl="${R}"
hp_car "${_cl}"
p1="${R}"
hp_cdr "${_cl}"
_cl="${R}"
hp_car "${_cl}"
p2="${R}"
hp_cdr "${_cl}"
_cl="${R}"
FTOP=$((FP + SIZE___sl1))
NP=1
case $PC in
0)
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=${p1}
RPC=1; ACTION=call; return
;;
1)
eval "p1=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
CALLEE=${p2}
RPC=2; ACTION=call; return
;;
2)
eval "p2=\"\$F$((FP+NP+0))\""
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_zzLzzE=2
zzLzzE() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_zzLzzE))
NP=2
case $PC in
0)
if [ ${p0#??} -lt ${p1#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ ${p0#??} -eq ${p1#??} ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_zzG=2
zzG() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_zzG))
NP=2
case $PC in
0)
if [ ${p1#??} -lt ${p0#??} ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_zzGzzE=2
zzGzzE() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_zzGzzE))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"\${p0}\""
CALLEE=zzLzzE
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_abs=1
abs() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_abs))
NP=1
case $PC in
0)
if [ ${p0#??} -lt 0 ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
sht0="I:$(( 0 - ${p0#??} ))"
R="${sht0}"; ACTION=ret; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_max=2
max() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_max))
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
SIZE_min=2
min() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_min))
NP=2
case $PC in
0)
if [ ${p0#??} -lt ${p1#??} ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
;;
2)
R="${p1}"; ACTION=ret; return
;;
esac; }
SIZE_sum=1
sum() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_sum))
NP=1
case $PC in
0)
hp_cons "S:__sl2" "NIL"
sht0="${R}"
sht1="K:${sht0#P:}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${p0}\""
CALLEE=foldl
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE___sl2=2
__sl2() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___sl2))
NP=2
case $PC in
0)
sht0="I:$(( ${p0#??} + ${p1#??} ))"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE_product=1
product() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_product))
NP=1
case $PC in
0)
hp_cons "S:__sl3" "NIL"
sht0="${R}"
sht1="K:${sht0#P:}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"I:1\""
eval "F$((NFP+2))=\"\${p0}\""
CALLEE=foldl
RPC=1; ACTION=call; return
;;
1)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
esac; }
SIZE___sl3=2
__sl3() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE___sl3))
NP=2
case $PC in
0)
sht0="I:$(( ${p0#??} * ${p1#??} ))"
R="${sht0}"; ACTION=ret; return
;;
esac; }
SIZE__zzGstring=1
_zzGstring() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE__zzGstring))
NP=1
case $PC in
0)
if [ "${p0#T:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="${p0}"; ACTION=ret; return
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
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_join=2
join() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_join))
NP=2
case $PC in
0)
if [ "${p1}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:"; ACTION=ret; return
;;
2)
hp_cons "${p0}" "NIL"
sht0="${R}"
hp_cons "S:__sl4" "${sht0}"
sht1="${R}"
sht2="K:${sht1#P:}"
hp_car "${p1}"
sht3="${R}"
hp_cdr "${p1}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
eval "F$((NFP+1))=\"\${sht3}\""
eval "F$((NFP+2))=\"\${sht4}\""
CALLEE=foldl
RPC=3; ACTION=call; return
;;
3)
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE___sl4=2
__sl4() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
hp_cdr "P:${CLO}"
_cl="${R}"
hp_car "${_cl}"
p2="${R}"
hp_cdr "${_cl}"
_cl="${R}"
FTOP=$((FP + SIZE___sl4))
NP=2
case $PC in
0)
sht0="T:${p2#??}${p1#??}"
sht1="T:${p0#??}${sht0#??}"
R="${sht1}"; ACTION=ret; return
;;
esac; }

# ---- closure-capable trampoline driver (K:/CLO/RSL) + comp's I/O prims --------------------
GLOBAL=NIL
G_DQ='T:"'
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    [ -n "$ACTION" ] || { printf 'drive: %s yielded no ACTION (unbound global / first-class named fn?)\n' "$CURFN" >&2; return 1; }
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            case $CALLEE in
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;;   # closure: label from record, CLO=record
              C:*) CURFN=${CALLEE#C:} ;;                                            # first-class named fn value
              *)   CURFN=$CALLEE ;;
            esac ;;
      apply) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
            _ai=0; _ac=$APLIST                                                     # spread APLIST -> frame slots FP+0..
            while [ "$_ac" != NIL ]; do hp_car "$_ac"; eval "F$((FP+_ai))=\$R"; hp_cdr "$_ac"; _ac=$R; _ai=$((_ai+1)); done
            case $CALLEE in
              K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;;
              C:*) CURFN=${CALLEE#C:} ;;
              *)   CURFN=$CALLEE ;;
            esac ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}

# ---- eval keystone: eval(expr) = run(compile((lambda () expr))) ---------------------------
eval_form() {   # $1 = a heap ref to the form to eval
  _tmp=$(mktemp)
  # wrap: build (define __ev (lambda () <expr>)) on the heap, then [that] as a 1-form program.
  hp_cons "$1" NIL;            _body=$R          # (<expr>)
  hp_cons NIL "$_body";        _ll=$R            # (() <expr>)
  hp_cons "S:lambda" "$_ll";   _lam=$R           # (lambda () <expr>)
  hp_cons "$_lam" NIL;         _d3=$R
  hp_cons "S:__ev" "$_d3";     _d2=$R            # (__ev (lambda () <expr>))
  hp_cons "S:define" "$_d2";   _def=$R           # (define __ev (lambda () <expr>))
  hp_cons "$_def" NIL;         _forms=$R         # ((define __ev ...))
  # compile in-process via the embedded comp -> _tmp holds __ev() (+ any lifted __lamN()).
  FP=0; RSP=0; PC=0; CLO=""; F0=$_forms; F1="T:$_tmp"; CURFN=compile_program_sh; drive
  . "$_tmp"                                       # define __ev() in this shell
  # run the thunk.
  FP=0; RSP=0; PC=0; CLO=""; CURFN=__ev; drive
  rm -f "$_tmp"
}

# render a runtime value (I:n -> n, T:str -> str, S:sym -> sym, P:/K: -> as-is) for display.
_relem() { case $1 in NIL) printf nil ;; I:*) printf %s "${1#I:}" ;; T:*) printf %s "${1#T:}" ;; S:*) printf %s "${1#S:}" ;; K:*) printf "<closure>" ;; C:*) printf "<fn:%s>" "${1#C:}" ;; P:*) printf "("; _rlist "$1"; printf ")" ;; *) printf %s "$1" ;; esac; }
_rlist() { hp_car "$1"; _e=$R; _relem "$_e"; hp_cdr "$1"; _t=$R; case ${_t#P:} in "$_t") [ "$_t" = NIL ] || { printf " . "; _relem "$_t"; } ;; *) printf " "; _rlist "$_t" ;; esac; }
show_val() { _relem "$1"; printf "\n"; }

SRC=$(cat "$1"); rd_expr; _expr=$R
eval_form "$_expr"
show_val "$R"
