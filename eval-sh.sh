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
STGV="S:__gfns"
eval "F$((NFP+0))=\"\$STGV\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=15; ACTION=call; return
;;
14)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:loc" "${sht12}"
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
CALLEE=sh_mangle
RPC=19; ACTION=call; return
;;
18)
sht20="T:${p0#??}"
sht21="T:G_${sht20#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:loc" "${sht21}"
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
sht67="${R}"
if [ "${sht67}" = "S:car" ]; then PC=35; else PC=36; fi
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
CALLEE=rvar
RPC=24; ACTION=call; return
;;
24)
eval "sht35=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht34=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
sht37="${R}"
sht38="${sht37}"
if [ "${sht38}" = NIL ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
25)
sht39="${p3}"
PC=27; ACTION=jump; return
;;
26)
eval "F$((FP+NP+0))=\"\${sht38}\""
eval "F$((FP+NP+1))=\"\${sht35}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht34}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
hp_cons "${sht38}" "${p3}"
eval "sht38=\"\$F$((FP+NP+0))\""
eval "sht35=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht34=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
sht40="${R}"
sht39="${sht40}"
PC=27; ACTION=jump; return
;;
27)
eval "F$((FP+NP+0))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht35}\""
eval "F$((NFP+3))=\"\${sht39}\""
CALLEE=lval
RPC=28; ACTION=call; return
;;
28)
eval "sht31=\"\$F$((FP+NP+0))\""
sht41="${R}"
sht42="${sht41}"
hp_car "${sht42}"
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht42}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht43}\""
CALLEE=tmpn
RPC=29; ACTION=call; return
;;
29)
eval "sht42=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
sht44="${R}"
sht45="${sht44}"
hp_car "${sht42}"
sht46="${R}"
hp_cdr "${sht31}"
sht47="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht45}\""
eval "F$((FP+NP+2))=\"\${sht46}\""
eval "F$((FP+NP+3))=\"\${sht45}\""
eval "F$((FP+NP+4))=\"\${sht42}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht47}\""
CALLEE=shdet
RPC=30; ACTION=call; return
;;
30)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht45=\"\$F$((FP+NP+1))\""
eval "sht46=\"\$F$((FP+NP+2))\""
eval "sht45=\"\$F$((FP+NP+3))\""
eval "sht42=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
sht48="${R}"
hp_car "${p0}"
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht48}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht45}\""
eval "F$((FP+NP+3))=\"\${sht46}\""
eval "F$((FP+NP+4))=\"\${sht45}\""
eval "F$((FP+NP+5))=\"\${sht42}\""
eval "F$((FP+NP+6))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht49}\""
CALLEE=shop
RPC=31; ACTION=call; return
;;
31)
eval "sht48=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht45=\"\$F$((FP+NP+2))\""
eval "sht46=\"\$F$((FP+NP+3))\""
eval "sht45=\"\$F$((FP+NP+4))\""
eval "sht42=\"\$F$((FP+NP+5))\""
eval "sht31=\"\$F$((FP+NP+6))\""
sht50="${R}"
hp_cdr "${sht42}"
sht51="${R}"
eval "F$((FP+NP+0))=\"\${sht50}\""
eval "F$((FP+NP+1))=\"\${sht48}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht45}\""
eval "F$((FP+NP+4))=\"\${sht46}\""
eval "F$((FP+NP+5))=\"\${sht45}\""
eval "F$((FP+NP+6))=\"\${sht42}\""
eval "F$((FP+NP+7))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
CALLEE=shdet
RPC=32; ACTION=call; return
;;
32)
eval "sht50=\"\$F$((FP+NP+0))\""
eval "sht48=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht45=\"\$F$((FP+NP+3))\""
eval "sht46=\"\$F$((FP+NP+4))\""
eval "sht45=\"\$F$((FP+NP+5))\""
eval "sht42=\"\$F$((FP+NP+6))\""
eval "sht31=\"\$F$((FP+NP+7))\""
sht52="${R}"
sht53="T: ))${G_DQ#??}"
sht54="T:${sht52#??}${sht53#??}"
sht55="T: ${sht54#??}"
sht56="T:${sht50#??}${sht55#??}"
sht57="T: ${sht56#??}"
sht58="T:${sht48#??}${sht57#??}"
sht59="T:I:\$(( ${sht58#??}"
sht60="T:${G_DQ#??}${sht59#??}"
sht61="T:=${sht60#??}"
sht62="T:${sht45#??}${sht61#??}"
eval "F$((FP+NP+0))=\"\${sht45}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht46}\""
eval "F$((NFP+1))=\"\${sht62}\""
CALLEE=emit
RPC=33; ACTION=call; return
;;
33)
eval "sht45=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
sht63="${R}"
eval "F$((FP+NP+0))=\"\${sht45}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht63}\""
CALLEE=bkzzP
RPC=34; ACTION=call; return
;;
34)
eval "sht45=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
sht64="${R}"
eval "F$((FP+NP+0))=\"\${sht64}\""
eval "F$((FP+NP+1))=\"\${sht45}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht31}\""
hp_cons "S:loc" "${sht45}"
eval "sht64=\"\$F$((FP+NP+0))\""
eval "sht45=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
sht65="${R}"
eval "F$((FP+NP+0))=\"\${sht45}\""
eval "F$((FP+NP+1))=\"\${sht42}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
hp_cons "${sht64}" "${sht65}"
eval "sht45=\"\$F$((FP+NP+0))\""
eval "sht42=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
sht66="${R}"
R="${sht66}"; ACTION=ret; return
;;
35)
hp_cdr "${p0}"
sht68="${R}"
hp_car "${sht68}"
sht69="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht69}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=37; ACTION=call; return
;;
36)
hp_car "${p0}"
sht90="${R}"
if [ "${sht90}" = "S:cdr" ]; then PC=43; else PC=44; fi
ACTION=jump; return
;;
37)
sht70="${R}"
sht71="${sht70}"
hp_car "${sht71}"
sht72="${R}"
eval "F$((FP+NP+0))=\"\${sht71}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht72}\""
CALLEE=tmpn
RPC=38; ACTION=call; return
;;
38)
eval "sht71=\"\$F$((FP+NP+0))\""
sht73="${R}"
sht74="${sht73}"
hp_car "${sht71}"
sht75="${R}"
hp_cdr "${sht71}"
sht76="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht75}\""
eval "F$((FP+NP+2))=\"\${sht74}\""
eval "F$((FP+NP+3))=\"\${sht71}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht76}\""
CALLEE=shval
RPC=39; ACTION=call; return
;;
39)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht75=\"\$F$((FP+NP+1))\""
eval "sht74=\"\$F$((FP+NP+2))\""
eval "sht71=\"\$F$((FP+NP+3))\""
sht77="${R}"
sht78="T:${sht77#??}${G_DQ#??}"
sht79="T:${G_DQ#??}${sht78#??}"
sht80="T:hp_car ${sht79#??}"
eval "F$((FP+NP+0))=\"\${sht74}\""
eval "F$((FP+NP+1))=\"\${sht71}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht75}\""
eval "F$((NFP+1))=\"\${sht80}\""
CALLEE=emit
RPC=40; ACTION=call; return
;;
40)
eval "sht74=\"\$F$((FP+NP+0))\""
eval "sht71=\"\$F$((FP+NP+1))\""
sht81="${R}"
sht82="T:\${R}${G_DQ#??}"
sht83="T:${G_DQ#??}${sht82#??}"
sht84="T:=${sht83#??}"
sht85="T:${sht74#??}${sht84#??}"
eval "F$((FP+NP+0))=\"\${sht74}\""
eval "F$((FP+NP+1))=\"\${sht71}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht81}\""
eval "F$((NFP+1))=\"\${sht85}\""
CALLEE=emit
RPC=41; ACTION=call; return
;;
41)
eval "sht74=\"\$F$((FP+NP+0))\""
eval "sht71=\"\$F$((FP+NP+1))\""
sht86="${R}"
eval "F$((FP+NP+0))=\"\${sht74}\""
eval "F$((FP+NP+1))=\"\${sht71}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht86}\""
CALLEE=bkzzP
RPC=42; ACTION=call; return
;;
42)
eval "sht74=\"\$F$((FP+NP+0))\""
eval "sht71=\"\$F$((FP+NP+1))\""
sht87="${R}"
eval "F$((FP+NP+0))=\"\${sht87}\""
eval "F$((FP+NP+1))=\"\${sht74}\""
eval "F$((FP+NP+2))=\"\${sht71}\""
hp_cons "S:loc" "${sht74}"
eval "sht87=\"\$F$((FP+NP+0))\""
eval "sht74=\"\$F$((FP+NP+1))\""
eval "sht71=\"\$F$((FP+NP+2))\""
sht88="${R}"
eval "F$((FP+NP+0))=\"\${sht74}\""
eval "F$((FP+NP+1))=\"\${sht71}\""
hp_cons "${sht87}" "${sht88}"
eval "sht74=\"\$F$((FP+NP+0))\""
eval "sht71=\"\$F$((FP+NP+1))\""
sht89="${R}"
R="${sht89}"; ACTION=ret; return
;;
43)
hp_cdr "${p0}"
sht91="${R}"
hp_car "${sht91}"
sht92="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht92}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=45; ACTION=call; return
;;
44)
hp_car "${p0}"
sht113="${R}"
if [ "${sht113}" = "S:cons" ]; then PC=51; else PC=52; fi
ACTION=jump; return
;;
45)
sht93="${R}"
sht94="${sht93}"
hp_car "${sht94}"
sht95="${R}"
eval "F$((FP+NP+0))=\"\${sht94}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht95}\""
CALLEE=tmpn
RPC=46; ACTION=call; return
;;
46)
eval "sht94=\"\$F$((FP+NP+0))\""
sht96="${R}"
sht97="${sht96}"
hp_car "${sht94}"
sht98="${R}"
hp_cdr "${sht94}"
sht99="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht98}\""
eval "F$((FP+NP+2))=\"\${sht97}\""
eval "F$((FP+NP+3))=\"\${sht94}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht99}\""
CALLEE=shval
RPC=47; ACTION=call; return
;;
47)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht98=\"\$F$((FP+NP+1))\""
eval "sht97=\"\$F$((FP+NP+2))\""
eval "sht94=\"\$F$((FP+NP+3))\""
sht100="${R}"
sht101="T:${sht100#??}${G_DQ#??}"
sht102="T:${G_DQ#??}${sht101#??}"
sht103="T:hp_cdr ${sht102#??}"
eval "F$((FP+NP+0))=\"\${sht97}\""
eval "F$((FP+NP+1))=\"\${sht94}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht98}\""
eval "F$((NFP+1))=\"\${sht103}\""
CALLEE=emit
RPC=48; ACTION=call; return
;;
48)
eval "sht97=\"\$F$((FP+NP+0))\""
eval "sht94=\"\$F$((FP+NP+1))\""
sht104="${R}"
sht105="T:\${R}${G_DQ#??}"
sht106="T:${G_DQ#??}${sht105#??}"
sht107="T:=${sht106#??}"
sht108="T:${sht97#??}${sht107#??}"
eval "F$((FP+NP+0))=\"\${sht97}\""
eval "F$((FP+NP+1))=\"\${sht94}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht104}\""
eval "F$((NFP+1))=\"\${sht108}\""
CALLEE=emit
RPC=49; ACTION=call; return
;;
49)
eval "sht97=\"\$F$((FP+NP+0))\""
eval "sht94=\"\$F$((FP+NP+1))\""
sht109="${R}"
eval "F$((FP+NP+0))=\"\${sht97}\""
eval "F$((FP+NP+1))=\"\${sht94}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht109}\""
CALLEE=bkzzP
RPC=50; ACTION=call; return
;;
50)
eval "sht97=\"\$F$((FP+NP+0))\""
eval "sht94=\"\$F$((FP+NP+1))\""
sht110="${R}"
eval "F$((FP+NP+0))=\"\${sht110}\""
eval "F$((FP+NP+1))=\"\${sht97}\""
eval "F$((FP+NP+2))=\"\${sht94}\""
hp_cons "S:loc" "${sht97}"
eval "sht110=\"\$F$((FP+NP+0))\""
eval "sht97=\"\$F$((FP+NP+1))\""
eval "sht94=\"\$F$((FP+NP+2))\""
sht111="${R}"
eval "F$((FP+NP+0))=\"\${sht97}\""
eval "F$((FP+NP+1))=\"\${sht94}\""
hp_cons "${sht110}" "${sht111}"
eval "sht97=\"\$F$((FP+NP+0))\""
eval "sht94=\"\$F$((FP+NP+1))\""
sht112="${R}"
R="${sht112}"; ACTION=ret; return
;;
51)
hp_cdr "${p0}"
sht114="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht114}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=53; ACTION=call; return
;;
52)
hp_car "${p0}"
sht150="${R}"
if [ "${sht150}" = "S:quote" ]; then PC=64; else PC=65; fi
ACTION=jump; return
;;
53)
sht115="${R}"
sht116="${sht115}"
hp_car "${sht116}"
sht117="${R}"
eval "F$((FP+NP+0))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht117}\""
CALLEE=tmpn
RPC=54; ACTION=call; return
;;
54)
eval "sht116=\"\$F$((FP+NP+0))\""
sht118="${R}"
sht119="${sht118}"
hp_cdr "${sht116}"
sht120="${R}"
hp_car "${sht120}"
sht121="${R}"
sht122="${sht121}"
hp_cdr "${sht116}"
sht123="${R}"
hp_cdr "${sht123}"
sht124="${R}"
hp_car "${sht124}"
sht125="${R}"
sht126="${sht125}"
hp_car "${sht116}"
sht127="${R}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht127}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=55; ACTION=call; return
;;
55)
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht128="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht128}\""
eval "F$((FP+NP+2))=\"\${sht126}\""
eval "F$((FP+NP+3))=\"\${sht122}\""
eval "F$((FP+NP+4))=\"\${sht119}\""
eval "F$((FP+NP+5))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht122}\""
CALLEE=shval
RPC=56; ACTION=call; return
;;
56)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht128=\"\$F$((FP+NP+1))\""
eval "sht126=\"\$F$((FP+NP+2))\""
eval "sht122=\"\$F$((FP+NP+3))\""
eval "sht119=\"\$F$((FP+NP+4))\""
eval "sht116=\"\$F$((FP+NP+5))\""
sht129="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht129}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht128}\""
eval "F$((FP+NP+5))=\"\${sht126}\""
eval "F$((FP+NP+6))=\"\${sht122}\""
eval "F$((FP+NP+7))=\"\${sht119}\""
eval "F$((FP+NP+8))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht126}\""
CALLEE=shval
RPC=57; ACTION=call; return
;;
57)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht129=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht128=\"\$F$((FP+NP+4))\""
eval "sht126=\"\$F$((FP+NP+5))\""
eval "sht122=\"\$F$((FP+NP+6))\""
eval "sht119=\"\$F$((FP+NP+7))\""
eval "sht116=\"\$F$((FP+NP+8))\""
sht130="${R}"
sht131="T:${sht130#??}${G_DQ#??}"
sht132="T:${G_DQ#??}${sht131#??}"
sht133="T: ${sht132#??}"
sht134="T:${G_DQ#??}${sht133#??}"
sht135="T:${sht129#??}${sht134#??}"
sht136="T:${G_DQ#??}${sht135#??}"
sht137="T:hp_cons ${sht136#??}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht128}\""
eval "F$((NFP+1))=\"\${sht137}\""
CALLEE=emit
RPC=58; ACTION=call; return
;;
58)
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht138="${R}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht138}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=59; ACTION=call; return
;;
59)
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht139="${R}"
sht140="T:\${R}${G_DQ#??}"
sht141="T:${G_DQ#??}${sht140#??}"
sht142="T:=${sht141#??}"
sht143="T:${sht119#??}${sht142#??}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht139}\""
eval "F$((NFP+1))=\"\${sht143}\""
CALLEE=emit
RPC=60; ACTION=call; return
;;
60)
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht144="${R}"
eval "F$((FP+NP+0))=\"\${sht144}\""
eval "F$((FP+NP+1))=\"\${sht126}\""
eval "F$((FP+NP+2))=\"\${sht122}\""
eval "F$((FP+NP+3))=\"\${sht119}\""
eval "F$((FP+NP+4))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=61; ACTION=call; return
;;
61)
eval "sht144=\"\$F$((FP+NP+0))\""
eval "sht126=\"\$F$((FP+NP+1))\""
eval "sht122=\"\$F$((FP+NP+2))\""
eval "sht119=\"\$F$((FP+NP+3))\""
eval "sht116=\"\$F$((FP+NP+4))\""
sht145="${R}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht144}\""
eval "F$((NFP+1))=\"\${sht145}\""
CALLEE=bsm
RPC=62; ACTION=call; return
;;
62)
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht146="${R}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht146}\""
CALLEE=bkzzP
RPC=63; ACTION=call; return
;;
63)
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht147="${R}"
eval "F$((FP+NP+0))=\"\${sht147}\""
eval "F$((FP+NP+1))=\"\${sht126}\""
eval "F$((FP+NP+2))=\"\${sht122}\""
eval "F$((FP+NP+3))=\"\${sht119}\""
eval "F$((FP+NP+4))=\"\${sht116}\""
hp_cons "S:loc" "${sht119}"
eval "sht147=\"\$F$((FP+NP+0))\""
eval "sht126=\"\$F$((FP+NP+1))\""
eval "sht122=\"\$F$((FP+NP+2))\""
eval "sht119=\"\$F$((FP+NP+3))\""
eval "sht116=\"\$F$((FP+NP+4))\""
sht148="${R}"
eval "F$((FP+NP+0))=\"\${sht126}\""
eval "F$((FP+NP+1))=\"\${sht122}\""
eval "F$((FP+NP+2))=\"\${sht119}\""
eval "F$((FP+NP+3))=\"\${sht116}\""
hp_cons "${sht147}" "${sht148}"
eval "sht126=\"\$F$((FP+NP+0))\""
eval "sht122=\"\$F$((FP+NP+1))\""
eval "sht119=\"\$F$((FP+NP+2))\""
eval "sht116=\"\$F$((FP+NP+3))\""
sht149="${R}"
R="${sht149}"; ACTION=ret; return
;;
64)
hp_cdr "${p0}"
sht151="${R}"
hp_car "${sht151}"
sht152="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht152}\""
eval "F$((NFP+1))=\"\${p2}\""
CALLEE=lquote
RPC=66; ACTION=call; return
;;
65)
hp_car "${p0}"
sht154="${R}"
if [ "${sht154}" = "S:cond" ]; then PC=67; else PC=68; fi
ACTION=jump; return
;;
66)
sht153="${R}"
R="${sht153}"; ACTION=ret; return
;;
67)
hp_cdr "${p0}"
sht155="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht155}\""
CALLEE=cond_zzGif
RPC=69; ACTION=call; return
;;
68)
hp_car "${p0}"
sht157="${R}"
if [ "${sht157}" = "S:and" ]; then PC=70; else PC=71; fi
ACTION=jump; return
;;
69)
sht156="${R}"
eval "F$((FP+0))=\"\${sht156}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
70)
hp_cdr "${p0}"
sht158="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht158}\""
CALLEE=dsg_and
RPC=72; ACTION=call; return
;;
71)
hp_car "${p0}"
sht160="${R}"
if [ "${sht160}" = "S:or" ]; then PC=73; else PC=74; fi
ACTION=jump; return
;;
72)
sht159="${R}"
eval "F$((FP+0))=\"\${sht159}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
73)
hp_cdr "${p0}"
sht161="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht161}\""
CALLEE=dsg_or
RPC=75; ACTION=call; return
;;
74)
hp_car "${p0}"
sht163="${R}"
if [ "${sht163}" = "S:str" ]; then PC=76; else PC=77; fi
ACTION=jump; return
;;
75)
sht162="${R}"
eval "F$((FP+0))=\"\${sht162}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
76)
hp_cdr "${p0}"
sht164="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht164}\""
CALLEE=dsg_str
RPC=78; ACTION=call; return
;;
77)
hp_car "${p0}"
sht166="${R}"
if [ "${sht166}" = "S:list" ]; then PC=79; else PC=80; fi
ACTION=jump; return
;;
78)
sht165="${R}"
eval "F$((FP+0))=\"\${sht165}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
79)
hp_cdr "${p0}"
sht167="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht167}\""
CALLEE=dsg_list
RPC=81; ACTION=call; return
;;
80)
hp_car "${p0}"
sht169="${R}"
if [ "${sht169}" = "S:when" ]; then PC=82; else PC=83; fi
ACTION=jump; return
;;
81)
sht168="${R}"
eval "F$((FP+0))=\"\${sht168}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
82)
hp_cdr "${p0}"
sht170="${R}"
hp_car "${sht170}"
sht171="${R}"
hp_cdr "${p0}"
sht172="${R}"
hp_cdr "${sht172}"
sht173="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht171}\""
eval "F$((NFP+1))=\"\${sht173}\""
CALLEE=when_zzGif
RPC=84; ACTION=call; return
;;
83)
hp_car "${p0}"
sht175="${R}"
if [ "${sht175}" = "S:unless" ]; then PC=85; else PC=86; fi
ACTION=jump; return
;;
84)
sht174="${R}"
eval "F$((FP+0))=\"\${sht174}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
85)
hp_cdr "${p0}"
sht176="${R}"
hp_car "${sht176}"
sht177="${R}"
hp_cdr "${p0}"
sht178="${R}"
hp_cdr "${sht178}"
sht179="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht177}\""
eval "F$((NFP+1))=\"\${sht179}\""
CALLEE=unless_zzGif
RPC=87; ACTION=call; return
;;
86)
hp_car "${p0}"
sht181="${R}"
if [ "${sht181}" = "S:case" ]; then PC=88; else PC=89; fi
ACTION=jump; return
;;
87)
sht180="${R}"
eval "F$((FP+0))=\"\${sht180}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
88)
hp_cdr "${p0}"
sht182="${R}"
hp_car "${sht182}"
sht183="${R}"
hp_cdr "${p0}"
sht184="${R}"
hp_cdr "${sht184}"
sht185="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht183}\""
eval "F$((NFP+1))=\"\${sht185}\""
CALLEE=case_zzGcond
RPC=90; ACTION=call; return
;;
89)
hp_car "${p0}"
sht187="${R}"
if [ "${sht187}" = "S:let*" ]; then PC=91; else PC=92; fi
ACTION=jump; return
;;
90)
sht186="${R}"
eval "F$((FP+0))=\"\${sht186}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
91)
hp_cdr "${p0}"
sht188="${R}"
hp_car "${sht188}"
sht189="${R}"
hp_cdr "${p0}"
sht190="${R}"
hp_cdr "${sht190}"
sht191="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht189}\""
eval "F$((NFP+1))=\"\${sht191}\""
CALLEE=letzzS_zzGlets
RPC=93; ACTION=call; return
;;
92)
hp_car "${p0}"
sht193="${R}"
if [ "${sht193}" = "S:begin" ]; then PC=94; else PC=95; fi
ACTION=jump; return
;;
93)
sht192="${R}"
eval "F$((FP+0))=\"\${sht192}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
PC=0; ACTION=tail; return
;;
94)
hp_cdr "${p0}"
sht194="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht194}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lbegin
RPC=96; ACTION=call; return
;;
95)
hp_car "${p0}"
sht196="${R}"
if [ "${sht196}" = "S:let" ]; then PC=97; else PC=98; fi
ACTION=jump; return
;;
96)
sht195="${R}"
R="${sht195}"; ACTION=ret; return
;;
97)
hp_cdr "${p0}"
sht197="${R}"
hp_car "${sht197}"
sht198="${R}"
hp_cdr "${p0}"
sht199="${R}"
hp_cdr "${sht199}"
sht200="${R}"
hp_car "${sht200}"
sht201="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht198}\""
eval "F$((NFP+1))=\"\${sht201}\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=llet
RPC=99; ACTION=call; return
;;
98)
hp_car "${p0}"
sht203="${R}"
if [ "${sht203}" = "S:if" ]; then PC=100; else PC=101; fi
ACTION=jump; return
;;
99)
sht202="${R}"
R="${sht202}"; ACTION=ret; return
;;
100)
hp_cdr "${p0}"
sht204="${R}"
hp_car "${sht204}"
sht205="${R}"
hp_cdr "${p0}"
sht206="${R}"
hp_cdr "${sht206}"
sht207="${R}"
hp_car "${sht207}"
sht208="${R}"
eval "F$((FP+NP+0))=\"\${sht208}\""
eval "F$((FP+NP+1))=\"\${sht205}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=102; ACTION=call; return
;;
101)
hp_car "${p0}"
sht211="${R}"
if [ "${sht211}" = "S:dq" ]; then PC=104; else PC=105; fi
ACTION=jump; return
;;
102)
eval "sht208=\"\$F$((FP+NP+0))\""
eval "sht205=\"\$F$((FP+NP+1))\""
sht209="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht205}\""
eval "F$((NFP+1))=\"\${sht208}\""
eval "F$((NFP+2))=\"\${sht209}\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
CALLEE=lif_val
RPC=103; ACTION=call; return
;;
103)
sht210="${R}"
R="${sht210}"; ACTION=ret; return
;;
104)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:loc" "T:G_DQ"
eval "p2=\"\$F$((FP+NP+0))\""
sht212="${R}"
hp_cons "${p2}" "${sht212}"
sht213="${R}"
R="${sht213}"; ACTION=ret; return
;;
105)
hp_car "${p0}"
sht214="${R}"
if [ "${sht214}" = "S:symbol->string" ]; then PC=106; else PC=107; fi
ACTION=jump; return
;;
106)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=108; ACTION=call; return
;;
107)
hp_car "${p0}"
sht216="${R}"
if [ "${sht216}" = "S:number->string" ]; then PC=109; else PC=110; fi
ACTION=jump; return
;;
108)
sht215="${R}"
R="${sht215}"; ACTION=ret; return
;;
109)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=111; ACTION=call; return
;;
110)
hp_car "${p0}"
sht218="${R}"
if [ "${sht218}" = "S:string->symbol" ]; then PC=112; else PC=113; fi
ACTION=jump; return
;;
111)
sht217="${R}"
R="${sht217}"; ACTION=ret; return
;;
112)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=114; ACTION=call; return
;;
113)
hp_car "${p0}"
sht220="${R}"
if [ "${sht220}" = "S:string->number" ]; then PC=115; else PC=116; fi
ACTION=jump; return
;;
114)
sht219="${R}"
R="${sht219}"; ACTION=ret; return
;;
115)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
CALLEE=lretag
RPC=117; ACTION=call; return
;;
116)
hp_car "${p0}"
sht222="${R}"
if [ "${sht222}" = "S:string-length" ]; then PC=118; else PC=119; fi
ACTION=jump; return
;;
117)
sht221="${R}"
R="${sht221}"; ACTION=ret; return
;;
118)
hp_cdr "${p0}"
sht223="${R}"
hp_car "${sht223}"
sht224="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht224}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=120; ACTION=call; return
;;
119)
hp_car "${p0}"
sht243="${R}"
if [ "${sht243}" = "S:string-append" ]; then PC=124; else PC=125; fi
ACTION=jump; return
;;
120)
sht225="${R}"
sht226="${sht225}"
hp_car "${sht226}"
sht227="${R}"
eval "F$((FP+NP+0))=\"\${sht226}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht227}\""
CALLEE=tmpn
RPC=121; ACTION=call; return
;;
121)
eval "sht226=\"\$F$((FP+NP+0))\""
sht228="${R}"
sht229="${sht228}"
hp_car "${sht226}"
sht230="${R}"
hp_cdr "${sht226}"
sht231="${R}"
hp_cdr "${sht231}"
sht232="${R}"
sht233="T:} - 2 ))${G_DQ#??}"
sht234="T:${sht232#??}${sht233#??}"
sht235="T:I:\$(( \${#${sht234#??}"
sht236="T:${G_DQ#??}${sht235#??}"
sht237="T:=${sht236#??}"
sht238="T:${sht229#??}${sht237#??}"
eval "F$((FP+NP+0))=\"\${sht229}\""
eval "F$((FP+NP+1))=\"\${sht226}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht230}\""
eval "F$((NFP+1))=\"\${sht238}\""
CALLEE=emit
RPC=122; ACTION=call; return
;;
122)
eval "sht229=\"\$F$((FP+NP+0))\""
eval "sht226=\"\$F$((FP+NP+1))\""
sht239="${R}"
eval "F$((FP+NP+0))=\"\${sht229}\""
eval "F$((FP+NP+1))=\"\${sht226}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht239}\""
CALLEE=bkzzP
RPC=123; ACTION=call; return
;;
123)
eval "sht229=\"\$F$((FP+NP+0))\""
eval "sht226=\"\$F$((FP+NP+1))\""
sht240="${R}"
eval "F$((FP+NP+0))=\"\${sht240}\""
eval "F$((FP+NP+1))=\"\${sht229}\""
eval "F$((FP+NP+2))=\"\${sht226}\""
hp_cons "S:loc" "${sht229}"
eval "sht240=\"\$F$((FP+NP+0))\""
eval "sht229=\"\$F$((FP+NP+1))\""
eval "sht226=\"\$F$((FP+NP+2))\""
sht241="${R}"
eval "F$((FP+NP+0))=\"\${sht229}\""
eval "F$((FP+NP+1))=\"\${sht226}\""
hp_cons "${sht240}" "${sht241}"
eval "sht229=\"\$F$((FP+NP+0))\""
eval "sht226=\"\$F$((FP+NP+1))\""
sht242="${R}"
R="${sht242}"; ACTION=ret; return
;;
124)
hp_cdr "${p0}"
sht244="${R}"
hp_car "${sht244}"
sht245="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht245}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=126; ACTION=call; return
;;
125)
hp_car "${p0}"
sht274="${R}"
if [ "${sht274}" = "S:substring" ]; then PC=134; else PC=135; fi
ACTION=jump; return
;;
126)
sht246="${R}"
sht247="${sht246}"
hp_cdr "${p0}"
sht248="${R}"
hp_cdr "${sht248}"
sht249="${R}"
hp_car "${sht249}"
sht250="${R}"
hp_car "${sht247}"
sht251="${R}"
hp_cdr "${sht247}"
sht252="${R}"
eval "F$((FP+NP+0))=\"\${sht251}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht250}\""
eval "F$((FP+NP+3))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht252}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=127; ACTION=call; return
;;
127)
eval "sht251=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht250=\"\$F$((FP+NP+2))\""
eval "sht247=\"\$F$((FP+NP+3))\""
sht253="${R}"
eval "F$((FP+NP+0))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht250}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht251}\""
eval "F$((NFP+3))=\"\${sht253}\""
CALLEE=lval
RPC=128; ACTION=call; return
;;
128)
eval "sht247=\"\$F$((FP+NP+0))\""
sht254="${R}"
sht255="${sht254}"
hp_car "${sht255}"
sht256="${R}"
eval "F$((FP+NP+0))=\"\${sht255}\""
eval "F$((FP+NP+1))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht256}\""
CALLEE=tmpn
RPC=129; ACTION=call; return
;;
129)
eval "sht255=\"\$F$((FP+NP+0))\""
eval "sht247=\"\$F$((FP+NP+1))\""
sht257="${R}"
sht258="${sht257}"
hp_car "${sht255}"
sht259="${R}"
hp_cdr "${sht247}"
sht260="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht258}\""
eval "F$((FP+NP+2))=\"\${sht259}\""
eval "F$((FP+NP+3))=\"\${sht258}\""
eval "F$((FP+NP+4))=\"\${sht255}\""
eval "F$((FP+NP+5))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht260}\""
CALLEE=shdet
RPC=130; ACTION=call; return
;;
130)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht258=\"\$F$((FP+NP+1))\""
eval "sht259=\"\$F$((FP+NP+2))\""
eval "sht258=\"\$F$((FP+NP+3))\""
eval "sht255=\"\$F$((FP+NP+4))\""
eval "sht247=\"\$F$((FP+NP+5))\""
sht261="${R}"
hp_cdr "${sht255}"
sht262="${R}"
eval "F$((FP+NP+0))=\"\${sht261}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht258}\""
eval "F$((FP+NP+3))=\"\${sht259}\""
eval "F$((FP+NP+4))=\"\${sht258}\""
eval "F$((FP+NP+5))=\"\${sht255}\""
eval "F$((FP+NP+6))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht262}\""
CALLEE=shdet
RPC=131; ACTION=call; return
;;
131)
eval "sht261=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht258=\"\$F$((FP+NP+2))\""
eval "sht259=\"\$F$((FP+NP+3))\""
eval "sht258=\"\$F$((FP+NP+4))\""
eval "sht255=\"\$F$((FP+NP+5))\""
eval "sht247=\"\$F$((FP+NP+6))\""
sht263="${R}"
sht264="T:${sht263#??}${G_DQ#??}"
sht265="T:${sht261#??}${sht264#??}"
sht266="T:T:${sht265#??}"
sht267="T:${G_DQ#??}${sht266#??}"
sht268="T:=${sht267#??}"
sht269="T:${sht258#??}${sht268#??}"
eval "F$((FP+NP+0))=\"\${sht258}\""
eval "F$((FP+NP+1))=\"\${sht255}\""
eval "F$((FP+NP+2))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht259}\""
eval "F$((NFP+1))=\"\${sht269}\""
CALLEE=emit
RPC=132; ACTION=call; return
;;
132)
eval "sht258=\"\$F$((FP+NP+0))\""
eval "sht255=\"\$F$((FP+NP+1))\""
eval "sht247=\"\$F$((FP+NP+2))\""
sht270="${R}"
eval "F$((FP+NP+0))=\"\${sht258}\""
eval "F$((FP+NP+1))=\"\${sht255}\""
eval "F$((FP+NP+2))=\"\${sht247}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht270}\""
CALLEE=bkzzP
RPC=133; ACTION=call; return
;;
133)
eval "sht258=\"\$F$((FP+NP+0))\""
eval "sht255=\"\$F$((FP+NP+1))\""
eval "sht247=\"\$F$((FP+NP+2))\""
sht271="${R}"
eval "F$((FP+NP+0))=\"\${sht271}\""
eval "F$((FP+NP+1))=\"\${sht258}\""
eval "F$((FP+NP+2))=\"\${sht255}\""
eval "F$((FP+NP+3))=\"\${sht247}\""
hp_cons "S:loc" "${sht258}"
eval "sht271=\"\$F$((FP+NP+0))\""
eval "sht258=\"\$F$((FP+NP+1))\""
eval "sht255=\"\$F$((FP+NP+2))\""
eval "sht247=\"\$F$((FP+NP+3))\""
sht272="${R}"
eval "F$((FP+NP+0))=\"\${sht258}\""
eval "F$((FP+NP+1))=\"\${sht255}\""
eval "F$((FP+NP+2))=\"\${sht247}\""
hp_cons "${sht271}" "${sht272}"
eval "sht258=\"\$F$((FP+NP+0))\""
eval "sht255=\"\$F$((FP+NP+1))\""
eval "sht247=\"\$F$((FP+NP+2))\""
sht273="${R}"
R="${sht273}"; ACTION=ret; return
;;
134)
hp_cdr "${p0}"
sht275="${R}"
hp_car "${sht275}"
sht276="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht276}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=136; ACTION=call; return
;;
135)
hp_car "${p0}"
sht325="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht325}\""
CALLEE=predzzQ
RPC=150; ACTION=call; return
;;
136)
sht277="${R}"
sht278="${sht277}"
hp_cdr "${p0}"
sht279="${R}"
hp_cdr "${sht279}"
sht280="${R}"
hp_car "${sht280}"
sht281="${R}"
hp_car "${sht278}"
sht282="${R}"
hp_cdr "${sht278}"
sht283="${R}"
eval "F$((FP+NP+0))=\"\${sht282}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht281}\""
eval "F$((FP+NP+3))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht283}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=137; ACTION=call; return
;;
137)
eval "sht282=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht281=\"\$F$((FP+NP+2))\""
eval "sht278=\"\$F$((FP+NP+3))\""
sht284="${R}"
eval "F$((FP+NP+0))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht281}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht282}\""
eval "F$((NFP+3))=\"\${sht284}\""
CALLEE=lval
RPC=138; ACTION=call; return
;;
138)
eval "sht278=\"\$F$((FP+NP+0))\""
sht285="${R}"
sht286="${sht285}"
eval "F$((FP+NP+0))=\"\${sht286}\""
eval "F$((FP+NP+1))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
CALLEE=cadddr
RPC=139; ACTION=call; return
;;
139)
eval "sht286=\"\$F$((FP+NP+0))\""
eval "sht278=\"\$F$((FP+NP+1))\""
sht287="${R}"
hp_car "${sht286}"
sht288="${R}"
hp_cdr "${sht286}"
sht289="${R}"
hp_cdr "${sht278}"
sht290="${R}"
eval "F$((FP+NP+0))=\"\${sht289}\""
eval "F$((FP+NP+1))=\"\${sht288}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht287}\""
eval "F$((FP+NP+4))=\"\${sht286}\""
eval "F$((FP+NP+5))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht290}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=140; ACTION=call; return
;;
140)
eval "sht289=\"\$F$((FP+NP+0))\""
eval "sht288=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht287=\"\$F$((FP+NP+3))\""
eval "sht286=\"\$F$((FP+NP+4))\""
eval "sht278=\"\$F$((FP+NP+5))\""
sht291="${R}"
eval "F$((FP+NP+0))=\"\${sht288}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht287}\""
eval "F$((FP+NP+3))=\"\${sht286}\""
eval "F$((FP+NP+4))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht289}\""
eval "F$((NFP+1))=\"\${sht291}\""
CALLEE=addlive
RPC=141; ACTION=call; return
;;
141)
eval "sht288=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht287=\"\$F$((FP+NP+2))\""
eval "sht286=\"\$F$((FP+NP+3))\""
eval "sht278=\"\$F$((FP+NP+4))\""
sht292="${R}"
eval "F$((FP+NP+0))=\"\${sht286}\""
eval "F$((FP+NP+1))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht287}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht288}\""
eval "F$((NFP+3))=\"\${sht292}\""
CALLEE=lval
RPC=142; ACTION=call; return
;;
142)
eval "sht286=\"\$F$((FP+NP+0))\""
eval "sht278=\"\$F$((FP+NP+1))\""
sht293="${R}"
sht294="${sht293}"
hp_car "${sht294}"
sht295="${R}"
eval "F$((FP+NP+0))=\"\${sht294}\""
eval "F$((FP+NP+1))=\"\${sht286}\""
eval "F$((FP+NP+2))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht295}\""
CALLEE=tmpn
RPC=143; ACTION=call; return
;;
143)
eval "sht294=\"\$F$((FP+NP+0))\""
eval "sht286=\"\$F$((FP+NP+1))\""
eval "sht278=\"\$F$((FP+NP+2))\""
sht296="${R}"
sht297="${sht296}"
hp_car "${sht294}"
sht298="${R}"
hp_cdr "${sht278}"
sht299="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht297}\""
eval "F$((FP+NP+3))=\"\${sht298}\""
eval "F$((FP+NP+4))=\"\${sht297}\""
eval "F$((FP+NP+5))=\"\${sht294}\""
eval "F$((FP+NP+6))=\"\${sht286}\""
eval "F$((FP+NP+7))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht299}\""
CALLEE=shdet
RPC=144; ACTION=call; return
;;
144)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht297=\"\$F$((FP+NP+2))\""
eval "sht298=\"\$F$((FP+NP+3))\""
eval "sht297=\"\$F$((FP+NP+4))\""
eval "sht294=\"\$F$((FP+NP+5))\""
eval "sht286=\"\$F$((FP+NP+6))\""
eval "sht278=\"\$F$((FP+NP+7))\""
sht300="${R}"
hp_cdr "${sht286}"
sht301="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht300}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht297}\""
eval "F$((FP+NP+5))=\"\${sht298}\""
eval "F$((FP+NP+6))=\"\${sht297}\""
eval "F$((FP+NP+7))=\"\${sht294}\""
eval "F$((FP+NP+8))=\"\${sht286}\""
eval "F$((FP+NP+9))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht301}\""
CALLEE=shdet
RPC=145; ACTION=call; return
;;
145)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht300=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht297=\"\$F$((FP+NP+4))\""
eval "sht298=\"\$F$((FP+NP+5))\""
eval "sht297=\"\$F$((FP+NP+6))\""
eval "sht294=\"\$F$((FP+NP+7))\""
eval "sht286=\"\$F$((FP+NP+8))\""
eval "sht278=\"\$F$((FP+NP+9))\""
sht302="${R}"
hp_cdr "${sht286}"
sht303="${R}"
eval "F$((FP+NP+0))=\"\${sht302}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht300}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
eval "F$((FP+NP+5))=\"\${sht297}\""
eval "F$((FP+NP+6))=\"\${sht298}\""
eval "F$((FP+NP+7))=\"\${sht297}\""
eval "F$((FP+NP+8))=\"\${sht294}\""
eval "F$((FP+NP+9))=\"\${sht286}\""
eval "F$((FP+NP+10))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht303}\""
CALLEE=shdet
RPC=146; ACTION=call; return
;;
146)
eval "sht302=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht300=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
eval "sht297=\"\$F$((FP+NP+5))\""
eval "sht298=\"\$F$((FP+NP+6))\""
eval "sht297=\"\$F$((FP+NP+7))\""
eval "sht294=\"\$F$((FP+NP+8))\""
eval "sht286=\"\$F$((FP+NP+9))\""
eval "sht278=\"\$F$((FP+NP+10))\""
sht304="${R}"
hp_cdr "${sht294}"
sht305="${R}"
eval "F$((FP+NP+0))=\"\${sht304}\""
eval "F$((FP+NP+1))=\"\${sht302}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht300}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
eval "F$((FP+NP+5))=\"\${G_DQ}\""
eval "F$((FP+NP+6))=\"\${sht297}\""
eval "F$((FP+NP+7))=\"\${sht298}\""
eval "F$((FP+NP+8))=\"\${sht297}\""
eval "F$((FP+NP+9))=\"\${sht294}\""
eval "F$((FP+NP+10))=\"\${sht286}\""
eval "F$((FP+NP+11))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht305}\""
CALLEE=shdet
RPC=147; ACTION=call; return
;;
147)
eval "sht304=\"\$F$((FP+NP+0))\""
eval "sht302=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht300=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
eval "G_DQ=\"\$F$((FP+NP+5))\""
eval "sht297=\"\$F$((FP+NP+6))\""
eval "sht298=\"\$F$((FP+NP+7))\""
eval "sht297=\"\$F$((FP+NP+8))\""
eval "sht294=\"\$F$((FP+NP+9))\""
eval "sht286=\"\$F$((FP+NP+10))\""
eval "sht278=\"\$F$((FP+NP+11))\""
sht306="${R}"
sht307="T: )))${G_DQ#??}"
sht308="T:${sht306#??}${sht307#??}"
sht309="T: + ${sht308#??}"
sht310="T:${sht304#??}${sht309#??}"
sht311="T: + 1 ))-\$(( ${sht310#??}"
sht312="T:${sht302#??}${sht311#??}"
sht313="T: | cut -c\$(( ${sht312#??}"
sht314="T:${G_DQ#??}${sht313#??}"
sht315="T:${sht300#??}${sht314#??}"
sht316="T:${G_DQ#??}${sht315#??}"
sht317="T:T:\$(printf '%s' ${sht316#??}"
sht318="T:${G_DQ#??}${sht317#??}"
sht319="T:=${sht318#??}"
sht320="T:${sht297#??}${sht319#??}"
eval "F$((FP+NP+0))=\"\${sht297}\""
eval "F$((FP+NP+1))=\"\${sht294}\""
eval "F$((FP+NP+2))=\"\${sht286}\""
eval "F$((FP+NP+3))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht298}\""
eval "F$((NFP+1))=\"\${sht320}\""
CALLEE=emit
RPC=148; ACTION=call; return
;;
148)
eval "sht297=\"\$F$((FP+NP+0))\""
eval "sht294=\"\$F$((FP+NP+1))\""
eval "sht286=\"\$F$((FP+NP+2))\""
eval "sht278=\"\$F$((FP+NP+3))\""
sht321="${R}"
eval "F$((FP+NP+0))=\"\${sht297}\""
eval "F$((FP+NP+1))=\"\${sht294}\""
eval "F$((FP+NP+2))=\"\${sht286}\""
eval "F$((FP+NP+3))=\"\${sht278}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht321}\""
CALLEE=bkzzP
RPC=149; ACTION=call; return
;;
149)
eval "sht297=\"\$F$((FP+NP+0))\""
eval "sht294=\"\$F$((FP+NP+1))\""
eval "sht286=\"\$F$((FP+NP+2))\""
eval "sht278=\"\$F$((FP+NP+3))\""
sht322="${R}"
eval "F$((FP+NP+0))=\"\${sht322}\""
eval "F$((FP+NP+1))=\"\${sht297}\""
eval "F$((FP+NP+2))=\"\${sht294}\""
eval "F$((FP+NP+3))=\"\${sht286}\""
eval "F$((FP+NP+4))=\"\${sht278}\""
hp_cons "S:loc" "${sht297}"
eval "sht322=\"\$F$((FP+NP+0))\""
eval "sht297=\"\$F$((FP+NP+1))\""
eval "sht294=\"\$F$((FP+NP+2))\""
eval "sht286=\"\$F$((FP+NP+3))\""
eval "sht278=\"\$F$((FP+NP+4))\""
sht323="${R}"
eval "F$((FP+NP+0))=\"\${sht297}\""
eval "F$((FP+NP+1))=\"\${sht294}\""
eval "F$((FP+NP+2))=\"\${sht286}\""
eval "F$((FP+NP+3))=\"\${sht278}\""
hp_cons "${sht322}" "${sht323}"
eval "sht297=\"\$F$((FP+NP+0))\""
eval "sht294=\"\$F$((FP+NP+1))\""
eval "sht286=\"\$F$((FP+NP+2))\""
eval "sht278=\"\$F$((FP+NP+3))\""
sht324="${R}"
R="${sht324}"; ACTION=ret; return
;;
150)
sht326="${R}"
if [ "${sht326}" != NIL ]; then PC=151; else PC=152; fi
ACTION=jump; return
;;
151)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=ctest
RPC=153; ACTION=call; return
;;
152)
hp_car "${p0}"
sht352="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht352}\""
CALLEE=builtinzzQ
RPC=161; ACTION=call; return
;;
153)
sht327="${R}"
sht328="${sht327}"
hp_car "${sht328}"
sht329="${R}"
eval "F$((FP+NP+0))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht329}\""
CALLEE=tmpn
RPC=154; ACTION=call; return
;;
154)
eval "sht328=\"\$F$((FP+NP+0))\""
sht330="${R}"
sht331="${sht330}"
hp_car "${sht328}"
sht332="${R}"
hp_cdr "${sht328}"
sht333="${R}"
sht334="T:${sht333#??}; then"
sht335="T:if ${sht334#??}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht332}\""
eval "F$((NFP+1))=\"\${sht335}\""
CALLEE=emit
RPC=155; ACTION=call; return
;;
155)
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht336="${R}"
sht337="T:S:t${G_DQ#??}"
sht338="T:${G_DQ#??}${sht337#??}"
sht339="T:=${sht338#??}"
sht340="T:${sht331#??}${sht339#??}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht336}\""
eval "F$((NFP+1))=\"\${sht340}\""
CALLEE=emit
RPC=156; ACTION=call; return
;;
156)
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht341="${R}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht341}\""
STGV="T:else"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=157; ACTION=call; return
;;
157)
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht342="${R}"
sht343="T:NIL${G_DQ#??}"
sht344="T:${G_DQ#??}${sht343#??}"
sht345="T:=${sht344#??}"
sht346="T:${sht331#??}${sht345#??}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht342}\""
eval "F$((NFP+1))=\"\${sht346}\""
CALLEE=emit
RPC=158; ACTION=call; return
;;
158)
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht347="${R}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht347}\""
STGV="T:fi"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=159; ACTION=call; return
;;
159)
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht348="${R}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht348}\""
CALLEE=bkzzP
RPC=160; ACTION=call; return
;;
160)
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht349="${R}"
eval "F$((FP+NP+0))=\"\${sht349}\""
eval "F$((FP+NP+1))=\"\${sht331}\""
eval "F$((FP+NP+2))=\"\${sht328}\""
hp_cons "S:loc" "${sht331}"
eval "sht349=\"\$F$((FP+NP+0))\""
eval "sht331=\"\$F$((FP+NP+1))\""
eval "sht328=\"\$F$((FP+NP+2))\""
sht350="${R}"
eval "F$((FP+NP+0))=\"\${sht331}\""
eval "F$((FP+NP+1))=\"\${sht328}\""
hp_cons "${sht349}" "${sht350}"
eval "sht331=\"\$F$((FP+NP+0))\""
eval "sht328=\"\$F$((FP+NP+1))\""
sht351="${R}"
R="${sht351}"; ACTION=ret; return
;;
161)
sht353="${R}"
if [ "${sht353}" != NIL ]; then PC=162; else PC=163; fi
ACTION=jump; return
;;
162)
hp_cdr "${p0}"
sht354="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht354}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=164; ACTION=call; return
;;
163)
hp_car "${p0}"
sht381="${R}"
if [ "${sht381}" = "S:make-closure" ]; then PC=175; else PC=176; fi
ACTION=jump; return
;;
164)
sht355="${R}"
sht356="${sht355}"
hp_car "${p0}"
sht357="${R}"
sht358="T:${sht357#??}"
eval "F$((FP+NP+0))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht358}\""
CALLEE=sh_mangle
RPC=165; ACTION=call; return
;;
165)
eval "sht356=\"\$F$((FP+NP+0))\""
sht359="${R}"
sht360="${sht359}"
hp_car "${sht356}"
sht361="${R}"
eval "F$((FP+NP+0))=\"\${sht360}\""
eval "F$((FP+NP+1))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht361}\""
CALLEE=tmpn
RPC=166; ACTION=call; return
;;
166)
eval "sht360=\"\$F$((FP+NP+0))\""
eval "sht356=\"\$F$((FP+NP+1))\""
sht362="${R}"
sht363="${sht362}"
hp_car "${sht356}"
sht364="${R}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht364}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=167; ACTION=call; return
;;
167)
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht365="${R}"
hp_cdr "${sht356}"
sht366="${R}"
eval "F$((FP+NP+0))=\"\${sht360}\""
eval "F$((FP+NP+1))=\"\${sht365}\""
eval "F$((FP+NP+2))=\"\${sht363}\""
eval "F$((FP+NP+3))=\"\${sht360}\""
eval "F$((FP+NP+4))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht366}\""
CALLEE=bargs
RPC=168; ACTION=call; return
;;
168)
eval "sht360=\"\$F$((FP+NP+0))\""
eval "sht365=\"\$F$((FP+NP+1))\""
eval "sht363=\"\$F$((FP+NP+2))\""
eval "sht360=\"\$F$((FP+NP+3))\""
eval "sht356=\"\$F$((FP+NP+4))\""
sht367="${R}"
sht368="T:${sht360#??}${sht367#??}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht365}\""
eval "F$((NFP+1))=\"\${sht368}\""
CALLEE=emit
RPC=169; ACTION=call; return
;;
169)
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht369="${R}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht369}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=170; ACTION=call; return
;;
170)
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht370="${R}"
sht371="T:\${R}${G_DQ#??}"
sht372="T:${G_DQ#??}${sht371#??}"
sht373="T:=${sht372#??}"
sht374="T:${sht363#??}${sht373#??}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht370}\""
eval "F$((NFP+1))=\"\${sht374}\""
CALLEE=emit
RPC=171; ACTION=call; return
;;
171)
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht375="${R}"
eval "F$((FP+NP+0))=\"\${sht375}\""
eval "F$((FP+NP+1))=\"\${sht363}\""
eval "F$((FP+NP+2))=\"\${sht360}\""
eval "F$((FP+NP+3))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=172; ACTION=call; return
;;
172)
eval "sht375=\"\$F$((FP+NP+0))\""
eval "sht363=\"\$F$((FP+NP+1))\""
eval "sht360=\"\$F$((FP+NP+2))\""
eval "sht356=\"\$F$((FP+NP+3))\""
sht376="${R}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht375}\""
eval "F$((NFP+1))=\"\${sht376}\""
CALLEE=bsm
RPC=173; ACTION=call; return
;;
173)
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht377="${R}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht377}\""
CALLEE=bkzzP
RPC=174; ACTION=call; return
;;
174)
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht378="${R}"
eval "F$((FP+NP+0))=\"\${sht378}\""
eval "F$((FP+NP+1))=\"\${sht363}\""
eval "F$((FP+NP+2))=\"\${sht360}\""
eval "F$((FP+NP+3))=\"\${sht356}\""
hp_cons "S:loc" "${sht363}"
eval "sht378=\"\$F$((FP+NP+0))\""
eval "sht363=\"\$F$((FP+NP+1))\""
eval "sht360=\"\$F$((FP+NP+2))\""
eval "sht356=\"\$F$((FP+NP+3))\""
sht379="${R}"
eval "F$((FP+NP+0))=\"\${sht363}\""
eval "F$((FP+NP+1))=\"\${sht360}\""
eval "F$((FP+NP+2))=\"\${sht356}\""
hp_cons "${sht378}" "${sht379}"
eval "sht363=\"\$F$((FP+NP+0))\""
eval "sht360=\"\$F$((FP+NP+1))\""
eval "sht356=\"\$F$((FP+NP+2))\""
sht380="${R}"
R="${sht380}"; ACTION=ret; return
;;
175)
hp_cdr "${p0}"
sht382="${R}"
hp_car "${sht382}"
sht383="${R}"
hp_cdr "${p0}"
sht384="${R}"
hp_cdr "${sht384}"
sht385="${R}"
eval "F$((FP+NP+0))=\"\${sht383}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht385}\""
CALLEE=mkclo_caps
RPC=177; ACTION=call; return
;;
176)
hp_car "${p0}"
sht408="${R}"
if [ "${sht408#S:}" != "${sht408}" ]; then PC=182; else PC=183; fi
ACTION=jump; return
;;
177)
eval "sht383=\"\$F$((FP+NP+0))\""
sht386="${R}"
eval "F$((FP+NP+0))=\"\${sht383}\""
hp_cons "${sht386}" "NIL"
eval "sht383=\"\$F$((FP+NP+0))\""
sht387="${R}"
hp_cons "${sht383}" "${sht387}"
sht388="${R}"
hp_cons "S:cons" "${sht388}"
sht389="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht389}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=178; ACTION=call; return
;;
178)
sht390="${R}"
sht391="${sht390}"
hp_car "${sht391}"
sht392="${R}"
eval "F$((FP+NP+0))=\"\${sht391}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht392}\""
CALLEE=tmpn
RPC=179; ACTION=call; return
;;
179)
eval "sht391=\"\$F$((FP+NP+0))\""
sht393="${R}"
sht394="${sht393}"
hp_car "${sht391}"
sht395="${R}"
hp_cdr "${sht391}"
sht396="${R}"
hp_cdr "${sht396}"
sht397="${R}"
sht398="T:#P:}${G_DQ#??}"
sht399="T:${sht397#??}${sht398#??}"
sht400="T:K:\${${sht399#??}"
sht401="T:${G_DQ#??}${sht400#??}"
sht402="T:=${sht401#??}"
sht403="T:${sht394#??}${sht402#??}"
eval "F$((FP+NP+0))=\"\${sht394}\""
eval "F$((FP+NP+1))=\"\${sht391}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht395}\""
eval "F$((NFP+1))=\"\${sht403}\""
CALLEE=emit
RPC=180; ACTION=call; return
;;
180)
eval "sht394=\"\$F$((FP+NP+0))\""
eval "sht391=\"\$F$((FP+NP+1))\""
sht404="${R}"
eval "F$((FP+NP+0))=\"\${sht394}\""
eval "F$((FP+NP+1))=\"\${sht391}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht404}\""
CALLEE=bkzzP
RPC=181; ACTION=call; return
;;
181)
eval "sht394=\"\$F$((FP+NP+0))\""
eval "sht391=\"\$F$((FP+NP+1))\""
sht405="${R}"
eval "F$((FP+NP+0))=\"\${sht405}\""
eval "F$((FP+NP+1))=\"\${sht394}\""
eval "F$((FP+NP+2))=\"\${sht391}\""
hp_cons "S:loc" "${sht394}"
eval "sht405=\"\$F$((FP+NP+0))\""
eval "sht394=\"\$F$((FP+NP+1))\""
eval "sht391=\"\$F$((FP+NP+2))\""
sht406="${R}"
eval "F$((FP+NP+0))=\"\${sht394}\""
eval "F$((FP+NP+1))=\"\${sht391}\""
hp_cons "${sht405}" "${sht406}"
eval "sht394=\"\$F$((FP+NP+0))\""
eval "sht391=\"\$F$((FP+NP+1))\""
sht407="${R}"
R="${sht407}"; ACTION=ret; return
;;
182)
hp_car "${p0}"
sht410="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht410}\""
eval "F$((NFP+1))=\"\${p1}\""
CALLEE=lookup
RPC=185; ACTION=call; return
;;
183)
sht409="NIL"
PC=184; ACTION=jump; return
;;
184)
if [ "${sht409}" != NIL ]; then PC=186; else PC=187; fi
ACTION=jump; return
;;
185)
sht411="${R}"
if [ "${sht411}" = NIL ]; then
sht412="S:t"
else
sht412="NIL"
fi
sht409="${sht412}"
PC=184; ACTION=jump; return
;;
186)
hp_cdr "${p0}"
sht413="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht413}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=largs
RPC=188; ACTION=call; return
;;
187)
hp_car "${p0}"
sht451="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht451}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
CALLEE=lval
RPC=204; ACTION=call; return
;;
188)
sht414="${R}"
sht415="${sht414}"
hp_car "${sht415}"
sht416="${R}"
eval "F$((FP+NP+0))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht416}\""
CALLEE=b_npc
RPC=189; ACTION=call; return
;;
189)
eval "sht415=\"\$F$((FP+NP+0))\""
sht417="${R}"
sht418="${sht417}"
hp_car "${p0}"
sht419="${R}"
sht420="T:${sht419#??}"
eval "F$((FP+NP+0))=\"\${sht418}\""
eval "F$((FP+NP+1))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht420}\""
CALLEE=sh_mangle
RPC=190; ACTION=call; return
;;
190)
eval "sht418=\"\$F$((FP+NP+0))\""
eval "sht415=\"\$F$((FP+NP+1))\""
sht421="${R}"
sht422="${sht421}"
hp_car "${sht415}"
sht423="${R}"
eval "F$((FP+NP+0))=\"\${sht422}\""
eval "F$((FP+NP+1))=\"\${sht418}\""
eval "F$((FP+NP+2))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht423}\""
CALLEE=bnpczzP
RPC=191; ACTION=call; return
;;
191)
eval "sht422=\"\$F$((FP+NP+0))\""
eval "sht418=\"\$F$((FP+NP+1))\""
eval "sht415=\"\$F$((FP+NP+2))\""
sht424="${R}"
eval "F$((FP+NP+0))=\"\${sht422}\""
eval "F$((FP+NP+1))=\"\${sht418}\""
eval "F$((FP+NP+2))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht424}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=192; ACTION=call; return
;;
192)
eval "sht422=\"\$F$((FP+NP+0))\""
eval "sht418=\"\$F$((FP+NP+1))\""
eval "sht415=\"\$F$((FP+NP+2))\""
sht425="${R}"
eval "F$((FP+NP+0))=\"\${sht422}\""
eval "F$((FP+NP+1))=\"\${sht418}\""
eval "F$((FP+NP+2))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht425}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=193; ACTION=call; return
;;
193)
eval "sht422=\"\$F$((FP+NP+0))\""
eval "sht418=\"\$F$((FP+NP+1))\""
eval "sht415=\"\$F$((FP+NP+2))\""
sht426="${R}"
hp_cdr "${sht415}"
sht427="${R}"
eval "F$((FP+NP+0))=\"\${sht422}\""
eval "F$((FP+NP+1))=\"\${sht418}\""
eval "F$((FP+NP+2))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht426}\""
eval "F$((NFP+1))=\"\${sht427}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=194; ACTION=call; return
;;
194)
eval "sht422=\"\$F$((FP+NP+0))\""
eval "sht418=\"\$F$((FP+NP+1))\""
eval "sht415=\"\$F$((FP+NP+2))\""
sht428="${R}"
sht429="T:CALLEE=${sht422#??}"
eval "F$((FP+NP+0))=\"\${sht422}\""
eval "F$((FP+NP+1))=\"\${sht418}\""
eval "F$((FP+NP+2))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht428}\""
eval "F$((NFP+1))=\"\${sht429}\""
CALLEE=emit
RPC=195; ACTION=call; return
;;
195)
eval "sht422=\"\$F$((FP+NP+0))\""
eval "sht418=\"\$F$((FP+NP+1))\""
eval "sht415=\"\$F$((FP+NP+2))\""
sht430="${R}"
sht431="T:${sht418#??}"
sht432="T:${sht431#??}; ACTION=call; return"
sht433="T:RPC=${sht432#??}"
eval "F$((FP+NP+0))=\"\${sht422}\""
eval "F$((FP+NP+1))=\"\${sht418}\""
eval "F$((FP+NP+2))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht430}\""
eval "F$((NFP+1))=\"\${sht433}\""
CALLEE=emit
RPC=196; ACTION=call; return
;;
196)
eval "sht422=\"\$F$((FP+NP+0))\""
eval "sht418=\"\$F$((FP+NP+1))\""
eval "sht415=\"\$F$((FP+NP+2))\""
sht434="${R}"
sht435="${sht434}"
eval "F$((FP+NP+0))=\"\${sht435}\""
eval "F$((FP+NP+1))=\"\${sht422}\""
eval "F$((FP+NP+2))=\"\${sht418}\""
eval "F$((FP+NP+3))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht435}\""
eval "F$((NFP+1))=\"\${sht418}\""
CALLEE=switch
RPC=197; ACTION=call; return
;;
197)
eval "sht435=\"\$F$((FP+NP+0))\""
eval "sht422=\"\$F$((FP+NP+1))\""
eval "sht418=\"\$F$((FP+NP+2))\""
eval "sht415=\"\$F$((FP+NP+3))\""
sht436="${R}"
sht437="${sht436}"
eval "F$((FP+NP+0))=\"\${sht437}\""
eval "F$((FP+NP+1))=\"\${sht435}\""
eval "F$((FP+NP+2))=\"\${sht422}\""
eval "F$((FP+NP+3))=\"\${sht418}\""
eval "F$((FP+NP+4))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht437}\""
CALLEE=tmpn
RPC=198; ACTION=call; return
;;
198)
eval "sht437=\"\$F$((FP+NP+0))\""
eval "sht435=\"\$F$((FP+NP+1))\""
eval "sht422=\"\$F$((FP+NP+2))\""
eval "sht418=\"\$F$((FP+NP+3))\""
eval "sht415=\"\$F$((FP+NP+4))\""
sht438="${R}"
sht439="${sht438}"
eval "F$((FP+NP+0))=\"\${sht439}\""
eval "F$((FP+NP+1))=\"\${sht437}\""
eval "F$((FP+NP+2))=\"\${sht435}\""
eval "F$((FP+NP+3))=\"\${sht422}\""
eval "F$((FP+NP+4))=\"\${sht418}\""
eval "F$((FP+NP+5))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht437}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=199; ACTION=call; return
;;
199)
eval "sht439=\"\$F$((FP+NP+0))\""
eval "sht437=\"\$F$((FP+NP+1))\""
eval "sht435=\"\$F$((FP+NP+2))\""
eval "sht422=\"\$F$((FP+NP+3))\""
eval "sht418=\"\$F$((FP+NP+4))\""
eval "sht415=\"\$F$((FP+NP+5))\""
sht440="${R}"
sht441="T:\${R}${G_DQ#??}"
sht442="T:${G_DQ#??}${sht441#??}"
sht443="T:=${sht442#??}"
sht444="T:${sht439#??}${sht443#??}"
eval "F$((FP+NP+0))=\"\${sht439}\""
eval "F$((FP+NP+1))=\"\${sht437}\""
eval "F$((FP+NP+2))=\"\${sht435}\""
eval "F$((FP+NP+3))=\"\${sht422}\""
eval "F$((FP+NP+4))=\"\${sht418}\""
eval "F$((FP+NP+5))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht440}\""
eval "F$((NFP+1))=\"\${sht444}\""
CALLEE=emit
RPC=200; ACTION=call; return
;;
200)
eval "sht439=\"\$F$((FP+NP+0))\""
eval "sht437=\"\$F$((FP+NP+1))\""
eval "sht435=\"\$F$((FP+NP+2))\""
eval "sht422=\"\$F$((FP+NP+3))\""
eval "sht418=\"\$F$((FP+NP+4))\""
eval "sht415=\"\$F$((FP+NP+5))\""
sht445="${R}"
eval "F$((FP+NP+0))=\"\${sht445}\""
eval "F$((FP+NP+1))=\"\${sht439}\""
eval "F$((FP+NP+2))=\"\${sht437}\""
eval "F$((FP+NP+3))=\"\${sht435}\""
eval "F$((FP+NP+4))=\"\${sht422}\""
eval "F$((FP+NP+5))=\"\${sht418}\""
eval "F$((FP+NP+6))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
CALLEE=lenl
RPC=201; ACTION=call; return
;;
201)
eval "sht445=\"\$F$((FP+NP+0))\""
eval "sht439=\"\$F$((FP+NP+1))\""
eval "sht437=\"\$F$((FP+NP+2))\""
eval "sht435=\"\$F$((FP+NP+3))\""
eval "sht422=\"\$F$((FP+NP+4))\""
eval "sht418=\"\$F$((FP+NP+5))\""
eval "sht415=\"\$F$((FP+NP+6))\""
sht446="${R}"
eval "F$((FP+NP+0))=\"\${sht439}\""
eval "F$((FP+NP+1))=\"\${sht437}\""
eval "F$((FP+NP+2))=\"\${sht435}\""
eval "F$((FP+NP+3))=\"\${sht422}\""
eval "F$((FP+NP+4))=\"\${sht418}\""
eval "F$((FP+NP+5))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht445}\""
eval "F$((NFP+1))=\"\${sht446}\""
CALLEE=bsm
RPC=202; ACTION=call; return
;;
202)
eval "sht439=\"\$F$((FP+NP+0))\""
eval "sht437=\"\$F$((FP+NP+1))\""
eval "sht435=\"\$F$((FP+NP+2))\""
eval "sht422=\"\$F$((FP+NP+3))\""
eval "sht418=\"\$F$((FP+NP+4))\""
eval "sht415=\"\$F$((FP+NP+5))\""
sht447="${R}"
eval "F$((FP+NP+0))=\"\${sht439}\""
eval "F$((FP+NP+1))=\"\${sht437}\""
eval "F$((FP+NP+2))=\"\${sht435}\""
eval "F$((FP+NP+3))=\"\${sht422}\""
eval "F$((FP+NP+4))=\"\${sht418}\""
eval "F$((FP+NP+5))=\"\${sht415}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht447}\""
CALLEE=bkzzP
RPC=203; ACTION=call; return
;;
203)
eval "sht439=\"\$F$((FP+NP+0))\""
eval "sht437=\"\$F$((FP+NP+1))\""
eval "sht435=\"\$F$((FP+NP+2))\""
eval "sht422=\"\$F$((FP+NP+3))\""
eval "sht418=\"\$F$((FP+NP+4))\""
eval "sht415=\"\$F$((FP+NP+5))\""
sht448="${R}"
eval "F$((FP+NP+0))=\"\${sht448}\""
eval "F$((FP+NP+1))=\"\${sht439}\""
eval "F$((FP+NP+2))=\"\${sht437}\""
eval "F$((FP+NP+3))=\"\${sht435}\""
eval "F$((FP+NP+4))=\"\${sht422}\""
eval "F$((FP+NP+5))=\"\${sht418}\""
eval "F$((FP+NP+6))=\"\${sht415}\""
hp_cons "S:loc" "${sht439}"
eval "sht448=\"\$F$((FP+NP+0))\""
eval "sht439=\"\$F$((FP+NP+1))\""
eval "sht437=\"\$F$((FP+NP+2))\""
eval "sht435=\"\$F$((FP+NP+3))\""
eval "sht422=\"\$F$((FP+NP+4))\""
eval "sht418=\"\$F$((FP+NP+5))\""
eval "sht415=\"\$F$((FP+NP+6))\""
sht449="${R}"
eval "F$((FP+NP+0))=\"\${sht439}\""
eval "F$((FP+NP+1))=\"\${sht437}\""
eval "F$((FP+NP+2))=\"\${sht435}\""
eval "F$((FP+NP+3))=\"\${sht422}\""
eval "F$((FP+NP+4))=\"\${sht418}\""
eval "F$((FP+NP+5))=\"\${sht415}\""
hp_cons "${sht448}" "${sht449}"
eval "sht439=\"\$F$((FP+NP+0))\""
eval "sht437=\"\$F$((FP+NP+1))\""
eval "sht435=\"\$F$((FP+NP+2))\""
eval "sht422=\"\$F$((FP+NP+3))\""
eval "sht418=\"\$F$((FP+NP+4))\""
eval "sht415=\"\$F$((FP+NP+5))\""
sht450="${R}"
R="${sht450}"; ACTION=ret; return
;;
204)
sht452="${R}"
sht453="${sht452}"
hp_cdr "${sht453}"
sht454="${R}"
hp_cdr "${sht454}"
sht455="${R}"
sht456="${sht455}"
hp_cdr "${sht453}"
sht457="${R}"
eval "F$((FP+NP+0))=\"\${sht456}\""
eval "F$((FP+NP+1))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht457}\""
eval "F$((NFP+1))=\"\${p3}\""
CALLEE=addlive
RPC=205; ACTION=call; return
;;
205)
eval "sht456=\"\$F$((FP+NP+0))\""
eval "sht453=\"\$F$((FP+NP+1))\""
sht458="${R}"
sht459="${sht458}"
hp_cdr "${p0}"
sht460="${R}"
hp_car "${sht453}"
sht461="${R}"
eval "F$((FP+NP+0))=\"\${sht459}\""
eval "F$((FP+NP+1))=\"\${sht456}\""
eval "F$((FP+NP+2))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht460}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht461}\""
eval "F$((NFP+3))=\"\${sht459}\""
CALLEE=largs
RPC=206; ACTION=call; return
;;
206)
eval "sht459=\"\$F$((FP+NP+0))\""
eval "sht456=\"\$F$((FP+NP+1))\""
eval "sht453=\"\$F$((FP+NP+2))\""
sht462="${R}"
sht463="${sht462}"
hp_car "${sht463}"
sht464="${R}"
eval "F$((FP+NP+0))=\"\${sht463}\""
eval "F$((FP+NP+1))=\"\${sht459}\""
eval "F$((FP+NP+2))=\"\${sht456}\""
eval "F$((FP+NP+3))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht464}\""
CALLEE=b_npc
RPC=207; ACTION=call; return
;;
207)
eval "sht463=\"\$F$((FP+NP+0))\""
eval "sht459=\"\$F$((FP+NP+1))\""
eval "sht456=\"\$F$((FP+NP+2))\""
eval "sht453=\"\$F$((FP+NP+3))\""
sht465="${R}"
sht466="${sht465}"
hp_car "${sht463}"
sht467="${R}"
eval "F$((FP+NP+0))=\"\${sht466}\""
eval "F$((FP+NP+1))=\"\${sht463}\""
eval "F$((FP+NP+2))=\"\${sht459}\""
eval "F$((FP+NP+3))=\"\${sht456}\""
eval "F$((FP+NP+4))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht467}\""
CALLEE=bnpczzP
RPC=208; ACTION=call; return
;;
208)
eval "sht466=\"\$F$((FP+NP+0))\""
eval "sht463=\"\$F$((FP+NP+1))\""
eval "sht459=\"\$F$((FP+NP+2))\""
eval "sht456=\"\$F$((FP+NP+3))\""
eval "sht453=\"\$F$((FP+NP+4))\""
sht468="${R}"
eval "F$((FP+NP+0))=\"\${sht466}\""
eval "F$((FP+NP+1))=\"\${sht463}\""
eval "F$((FP+NP+2))=\"\${sht459}\""
eval "F$((FP+NP+3))=\"\${sht456}\""
eval "F$((FP+NP+4))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht468}\""
eval "F$((NFP+1))=\"\${sht459}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=spill
RPC=209; ACTION=call; return
;;
209)
eval "sht466=\"\$F$((FP+NP+0))\""
eval "sht463=\"\$F$((FP+NP+1))\""
eval "sht459=\"\$F$((FP+NP+2))\""
eval "sht456=\"\$F$((FP+NP+3))\""
eval "sht453=\"\$F$((FP+NP+4))\""
sht469="${R}"
eval "F$((FP+NP+0))=\"\${sht466}\""
eval "F$((FP+NP+1))=\"\${sht463}\""
eval "F$((FP+NP+2))=\"\${sht459}\""
eval "F$((FP+NP+3))=\"\${sht456}\""
eval "F$((FP+NP+4))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht469}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
CALLEE=emit
RPC=210; ACTION=call; return
;;
210)
eval "sht466=\"\$F$((FP+NP+0))\""
eval "sht463=\"\$F$((FP+NP+1))\""
eval "sht459=\"\$F$((FP+NP+2))\""
eval "sht456=\"\$F$((FP+NP+3))\""
eval "sht453=\"\$F$((FP+NP+4))\""
sht470="${R}"
hp_cdr "${sht463}"
sht471="${R}"
eval "F$((FP+NP+0))=\"\${sht466}\""
eval "F$((FP+NP+1))=\"\${sht463}\""
eval "F$((FP+NP+2))=\"\${sht459}\""
eval "F$((FP+NP+3))=\"\${sht456}\""
eval "F$((FP+NP+4))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht470}\""
eval "F$((NFP+1))=\"\${sht471}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=stage
RPC=211; ACTION=call; return
;;
211)
eval "sht466=\"\$F$((FP+NP+0))\""
eval "sht463=\"\$F$((FP+NP+1))\""
eval "sht459=\"\$F$((FP+NP+2))\""
eval "sht456=\"\$F$((FP+NP+3))\""
eval "sht453=\"\$F$((FP+NP+4))\""
sht472="${R}"
sht473="T:${sht456#??}}"
sht474="T:CALLEE=\${${sht473#??}"
eval "F$((FP+NP+0))=\"\${sht466}\""
eval "F$((FP+NP+1))=\"\${sht463}\""
eval "F$((FP+NP+2))=\"\${sht459}\""
eval "F$((FP+NP+3))=\"\${sht456}\""
eval "F$((FP+NP+4))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht472}\""
eval "F$((NFP+1))=\"\${sht474}\""
CALLEE=emit
RPC=212; ACTION=call; return
;;
212)
eval "sht466=\"\$F$((FP+NP+0))\""
eval "sht463=\"\$F$((FP+NP+1))\""
eval "sht459=\"\$F$((FP+NP+2))\""
eval "sht456=\"\$F$((FP+NP+3))\""
eval "sht453=\"\$F$((FP+NP+4))\""
sht475="${R}"
sht476="T:${sht466#??}"
sht477="T:${sht476#??}; ACTION=call; return"
sht478="T:RPC=${sht477#??}"
eval "F$((FP+NP+0))=\"\${sht466}\""
eval "F$((FP+NP+1))=\"\${sht463}\""
eval "F$((FP+NP+2))=\"\${sht459}\""
eval "F$((FP+NP+3))=\"\${sht456}\""
eval "F$((FP+NP+4))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht475}\""
eval "F$((NFP+1))=\"\${sht478}\""
CALLEE=emit
RPC=213; ACTION=call; return
;;
213)
eval "sht466=\"\$F$((FP+NP+0))\""
eval "sht463=\"\$F$((FP+NP+1))\""
eval "sht459=\"\$F$((FP+NP+2))\""
eval "sht456=\"\$F$((FP+NP+3))\""
eval "sht453=\"\$F$((FP+NP+4))\""
sht479="${R}"
sht480="${sht479}"
eval "F$((FP+NP+0))=\"\${sht480}\""
eval "F$((FP+NP+1))=\"\${sht466}\""
eval "F$((FP+NP+2))=\"\${sht463}\""
eval "F$((FP+NP+3))=\"\${sht459}\""
eval "F$((FP+NP+4))=\"\${sht456}\""
eval "F$((FP+NP+5))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht480}\""
eval "F$((NFP+1))=\"\${sht466}\""
CALLEE=switch
RPC=214; ACTION=call; return
;;
214)
eval "sht480=\"\$F$((FP+NP+0))\""
eval "sht466=\"\$F$((FP+NP+1))\""
eval "sht463=\"\$F$((FP+NP+2))\""
eval "sht459=\"\$F$((FP+NP+3))\""
eval "sht456=\"\$F$((FP+NP+4))\""
eval "sht453=\"\$F$((FP+NP+5))\""
sht481="${R}"
sht482="${sht481}"
eval "F$((FP+NP+0))=\"\${sht482}\""
eval "F$((FP+NP+1))=\"\${sht480}\""
eval "F$((FP+NP+2))=\"\${sht466}\""
eval "F$((FP+NP+3))=\"\${sht463}\""
eval "F$((FP+NP+4))=\"\${sht459}\""
eval "F$((FP+NP+5))=\"\${sht456}\""
eval "F$((FP+NP+6))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht482}\""
CALLEE=tmpn
RPC=215; ACTION=call; return
;;
215)
eval "sht482=\"\$F$((FP+NP+0))\""
eval "sht480=\"\$F$((FP+NP+1))\""
eval "sht466=\"\$F$((FP+NP+2))\""
eval "sht463=\"\$F$((FP+NP+3))\""
eval "sht459=\"\$F$((FP+NP+4))\""
eval "sht456=\"\$F$((FP+NP+5))\""
eval "sht453=\"\$F$((FP+NP+6))\""
sht483="${R}"
sht484="${sht483}"
eval "F$((FP+NP+0))=\"\${sht484}\""
eval "F$((FP+NP+1))=\"\${sht482}\""
eval "F$((FP+NP+2))=\"\${sht480}\""
eval "F$((FP+NP+3))=\"\${sht466}\""
eval "F$((FP+NP+4))=\"\${sht463}\""
eval "F$((FP+NP+5))=\"\${sht459}\""
eval "F$((FP+NP+6))=\"\${sht456}\""
eval "F$((FP+NP+7))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht482}\""
eval "F$((NFP+1))=\"\${sht459}\""
eval "F$((NFP+2))=\"I:0\""
CALLEE=unspill
RPC=216; ACTION=call; return
;;
216)
eval "sht484=\"\$F$((FP+NP+0))\""
eval "sht482=\"\$F$((FP+NP+1))\""
eval "sht480=\"\$F$((FP+NP+2))\""
eval "sht466=\"\$F$((FP+NP+3))\""
eval "sht463=\"\$F$((FP+NP+4))\""
eval "sht459=\"\$F$((FP+NP+5))\""
eval "sht456=\"\$F$((FP+NP+6))\""
eval "sht453=\"\$F$((FP+NP+7))\""
sht485="${R}"
sht486="T:\${R}${G_DQ#??}"
sht487="T:${G_DQ#??}${sht486#??}"
sht488="T:=${sht487#??}"
sht489="T:${sht484#??}${sht488#??}"
eval "F$((FP+NP+0))=\"\${sht484}\""
eval "F$((FP+NP+1))=\"\${sht482}\""
eval "F$((FP+NP+2))=\"\${sht480}\""
eval "F$((FP+NP+3))=\"\${sht466}\""
eval "F$((FP+NP+4))=\"\${sht463}\""
eval "F$((FP+NP+5))=\"\${sht459}\""
eval "F$((FP+NP+6))=\"\${sht456}\""
eval "F$((FP+NP+7))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht485}\""
eval "F$((NFP+1))=\"\${sht489}\""
CALLEE=emit
RPC=217; ACTION=call; return
;;
217)
eval "sht484=\"\$F$((FP+NP+0))\""
eval "sht482=\"\$F$((FP+NP+1))\""
eval "sht480=\"\$F$((FP+NP+2))\""
eval "sht466=\"\$F$((FP+NP+3))\""
eval "sht463=\"\$F$((FP+NP+4))\""
eval "sht459=\"\$F$((FP+NP+5))\""
eval "sht456=\"\$F$((FP+NP+6))\""
eval "sht453=\"\$F$((FP+NP+7))\""
sht490="${R}"
eval "F$((FP+NP+0))=\"\${sht490}\""
eval "F$((FP+NP+1))=\"\${sht484}\""
eval "F$((FP+NP+2))=\"\${sht482}\""
eval "F$((FP+NP+3))=\"\${sht480}\""
eval "F$((FP+NP+4))=\"\${sht466}\""
eval "F$((FP+NP+5))=\"\${sht463}\""
eval "F$((FP+NP+6))=\"\${sht459}\""
eval "F$((FP+NP+7))=\"\${sht456}\""
eval "F$((FP+NP+8))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht459}\""
CALLEE=lenl
RPC=218; ACTION=call; return
;;
218)
eval "sht490=\"\$F$((FP+NP+0))\""
eval "sht484=\"\$F$((FP+NP+1))\""
eval "sht482=\"\$F$((FP+NP+2))\""
eval "sht480=\"\$F$((FP+NP+3))\""
eval "sht466=\"\$F$((FP+NP+4))\""
eval "sht463=\"\$F$((FP+NP+5))\""
eval "sht459=\"\$F$((FP+NP+6))\""
eval "sht456=\"\$F$((FP+NP+7))\""
eval "sht453=\"\$F$((FP+NP+8))\""
sht491="${R}"
eval "F$((FP+NP+0))=\"\${sht484}\""
eval "F$((FP+NP+1))=\"\${sht482}\""
eval "F$((FP+NP+2))=\"\${sht480}\""
eval "F$((FP+NP+3))=\"\${sht466}\""
eval "F$((FP+NP+4))=\"\${sht463}\""
eval "F$((FP+NP+5))=\"\${sht459}\""
eval "F$((FP+NP+6))=\"\${sht456}\""
eval "F$((FP+NP+7))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht490}\""
eval "F$((NFP+1))=\"\${sht491}\""
CALLEE=bsm
RPC=219; ACTION=call; return
;;
219)
eval "sht484=\"\$F$((FP+NP+0))\""
eval "sht482=\"\$F$((FP+NP+1))\""
eval "sht480=\"\$F$((FP+NP+2))\""
eval "sht466=\"\$F$((FP+NP+3))\""
eval "sht463=\"\$F$((FP+NP+4))\""
eval "sht459=\"\$F$((FP+NP+5))\""
eval "sht456=\"\$F$((FP+NP+6))\""
eval "sht453=\"\$F$((FP+NP+7))\""
sht492="${R}"
eval "F$((FP+NP+0))=\"\${sht484}\""
eval "F$((FP+NP+1))=\"\${sht482}\""
eval "F$((FP+NP+2))=\"\${sht480}\""
eval "F$((FP+NP+3))=\"\${sht466}\""
eval "F$((FP+NP+4))=\"\${sht463}\""
eval "F$((FP+NP+5))=\"\${sht459}\""
eval "F$((FP+NP+6))=\"\${sht456}\""
eval "F$((FP+NP+7))=\"\${sht453}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht492}\""
CALLEE=bkzzP
RPC=220; ACTION=call; return
;;
220)
eval "sht484=\"\$F$((FP+NP+0))\""
eval "sht482=\"\$F$((FP+NP+1))\""
eval "sht480=\"\$F$((FP+NP+2))\""
eval "sht466=\"\$F$((FP+NP+3))\""
eval "sht463=\"\$F$((FP+NP+4))\""
eval "sht459=\"\$F$((FP+NP+5))\""
eval "sht456=\"\$F$((FP+NP+6))\""
eval "sht453=\"\$F$((FP+NP+7))\""
sht493="${R}"
eval "F$((FP+NP+0))=\"\${sht493}\""
eval "F$((FP+NP+1))=\"\${sht484}\""
eval "F$((FP+NP+2))=\"\${sht482}\""
eval "F$((FP+NP+3))=\"\${sht480}\""
eval "F$((FP+NP+4))=\"\${sht466}\""
eval "F$((FP+NP+5))=\"\${sht463}\""
eval "F$((FP+NP+6))=\"\${sht459}\""
eval "F$((FP+NP+7))=\"\${sht456}\""
eval "F$((FP+NP+8))=\"\${sht453}\""
hp_cons "S:loc" "${sht484}"
eval "sht493=\"\$F$((FP+NP+0))\""
eval "sht484=\"\$F$((FP+NP+1))\""
eval "sht482=\"\$F$((FP+NP+2))\""
eval "sht480=\"\$F$((FP+NP+3))\""
eval "sht466=\"\$F$((FP+NP+4))\""
eval "sht463=\"\$F$((FP+NP+5))\""
eval "sht459=\"\$F$((FP+NP+6))\""
eval "sht456=\"\$F$((FP+NP+7))\""
eval "sht453=\"\$F$((FP+NP+8))\""
sht494="${R}"
eval "F$((FP+NP+0))=\"\${sht484}\""
eval "F$((FP+NP+1))=\"\${sht482}\""
eval "F$((FP+NP+2))=\"\${sht480}\""
eval "F$((FP+NP+3))=\"\${sht466}\""
eval "F$((FP+NP+4))=\"\${sht463}\""
eval "F$((FP+NP+5))=\"\${sht459}\""
eval "F$((FP+NP+6))=\"\${sht456}\""
eval "F$((FP+NP+7))=\"\${sht453}\""
hp_cons "${sht493}" "${sht494}"
eval "sht484=\"\$F$((FP+NP+0))\""
eval "sht482=\"\$F$((FP+NP+1))\""
eval "sht480=\"\$F$((FP+NP+2))\""
eval "sht466=\"\$F$((FP+NP+3))\""
eval "sht463=\"\$F$((FP+NP+4))\""
eval "sht459=\"\$F$((FP+NP+5))\""
eval "sht456=\"\$F$((FP+NP+6))\""
eval "sht453=\"\$F$((FP+NP+7))\""
sht495="${R}"
R="${sht495}"; ACTION=ret; return
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
show_val() { case $1 in NIL) printf 'nil\n' ;; I:*) printf '%s\n' "${1#I:}" ;; T:*) printf '%s\n' "${1#T:}" ;; S:*) printf '%s\n' "${1#S:}" ;; *) printf '%s\n' "$1" ;; esac; }

SRC=$(cat "$1"); rd_expr; _expr=$R
eval_form "$_expr"
show_val "$R"
