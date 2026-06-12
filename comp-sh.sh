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
    # a variadic callee may have ARGC staged args (beyond its SIZE of 1+spills) still in F while
    # its rest-collect conses them up -- widen the scan; overscan of stale slots is harmless.
    [ "${ARGC:-0}" -gt "$gs_sz" ] && gs_sz=$ARGC
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
      sh -c "$po_cmd"; R="I:$?" ;;   # exit code (world result); stdout was a live terminal effect
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
    '-')     hp_car "$args"; _d=${R#I:}; hp_cdr "$args"; lst=$R
             if [ "$lst" = NIL ]; then R="I:$((0 - _d))"; else
               while [ "$lst" != NIL ]; do hp_car "$lst"; _d=$((_d - ${R#I:})); hp_cdr "$lst"; lst=$R; done; R="I:$_d"; fi ;;
    '<'|'<='|'=')                       # chained: every adjacent pair must hold ((< 1 3 2) is nil)
             hp_car "$args"; _p=${R#I:}; hp_cdr "$args"; lst=$R; _ok=1
             while [ "$lst" != NIL ]; do hp_car "$lst"; _v=${R#I:}
               case $name in '<') [ "$_p" -lt "$_v" ] || _ok=0 ;; '<=') [ "$_p" -le "$_v" ] || _ok=0 ;; *) [ "$_p" -eq "$_v" ] || _ok=0 ;; esac
               _p=$_v; hp_cdr "$lst"; lst=$R; done
             [ "$_ok" = 1 ] && R="S:t" || R=NIL ;;
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
    'argv')  _av=NIL; _ai=${PORTSH_ARGC:-0}
             while [ "$_ai" -gt 0 ]; do _ai=$((_ai-1)); eval "_avv=\${PORTSH_ARGV_$_ai-}"; hp_cons "T:$_avv" "$_av"; _av=$R; done; R=$_av ;;
    'setenv') arg2 "$args"; _sn=${ARG1#T:}; _sv=${ARG2#T:}
             case $_sn in *[!A-Za-z0-9_]*|'') R=NIL ;;
               *) if [ -n "$_sv" ]; then eval "export $_sn=\$_sv"; else eval "unset $_sn"; fi; R="S:t" ;; esac ;;
    'exit')  arg1 "$args"; exit "${ARG1#I:}" ;;
    'make-dir')    arg1 "$args"; mkdir -p "${ARG1#T:}" 2>/dev/null && R="S:t" || R=NIL ;;
    'delete-file') arg1 "$args"; _df=${ARG1#T:}; if [ -e "$_df" ]; then rm -f "$_df" 2>/dev/null; fi
             [ -e "$_df" ] && R=NIL || R="S:t" ;;
    'copy-file')   arg2 "$args"; cp -f "${ARG1#T:}" "${ARG2#T:}" 2>/dev/null && R="S:t" || R=NIL ;;
    'getenv') arg1 "$args"; _gn=${ARG1#T:}
             case $_gn in *[!A-Za-z0-9_]*|'') R=NIL ;; *) eval "_gv=\${$_gn-}"; if [ -n "$_gv" ]; then R="T:$_gv"; else R=NIL; fi ;; esac ;;
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
  for p in cons car cdr 'eq?' 'null?' 'atom?' '+' '-' '*' '<' '<=' '=' 'file-exists?' 'string-append' 'string-length' substring 'symbol->string' 'string->symbol' 'number->string' 'string->number' split 'read' 'type-of' argv getenv setenv exit 'make-dir' 'delete-file' 'copy-file' 'read-lines' 'write-lines' 'append-lines' hmark hreset list wrap unwrap eval print dq; do
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
  # capture user args (after the program path) for (argv), unless a front-end already did
  if [ -z "${PORTSH_ARGC:-}" ] && [ "$#" -ge 1 ]; then
    _an=0; _askip=1
    for _aa in "$@"; do
      if [ "$_askip" = 1 ]; then _askip=0; continue; fi
      eval "PORTSH_ARGV_$_an=\$_aa"; export "PORTSH_ARGV_$_an"; _an=$((_an+1))
    done
    PORTSH_ARGC=$_an; export PORTSH_ARGC
  fi
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
ARGC=2
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
ARGC=2
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=1
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
ARGC=3
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
ARGC=3
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
ARGC=3
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
ARGC=3
PC=0; ACTION=tail; return
;;
esac; }
SIZE_fs_list=1
fs_list() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_fs_list))
NP=1
case $PC in
0)
if [ "${p0#S:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "${p0}" "NIL"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
R="${p0}"; ACTION=ret; return
;;
esac; }
SIZE_varargszzQ=1
varargszzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_varargszzQ))
NP=1
case $PC in
0)
if [ "${p0#S:}" != "${p0}" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
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
if [ "${p0#S:}" != "${p0}" ]; then PC=18; else PC=19; fi
ACTION=jump; return
;;
3)
R="${p2}"; ACTION=ret; return
;;
4)
hp_car "${p0}"
sht1="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
ARGC=1
CALLEE=runopzzQ
RPC=5; ACTION=call; return
;;
5)
sht2="${R}"
if [ "${sht2}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
R="${p2}"; ACTION=ret; return
;;
7)
hp_car "${p0}"
sht3="${R}"
if [ "${sht3}" = "S:lambda" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
8)
hp_cdr "${p0}"
sht4="${R}"
hp_cdr "${sht4}"
sht5="${R}"
hp_car "${sht5}"
sht6="${R}"
hp_cdr "${p0}"
sht7="${R}"
hp_car "${sht7}"
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
ARGC=1
CALLEE=fs_list
RPC=10; ACTION=call; return
;;
9)
hp_car "${p0}"
sht11="${R}"
if [ "${sht11}" = "S:let" ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
10)
eval "sht6=\"\$F$((FP+NP+0))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht9}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=append
RPC=11; ACTION=call; return
;;
11)
eval "sht6=\"\$F$((FP+NP+0))\""
sht10="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${sht10}\""
eval "F$((FP+2))=\"\${p2}\""
ARGC=3
PC=0; ACTION=tail; return
;;
12)
hp_cdr "${p0}"
sht12="${R}"
hp_cdr "${sht12}"
sht13="${R}"
hp_car "${sht13}"
sht14="${R}"
hp_cdr "${p0}"
sht15="${R}"
hp_car "${sht15}"
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
ARGC=1
CALLEE=lv_names
RPC=14; ACTION=call; return
;;
13)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=fv_list
RPC=17; ACTION=call; return
;;
14)
eval "sht14=\"\$F$((FP+NP+0))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=append
RPC=15; ACTION=call; return
;;
15)
eval "sht14=\"\$F$((FP+NP+0))\""
sht18="${R}"
hp_cdr "${p0}"
sht19="${R}"
hp_car "${sht19}"
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht18}\""
eval "F$((FP+NP+1))=\"\${sht14}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=fv_binds
RPC=16; ACTION=call; return
;;
16)
eval "sht18=\"\$F$((FP+NP+0))\""
eval "sht14=\"\$F$((FP+NP+1))\""
sht21="${R}"
eval "F$((FP+0))=\"\${sht14}\""
eval "F$((FP+1))=\"\${sht18}\""
eval "F$((FP+2))=\"\${sht21}\""
ARGC=3
PC=0; ACTION=tail; return
;;
17)
sht22="${R}"
R="${sht22}"; ACTION=ret; return
;;
18)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=memzzQ
RPC=20; ACTION=call; return
;;
19)
R="${p2}"; ACTION=ret; return
;;
20)
sht23="${R}"
if [ "${sht23}" != NIL ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
R="${p2}"; ACTION=ret; return
;;
22)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
ARGC=2
CALLEE=set_add
RPC=23; ACTION=call; return
;;
23)
sht24="${R}"
R="${sht24}"; ACTION=ret; return
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
ARGC=2
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
ARGC=2
CALLEE=keep_bound
RPC=6; ACTION=call; return
;;
5)
hp_cdr "${p0}"
sht6="${R}"
eval "F$((FP+0))=\"\${sht6}\""
eval "F$((FP+1))=\"\${p1}\""
ARGC=2
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
ARGC=3
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
ARGC=3
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
ARGC=2
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
sht58="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht58}"
eval "p0=\"\$F$((FP+NP+0))\""
sht59="${R}"
hp_cons "${p0}" "${sht59}"
sht60="${R}"
R="${sht60}"; ACTION=ret; return
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
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
ARGC=1
CALLEE=runopzzQ
RPC=5; ACTION=call; return
;;
5)
sht5="${R}"
if [ "${sht5}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
6)
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p2}" "NIL"
eval "p0=\"\$F$((FP+NP+0))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "NIL" "${sht6}"
eval "p0=\"\$F$((FP+NP+0))\""
sht7="${R}"
hp_cons "${p0}" "${sht7}"
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
7)
hp_car "${p0}"
sht9="${R}"
if [ "${sht9}" = "S:lambda" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
8)
hp_cdr "${p0}"
sht10="${R}"
hp_car "${sht10}"
sht11="${R}"
sht12="${sht11}"
hp_cdr "${p0}"
sht13="${R}"
hp_cdr "${sht13}"
sht14="${R}"
hp_car "${sht14}"
sht15="${R}"
hp_cdr "${p0}"
sht16="${R}"
hp_car "${sht16}"
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
ARGC=1
CALLEE=fs_list
RPC=10; ACTION=call; return
;;
9)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=lift_list
RPC=17; ACTION=call; return
;;
10)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=append
RPC=11; ACTION=call; return
;;
11)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
eval "F$((NFP+1))=\"\${sht19}\""
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=lift
RPC=12; ACTION=call; return
;;
12)
eval "sht12=\"\$F$((FP+NP+0))\""
sht20="${R}"
sht21="${sht20}"
hp_car "${sht21}"
sht22="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht21}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht12}\""
ARGC=1
CALLEE=fs_list
RPC=13; ACTION=call; return
;;
13)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht21=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
sht23="${R}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"\${sht23}\""
STGV="NIL"
eval "F$((NFP+2))=\"\$STGV\""
ARGC=3
CALLEE=fv
RPC=14; ACTION=call; return
;;
14)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht24="${R}"
eval "F$((FP+NP+0))=\"\${sht21}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=keep_bound
RPC=15; ACTION=call; return
;;
15)
eval "sht21=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht25="${R}"
sht26="${sht25}"
hp_cdr "${sht21}"
sht27="${R}"
hp_cdr "${sht27}"
sht28="${R}"
hp_car "${sht28}"
sht29="${R}"
sht30="T:${sht29#??}"
sht31="T:__lam${sht30#??}"
sht32="S:${sht31#??}"
sht33="${sht32}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
hp_cons "${sht33}" "NIL"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
hp_cons "S:quote" "${sht34}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
hp_cons "${sht35}" "${sht26}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
hp_cons "S:make-closure" "${sht36}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
sht37="${R}"
hp_cdr "${sht21}"
sht38="${R}"
hp_car "${sht38}"
sht39="${R}"
hp_car "${sht21}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht37}\""
eval "F$((FP+NP+5))=\"\${sht33}\""
eval "F$((FP+NP+6))=\"\${sht26}\""
eval "F$((FP+NP+7))=\"\${sht21}\""
eval "F$((FP+NP+8))=\"\${sht12}\""
hp_cons "${sht40}" "NIL"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht37=\"\$F$((FP+NP+4))\""
eval "sht33=\"\$F$((FP+NP+5))\""
eval "sht26=\"\$F$((FP+NP+6))\""
eval "sht21=\"\$F$((FP+NP+7))\""
eval "sht12=\"\$F$((FP+NP+8))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht37}\""
eval "F$((FP+NP+4))=\"\${sht33}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht21}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
hp_cons "${sht26}" "${sht41}"
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht37=\"\$F$((FP+NP+3))\""
eval "sht33=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht21=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht37}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht21}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
hp_cons "${sht12}" "${sht42}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht37=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht21=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht37}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht21}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
hp_cons "S:clambda" "${sht43}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht37=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht21=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht37}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht21}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
hp_cons "${sht44}" "NIL"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht37=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht21=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht37}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht21}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
hp_cons "${sht33}" "${sht45}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht37=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht21=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht37}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht21}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
hp_cons "S:define" "${sht46}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht37=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht21=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht37}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht21}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
hp_cons "${sht47}" "NIL"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht37=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht21=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht37}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht21}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht48}\""
ARGC=2
CALLEE=append
RPC=16; ACTION=call; return
;;
16)
eval "sht37=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht21=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
sht49="${R}"
hp_cdr "${sht21}"
sht50="${R}"
hp_cdr "${sht50}"
sht51="${R}"
hp_car "${sht51}"
sht52="${R}"
sht53="I:$(( ${sht52#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht49}\""
eval "F$((FP+NP+1))=\"\${sht37}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht21}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
hp_cons "${sht53}" "NIL"
eval "sht49=\"\$F$((FP+NP+0))\""
eval "sht37=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht21=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
sht54="${R}"
eval "F$((FP+NP+0))=\"\${sht37}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht21}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
hp_cons "${sht49}" "${sht54}"
eval "sht37=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht21=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
sht55="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht21}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
hp_cons "${sht37}" "${sht55}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht21=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
sht56="${R}"
R="${sht56}"; ACTION=ret; return
;;
17)
sht57="${R}"
R="${sht57}"; ACTION=ret; return
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
if [ "${p0}" = "S:<=" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:-le"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:=" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="T:-eq"; ACTION=ret; return
;;
6)
R="T:?"; ACTION=ret; return
;;
esac; }
SIZE_extra_argszzQ=1
extra_argszzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_extra_argszzQ))
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
if [ "${sht0}" = NIL ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="NIL"; ACTION=ret; return
;;
4)
hp_cdr "${p0}"
sht1="${R}"
hp_cdr "${sht1}"
sht2="${R}"
if [ "${sht2}" = NIL ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="NIL"; ACTION=ret; return
;;
6)
R="S:t"; ACTION=ret; return
;;
esac; }
SIZE_unary_argszzQ=1
unary_argszzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_unary_argszzQ))
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
if [ "${sht0}" = NIL ]; then
sht1="S:t"
else
sht1="NIL"
fi
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_nary_zzGbin=6
nary_zzGbin() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_nary_zzGbin))
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
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${p0}\""
hp_cons "${sht0}" "NIL"
eval "p1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht1="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
eval "F$((FP+NP+1))=\"\${p0}\""
hp_cons "${p1}" "${sht1}"
eval "p0=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${p0}" "${sht2}"
eval "p0=\"\$F$((FP+NP+0))\""
sht3="${R}"
hp_cdr "${p2}"
sht4="${R}"
eval "F$((FP+0))=\"\${p0}\""
eval "F$((FP+1))=\"\${sht3}\""
eval "F$((FP+2))=\"\${sht4}\""
ARGC=3
PC=0; ACTION=tail; return
;;
esac; }
SIZE_cmpchzzQ=1
cmpchzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_cmpchzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:<" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:<=" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="S:t"; ACTION=ret; return
;;
4)
if [ "${p0}" = "S:=" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
R="S:t"; ACTION=ret; return
;;
6)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_cmp_names=3
cmp_names() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_cmp_names))
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
sht1="T:__cmp${sht0#??}"
sht2="S:${sht1#??}"
hp_cdr "${p0}"
sht3="${R}"
sht4="I:$(( ${p1#??} + 1 ))"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${sht4}\""
ARGC=2
CALLEE=cmp_names
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${sht2}" "${sht5}"
sht6="${R}"
R="${sht6}"; ACTION=ret; return
;;
esac; }
SIZE_cmp_pairs=4
cmp_pairs() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_cmp_pairs))
NP=2
case $PC in
0)
hp_cdr "${p1}"
sht0="${R}"
if [ "${sht0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="NIL"; ACTION=ret; return
;;
2)
hp_car "${p1}"
sht1="${R}"
hp_cdr "${p1}"
sht2="${R}"
hp_car "${sht2}"
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${p0}\""
hp_cons "${sht3}" "NIL"
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${p0}\""
hp_cons "${sht1}" "${sht4}"
eval "p0=\"\$F$((FP+NP+0))\""
sht5="${R}"
hp_cons "${p0}" "${sht5}"
sht6="${R}"
hp_cdr "${p1}"
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht6}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht7}\""
ARGC=2
CALLEE=cmp_pairs
RPC=3; ACTION=call; return
;;
3)
eval "sht6=\"\$F$((FP+NP+0))\""
sht8="${R}"
hp_cons "${sht6}" "${sht8}"
sht9="${R}"
R="${sht9}"; ACTION=ret; return
;;
esac; }
SIZE_cmp_wrap=4
cmp_wrap() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_cmp_wrap))
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
hp_car "${p0}"
sht0="${R}"
hp_car "${p1}"
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
hp_cons "${sht1}" "NIL"
eval "sht0=\"\$F$((FP+NP+0))\""
sht2="${R}"
hp_cons "${sht0}" "${sht2}"
sht3="${R}"
hp_cons "${sht3}" "NIL"
sht4="${R}"
hp_cdr "${p0}"
sht5="${R}"
hp_cdr "${p1}"
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${sht6}\""
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=cmp_wrap
RPC=3; ACTION=call; return
;;
3)
eval "sht4=\"\$F$((FP+NP+0))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
hp_cons "${sht7}" "NIL"
eval "sht4=\"\$F$((FP+NP+0))\""
sht8="${R}"
hp_cons "${sht4}" "${sht8}"
sht9="${R}"
hp_cons "S:let" "${sht9}"
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
esac; }
SIZE_chain_zzGand=5
chain_zzGand() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_chain_zzGand))
NP=2
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=cmp_names
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht1}\""
ARGC=2
CALLEE=cmp_pairs
RPC=2; ACTION=call; return
;;
2)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
hp_cons "S:and" "${sht2}"
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht3}\""
ARGC=3
CALLEE=cmp_wrap
RPC=3; ACTION=call; return
;;
3)
eval "sht1=\"\$F$((FP+NP+0))\""
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_nary_formzzQ=1
nary_formzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_nary_formzzQ))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
ARGC=1
CALLEE=arithzzQ
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
hp_cdr "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
ARGC=1
CALLEE=extra_argszzQ
RPC=5; ACTION=call; return
;;
3)
sht2="NIL"
PC=4; ACTION=jump; return
;;
4)
if [ "${sht2}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
5)
sht4="${R}"
sht2="${sht4}"
PC=4; ACTION=jump; return
;;
6)
R="S:t"; ACTION=ret; return
;;
7)
hp_car "${p0}"
sht5="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
ARGC=1
CALLEE=arithzzQ
RPC=8; ACTION=call; return
;;
8)
sht6="${R}"
if [ "${sht6}" != NIL ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
hp_cdr "${p0}"
sht8="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht8}\""
ARGC=1
CALLEE=unary_argszzQ
RPC=12; ACTION=call; return
;;
10)
sht7="NIL"
PC=11; ACTION=jump; return
;;
11)
if [ "${sht7}" != NIL ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
12)
sht9="${R}"
sht7="${sht9}"
PC=11; ACTION=jump; return
;;
13)
R="S:t"; ACTION=ret; return
;;
14)
hp_car "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
ARGC=1
CALLEE=cmpchzzQ
RPC=15; ACTION=call; return
;;
15)
sht11="${R}"
if [ "${sht11}" != NIL ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
16)
hp_cdr "${p0}"
sht13="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
ARGC=1
CALLEE=extra_argszzQ
RPC=19; ACTION=call; return
;;
17)
sht12="NIL"
PC=18; ACTION=jump; return
;;
18)
if [ "${sht12}" != NIL ]; then PC=20; else PC=21; fi
ACTION=jump; return
;;
19)
sht14="${R}"
sht12="${sht14}"
PC=18; ACTION=jump; return
;;
20)
R="S:t"; ACTION=ret; return
;;
21)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_nary_rw=1
nary_rw() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_nary_rw))
NP=1
case $PC in
0)
hp_car "${p0}"
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
ARGC=1
CALLEE=arithzzQ
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
if [ "${sht1}" != NIL ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
hp_cdr "${p0}"
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
ARGC=1
CALLEE=extra_argszzQ
RPC=5; ACTION=call; return
;;
3)
sht2="NIL"
PC=4; ACTION=jump; return
;;
4)
if [ "${sht2}" != NIL ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
5)
sht4="${R}"
sht2="${sht4}"
PC=4; ACTION=jump; return
;;
6)
hp_car "${p0}"
sht5="${R}"
hp_cdr "${p0}"
sht6="${R}"
hp_car "${sht6}"
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
hp_cdr "${sht8}"
sht9="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${sht7}\""
eval "F$((NFP+2))=\"\${sht9}\""
ARGC=3
CALLEE=nary_zzGbin
RPC=8; ACTION=call; return
;;
7)
hp_car "${p0}"
sht11="${R}"
if [ "${sht11}" = "S:-" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
8)
sht10="${R}"
R="${sht10}"; ACTION=ret; return
;;
9)
hp_cdr "${p0}"
sht13="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht13}\""
ARGC=1
CALLEE=unary_argszzQ
RPC=12; ACTION=call; return
;;
10)
sht12="NIL"
PC=11; ACTION=jump; return
;;
11)
if [ "${sht12}" != NIL ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
12)
sht14="${R}"
sht12="${sht14}"
PC=11; ACTION=jump; return
;;
13)
hp_cdr "${p0}"
sht15="${R}"
hp_car "${sht15}"
sht16="${R}"
hp_cons "${sht16}" "NIL"
sht17="${R}"
hp_cons "I:0" "${sht17}"
sht18="${R}"
hp_cons "S:-" "${sht18}"
sht19="${R}"
R="${sht19}"; ACTION=ret; return
;;
14)
hp_car "${p0}"
sht20="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht20}\""
ARGC=1
CALLEE=arithzzQ
RPC=15; ACTION=call; return
;;
15)
sht21="${R}"
if [ "${sht21}" != NIL ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
16)
hp_cdr "${p0}"
sht22="${R}"
hp_car "${sht22}"
sht23="${R}"
R="${sht23}"; ACTION=ret; return
;;
17)
hp_car "${p0}"
sht24="${R}"
hp_cdr "${p0}"
sht25="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht24}\""
eval "F$((NFP+1))=\"\${sht25}\""
ARGC=2
CALLEE=chain_zzGand
RPC=18; ACTION=call; return
;;
18)
sht26="${R}"
R="${sht26}"; ACTION=ret; return
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
if [ "${p0}" = "S:<=" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="S:t"; ACTION=ret; return
;;
18)
if [ "${p0}" = "S:=" ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
R="S:t"; ACTION=ret; return
;;
20)
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
if [ "${p0}" = "S:print" ]; then PC=7; else PC=8; fi
ACTION=jump; return
;;
7)
R="S:t"; ACTION=ret; return
;;
8)
if [ "${p0}" = "S:read-lines" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="S:t"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:file-exists?" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="S:t"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:read" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="S:t"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:type-of" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="S:t"; ACTION=ret; return
;;
16)
if [ "${p0}" = "S:split" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="S:t"; ACTION=ret; return
;;
18)
if [ "${p0}" = "S:argv" ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
R="S:t"; ACTION=ret; return
;;
20)
if [ "${p0}" = "S:getenv" ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
R="S:t"; ACTION=ret; return
;;
22)
if [ "${p0}" = "S:setenv" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
23)
R="S:t"; ACTION=ret; return
;;
24)
if [ "${p0}" = "S:exit" ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
25)
R="S:t"; ACTION=ret; return
;;
26)
if [ "${p0}" = "S:make-dir" ]; then PC=27; else PC=28; fi
ACTION=jump; return
;;
27)
R="S:t"; ACTION=ret; return
;;
28)
if [ "${p0}" = "S:delete-file" ]; then PC=29; else PC=30; fi
ACTION=jump; return
;;
29)
R="S:t"; ACTION=ret; return
;;
30)
if [ "${p0}" = "S:copy-file" ]; then PC=31; else PC=32; fi
ACTION=jump; return
;;
31)
R="S:t"; ACTION=ret; return
;;
32)
R="NIL"; ACTION=ret; return
;;
esac; }
SIZE_brt=1
brt() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_brt))
NP=1
case $PC in
0)
if [ "${p0}" = "S:read" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="T:read_str"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:exit" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="T:exit_prim"; ACTION=ret; return
;;
4)
sht0="T:${p0#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
ARGC=1
CALLEE=sh_mangle
RPC=5; ACTION=call; return
;;
5)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_runopzzQ=1
runopzzQ() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_runopzzQ))
NP=1
case $PC in
0)
if [ "${p0}" = "S:run" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
R="S:t"; ACTION=ret; return
;;
2)
if [ "${p0}" = "S:run-capture" ]; then
sht0="S:t"
else
sht0="NIL"
fi
R="${sht0}"; ACTION=ret; return
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
if [ "${p0}" = "S:<=" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
9)
R="T:__p_le"; ACTION=ret; return
;;
10)
if [ "${p0}" = "S:=" ]; then PC=11; else PC=12; fi
ACTION=jump; return
;;
11)
R="T:__p_neq"; ACTION=ret; return
;;
12)
if [ "${p0}" = "S:cons" ]; then PC=13; else PC=14; fi
ACTION=jump; return
;;
13)
R="T:__p_cons"; ACTION=ret; return
;;
14)
if [ "${p0}" = "S:car" ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
R="T:__p_car"; ACTION=ret; return
;;
16)
if [ "${p0}" = "S:cdr" ]; then PC=17; else PC=18; fi
ACTION=jump; return
;;
17)
R="T:__p_cdr"; ACTION=ret; return
;;
18)
if [ "${p0}" = "S:null?" ]; then PC=19; else PC=20; fi
ACTION=jump; return
;;
19)
R="T:__p_null"; ACTION=ret; return
;;
20)
if [ "${p0}" = "S:eq?" ]; then PC=21; else PC=22; fi
ACTION=jump; return
;;
21)
R="T:__p_eq"; ACTION=ret; return
;;
22)
if [ "${p0}" = "S:pair?" ]; then PC=23; else PC=24; fi
ACTION=jump; return
;;
23)
R="T:__p_pair"; ACTION=ret; return
;;
24)
if [ "${p0}" = "S:not" ]; then PC=25; else PC=26; fi
ACTION=jump; return
;;
25)
R="T:__p_not"; ACTION=ret; return
;;
26)
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=4
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
ARGC=4
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
ARGC=1
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
ARGC=1
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=6
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
ARGC=1
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=6
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
ARGC=1
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=2
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
ARGC=6
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
ARGC=1
CALLEE=b_blk
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=6
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
ARGC=1
CALLEE=b_pc
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
eval "F$((FP+NP+0))=\"\${sht0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
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
ARGC=2
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=6
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
ARGC=1
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
ARGC=0
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
ARGC=0
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
ARGC=0
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
ARGC=2
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
ARGC=3
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
ARGC=0
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
ARGC=0
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
ARGC=2
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
ARGC=3
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
sht0="T:${p2#??}"
sht1="T:ARGC=${sht0#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht1}\""
ARGC=2
CALLEE=emit
RPC=3; ACTION=call; return
;;
2)
hp_car "${p1}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
if [ "${sht4}" = "S:cst" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
hp_car "${p1}"
sht6="${R}"
hp_cdr "${sht6}"
sht7="${R}"
sht8="T:${sht7#??}${G_DQ#??}"
sht9="T:${G_DQ#??}${sht8#??}"
sht10="T:STGV=${sht9#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht10}\""
ARGC=2
CALLEE=emit
RPC=7; ACTION=call; return
;;
5)
sht24="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=11; ACTION=call; return
;;
6)
hp_cdr "${p1}"
sht38="${R}"
sht39="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht5}\""
eval "F$((FP+1))=\"\${sht38}\""
eval "F$((FP+2))=\"\${sht39}\""
ARGC=3
PC=0; ACTION=tail; return
;;
7)
sht11="${R}"
sht12="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=8; ACTION=call; return
;;
8)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=9; ACTION=call; return
;;
9)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
sht14="${R}"
sht15="T:${sht14#??}${G_DQ#??}"
sht16="T:\\\$STGV${sht15#??}"
sht17="T:${sht13#??}${sht16#??}"
sht18="T:))=${sht17#??}"
sht19="T:${sht12#??}${sht18#??}"
sht20="T:F\$((NFP+${sht19#??}"
sht21="T:${G_DQ#??}${sht20#??}"
sht22="T:eval ${sht21#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"\${sht22}\""
ARGC=2
CALLEE=emit
RPC=10; ACTION=call; return
;;
10)
sht23="${R}"
sht5="${sht23}"
PC=6; ACTION=jump; return
;;
11)
eval "sht24=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht25="${R}"
hp_car "${p1}"
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
ARGC=1
CALLEE=fval
RPC=12; ACTION=call; return
;;
12)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht25}\""
eval "F$((FP+NP+2))=\"\${sht24}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${p0}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=13; ACTION=call; return
;;
13)
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht25=\"\$F$((FP+NP+1))\""
eval "sht24=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht28="${R}"
sht29="T:${sht28#??}${G_DQ#??}"
sht30="T:${sht27#??}${sht29#??}"
sht31="T:${sht25#??}${sht30#??}"
sht32="T:))=${sht31#??}"
sht33="T:${sht24#??}${sht32#??}"
sht34="T:F\$((NFP+${sht33#??}"
sht35="T:${G_DQ#??}${sht34#??}"
sht36="T:eval ${sht35#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht36}\""
ARGC=2
CALLEE=emit
RPC=14; ACTION=call; return
;;
14)
sht37="${R}"
sht5="${sht37}"
PC=6; ACTION=jump; return
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
sht0="T:${p2#??}"
sht1="T:ARGC=${sht0#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht1}\""
ARGC=2
CALLEE=emit
RPC=3; ACTION=call; return
;;
2)
hp_car "${p1}"
sht3="${R}"
hp_car "${sht3}"
sht4="${R}"
if [ "${sht4}" = "S:cst" ]; then PC=4; else PC=5; fi
ACTION=jump; return
;;
3)
sht2="${R}"
R="${sht2}"; ACTION=ret; return
;;
4)
hp_car "${p1}"
sht6="${R}"
hp_cdr "${sht6}"
sht7="${R}"
sht8="T:${sht7#??}${G_DQ#??}"
sht9="T:${G_DQ#??}${sht8#??}"
sht10="T:STGV=${sht9#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht10}\""
ARGC=2
CALLEE=emit
RPC=7; ACTION=call; return
;;
5)
sht24="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${p0}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=11; ACTION=call; return
;;
6)
hp_cdr "${p1}"
sht38="${R}"
sht39="I:$(( ${p2#??} + 1 ))"
eval "F$((FP+0))=\"\${sht5}\""
eval "F$((FP+1))=\"\${sht38}\""
eval "F$((FP+2))=\"\${sht39}\""
ARGC=3
PC=0; ACTION=tail; return
;;
7)
sht11="${R}"
sht12="T:${p2#??}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht11}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=8; ACTION=call; return
;;
8)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht11=\"\$F$((FP+NP+2))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht11}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=9; ACTION=call; return
;;
9)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht11=\"\$F$((FP+NP+3))\""
sht14="${R}"
sht15="T:${sht14#??}${G_DQ#??}"
sht16="T:\\\$STGV${sht15#??}"
sht17="T:${sht13#??}${sht16#??}"
sht18="T:))=${sht17#??}"
sht19="T:${sht12#??}${sht18#??}"
sht20="T:F\$((FP+${sht19#??}"
sht21="T:${G_DQ#??}${sht20#??}"
sht22="T:eval ${sht21#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
eval "F$((NFP+1))=\"\${sht22}\""
ARGC=2
CALLEE=emit
RPC=10; ACTION=call; return
;;
10)
sht23="${R}"
sht5="${sht23}"
PC=6; ACTION=jump; return
;;
11)
eval "sht24=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "p0=\"\$F$((FP+NP+2))\""
sht25="${R}"
hp_car "${p1}"
sht26="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${p0}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht26}\""
ARGC=1
CALLEE=fval
RPC=12; ACTION=call; return
;;
12)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "p0=\"\$F$((FP+NP+3))\""
sht27="${R}"
eval "F$((FP+NP+0))=\"\${sht27}\""
eval "F$((FP+NP+1))=\"\${sht25}\""
eval "F$((FP+NP+2))=\"\${sht24}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${p0}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=13; ACTION=call; return
;;
13)
eval "sht27=\"\$F$((FP+NP+0))\""
eval "sht25=\"\$F$((FP+NP+1))\""
eval "sht24=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "p0=\"\$F$((FP+NP+4))\""
sht28="${R}"
sht29="T:${sht28#??}${G_DQ#??}"
sht30="T:${sht27#??}${sht29#??}"
sht31="T:${sht25#??}${sht30#??}"
sht32="T:))=${sht31#??}"
sht33="T:${sht24#??}${sht32#??}"
sht34="T:F\$((FP+${sht33#??}"
sht35="T:${G_DQ#??}${sht34#??}"
sht36="T:eval ${sht35#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${sht36}\""
ARGC=2
CALLEE=emit
RPC=14; ACTION=call; return
;;
14)
sht37="${R}"
sht5="${sht37}"
PC=6; ACTION=jump; return
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
ARGC=4
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
ARGC=1
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
ARGC=4
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
ARGC=1
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
ARGC=2
CALLEE=lookup
RPC=12; ACTION=call; return
;;
11)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
CALLEE=nary_formzzQ
RPC=25; ACTION=call; return
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
ARGC=1
CALLEE=prim_wrap
RPC=15; ACTION=call; return
;;
14)
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:loc" "${sht12}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht30}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht31="${R}"
R="${sht31}"; ACTION=ret; return
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=1
CALLEE=sh_mangle
RPC=23; ACTION=call; return
;;
22)
sht25="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht25}\""
ARGC=1
CALLEE=sh_mangle
RPC=24; ACTION=call; return
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
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht26="${R}"
sht27="T:G_${sht26#??}"
eval "F$((FP+NP+0))=\"\${p2}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
hp_cons "S:loc" "${sht27}"
eval "p2=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
sht28="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
hp_cons "${p2}" "${sht28}"
eval "sht12=\"\$F$((FP+NP+0))\""
sht29="${R}"
R="${sht29}"; ACTION=ret; return
;;
25)
sht32="${R}"
if [ "${sht32}" != NIL ]; then PC=26; else PC=27; fi
ACTION=jump; return
;;
26)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
CALLEE=nary_rw
RPC=28; ACTION=call; return
;;
27)
hp_car "${p0}"
sht34="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
ARGC=1
CALLEE=arithzzQ
RPC=29; ACTION=call; return
;;
28)
sht33="${R}"
eval "F$((FP+0))=\"\${sht33}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
29)
sht35="${R}"
if [ "${sht35}" != NIL ]; then PC=30; else PC=31; fi
ACTION=jump; return
;;
30)
hp_cdr "${p0}"
sht36="${R}"
hp_car "${sht36}"
sht37="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=32; ACTION=call; return
;;
31)
hp_car "${p0}"
sht75="${R}"
if [ "${sht75}" = "S:car" ]; then PC=44; else PC=45; fi
ACTION=jump; return
;;
32)
sht38="${R}"
sht39="${sht38}"
hp_cdr "${p0}"
sht40="${R}"
hp_cdr "${sht40}"
sht41="${R}"
hp_car "${sht41}"
sht42="${R}"
hp_car "${sht39}"
sht43="${R}"
hp_cdr "${sht39}"
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht43}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht42}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht44}\""
ARGC=1
CALLEE=rvar
RPC=33; ACTION=call; return
;;
33)
eval "sht43=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht42=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
sht45="${R}"
sht46="${sht45}"
if [ "${sht46}" = NIL ]; then PC=34; else PC=35; fi
ACTION=jump; return
;;
34)
sht47="${p3}"
PC=36; ACTION=jump; return
;;
35)
eval "F$((FP+NP+0))=\"\${sht46}\""
eval "F$((FP+NP+1))=\"\${sht43}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht42}\""
eval "F$((FP+NP+4))=\"\${sht39}\""
hp_cons "${sht46}" "${p3}"
eval "sht46=\"\$F$((FP+NP+0))\""
eval "sht43=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht42=\"\$F$((FP+NP+3))\""
eval "sht39=\"\$F$((FP+NP+4))\""
sht48="${R}"
sht47="${sht48}"
PC=36; ACTION=jump; return
;;
36)
eval "F$((FP+NP+0))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht43}\""
eval "F$((NFP+3))=\"\${sht47}\""
ARGC=4
CALLEE=lval
RPC=37; ACTION=call; return
;;
37)
eval "sht39=\"\$F$((FP+NP+0))\""
sht49="${R}"
sht50="${sht49}"
hp_car "${sht50}"
sht51="${R}"
eval "F$((FP+NP+0))=\"\${sht50}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht51}\""
ARGC=1
CALLEE=tmpn
RPC=38; ACTION=call; return
;;
38)
eval "sht50=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
sht52="${R}"
sht53="${sht52}"
hp_car "${sht50}"
sht54="${R}"
hp_cdr "${sht39}"
sht55="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht53}\""
eval "F$((FP+NP+2))=\"\${sht54}\""
eval "F$((FP+NP+3))=\"\${sht53}\""
eval "F$((FP+NP+4))=\"\${sht50}\""
eval "F$((FP+NP+5))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht55}\""
ARGC=1
CALLEE=shdet
RPC=39; ACTION=call; return
;;
39)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht53=\"\$F$((FP+NP+1))\""
eval "sht54=\"\$F$((FP+NP+2))\""
eval "sht53=\"\$F$((FP+NP+3))\""
eval "sht50=\"\$F$((FP+NP+4))\""
eval "sht39=\"\$F$((FP+NP+5))\""
sht56="${R}"
hp_car "${p0}"
sht57="${R}"
eval "F$((FP+NP+0))=\"\${sht56}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht53}\""
eval "F$((FP+NP+3))=\"\${sht54}\""
eval "F$((FP+NP+4))=\"\${sht53}\""
eval "F$((FP+NP+5))=\"\${sht50}\""
eval "F$((FP+NP+6))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht57}\""
ARGC=1
CALLEE=shop
RPC=40; ACTION=call; return
;;
40)
eval "sht56=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht53=\"\$F$((FP+NP+2))\""
eval "sht54=\"\$F$((FP+NP+3))\""
eval "sht53=\"\$F$((FP+NP+4))\""
eval "sht50=\"\$F$((FP+NP+5))\""
eval "sht39=\"\$F$((FP+NP+6))\""
sht58="${R}"
hp_cdr "${sht50}"
sht59="${R}"
eval "F$((FP+NP+0))=\"\${sht58}\""
eval "F$((FP+NP+1))=\"\${sht56}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht53}\""
eval "F$((FP+NP+4))=\"\${sht54}\""
eval "F$((FP+NP+5))=\"\${sht53}\""
eval "F$((FP+NP+6))=\"\${sht50}\""
eval "F$((FP+NP+7))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht59}\""
ARGC=1
CALLEE=shdet
RPC=41; ACTION=call; return
;;
41)
eval "sht58=\"\$F$((FP+NP+0))\""
eval "sht56=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht53=\"\$F$((FP+NP+3))\""
eval "sht54=\"\$F$((FP+NP+4))\""
eval "sht53=\"\$F$((FP+NP+5))\""
eval "sht50=\"\$F$((FP+NP+6))\""
eval "sht39=\"\$F$((FP+NP+7))\""
sht60="${R}"
sht61="T: ))${G_DQ#??}"
sht62="T:${sht60#??}${sht61#??}"
sht63="T: ${sht62#??}"
sht64="T:${sht58#??}${sht63#??}"
sht65="T: ${sht64#??}"
sht66="T:${sht56#??}${sht65#??}"
sht67="T:I:\$(( ${sht66#??}"
sht68="T:${G_DQ#??}${sht67#??}"
sht69="T:=${sht68#??}"
sht70="T:${sht53#??}${sht69#??}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht50}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht54}\""
eval "F$((NFP+1))=\"\${sht70}\""
ARGC=2
CALLEE=emit
RPC=42; ACTION=call; return
;;
42)
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht50=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
sht71="${R}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht50}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht71}\""
ARGC=1
CALLEE=bkzzP
RPC=43; ACTION=call; return
;;
43)
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht50=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
sht72="${R}"
eval "F$((FP+NP+0))=\"\${sht72}\""
eval "F$((FP+NP+1))=\"\${sht53}\""
eval "F$((FP+NP+2))=\"\${sht50}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
hp_cons "S:loc" "${sht53}"
eval "sht72=\"\$F$((FP+NP+0))\""
eval "sht53=\"\$F$((FP+NP+1))\""
eval "sht50=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
sht73="${R}"
eval "F$((FP+NP+0))=\"\${sht53}\""
eval "F$((FP+NP+1))=\"\${sht50}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
hp_cons "${sht72}" "${sht73}"
eval "sht53=\"\$F$((FP+NP+0))\""
eval "sht50=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
sht74="${R}"
R="${sht74}"; ACTION=ret; return
;;
44)
hp_cdr "${p0}"
sht76="${R}"
hp_car "${sht76}"
sht77="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht77}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=46; ACTION=call; return
;;
45)
hp_car "${p0}"
sht98="${R}"
if [ "${sht98}" = "S:cdr" ]; then PC=52; else PC=53; fi
ACTION=jump; return
;;
46)
sht78="${R}"
sht79="${sht78}"
hp_car "${sht79}"
sht80="${R}"
eval "F$((FP+NP+0))=\"\${sht79}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht80}\""
ARGC=1
CALLEE=tmpn
RPC=47; ACTION=call; return
;;
47)
eval "sht79=\"\$F$((FP+NP+0))\""
sht81="${R}"
sht82="${sht81}"
hp_car "${sht79}"
sht83="${R}"
hp_cdr "${sht79}"
sht84="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht83}\""
eval "F$((FP+NP+2))=\"\${sht82}\""
eval "F$((FP+NP+3))=\"\${sht79}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht84}\""
ARGC=1
CALLEE=shval
RPC=48; ACTION=call; return
;;
48)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht83=\"\$F$((FP+NP+1))\""
eval "sht82=\"\$F$((FP+NP+2))\""
eval "sht79=\"\$F$((FP+NP+3))\""
sht85="${R}"
sht86="T:${sht85#??}${G_DQ#??}"
sht87="T:${G_DQ#??}${sht86#??}"
sht88="T:hp_car ${sht87#??}"
eval "F$((FP+NP+0))=\"\${sht82}\""
eval "F$((FP+NP+1))=\"\${sht79}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht83}\""
eval "F$((NFP+1))=\"\${sht88}\""
ARGC=2
CALLEE=emit
RPC=49; ACTION=call; return
;;
49)
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht79=\"\$F$((FP+NP+1))\""
sht89="${R}"
sht90="T:\${R}${G_DQ#??}"
sht91="T:${G_DQ#??}${sht90#??}"
sht92="T:=${sht91#??}"
sht93="T:${sht82#??}${sht92#??}"
eval "F$((FP+NP+0))=\"\${sht82}\""
eval "F$((FP+NP+1))=\"\${sht79}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht89}\""
eval "F$((NFP+1))=\"\${sht93}\""
ARGC=2
CALLEE=emit
RPC=50; ACTION=call; return
;;
50)
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht79=\"\$F$((FP+NP+1))\""
sht94="${R}"
eval "F$((FP+NP+0))=\"\${sht82}\""
eval "F$((FP+NP+1))=\"\${sht79}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht94}\""
ARGC=1
CALLEE=bkzzP
RPC=51; ACTION=call; return
;;
51)
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht79=\"\$F$((FP+NP+1))\""
sht95="${R}"
eval "F$((FP+NP+0))=\"\${sht95}\""
eval "F$((FP+NP+1))=\"\${sht82}\""
eval "F$((FP+NP+2))=\"\${sht79}\""
hp_cons "S:loc" "${sht82}"
eval "sht95=\"\$F$((FP+NP+0))\""
eval "sht82=\"\$F$((FP+NP+1))\""
eval "sht79=\"\$F$((FP+NP+2))\""
sht96="${R}"
eval "F$((FP+NP+0))=\"\${sht82}\""
eval "F$((FP+NP+1))=\"\${sht79}\""
hp_cons "${sht95}" "${sht96}"
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht79=\"\$F$((FP+NP+1))\""
sht97="${R}"
R="${sht97}"; ACTION=ret; return
;;
52)
hp_cdr "${p0}"
sht99="${R}"
hp_car "${sht99}"
sht100="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht100}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=54; ACTION=call; return
;;
53)
hp_car "${p0}"
sht121="${R}"
if [ "${sht121}" = "S:cons" ]; then PC=60; else PC=61; fi
ACTION=jump; return
;;
54)
sht101="${R}"
sht102="${sht101}"
hp_car "${sht102}"
sht103="${R}"
eval "F$((FP+NP+0))=\"\${sht102}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht103}\""
ARGC=1
CALLEE=tmpn
RPC=55; ACTION=call; return
;;
55)
eval "sht102=\"\$F$((FP+NP+0))\""
sht104="${R}"
sht105="${sht104}"
hp_car "${sht102}"
sht106="${R}"
hp_cdr "${sht102}"
sht107="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht106}\""
eval "F$((FP+NP+2))=\"\${sht105}\""
eval "F$((FP+NP+3))=\"\${sht102}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht107}\""
ARGC=1
CALLEE=shval
RPC=56; ACTION=call; return
;;
56)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht106=\"\$F$((FP+NP+1))\""
eval "sht105=\"\$F$((FP+NP+2))\""
eval "sht102=\"\$F$((FP+NP+3))\""
sht108="${R}"
sht109="T:${sht108#??}${G_DQ#??}"
sht110="T:${G_DQ#??}${sht109#??}"
sht111="T:hp_cdr ${sht110#??}"
eval "F$((FP+NP+0))=\"\${sht105}\""
eval "F$((FP+NP+1))=\"\${sht102}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht106}\""
eval "F$((NFP+1))=\"\${sht111}\""
ARGC=2
CALLEE=emit
RPC=57; ACTION=call; return
;;
57)
eval "sht105=\"\$F$((FP+NP+0))\""
eval "sht102=\"\$F$((FP+NP+1))\""
sht112="${R}"
sht113="T:\${R}${G_DQ#??}"
sht114="T:${G_DQ#??}${sht113#??}"
sht115="T:=${sht114#??}"
sht116="T:${sht105#??}${sht115#??}"
eval "F$((FP+NP+0))=\"\${sht105}\""
eval "F$((FP+NP+1))=\"\${sht102}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht112}\""
eval "F$((NFP+1))=\"\${sht116}\""
ARGC=2
CALLEE=emit
RPC=58; ACTION=call; return
;;
58)
eval "sht105=\"\$F$((FP+NP+0))\""
eval "sht102=\"\$F$((FP+NP+1))\""
sht117="${R}"
eval "F$((FP+NP+0))=\"\${sht105}\""
eval "F$((FP+NP+1))=\"\${sht102}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht117}\""
ARGC=1
CALLEE=bkzzP
RPC=59; ACTION=call; return
;;
59)
eval "sht105=\"\$F$((FP+NP+0))\""
eval "sht102=\"\$F$((FP+NP+1))\""
sht118="${R}"
eval "F$((FP+NP+0))=\"\${sht118}\""
eval "F$((FP+NP+1))=\"\${sht105}\""
eval "F$((FP+NP+2))=\"\${sht102}\""
hp_cons "S:loc" "${sht105}"
eval "sht118=\"\$F$((FP+NP+0))\""
eval "sht105=\"\$F$((FP+NP+1))\""
eval "sht102=\"\$F$((FP+NP+2))\""
sht119="${R}"
eval "F$((FP+NP+0))=\"\${sht105}\""
eval "F$((FP+NP+1))=\"\${sht102}\""
hp_cons "${sht118}" "${sht119}"
eval "sht105=\"\$F$((FP+NP+0))\""
eval "sht102=\"\$F$((FP+NP+1))\""
sht120="${R}"
R="${sht120}"; ACTION=ret; return
;;
60)
hp_cdr "${p0}"
sht122="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht122}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=largs
RPC=62; ACTION=call; return
;;
61)
hp_car "${p0}"
sht158="${R}"
if [ "${sht158}" = "S:quote" ]; then PC=73; else PC=74; fi
ACTION=jump; return
;;
62)
sht123="${R}"
sht124="${sht123}"
hp_car "${sht124}"
sht125="${R}"
eval "F$((FP+NP+0))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht125}\""
ARGC=1
CALLEE=tmpn
RPC=63; ACTION=call; return
;;
63)
eval "sht124=\"\$F$((FP+NP+0))\""
sht126="${R}"
sht127="${sht126}"
hp_cdr "${sht124}"
sht128="${R}"
hp_car "${sht128}"
sht129="${R}"
sht130="${sht129}"
hp_cdr "${sht124}"
sht131="${R}"
hp_cdr "${sht131}"
sht132="${R}"
hp_car "${sht132}"
sht133="${R}"
sht134="${sht133}"
hp_car "${sht124}"
sht135="${R}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht135}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=spill
RPC=64; ACTION=call; return
;;
64)
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht136="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht136}\""
eval "F$((FP+NP+2))=\"\${sht134}\""
eval "F$((FP+NP+3))=\"\${sht130}\""
eval "F$((FP+NP+4))=\"\${sht127}\""
eval "F$((FP+NP+5))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht130}\""
ARGC=1
CALLEE=shval
RPC=65; ACTION=call; return
;;
65)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht136=\"\$F$((FP+NP+1))\""
eval "sht134=\"\$F$((FP+NP+2))\""
eval "sht130=\"\$F$((FP+NP+3))\""
eval "sht127=\"\$F$((FP+NP+4))\""
eval "sht124=\"\$F$((FP+NP+5))\""
sht137="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht137}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht136}\""
eval "F$((FP+NP+5))=\"\${sht134}\""
eval "F$((FP+NP+6))=\"\${sht130}\""
eval "F$((FP+NP+7))=\"\${sht127}\""
eval "F$((FP+NP+8))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht134}\""
ARGC=1
CALLEE=shval
RPC=66; ACTION=call; return
;;
66)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht137=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht136=\"\$F$((FP+NP+4))\""
eval "sht134=\"\$F$((FP+NP+5))\""
eval "sht130=\"\$F$((FP+NP+6))\""
eval "sht127=\"\$F$((FP+NP+7))\""
eval "sht124=\"\$F$((FP+NP+8))\""
sht138="${R}"
sht139="T:${sht138#??}${G_DQ#??}"
sht140="T:${G_DQ#??}${sht139#??}"
sht141="T: ${sht140#??}"
sht142="T:${G_DQ#??}${sht141#??}"
sht143="T:${sht137#??}${sht142#??}"
sht144="T:${G_DQ#??}${sht143#??}"
sht145="T:hp_cons ${sht144#??}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht136}\""
eval "F$((NFP+1))=\"\${sht145}\""
ARGC=2
CALLEE=emit
RPC=67; ACTION=call; return
;;
67)
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht146="${R}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht146}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=unspill
RPC=68; ACTION=call; return
;;
68)
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht147="${R}"
sht148="T:\${R}${G_DQ#??}"
sht149="T:${G_DQ#??}${sht148#??}"
sht150="T:=${sht149#??}"
sht151="T:${sht127#??}${sht150#??}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht147}\""
eval "F$((NFP+1))=\"\${sht151}\""
ARGC=2
CALLEE=emit
RPC=69; ACTION=call; return
;;
69)
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht152="${R}"
eval "F$((FP+NP+0))=\"\${sht152}\""
eval "F$((FP+NP+1))=\"\${sht134}\""
eval "F$((FP+NP+2))=\"\${sht130}\""
eval "F$((FP+NP+3))=\"\${sht127}\""
eval "F$((FP+NP+4))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
ARGC=1
CALLEE=lenl
RPC=70; ACTION=call; return
;;
70)
eval "sht152=\"\$F$((FP+NP+0))\""
eval "sht134=\"\$F$((FP+NP+1))\""
eval "sht130=\"\$F$((FP+NP+2))\""
eval "sht127=\"\$F$((FP+NP+3))\""
eval "sht124=\"\$F$((FP+NP+4))\""
sht153="${R}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht152}\""
eval "F$((NFP+1))=\"\${sht153}\""
ARGC=2
CALLEE=bsm
RPC=71; ACTION=call; return
;;
71)
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht154="${R}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht154}\""
ARGC=1
CALLEE=bkzzP
RPC=72; ACTION=call; return
;;
72)
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht155="${R}"
eval "F$((FP+NP+0))=\"\${sht155}\""
eval "F$((FP+NP+1))=\"\${sht134}\""
eval "F$((FP+NP+2))=\"\${sht130}\""
eval "F$((FP+NP+3))=\"\${sht127}\""
eval "F$((FP+NP+4))=\"\${sht124}\""
hp_cons "S:loc" "${sht127}"
eval "sht155=\"\$F$((FP+NP+0))\""
eval "sht134=\"\$F$((FP+NP+1))\""
eval "sht130=\"\$F$((FP+NP+2))\""
eval "sht127=\"\$F$((FP+NP+3))\""
eval "sht124=\"\$F$((FP+NP+4))\""
sht156="${R}"
eval "F$((FP+NP+0))=\"\${sht134}\""
eval "F$((FP+NP+1))=\"\${sht130}\""
eval "F$((FP+NP+2))=\"\${sht127}\""
eval "F$((FP+NP+3))=\"\${sht124}\""
hp_cons "${sht155}" "${sht156}"
eval "sht134=\"\$F$((FP+NP+0))\""
eval "sht130=\"\$F$((FP+NP+1))\""
eval "sht127=\"\$F$((FP+NP+2))\""
eval "sht124=\"\$F$((FP+NP+3))\""
sht157="${R}"
R="${sht157}"; ACTION=ret; return
;;
73)
hp_cdr "${p0}"
sht159="${R}"
hp_car "${sht159}"
sht160="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht160}\""
eval "F$((NFP+1))=\"\${p2}\""
ARGC=2
CALLEE=lquote
RPC=75; ACTION=call; return
;;
74)
hp_car "${p0}"
sht162="${R}"
if [ "${sht162}" = "S:cond" ]; then PC=76; else PC=77; fi
ACTION=jump; return
;;
75)
sht161="${R}"
R="${sht161}"; ACTION=ret; return
;;
76)
hp_cdr "${p0}"
sht163="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht163}\""
ARGC=1
CALLEE=cond_zzGif
RPC=78; ACTION=call; return
;;
77)
hp_car "${p0}"
sht165="${R}"
if [ "${sht165}" = "S:and" ]; then PC=79; else PC=80; fi
ACTION=jump; return
;;
78)
sht164="${R}"
eval "F$((FP+0))=\"\${sht164}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
79)
hp_cdr "${p0}"
sht166="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht166}\""
ARGC=1
CALLEE=dsg_and
RPC=81; ACTION=call; return
;;
80)
hp_car "${p0}"
sht168="${R}"
if [ "${sht168}" = "S:or" ]; then PC=82; else PC=83; fi
ACTION=jump; return
;;
81)
sht167="${R}"
eval "F$((FP+0))=\"\${sht167}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
82)
hp_cdr "${p0}"
sht169="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht169}\""
ARGC=1
CALLEE=dsg_or
RPC=84; ACTION=call; return
;;
83)
hp_car "${p0}"
sht171="${R}"
if [ "${sht171}" = "S:str" ]; then PC=85; else PC=86; fi
ACTION=jump; return
;;
84)
sht170="${R}"
eval "F$((FP+0))=\"\${sht170}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
85)
hp_cdr "${p0}"
sht172="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht172}\""
ARGC=1
CALLEE=dsg_str
RPC=87; ACTION=call; return
;;
86)
hp_car "${p0}"
sht174="${R}"
if [ "${sht174}" = "S:list" ]; then PC=88; else PC=89; fi
ACTION=jump; return
;;
87)
sht173="${R}"
eval "F$((FP+0))=\"\${sht173}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
88)
hp_cdr "${p0}"
sht175="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht175}\""
ARGC=1
CALLEE=dsg_list
RPC=90; ACTION=call; return
;;
89)
hp_car "${p0}"
sht177="${R}"
if [ "${sht177}" = "S:when" ]; then PC=91; else PC=92; fi
ACTION=jump; return
;;
90)
sht176="${R}"
eval "F$((FP+0))=\"\${sht176}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
91)
hp_cdr "${p0}"
sht178="${R}"
hp_car "${sht178}"
sht179="${R}"
hp_cdr "${p0}"
sht180="${R}"
hp_cdr "${sht180}"
sht181="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht179}\""
eval "F$((NFP+1))=\"\${sht181}\""
ARGC=2
CALLEE=when_zzGif
RPC=93; ACTION=call; return
;;
92)
hp_car "${p0}"
sht183="${R}"
if [ "${sht183}" = "S:unless" ]; then PC=94; else PC=95; fi
ACTION=jump; return
;;
93)
sht182="${R}"
eval "F$((FP+0))=\"\${sht182}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
94)
hp_cdr "${p0}"
sht184="${R}"
hp_car "${sht184}"
sht185="${R}"
hp_cdr "${p0}"
sht186="${R}"
hp_cdr "${sht186}"
sht187="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht185}\""
eval "F$((NFP+1))=\"\${sht187}\""
ARGC=2
CALLEE=unless_zzGif
RPC=96; ACTION=call; return
;;
95)
hp_car "${p0}"
sht189="${R}"
if [ "${sht189}" = "S:case" ]; then PC=97; else PC=98; fi
ACTION=jump; return
;;
96)
sht188="${R}"
eval "F$((FP+0))=\"\${sht188}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
97)
hp_cdr "${p0}"
sht190="${R}"
hp_car "${sht190}"
sht191="${R}"
hp_cdr "${p0}"
sht192="${R}"
hp_cdr "${sht192}"
sht193="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht191}\""
eval "F$((NFP+1))=\"\${sht193}\""
ARGC=2
CALLEE=case_zzGcond
RPC=99; ACTION=call; return
;;
98)
hp_car "${p0}"
sht195="${R}"
if [ "${sht195}" = "S:let*" ]; then PC=100; else PC=101; fi
ACTION=jump; return
;;
99)
sht194="${R}"
eval "F$((FP+0))=\"\${sht194}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
100)
hp_cdr "${p0}"
sht196="${R}"
hp_car "${sht196}"
sht197="${R}"
hp_cdr "${p0}"
sht198="${R}"
hp_cdr "${sht198}"
sht199="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht197}\""
eval "F$((NFP+1))=\"\${sht199}\""
ARGC=2
CALLEE=letzzS_zzGlets
RPC=102; ACTION=call; return
;;
101)
hp_car "${p0}"
sht201="${R}"
if [ "${sht201}" = "S:begin" ]; then PC=103; else PC=104; fi
ACTION=jump; return
;;
102)
sht200="${R}"
eval "F$((FP+0))=\"\${sht200}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
103)
hp_cdr "${p0}"
sht202="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht202}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lbegin
RPC=105; ACTION=call; return
;;
104)
hp_car "${p0}"
sht204="${R}"
if [ "${sht204}" = "S:let" ]; then PC=106; else PC=107; fi
ACTION=jump; return
;;
105)
sht203="${R}"
R="${sht203}"; ACTION=ret; return
;;
106)
hp_cdr "${p0}"
sht205="${R}"
hp_car "${sht205}"
sht206="${R}"
hp_cdr "${p0}"
sht207="${R}"
hp_cdr "${sht207}"
sht208="${R}"
hp_car "${sht208}"
sht209="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht206}\""
eval "F$((NFP+1))=\"\${sht209}\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
ARGC=5
CALLEE=llet
RPC=108; ACTION=call; return
;;
107)
hp_car "${p0}"
sht211="${R}"
if [ "${sht211}" = "S:if" ]; then PC=109; else PC=110; fi
ACTION=jump; return
;;
108)
sht210="${R}"
R="${sht210}"; ACTION=ret; return
;;
109)
hp_cdr "${p0}"
sht212="${R}"
hp_car "${sht212}"
sht213="${R}"
hp_cdr "${p0}"
sht214="${R}"
hp_cdr "${sht214}"
sht215="${R}"
hp_car "${sht215}"
sht216="${R}"
eval "F$((FP+NP+0))=\"\${sht216}\""
eval "F$((FP+NP+1))=\"\${sht213}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
CALLEE=cadddr
RPC=111; ACTION=call; return
;;
110)
hp_car "${p0}"
sht219="${R}"
if [ "${sht219}" = "S:dq" ]; then PC=113; else PC=114; fi
ACTION=jump; return
;;
111)
eval "sht216=\"\$F$((FP+NP+0))\""
eval "sht213=\"\$F$((FP+NP+1))\""
sht217="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht213}\""
eval "F$((NFP+1))=\"\${sht216}\""
eval "F$((NFP+2))=\"\${sht217}\""
eval "F$((NFP+3))=\"\${p1}\""
eval "F$((NFP+4))=\"\${p2}\""
eval "F$((NFP+5))=\"\${p3}\""
ARGC=6
CALLEE=lif_val
RPC=112; ACTION=call; return
;;
112)
sht218="${R}"
R="${sht218}"; ACTION=ret; return
;;
113)
eval "F$((FP+NP+0))=\"\${p2}\""
hp_cons "S:loc" "T:G_DQ"
eval "p2=\"\$F$((FP+NP+0))\""
sht220="${R}"
hp_cons "${p2}" "${sht220}"
sht221="${R}"
R="${sht221}"; ACTION=ret; return
;;
114)
hp_car "${p0}"
sht222="${R}"
if [ "${sht222}" = "S:symbol->string" ]; then PC=115; else PC=116; fi
ACTION=jump; return
;;
115)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
ARGC=5
CALLEE=lretag
RPC=117; ACTION=call; return
;;
116)
hp_car "${p0}"
sht224="${R}"
if [ "${sht224}" = "S:number->string" ]; then PC=118; else PC=119; fi
ACTION=jump; return
;;
117)
sht223="${R}"
R="${sht223}"; ACTION=ret; return
;;
118)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
ARGC=5
CALLEE=lretag
RPC=120; ACTION=call; return
;;
119)
hp_car "${p0}"
sht226="${R}"
if [ "${sht226}" = "S:string->symbol" ]; then PC=121; else PC=122; fi
ACTION=jump; return
;;
120)
sht225="${R}"
R="${sht225}"; ACTION=ret; return
;;
121)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
ARGC=5
CALLEE=lretag
RPC=123; ACTION=call; return
;;
122)
hp_car "${p0}"
sht228="${R}"
if [ "${sht228}" = "S:string->number" ]; then PC=124; else PC=125; fi
ACTION=jump; return
;;
123)
sht227="${R}"
R="${sht227}"; ACTION=ret; return
;;
124)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"\${p1}\""
eval "F$((NFP+3))=\"\${p2}\""
eval "F$((NFP+4))=\"\${p3}\""
ARGC=5
CALLEE=lretag
RPC=126; ACTION=call; return
;;
125)
hp_car "${p0}"
sht230="${R}"
if [ "${sht230}" = "S:string-length" ]; then PC=127; else PC=128; fi
ACTION=jump; return
;;
126)
sht229="${R}"
R="${sht229}"; ACTION=ret; return
;;
127)
hp_cdr "${p0}"
sht231="${R}"
hp_car "${sht231}"
sht232="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht232}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=129; ACTION=call; return
;;
128)
hp_car "${p0}"
sht268="${R}"
if [ "${sht268}" = "S:string-append" ]; then PC=137; else PC=138; fi
ACTION=jump; return
;;
129)
sht233="${R}"
sht234="${sht233}"
hp_car "${sht234}"
sht235="${R}"
eval "F$((FP+NP+0))=\"\${sht234}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht235}\""
ARGC=1
CALLEE=tmpn
RPC=130; ACTION=call; return
;;
130)
eval "sht234=\"\$F$((FP+NP+0))\""
sht236="${R}"
sht237="${sht236}"
hp_cdr "${sht234}"
sht238="${R}"
hp_car "${sht238}"
sht239="${R}"
if [ "${sht239}" = "S:cst" ]; then PC=131; else PC=132; fi
ACTION=jump; return
;;
131)
hp_car "${sht234}"
sht240="${R}"
hp_cdr "${sht234}"
sht241="${R}"
hp_cdr "${sht241}"
sht242="${R}"
sht243="I:$(( ${#sht242} - 2 ))"
sht244="I:$(( ${sht243#??} - 2 ))"
sht245="T:${sht244#??}"
sht246="T:${sht245#??}${G_DQ#??}"
sht247="T:I:${sht246#??}"
sht248="T:${G_DQ#??}${sht247#??}"
sht249="T:=${sht248#??}"
sht250="T:${sht237#??}${sht249#??}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht240}\""
eval "F$((NFP+1))=\"\${sht250}\""
ARGC=2
CALLEE=emit
RPC=133; ACTION=call; return
;;
132)
hp_car "${sht234}"
sht255="${R}"
hp_cdr "${sht234}"
sht256="${R}"
hp_cdr "${sht256}"
sht257="${R}"
sht258="T:} - 2 ))${G_DQ#??}"
sht259="T:${sht257#??}${sht258#??}"
sht260="T:I:\$(( \${#${sht259#??}"
sht261="T:${G_DQ#??}${sht260#??}"
sht262="T:=${sht261#??}"
sht263="T:${sht237#??}${sht262#??}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht255}\""
eval "F$((NFP+1))=\"\${sht263}\""
ARGC=2
CALLEE=emit
RPC=135; ACTION=call; return
;;
133)
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
sht251="${R}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht251}\""
ARGC=1
CALLEE=bkzzP
RPC=134; ACTION=call; return
;;
134)
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
sht252="${R}"
eval "F$((FP+NP+0))=\"\${sht252}\""
eval "F$((FP+NP+1))=\"\${sht237}\""
eval "F$((FP+NP+2))=\"\${sht234}\""
hp_cons "S:loc" "${sht237}"
eval "sht252=\"\$F$((FP+NP+0))\""
eval "sht237=\"\$F$((FP+NP+1))\""
eval "sht234=\"\$F$((FP+NP+2))\""
sht253="${R}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
hp_cons "${sht252}" "${sht253}"
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
sht254="${R}"
R="${sht254}"; ACTION=ret; return
;;
135)
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
sht264="${R}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht264}\""
ARGC=1
CALLEE=bkzzP
RPC=136; ACTION=call; return
;;
136)
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
sht265="${R}"
eval "F$((FP+NP+0))=\"\${sht265}\""
eval "F$((FP+NP+1))=\"\${sht237}\""
eval "F$((FP+NP+2))=\"\${sht234}\""
hp_cons "S:loc" "${sht237}"
eval "sht265=\"\$F$((FP+NP+0))\""
eval "sht237=\"\$F$((FP+NP+1))\""
eval "sht234=\"\$F$((FP+NP+2))\""
sht266="${R}"
eval "F$((FP+NP+0))=\"\${sht237}\""
eval "F$((FP+NP+1))=\"\${sht234}\""
hp_cons "${sht265}" "${sht266}"
eval "sht237=\"\$F$((FP+NP+0))\""
eval "sht234=\"\$F$((FP+NP+1))\""
sht267="${R}"
R="${sht267}"; ACTION=ret; return
;;
137)
hp_cdr "${p0}"
sht269="${R}"
hp_car "${sht269}"
sht270="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht270}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=139; ACTION=call; return
;;
138)
hp_car "${p0}"
sht299="${R}"
if [ "${sht299}" = "S:substring" ]; then PC=147; else PC=148; fi
ACTION=jump; return
;;
139)
sht271="${R}"
sht272="${sht271}"
hp_cdr "${p0}"
sht273="${R}"
hp_cdr "${sht273}"
sht274="${R}"
hp_car "${sht274}"
sht275="${R}"
hp_car "${sht272}"
sht276="${R}"
hp_cdr "${sht272}"
sht277="${R}"
eval "F$((FP+NP+0))=\"\${sht276}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht275}\""
eval "F$((FP+NP+3))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht277}\""
eval "F$((NFP+1))=\"\${p3}\""
ARGC=2
CALLEE=addlive
RPC=140; ACTION=call; return
;;
140)
eval "sht276=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht275=\"\$F$((FP+NP+2))\""
eval "sht272=\"\$F$((FP+NP+3))\""
sht278="${R}"
eval "F$((FP+NP+0))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht275}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht276}\""
eval "F$((NFP+3))=\"\${sht278}\""
ARGC=4
CALLEE=lval
RPC=141; ACTION=call; return
;;
141)
eval "sht272=\"\$F$((FP+NP+0))\""
sht279="${R}"
sht280="${sht279}"
hp_car "${sht280}"
sht281="${R}"
eval "F$((FP+NP+0))=\"\${sht280}\""
eval "F$((FP+NP+1))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht281}\""
ARGC=1
CALLEE=tmpn
RPC=142; ACTION=call; return
;;
142)
eval "sht280=\"\$F$((FP+NP+0))\""
eval "sht272=\"\$F$((FP+NP+1))\""
sht282="${R}"
sht283="${sht282}"
hp_car "${sht280}"
sht284="${R}"
hp_cdr "${sht272}"
sht285="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht283}\""
eval "F$((FP+NP+2))=\"\${sht284}\""
eval "F$((FP+NP+3))=\"\${sht283}\""
eval "F$((FP+NP+4))=\"\${sht280}\""
eval "F$((FP+NP+5))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht285}\""
ARGC=1
CALLEE=shdet
RPC=143; ACTION=call; return
;;
143)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht283=\"\$F$((FP+NP+1))\""
eval "sht284=\"\$F$((FP+NP+2))\""
eval "sht283=\"\$F$((FP+NP+3))\""
eval "sht280=\"\$F$((FP+NP+4))\""
eval "sht272=\"\$F$((FP+NP+5))\""
sht286="${R}"
hp_cdr "${sht280}"
sht287="${R}"
eval "F$((FP+NP+0))=\"\${sht286}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht283}\""
eval "F$((FP+NP+3))=\"\${sht284}\""
eval "F$((FP+NP+4))=\"\${sht283}\""
eval "F$((FP+NP+5))=\"\${sht280}\""
eval "F$((FP+NP+6))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht287}\""
ARGC=1
CALLEE=shdet
RPC=144; ACTION=call; return
;;
144)
eval "sht286=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht283=\"\$F$((FP+NP+2))\""
eval "sht284=\"\$F$((FP+NP+3))\""
eval "sht283=\"\$F$((FP+NP+4))\""
eval "sht280=\"\$F$((FP+NP+5))\""
eval "sht272=\"\$F$((FP+NP+6))\""
sht288="${R}"
sht289="T:${sht288#??}${G_DQ#??}"
sht290="T:${sht286#??}${sht289#??}"
sht291="T:T:${sht290#??}"
sht292="T:${G_DQ#??}${sht291#??}"
sht293="T:=${sht292#??}"
sht294="T:${sht283#??}${sht293#??}"
eval "F$((FP+NP+0))=\"\${sht283}\""
eval "F$((FP+NP+1))=\"\${sht280}\""
eval "F$((FP+NP+2))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht284}\""
eval "F$((NFP+1))=\"\${sht294}\""
ARGC=2
CALLEE=emit
RPC=145; ACTION=call; return
;;
145)
eval "sht283=\"\$F$((FP+NP+0))\""
eval "sht280=\"\$F$((FP+NP+1))\""
eval "sht272=\"\$F$((FP+NP+2))\""
sht295="${R}"
eval "F$((FP+NP+0))=\"\${sht283}\""
eval "F$((FP+NP+1))=\"\${sht280}\""
eval "F$((FP+NP+2))=\"\${sht272}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht295}\""
ARGC=1
CALLEE=bkzzP
RPC=146; ACTION=call; return
;;
146)
eval "sht283=\"\$F$((FP+NP+0))\""
eval "sht280=\"\$F$((FP+NP+1))\""
eval "sht272=\"\$F$((FP+NP+2))\""
sht296="${R}"
eval "F$((FP+NP+0))=\"\${sht296}\""
eval "F$((FP+NP+1))=\"\${sht283}\""
eval "F$((FP+NP+2))=\"\${sht280}\""
eval "F$((FP+NP+3))=\"\${sht272}\""
hp_cons "S:loc" "${sht283}"
eval "sht296=\"\$F$((FP+NP+0))\""
eval "sht283=\"\$F$((FP+NP+1))\""
eval "sht280=\"\$F$((FP+NP+2))\""
eval "sht272=\"\$F$((FP+NP+3))\""
sht297="${R}"
eval "F$((FP+NP+0))=\"\${sht283}\""
eval "F$((FP+NP+1))=\"\${sht280}\""
eval "F$((FP+NP+2))=\"\${sht272}\""
hp_cons "${sht296}" "${sht297}"
eval "sht283=\"\$F$((FP+NP+0))\""
eval "sht280=\"\$F$((FP+NP+1))\""
eval "sht272=\"\$F$((FP+NP+2))\""
sht298="${R}"
R="${sht298}"; ACTION=ret; return
;;
147)
hp_cdr "${p0}"
sht300="${R}"
hp_car "${sht300}"
sht301="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht301}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=149; ACTION=call; return
;;
148)
hp_car "${p0}"
sht350="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht350}\""
ARGC=1
CALLEE=predzzQ
RPC=163; ACTION=call; return
;;
149)
sht302="${R}"
sht303="${sht302}"
hp_cdr "${p0}"
sht304="${R}"
hp_cdr "${sht304}"
sht305="${R}"
hp_car "${sht305}"
sht306="${R}"
hp_car "${sht303}"
sht307="${R}"
hp_cdr "${sht303}"
sht308="${R}"
eval "F$((FP+NP+0))=\"\${sht307}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht306}\""
eval "F$((FP+NP+3))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht308}\""
eval "F$((NFP+1))=\"\${p3}\""
ARGC=2
CALLEE=addlive
RPC=150; ACTION=call; return
;;
150)
eval "sht307=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht306=\"\$F$((FP+NP+2))\""
eval "sht303=\"\$F$((FP+NP+3))\""
sht309="${R}"
eval "F$((FP+NP+0))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht306}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht307}\""
eval "F$((NFP+3))=\"\${sht309}\""
ARGC=4
CALLEE=lval
RPC=151; ACTION=call; return
;;
151)
eval "sht303=\"\$F$((FP+NP+0))\""
sht310="${R}"
sht311="${sht310}"
eval "F$((FP+NP+0))=\"\${sht311}\""
eval "F$((FP+NP+1))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
ARGC=1
CALLEE=cadddr
RPC=152; ACTION=call; return
;;
152)
eval "sht311=\"\$F$((FP+NP+0))\""
eval "sht303=\"\$F$((FP+NP+1))\""
sht312="${R}"
hp_car "${sht311}"
sht313="${R}"
hp_cdr "${sht311}"
sht314="${R}"
hp_cdr "${sht303}"
sht315="${R}"
eval "F$((FP+NP+0))=\"\${sht314}\""
eval "F$((FP+NP+1))=\"\${sht313}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht312}\""
eval "F$((FP+NP+4))=\"\${sht311}\""
eval "F$((FP+NP+5))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht315}\""
eval "F$((NFP+1))=\"\${p3}\""
ARGC=2
CALLEE=addlive
RPC=153; ACTION=call; return
;;
153)
eval "sht314=\"\$F$((FP+NP+0))\""
eval "sht313=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht312=\"\$F$((FP+NP+3))\""
eval "sht311=\"\$F$((FP+NP+4))\""
eval "sht303=\"\$F$((FP+NP+5))\""
sht316="${R}"
eval "F$((FP+NP+0))=\"\${sht313}\""
eval "F$((FP+NP+1))=\"\${p1}\""
eval "F$((FP+NP+2))=\"\${sht312}\""
eval "F$((FP+NP+3))=\"\${sht311}\""
eval "F$((FP+NP+4))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht314}\""
eval "F$((NFP+1))=\"\${sht316}\""
ARGC=2
CALLEE=addlive
RPC=154; ACTION=call; return
;;
154)
eval "sht313=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht312=\"\$F$((FP+NP+2))\""
eval "sht311=\"\$F$((FP+NP+3))\""
eval "sht303=\"\$F$((FP+NP+4))\""
sht317="${R}"
eval "F$((FP+NP+0))=\"\${sht311}\""
eval "F$((FP+NP+1))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht312}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht313}\""
eval "F$((NFP+3))=\"\${sht317}\""
ARGC=4
CALLEE=lval
RPC=155; ACTION=call; return
;;
155)
eval "sht311=\"\$F$((FP+NP+0))\""
eval "sht303=\"\$F$((FP+NP+1))\""
sht318="${R}"
sht319="${sht318}"
hp_car "${sht319}"
sht320="${R}"
eval "F$((FP+NP+0))=\"\${sht319}\""
eval "F$((FP+NP+1))=\"\${sht311}\""
eval "F$((FP+NP+2))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht320}\""
ARGC=1
CALLEE=tmpn
RPC=156; ACTION=call; return
;;
156)
eval "sht319=\"\$F$((FP+NP+0))\""
eval "sht311=\"\$F$((FP+NP+1))\""
eval "sht303=\"\$F$((FP+NP+2))\""
sht321="${R}"
sht322="${sht321}"
hp_car "${sht319}"
sht323="${R}"
hp_cdr "${sht303}"
sht324="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht322}\""
eval "F$((FP+NP+3))=\"\${sht323}\""
eval "F$((FP+NP+4))=\"\${sht322}\""
eval "F$((FP+NP+5))=\"\${sht319}\""
eval "F$((FP+NP+6))=\"\${sht311}\""
eval "F$((FP+NP+7))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht324}\""
ARGC=1
CALLEE=shdet
RPC=157; ACTION=call; return
;;
157)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht322=\"\$F$((FP+NP+2))\""
eval "sht323=\"\$F$((FP+NP+3))\""
eval "sht322=\"\$F$((FP+NP+4))\""
eval "sht319=\"\$F$((FP+NP+5))\""
eval "sht311=\"\$F$((FP+NP+6))\""
eval "sht303=\"\$F$((FP+NP+7))\""
sht325="${R}"
hp_cdr "${sht311}"
sht326="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht325}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht322}\""
eval "F$((FP+NP+5))=\"\${sht323}\""
eval "F$((FP+NP+6))=\"\${sht322}\""
eval "F$((FP+NP+7))=\"\${sht319}\""
eval "F$((FP+NP+8))=\"\${sht311}\""
eval "F$((FP+NP+9))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht326}\""
ARGC=1
CALLEE=shdet
RPC=158; ACTION=call; return
;;
158)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht325=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht322=\"\$F$((FP+NP+4))\""
eval "sht323=\"\$F$((FP+NP+5))\""
eval "sht322=\"\$F$((FP+NP+6))\""
eval "sht319=\"\$F$((FP+NP+7))\""
eval "sht311=\"\$F$((FP+NP+8))\""
eval "sht303=\"\$F$((FP+NP+9))\""
sht327="${R}"
hp_cdr "${sht311}"
sht328="${R}"
eval "F$((FP+NP+0))=\"\${sht327}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht325}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
eval "F$((FP+NP+5))=\"\${sht322}\""
eval "F$((FP+NP+6))=\"\${sht323}\""
eval "F$((FP+NP+7))=\"\${sht322}\""
eval "F$((FP+NP+8))=\"\${sht319}\""
eval "F$((FP+NP+9))=\"\${sht311}\""
eval "F$((FP+NP+10))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht328}\""
ARGC=1
CALLEE=shdet
RPC=159; ACTION=call; return
;;
159)
eval "sht327=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht325=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
eval "sht322=\"\$F$((FP+NP+5))\""
eval "sht323=\"\$F$((FP+NP+6))\""
eval "sht322=\"\$F$((FP+NP+7))\""
eval "sht319=\"\$F$((FP+NP+8))\""
eval "sht311=\"\$F$((FP+NP+9))\""
eval "sht303=\"\$F$((FP+NP+10))\""
sht329="${R}"
hp_cdr "${sht319}"
sht330="${R}"
eval "F$((FP+NP+0))=\"\${sht329}\""
eval "F$((FP+NP+1))=\"\${sht327}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht325}\""
eval "F$((FP+NP+4))=\"\${G_DQ}\""
eval "F$((FP+NP+5))=\"\${G_DQ}\""
eval "F$((FP+NP+6))=\"\${sht322}\""
eval "F$((FP+NP+7))=\"\${sht323}\""
eval "F$((FP+NP+8))=\"\${sht322}\""
eval "F$((FP+NP+9))=\"\${sht319}\""
eval "F$((FP+NP+10))=\"\${sht311}\""
eval "F$((FP+NP+11))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht330}\""
ARGC=1
CALLEE=shdet
RPC=160; ACTION=call; return
;;
160)
eval "sht329=\"\$F$((FP+NP+0))\""
eval "sht327=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht325=\"\$F$((FP+NP+3))\""
eval "G_DQ=\"\$F$((FP+NP+4))\""
eval "G_DQ=\"\$F$((FP+NP+5))\""
eval "sht322=\"\$F$((FP+NP+6))\""
eval "sht323=\"\$F$((FP+NP+7))\""
eval "sht322=\"\$F$((FP+NP+8))\""
eval "sht319=\"\$F$((FP+NP+9))\""
eval "sht311=\"\$F$((FP+NP+10))\""
eval "sht303=\"\$F$((FP+NP+11))\""
sht331="${R}"
sht332="T: )))${G_DQ#??}"
sht333="T:${sht331#??}${sht332#??}"
sht334="T: + ${sht333#??}"
sht335="T:${sht329#??}${sht334#??}"
sht336="T: + 1 ))-\$(( ${sht335#??}"
sht337="T:${sht327#??}${sht336#??}"
sht338="T: | cut -c\$(( ${sht337#??}"
sht339="T:${G_DQ#??}${sht338#??}"
sht340="T:${sht325#??}${sht339#??}"
sht341="T:${G_DQ#??}${sht340#??}"
sht342="T:T:\$(printf '%s' ${sht341#??}"
sht343="T:${G_DQ#??}${sht342#??}"
sht344="T:=${sht343#??}"
sht345="T:${sht322#??}${sht344#??}"
eval "F$((FP+NP+0))=\"\${sht322}\""
eval "F$((FP+NP+1))=\"\${sht319}\""
eval "F$((FP+NP+2))=\"\${sht311}\""
eval "F$((FP+NP+3))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht323}\""
eval "F$((NFP+1))=\"\${sht345}\""
ARGC=2
CALLEE=emit
RPC=161; ACTION=call; return
;;
161)
eval "sht322=\"\$F$((FP+NP+0))\""
eval "sht319=\"\$F$((FP+NP+1))\""
eval "sht311=\"\$F$((FP+NP+2))\""
eval "sht303=\"\$F$((FP+NP+3))\""
sht346="${R}"
eval "F$((FP+NP+0))=\"\${sht322}\""
eval "F$((FP+NP+1))=\"\${sht319}\""
eval "F$((FP+NP+2))=\"\${sht311}\""
eval "F$((FP+NP+3))=\"\${sht303}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht346}\""
ARGC=1
CALLEE=bkzzP
RPC=162; ACTION=call; return
;;
162)
eval "sht322=\"\$F$((FP+NP+0))\""
eval "sht319=\"\$F$((FP+NP+1))\""
eval "sht311=\"\$F$((FP+NP+2))\""
eval "sht303=\"\$F$((FP+NP+3))\""
sht347="${R}"
eval "F$((FP+NP+0))=\"\${sht347}\""
eval "F$((FP+NP+1))=\"\${sht322}\""
eval "F$((FP+NP+2))=\"\${sht319}\""
eval "F$((FP+NP+3))=\"\${sht311}\""
eval "F$((FP+NP+4))=\"\${sht303}\""
hp_cons "S:loc" "${sht322}"
eval "sht347=\"\$F$((FP+NP+0))\""
eval "sht322=\"\$F$((FP+NP+1))\""
eval "sht319=\"\$F$((FP+NP+2))\""
eval "sht311=\"\$F$((FP+NP+3))\""
eval "sht303=\"\$F$((FP+NP+4))\""
sht348="${R}"
eval "F$((FP+NP+0))=\"\${sht322}\""
eval "F$((FP+NP+1))=\"\${sht319}\""
eval "F$((FP+NP+2))=\"\${sht311}\""
eval "F$((FP+NP+3))=\"\${sht303}\""
hp_cons "${sht347}" "${sht348}"
eval "sht322=\"\$F$((FP+NP+0))\""
eval "sht319=\"\$F$((FP+NP+1))\""
eval "sht311=\"\$F$((FP+NP+2))\""
eval "sht303=\"\$F$((FP+NP+3))\""
sht349="${R}"
R="${sht349}"; ACTION=ret; return
;;
163)
sht351="${R}"
if [ "${sht351}" != NIL ]; then PC=164; else PC=165; fi
ACTION=jump; return
;;
164)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=ctest
RPC=166; ACTION=call; return
;;
165)
hp_car "${p0}"
sht377="${R}"
if [ "${sht377}" = "S:run" ]; then PC=174; else PC=175; fi
ACTION=jump; return
;;
166)
sht352="${R}"
sht353="${sht352}"
hp_car "${sht353}"
sht354="${R}"
eval "F$((FP+NP+0))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht354}\""
ARGC=1
CALLEE=tmpn
RPC=167; ACTION=call; return
;;
167)
eval "sht353=\"\$F$((FP+NP+0))\""
sht355="${R}"
sht356="${sht355}"
hp_car "${sht353}"
sht357="${R}"
hp_cdr "${sht353}"
sht358="${R}"
sht359="T:${sht358#??}; then"
sht360="T:if ${sht359#??}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht357}\""
eval "F$((NFP+1))=\"\${sht360}\""
ARGC=2
CALLEE=emit
RPC=168; ACTION=call; return
;;
168)
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht361="${R}"
sht362="T:S:t${G_DQ#??}"
sht363="T:${G_DQ#??}${sht362#??}"
sht364="T:=${sht363#??}"
sht365="T:${sht356#??}${sht364#??}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht361}\""
eval "F$((NFP+1))=\"\${sht365}\""
ARGC=2
CALLEE=emit
RPC=169; ACTION=call; return
;;
169)
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht366="${R}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht366}\""
STGV="T:else"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=emit
RPC=170; ACTION=call; return
;;
170)
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht367="${R}"
sht368="T:NIL${G_DQ#??}"
sht369="T:${G_DQ#??}${sht368#??}"
sht370="T:=${sht369#??}"
sht371="T:${sht356#??}${sht370#??}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht367}\""
eval "F$((NFP+1))=\"\${sht371}\""
ARGC=2
CALLEE=emit
RPC=171; ACTION=call; return
;;
171)
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht372="${R}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht372}\""
STGV="T:fi"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=emit
RPC=172; ACTION=call; return
;;
172)
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht373="${R}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht373}\""
ARGC=1
CALLEE=bkzzP
RPC=173; ACTION=call; return
;;
173)
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht374="${R}"
eval "F$((FP+NP+0))=\"\${sht374}\""
eval "F$((FP+NP+1))=\"\${sht356}\""
eval "F$((FP+NP+2))=\"\${sht353}\""
hp_cons "S:loc" "${sht356}"
eval "sht374=\"\$F$((FP+NP+0))\""
eval "sht356=\"\$F$((FP+NP+1))\""
eval "sht353=\"\$F$((FP+NP+2))\""
sht375="${R}"
eval "F$((FP+NP+0))=\"\${sht356}\""
eval "F$((FP+NP+1))=\"\${sht353}\""
hp_cons "${sht374}" "${sht375}"
eval "sht356=\"\$F$((FP+NP+0))\""
eval "sht353=\"\$F$((FP+NP+1))\""
sht376="${R}"
R="${sht376}"; ACTION=ret; return
;;
174)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
ARGC=1
CALLEE=tmpn
RPC=176; ACTION=call; return
;;
175)
hp_car "${p0}"
sht395="${R}"
if [ "${sht395}" = "S:run-capture" ]; then PC=182; else PC=183; fi
ACTION=jump; return
;;
176)
sht378="${R}"
sht379="${sht378}"
hp_cdr "${p0}"
sht380="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht379}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht380}\""
ARGC=1
CALLEE=join_toks
RPC=177; ACTION=call; return
;;
177)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht379=\"\$F$((FP+NP+2))\""
sht381="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${p2}\""
eval "F$((FP+NP+2))=\"\${sht379}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht381}\""
ARGC=1
CALLEE=run_esc
RPC=178; ACTION=call; return
;;
178)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "p2=\"\$F$((FP+NP+1))\""
eval "sht379=\"\$F$((FP+NP+2))\""
sht382="${R}"
sht383="T:${sht382#??}${G_DQ#??}"
sht384="T:${G_DQ#??}${sht383#??}"
sht385="T:run_cmd ${sht384#??}"
eval "F$((FP+NP+0))=\"\${sht379}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht385}\""
ARGC=2
CALLEE=emit
RPC=179; ACTION=call; return
;;
179)
eval "sht379=\"\$F$((FP+NP+0))\""
sht386="${R}"
sht387="T:\${R}${G_DQ#??}"
sht388="T:${G_DQ#??}${sht387#??}"
sht389="T:=${sht388#??}"
sht390="T:${sht379#??}${sht389#??}"
eval "F$((FP+NP+0))=\"\${sht379}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht386}\""
eval "F$((NFP+1))=\"\${sht390}\""
ARGC=2
CALLEE=emit
RPC=180; ACTION=call; return
;;
180)
eval "sht379=\"\$F$((FP+NP+0))\""
sht391="${R}"
eval "F$((FP+NP+0))=\"\${sht379}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht391}\""
ARGC=1
CALLEE=bkzzP
RPC=181; ACTION=call; return
;;
181)
eval "sht379=\"\$F$((FP+NP+0))\""
sht392="${R}"
eval "F$((FP+NP+0))=\"\${sht392}\""
eval "F$((FP+NP+1))=\"\${sht379}\""
hp_cons "S:loc" "${sht379}"
eval "sht392=\"\$F$((FP+NP+0))\""
eval "sht379=\"\$F$((FP+NP+1))\""
sht393="${R}"
eval "F$((FP+NP+0))=\"\${sht379}\""
hp_cons "${sht392}" "${sht393}"
eval "sht379=\"\$F$((FP+NP+0))\""
sht394="${R}"
R="${sht394}"; ACTION=ret; return
;;
182)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
ARGC=1
CALLEE=tmpn
RPC=184; ACTION=call; return
;;
183)
hp_car "${p0}"
sht417="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht417}\""
ARGC=1
CALLEE=builtinzzQ
RPC=194; ACTION=call; return
;;
184)
sht396="${R}"
sht397="${sht396}"
eval "F$((FP+NP+0))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=spill
RPC=185; ACTION=call; return
;;
185)
eval "sht397=\"\$F$((FP+NP+0))\""
sht398="${R}"
hp_cdr "${p0}"
sht399="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht398}\""
eval "F$((FP+NP+2))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht399}\""
ARGC=1
CALLEE=join_toks
RPC=186; ACTION=call; return
;;
186)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht398=\"\$F$((FP+NP+1))\""
eval "sht397=\"\$F$((FP+NP+2))\""
sht400="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht398}\""
eval "F$((FP+NP+2))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht400}\""
ARGC=1
CALLEE=run_esc
RPC=187; ACTION=call; return
;;
187)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht398=\"\$F$((FP+NP+1))\""
eval "sht397=\"\$F$((FP+NP+2))\""
sht401="${R}"
sht402="T:${sht401#??}${G_DQ#??}"
sht403="T:${G_DQ#??}${sht402#??}"
sht404="T:run_capture ${sht403#??}"
eval "F$((FP+NP+0))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht398}\""
eval "F$((NFP+1))=\"\${sht404}\""
ARGC=2
CALLEE=emit
RPC=188; ACTION=call; return
;;
188)
eval "sht397=\"\$F$((FP+NP+0))\""
sht405="${R}"
eval "F$((FP+NP+0))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht405}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=unspill
RPC=189; ACTION=call; return
;;
189)
eval "sht397=\"\$F$((FP+NP+0))\""
sht406="${R}"
sht407="T:\${R}${G_DQ#??}"
sht408="T:${G_DQ#??}${sht407#??}"
sht409="T:=${sht408#??}"
sht410="T:${sht397#??}${sht409#??}"
eval "F$((FP+NP+0))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht406}\""
eval "F$((NFP+1))=\"\${sht410}\""
ARGC=2
CALLEE=emit
RPC=190; ACTION=call; return
;;
190)
eval "sht397=\"\$F$((FP+NP+0))\""
sht411="${R}"
eval "F$((FP+NP+0))=\"\${sht411}\""
eval "F$((FP+NP+1))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
ARGC=1
CALLEE=lenl
RPC=191; ACTION=call; return
;;
191)
eval "sht411=\"\$F$((FP+NP+0))\""
eval "sht397=\"\$F$((FP+NP+1))\""
sht412="${R}"
eval "F$((FP+NP+0))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht411}\""
eval "F$((NFP+1))=\"\${sht412}\""
ARGC=2
CALLEE=bsm
RPC=192; ACTION=call; return
;;
192)
eval "sht397=\"\$F$((FP+NP+0))\""
sht413="${R}"
eval "F$((FP+NP+0))=\"\${sht397}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht413}\""
ARGC=1
CALLEE=bkzzP
RPC=193; ACTION=call; return
;;
193)
eval "sht397=\"\$F$((FP+NP+0))\""
sht414="${R}"
eval "F$((FP+NP+0))=\"\${sht414}\""
eval "F$((FP+NP+1))=\"\${sht397}\""
hp_cons "S:loc" "${sht397}"
eval "sht414=\"\$F$((FP+NP+0))\""
eval "sht397=\"\$F$((FP+NP+1))\""
sht415="${R}"
eval "F$((FP+NP+0))=\"\${sht397}\""
hp_cons "${sht414}" "${sht415}"
eval "sht397=\"\$F$((FP+NP+0))\""
sht416="${R}"
R="${sht416}"; ACTION=ret; return
;;
194)
sht418="${R}"
if [ "${sht418}" != NIL ]; then PC=195; else PC=196; fi
ACTION=jump; return
;;
195)
hp_cdr "${p0}"
sht419="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht419}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=largs
RPC=197; ACTION=call; return
;;
196)
hp_car "${p0}"
sht445="${R}"
if [ "${sht445}" = "S:make-closure" ]; then PC=208; else PC=209; fi
ACTION=jump; return
;;
197)
sht420="${R}"
sht421="${sht420}"
hp_car "${p0}"
sht422="${R}"
eval "F$((FP+NP+0))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht422}\""
ARGC=1
CALLEE=brt
RPC=198; ACTION=call; return
;;
198)
eval "sht421=\"\$F$((FP+NP+0))\""
sht423="${R}"
sht424="${sht423}"
hp_car "${sht421}"
sht425="${R}"
eval "F$((FP+NP+0))=\"\${sht424}\""
eval "F$((FP+NP+1))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht425}\""
ARGC=1
CALLEE=tmpn
RPC=199; ACTION=call; return
;;
199)
eval "sht424=\"\$F$((FP+NP+0))\""
eval "sht421=\"\$F$((FP+NP+1))\""
sht426="${R}"
sht427="${sht426}"
hp_car "${sht421}"
sht428="${R}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht428}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=spill
RPC=200; ACTION=call; return
;;
200)
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht429="${R}"
hp_cdr "${sht421}"
sht430="${R}"
eval "F$((FP+NP+0))=\"\${sht424}\""
eval "F$((FP+NP+1))=\"\${sht429}\""
eval "F$((FP+NP+2))=\"\${sht427}\""
eval "F$((FP+NP+3))=\"\${sht424}\""
eval "F$((FP+NP+4))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht430}\""
ARGC=1
CALLEE=bargs
RPC=201; ACTION=call; return
;;
201)
eval "sht424=\"\$F$((FP+NP+0))\""
eval "sht429=\"\$F$((FP+NP+1))\""
eval "sht427=\"\$F$((FP+NP+2))\""
eval "sht424=\"\$F$((FP+NP+3))\""
eval "sht421=\"\$F$((FP+NP+4))\""
sht431="${R}"
sht432="T:${sht424#??}${sht431#??}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht429}\""
eval "F$((NFP+1))=\"\${sht432}\""
ARGC=2
CALLEE=emit
RPC=202; ACTION=call; return
;;
202)
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht433="${R}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht433}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=unspill
RPC=203; ACTION=call; return
;;
203)
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht434="${R}"
sht435="T:\${R}${G_DQ#??}"
sht436="T:${G_DQ#??}${sht435#??}"
sht437="T:=${sht436#??}"
sht438="T:${sht427#??}${sht437#??}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht434}\""
eval "F$((NFP+1))=\"\${sht438}\""
ARGC=2
CALLEE=emit
RPC=204; ACTION=call; return
;;
204)
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht439="${R}"
eval "F$((FP+NP+0))=\"\${sht439}\""
eval "F$((FP+NP+1))=\"\${sht427}\""
eval "F$((FP+NP+2))=\"\${sht424}\""
eval "F$((FP+NP+3))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
ARGC=1
CALLEE=lenl
RPC=205; ACTION=call; return
;;
205)
eval "sht439=\"\$F$((FP+NP+0))\""
eval "sht427=\"\$F$((FP+NP+1))\""
eval "sht424=\"\$F$((FP+NP+2))\""
eval "sht421=\"\$F$((FP+NP+3))\""
sht440="${R}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht439}\""
eval "F$((NFP+1))=\"\${sht440}\""
ARGC=2
CALLEE=bsm
RPC=206; ACTION=call; return
;;
206)
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht441="${R}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht441}\""
ARGC=1
CALLEE=bkzzP
RPC=207; ACTION=call; return
;;
207)
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht442="${R}"
eval "F$((FP+NP+0))=\"\${sht442}\""
eval "F$((FP+NP+1))=\"\${sht427}\""
eval "F$((FP+NP+2))=\"\${sht424}\""
eval "F$((FP+NP+3))=\"\${sht421}\""
hp_cons "S:loc" "${sht427}"
eval "sht442=\"\$F$((FP+NP+0))\""
eval "sht427=\"\$F$((FP+NP+1))\""
eval "sht424=\"\$F$((FP+NP+2))\""
eval "sht421=\"\$F$((FP+NP+3))\""
sht443="${R}"
eval "F$((FP+NP+0))=\"\${sht427}\""
eval "F$((FP+NP+1))=\"\${sht424}\""
eval "F$((FP+NP+2))=\"\${sht421}\""
hp_cons "${sht442}" "${sht443}"
eval "sht427=\"\$F$((FP+NP+0))\""
eval "sht424=\"\$F$((FP+NP+1))\""
eval "sht421=\"\$F$((FP+NP+2))\""
sht444="${R}"
R="${sht444}"; ACTION=ret; return
;;
208)
hp_cdr "${p0}"
sht446="${R}"
hp_car "${sht446}"
sht447="${R}"
hp_cdr "${p0}"
sht448="${R}"
hp_cdr "${sht448}"
sht449="${R}"
eval "F$((FP+NP+0))=\"\${sht447}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht449}\""
ARGC=1
CALLEE=mkclo_caps
RPC=210; ACTION=call; return
;;
209)
hp_car "${p0}"
sht472="${R}"
if [ "${sht472}" = "S:apply" ]; then PC=215; else PC=216; fi
ACTION=jump; return
;;
210)
eval "sht447=\"\$F$((FP+NP+0))\""
sht450="${R}"
eval "F$((FP+NP+0))=\"\${sht447}\""
hp_cons "${sht450}" "NIL"
eval "sht447=\"\$F$((FP+NP+0))\""
sht451="${R}"
hp_cons "${sht447}" "${sht451}"
sht452="${R}"
hp_cons "S:cons" "${sht452}"
sht453="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht453}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=211; ACTION=call; return
;;
211)
sht454="${R}"
sht455="${sht454}"
hp_car "${sht455}"
sht456="${R}"
eval "F$((FP+NP+0))=\"\${sht455}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht456}\""
ARGC=1
CALLEE=tmpn
RPC=212; ACTION=call; return
;;
212)
eval "sht455=\"\$F$((FP+NP+0))\""
sht457="${R}"
sht458="${sht457}"
hp_car "${sht455}"
sht459="${R}"
hp_cdr "${sht455}"
sht460="${R}"
hp_cdr "${sht460}"
sht461="${R}"
sht462="T:#P:}${G_DQ#??}"
sht463="T:${sht461#??}${sht462#??}"
sht464="T:K:\${${sht463#??}"
sht465="T:${G_DQ#??}${sht464#??}"
sht466="T:=${sht465#??}"
sht467="T:${sht458#??}${sht466#??}"
eval "F$((FP+NP+0))=\"\${sht458}\""
eval "F$((FP+NP+1))=\"\${sht455}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht459}\""
eval "F$((NFP+1))=\"\${sht467}\""
ARGC=2
CALLEE=emit
RPC=213; ACTION=call; return
;;
213)
eval "sht458=\"\$F$((FP+NP+0))\""
eval "sht455=\"\$F$((FP+NP+1))\""
sht468="${R}"
eval "F$((FP+NP+0))=\"\${sht458}\""
eval "F$((FP+NP+1))=\"\${sht455}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht468}\""
ARGC=1
CALLEE=bkzzP
RPC=214; ACTION=call; return
;;
214)
eval "sht458=\"\$F$((FP+NP+0))\""
eval "sht455=\"\$F$((FP+NP+1))\""
sht469="${R}"
eval "F$((FP+NP+0))=\"\${sht469}\""
eval "F$((FP+NP+1))=\"\${sht458}\""
eval "F$((FP+NP+2))=\"\${sht455}\""
hp_cons "S:loc" "${sht458}"
eval "sht469=\"\$F$((FP+NP+0))\""
eval "sht458=\"\$F$((FP+NP+1))\""
eval "sht455=\"\$F$((FP+NP+2))\""
sht470="${R}"
eval "F$((FP+NP+0))=\"\${sht458}\""
eval "F$((FP+NP+1))=\"\${sht455}\""
hp_cons "${sht469}" "${sht470}"
eval "sht458=\"\$F$((FP+NP+0))\""
eval "sht455=\"\$F$((FP+NP+1))\""
sht471="${R}"
R="${sht471}"; ACTION=ret; return
;;
215)
hp_cdr "${p0}"
sht473="${R}"
hp_car "${sht473}"
sht474="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht474}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=217; ACTION=call; return
;;
216)
hp_car "${p0}"
sht524="${R}"
if [ "${sht524#S:}" != "${sht524}" ]; then PC=237; else PC=238; fi
ACTION=jump; return
;;
217)
sht475="${R}"
sht476="${sht475}"
hp_cdr "${sht476}"
sht477="${R}"
eval "F$((FP+NP+0))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht477}\""
eval "F$((NFP+1))=\"\${p3}\""
ARGC=2
CALLEE=addlive
RPC=218; ACTION=call; return
;;
218)
eval "sht476=\"\$F$((FP+NP+0))\""
sht478="${R}"
sht479="${sht478}"
hp_cdr "${p0}"
sht480="${R}"
hp_cdr "${sht480}"
sht481="${R}"
hp_car "${sht481}"
sht482="${R}"
hp_car "${sht476}"
sht483="${R}"
eval "F$((FP+NP+0))=\"\${sht479}\""
eval "F$((FP+NP+1))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht482}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht483}\""
eval "F$((NFP+3))=\"\${sht479}\""
ARGC=4
CALLEE=lval
RPC=219; ACTION=call; return
;;
219)
eval "sht479=\"\$F$((FP+NP+0))\""
eval "sht476=\"\$F$((FP+NP+1))\""
sht484="${R}"
sht485="${sht484}"
hp_cdr "${sht485}"
sht486="${R}"
eval "F$((FP+NP+0))=\"\${sht485}\""
eval "F$((FP+NP+1))=\"\${sht479}\""
eval "F$((FP+NP+2))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht486}\""
eval "F$((NFP+1))=\"\${sht479}\""
ARGC=2
CALLEE=addlive
RPC=220; ACTION=call; return
;;
220)
eval "sht485=\"\$F$((FP+NP+0))\""
eval "sht479=\"\$F$((FP+NP+1))\""
eval "sht476=\"\$F$((FP+NP+2))\""
sht487="${R}"
sht488="${sht487}"
hp_car "${sht485}"
sht489="${R}"
eval "F$((FP+NP+0))=\"\${sht488}\""
eval "F$((FP+NP+1))=\"\${sht485}\""
eval "F$((FP+NP+2))=\"\${sht479}\""
eval "F$((FP+NP+3))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht489}\""
ARGC=1
CALLEE=b_npc
RPC=221; ACTION=call; return
;;
221)
eval "sht488=\"\$F$((FP+NP+0))\""
eval "sht485=\"\$F$((FP+NP+1))\""
eval "sht479=\"\$F$((FP+NP+2))\""
eval "sht476=\"\$F$((FP+NP+3))\""
sht490="${R}"
sht491="${sht490}"
hp_car "${sht485}"
sht492="${R}"
eval "F$((FP+NP+0))=\"\${sht491}\""
eval "F$((FP+NP+1))=\"\${sht488}\""
eval "F$((FP+NP+2))=\"\${sht485}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht492}\""
ARGC=1
CALLEE=bnpczzP
RPC=222; ACTION=call; return
;;
222)
eval "sht491=\"\$F$((FP+NP+0))\""
eval "sht488=\"\$F$((FP+NP+1))\""
eval "sht485=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht476=\"\$F$((FP+NP+4))\""
sht493="${R}"
eval "F$((FP+NP+0))=\"\${sht491}\""
eval "F$((FP+NP+1))=\"\${sht488}\""
eval "F$((FP+NP+2))=\"\${sht485}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht493}\""
eval "F$((NFP+1))=\"\${sht488}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=spill
RPC=223; ACTION=call; return
;;
223)
eval "sht491=\"\$F$((FP+NP+0))\""
eval "sht488=\"\$F$((FP+NP+1))\""
eval "sht485=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht476=\"\$F$((FP+NP+4))\""
sht494="${R}"
eval "F$((FP+NP+0))=\"\${sht491}\""
eval "F$((FP+NP+1))=\"\${sht488}\""
eval "F$((FP+NP+2))=\"\${sht485}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht494}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=emit
RPC=224; ACTION=call; return
;;
224)
eval "sht491=\"\$F$((FP+NP+0))\""
eval "sht488=\"\$F$((FP+NP+1))\""
eval "sht485=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht476=\"\$F$((FP+NP+4))\""
sht495="${R}"
hp_cdr "${sht476}"
sht496="${R}"
eval "F$((FP+NP+0))=\"\${sht495}\""
eval "F$((FP+NP+1))=\"\${sht491}\""
eval "F$((FP+NP+2))=\"\${sht488}\""
eval "F$((FP+NP+3))=\"\${sht485}\""
eval "F$((FP+NP+4))=\"\${sht479}\""
eval "F$((FP+NP+5))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht496}\""
ARGC=1
CALLEE=refrhs
RPC=225; ACTION=call; return
;;
225)
eval "sht495=\"\$F$((FP+NP+0))\""
eval "sht491=\"\$F$((FP+NP+1))\""
eval "sht488=\"\$F$((FP+NP+2))\""
eval "sht485=\"\$F$((FP+NP+3))\""
eval "sht479=\"\$F$((FP+NP+4))\""
eval "sht476=\"\$F$((FP+NP+5))\""
sht497="${R}"
sht498="T:CALLEE=${sht497#??}"
eval "F$((FP+NP+0))=\"\${sht491}\""
eval "F$((FP+NP+1))=\"\${sht488}\""
eval "F$((FP+NP+2))=\"\${sht485}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht495}\""
eval "F$((NFP+1))=\"\${sht498}\""
ARGC=2
CALLEE=emit
RPC=226; ACTION=call; return
;;
226)
eval "sht491=\"\$F$((FP+NP+0))\""
eval "sht488=\"\$F$((FP+NP+1))\""
eval "sht485=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht476=\"\$F$((FP+NP+4))\""
sht499="${R}"
hp_cdr "${sht485}"
sht500="${R}"
eval "F$((FP+NP+0))=\"\${sht499}\""
eval "F$((FP+NP+1))=\"\${sht491}\""
eval "F$((FP+NP+2))=\"\${sht488}\""
eval "F$((FP+NP+3))=\"\${sht485}\""
eval "F$((FP+NP+4))=\"\${sht479}\""
eval "F$((FP+NP+5))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht500}\""
ARGC=1
CALLEE=refrhs
RPC=227; ACTION=call; return
;;
227)
eval "sht499=\"\$F$((FP+NP+0))\""
eval "sht491=\"\$F$((FP+NP+1))\""
eval "sht488=\"\$F$((FP+NP+2))\""
eval "sht485=\"\$F$((FP+NP+3))\""
eval "sht479=\"\$F$((FP+NP+4))\""
eval "sht476=\"\$F$((FP+NP+5))\""
sht501="${R}"
sht502="T:APLIST=${sht501#??}"
eval "F$((FP+NP+0))=\"\${sht491}\""
eval "F$((FP+NP+1))=\"\${sht488}\""
eval "F$((FP+NP+2))=\"\${sht485}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht499}\""
eval "F$((NFP+1))=\"\${sht502}\""
ARGC=2
CALLEE=emit
RPC=228; ACTION=call; return
;;
228)
eval "sht491=\"\$F$((FP+NP+0))\""
eval "sht488=\"\$F$((FP+NP+1))\""
eval "sht485=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht476=\"\$F$((FP+NP+4))\""
sht503="${R}"
sht504="T:${sht491#??}"
sht505="T:${sht504#??}; ACTION=apply; return"
sht506="T:RPC=${sht505#??}"
eval "F$((FP+NP+0))=\"\${sht491}\""
eval "F$((FP+NP+1))=\"\${sht488}\""
eval "F$((FP+NP+2))=\"\${sht485}\""
eval "F$((FP+NP+3))=\"\${sht479}\""
eval "F$((FP+NP+4))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht503}\""
eval "F$((NFP+1))=\"\${sht506}\""
ARGC=2
CALLEE=emit
RPC=229; ACTION=call; return
;;
229)
eval "sht491=\"\$F$((FP+NP+0))\""
eval "sht488=\"\$F$((FP+NP+1))\""
eval "sht485=\"\$F$((FP+NP+2))\""
eval "sht479=\"\$F$((FP+NP+3))\""
eval "sht476=\"\$F$((FP+NP+4))\""
sht507="${R}"
sht508="${sht507}"
eval "F$((FP+NP+0))=\"\${sht508}\""
eval "F$((FP+NP+1))=\"\${sht491}\""
eval "F$((FP+NP+2))=\"\${sht488}\""
eval "F$((FP+NP+3))=\"\${sht485}\""
eval "F$((FP+NP+4))=\"\${sht479}\""
eval "F$((FP+NP+5))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht508}\""
eval "F$((NFP+1))=\"\${sht491}\""
ARGC=2
CALLEE=switch
RPC=230; ACTION=call; return
;;
230)
eval "sht508=\"\$F$((FP+NP+0))\""
eval "sht491=\"\$F$((FP+NP+1))\""
eval "sht488=\"\$F$((FP+NP+2))\""
eval "sht485=\"\$F$((FP+NP+3))\""
eval "sht479=\"\$F$((FP+NP+4))\""
eval "sht476=\"\$F$((FP+NP+5))\""
sht509="${R}"
sht510="${sht509}"
eval "F$((FP+NP+0))=\"\${sht510}\""
eval "F$((FP+NP+1))=\"\${sht508}\""
eval "F$((FP+NP+2))=\"\${sht491}\""
eval "F$((FP+NP+3))=\"\${sht488}\""
eval "F$((FP+NP+4))=\"\${sht485}\""
eval "F$((FP+NP+5))=\"\${sht479}\""
eval "F$((FP+NP+6))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht510}\""
ARGC=1
CALLEE=tmpn
RPC=231; ACTION=call; return
;;
231)
eval "sht510=\"\$F$((FP+NP+0))\""
eval "sht508=\"\$F$((FP+NP+1))\""
eval "sht491=\"\$F$((FP+NP+2))\""
eval "sht488=\"\$F$((FP+NP+3))\""
eval "sht485=\"\$F$((FP+NP+4))\""
eval "sht479=\"\$F$((FP+NP+5))\""
eval "sht476=\"\$F$((FP+NP+6))\""
sht511="${R}"
sht512="${sht511}"
eval "F$((FP+NP+0))=\"\${sht512}\""
eval "F$((FP+NP+1))=\"\${sht510}\""
eval "F$((FP+NP+2))=\"\${sht508}\""
eval "F$((FP+NP+3))=\"\${sht491}\""
eval "F$((FP+NP+4))=\"\${sht488}\""
eval "F$((FP+NP+5))=\"\${sht485}\""
eval "F$((FP+NP+6))=\"\${sht479}\""
eval "F$((FP+NP+7))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht510}\""
eval "F$((NFP+1))=\"\${sht488}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=unspill
RPC=232; ACTION=call; return
;;
232)
eval "sht512=\"\$F$((FP+NP+0))\""
eval "sht510=\"\$F$((FP+NP+1))\""
eval "sht508=\"\$F$((FP+NP+2))\""
eval "sht491=\"\$F$((FP+NP+3))\""
eval "sht488=\"\$F$((FP+NP+4))\""
eval "sht485=\"\$F$((FP+NP+5))\""
eval "sht479=\"\$F$((FP+NP+6))\""
eval "sht476=\"\$F$((FP+NP+7))\""
sht513="${R}"
sht514="T:\${R}${G_DQ#??}"
sht515="T:${G_DQ#??}${sht514#??}"
sht516="T:=${sht515#??}"
sht517="T:${sht512#??}${sht516#??}"
eval "F$((FP+NP+0))=\"\${sht512}\""
eval "F$((FP+NP+1))=\"\${sht510}\""
eval "F$((FP+NP+2))=\"\${sht508}\""
eval "F$((FP+NP+3))=\"\${sht491}\""
eval "F$((FP+NP+4))=\"\${sht488}\""
eval "F$((FP+NP+5))=\"\${sht485}\""
eval "F$((FP+NP+6))=\"\${sht479}\""
eval "F$((FP+NP+7))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht513}\""
eval "F$((NFP+1))=\"\${sht517}\""
ARGC=2
CALLEE=emit
RPC=233; ACTION=call; return
;;
233)
eval "sht512=\"\$F$((FP+NP+0))\""
eval "sht510=\"\$F$((FP+NP+1))\""
eval "sht508=\"\$F$((FP+NP+2))\""
eval "sht491=\"\$F$((FP+NP+3))\""
eval "sht488=\"\$F$((FP+NP+4))\""
eval "sht485=\"\$F$((FP+NP+5))\""
eval "sht479=\"\$F$((FP+NP+6))\""
eval "sht476=\"\$F$((FP+NP+7))\""
sht518="${R}"
eval "F$((FP+NP+0))=\"\${sht518}\""
eval "F$((FP+NP+1))=\"\${sht512}\""
eval "F$((FP+NP+2))=\"\${sht510}\""
eval "F$((FP+NP+3))=\"\${sht508}\""
eval "F$((FP+NP+4))=\"\${sht491}\""
eval "F$((FP+NP+5))=\"\${sht488}\""
eval "F$((FP+NP+6))=\"\${sht485}\""
eval "F$((FP+NP+7))=\"\${sht479}\""
eval "F$((FP+NP+8))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht488}\""
ARGC=1
CALLEE=lenl
RPC=234; ACTION=call; return
;;
234)
eval "sht518=\"\$F$((FP+NP+0))\""
eval "sht512=\"\$F$((FP+NP+1))\""
eval "sht510=\"\$F$((FP+NP+2))\""
eval "sht508=\"\$F$((FP+NP+3))\""
eval "sht491=\"\$F$((FP+NP+4))\""
eval "sht488=\"\$F$((FP+NP+5))\""
eval "sht485=\"\$F$((FP+NP+6))\""
eval "sht479=\"\$F$((FP+NP+7))\""
eval "sht476=\"\$F$((FP+NP+8))\""
sht519="${R}"
eval "F$((FP+NP+0))=\"\${sht512}\""
eval "F$((FP+NP+1))=\"\${sht510}\""
eval "F$((FP+NP+2))=\"\${sht508}\""
eval "F$((FP+NP+3))=\"\${sht491}\""
eval "F$((FP+NP+4))=\"\${sht488}\""
eval "F$((FP+NP+5))=\"\${sht485}\""
eval "F$((FP+NP+6))=\"\${sht479}\""
eval "F$((FP+NP+7))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht518}\""
eval "F$((NFP+1))=\"\${sht519}\""
ARGC=2
CALLEE=bsm
RPC=235; ACTION=call; return
;;
235)
eval "sht512=\"\$F$((FP+NP+0))\""
eval "sht510=\"\$F$((FP+NP+1))\""
eval "sht508=\"\$F$((FP+NP+2))\""
eval "sht491=\"\$F$((FP+NP+3))\""
eval "sht488=\"\$F$((FP+NP+4))\""
eval "sht485=\"\$F$((FP+NP+5))\""
eval "sht479=\"\$F$((FP+NP+6))\""
eval "sht476=\"\$F$((FP+NP+7))\""
sht520="${R}"
eval "F$((FP+NP+0))=\"\${sht512}\""
eval "F$((FP+NP+1))=\"\${sht510}\""
eval "F$((FP+NP+2))=\"\${sht508}\""
eval "F$((FP+NP+3))=\"\${sht491}\""
eval "F$((FP+NP+4))=\"\${sht488}\""
eval "F$((FP+NP+5))=\"\${sht485}\""
eval "F$((FP+NP+6))=\"\${sht479}\""
eval "F$((FP+NP+7))=\"\${sht476}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht520}\""
ARGC=1
CALLEE=bkzzP
RPC=236; ACTION=call; return
;;
236)
eval "sht512=\"\$F$((FP+NP+0))\""
eval "sht510=\"\$F$((FP+NP+1))\""
eval "sht508=\"\$F$((FP+NP+2))\""
eval "sht491=\"\$F$((FP+NP+3))\""
eval "sht488=\"\$F$((FP+NP+4))\""
eval "sht485=\"\$F$((FP+NP+5))\""
eval "sht479=\"\$F$((FP+NP+6))\""
eval "sht476=\"\$F$((FP+NP+7))\""
sht521="${R}"
eval "F$((FP+NP+0))=\"\${sht521}\""
eval "F$((FP+NP+1))=\"\${sht512}\""
eval "F$((FP+NP+2))=\"\${sht510}\""
eval "F$((FP+NP+3))=\"\${sht508}\""
eval "F$((FP+NP+4))=\"\${sht491}\""
eval "F$((FP+NP+5))=\"\${sht488}\""
eval "F$((FP+NP+6))=\"\${sht485}\""
eval "F$((FP+NP+7))=\"\${sht479}\""
eval "F$((FP+NP+8))=\"\${sht476}\""
hp_cons "S:loc" "${sht512}"
eval "sht521=\"\$F$((FP+NP+0))\""
eval "sht512=\"\$F$((FP+NP+1))\""
eval "sht510=\"\$F$((FP+NP+2))\""
eval "sht508=\"\$F$((FP+NP+3))\""
eval "sht491=\"\$F$((FP+NP+4))\""
eval "sht488=\"\$F$((FP+NP+5))\""
eval "sht485=\"\$F$((FP+NP+6))\""
eval "sht479=\"\$F$((FP+NP+7))\""
eval "sht476=\"\$F$((FP+NP+8))\""
sht522="${R}"
eval "F$((FP+NP+0))=\"\${sht512}\""
eval "F$((FP+NP+1))=\"\${sht510}\""
eval "F$((FP+NP+2))=\"\${sht508}\""
eval "F$((FP+NP+3))=\"\${sht491}\""
eval "F$((FP+NP+4))=\"\${sht488}\""
eval "F$((FP+NP+5))=\"\${sht485}\""
eval "F$((FP+NP+6))=\"\${sht479}\""
eval "F$((FP+NP+7))=\"\${sht476}\""
hp_cons "${sht521}" "${sht522}"
eval "sht512=\"\$F$((FP+NP+0))\""
eval "sht510=\"\$F$((FP+NP+1))\""
eval "sht508=\"\$F$((FP+NP+2))\""
eval "sht491=\"\$F$((FP+NP+3))\""
eval "sht488=\"\$F$((FP+NP+4))\""
eval "sht485=\"\$F$((FP+NP+5))\""
eval "sht479=\"\$F$((FP+NP+6))\""
eval "sht476=\"\$F$((FP+NP+7))\""
sht523="${R}"
R="${sht523}"; ACTION=ret; return
;;
237)
hp_car "${p0}"
sht526="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht526}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=lookup
RPC=240; ACTION=call; return
;;
238)
sht525="NIL"
PC=239; ACTION=jump; return
;;
239)
if [ "${sht525}" != NIL ]; then PC=241; else PC=242; fi
ACTION=jump; return
;;
240)
sht527="${R}"
if [ "${sht527}" = NIL ]; then
sht528="S:t"
else
sht528="NIL"
fi
sht525="${sht528}"
PC=239; ACTION=jump; return
;;
241)
hp_cdr "${p0}"
sht529="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht529}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=largs
RPC=243; ACTION=call; return
;;
242)
hp_car "${p0}"
sht576="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht576}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=265; ACTION=call; return
;;
243)
sht530="${R}"
sht531="${sht530}"
hp_car "${sht531}"
sht532="${R}"
eval "F$((FP+NP+0))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht532}\""
ARGC=1
CALLEE=b_npc
RPC=244; ACTION=call; return
;;
244)
eval "sht531=\"\$F$((FP+NP+0))\""
sht533="${R}"
sht534="${sht533}"
hp_car "${p0}"
sht535="${R}"
eval "F$((FP+NP+0))=\"\${sht535}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
STGV="S:__gvars"
eval "F$((NFP+0))=\"\$STGV\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=lookup
RPC=245; ACTION=call; return
;;
245)
eval "sht535=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht536="${R}"
eval "F$((FP+NP+0))=\"\${sht534}\""
eval "F$((FP+NP+1))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht535}\""
eval "F$((NFP+1))=\"\${sht536}\""
ARGC=2
CALLEE=memzzQ
RPC=246; ACTION=call; return
;;
246)
eval "sht534=\"\$F$((FP+NP+0))\""
eval "sht531=\"\$F$((FP+NP+1))\""
sht537="${R}"
if [ "${sht537}" != NIL ]; then PC=247; else PC=248; fi
ACTION=jump; return
;;
247)
hp_car "${p0}"
sht539="${R}"
sht540="T:${sht539#??}"
eval "F$((FP+NP+0))=\"\${sht534}\""
eval "F$((FP+NP+1))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht540}\""
ARGC=1
CALLEE=sh_mangle
RPC=250; ACTION=call; return
;;
248)
hp_car "${p0}"
sht544="${R}"
sht545="T:${sht544#??}"
eval "F$((FP+NP+0))=\"\${sht534}\""
eval "F$((FP+NP+1))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht545}\""
ARGC=1
CALLEE=sh_mangle
RPC=251; ACTION=call; return
;;
249)
sht548="${sht538}"
hp_car "${sht531}"
sht549="${R}"
eval "F$((FP+NP+0))=\"\${sht548}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht549}\""
ARGC=1
CALLEE=bnpczzP
RPC=252; ACTION=call; return
;;
250)
eval "sht534=\"\$F$((FP+NP+0))\""
eval "sht531=\"\$F$((FP+NP+1))\""
sht541="${R}"
sht542="T:${sht541#??}}"
sht543="T:CALLEE=\${G_${sht542#??}"
sht538="${sht543}"
PC=249; ACTION=jump; return
;;
251)
eval "sht534=\"\$F$((FP+NP+0))\""
eval "sht531=\"\$F$((FP+NP+1))\""
sht546="${R}"
sht547="T:CALLEE=${sht546#??}"
sht538="${sht547}"
PC=249; ACTION=jump; return
;;
252)
eval "sht548=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht550="${R}"
eval "F$((FP+NP+0))=\"\${sht548}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht550}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=spill
RPC=253; ACTION=call; return
;;
253)
eval "sht548=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht551="${R}"
eval "F$((FP+NP+0))=\"\${sht548}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht551}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=emit
RPC=254; ACTION=call; return
;;
254)
eval "sht548=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht552="${R}"
hp_cdr "${sht531}"
sht553="${R}"
eval "F$((FP+NP+0))=\"\${sht548}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht552}\""
eval "F$((NFP+1))=\"\${sht553}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=stage
RPC=255; ACTION=call; return
;;
255)
eval "sht548=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht554="${R}"
eval "F$((FP+NP+0))=\"\${sht548}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht554}\""
eval "F$((NFP+1))=\"\${sht548}\""
ARGC=2
CALLEE=emit
RPC=256; ACTION=call; return
;;
256)
eval "sht548=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht555="${R}"
sht556="T:${sht534#??}"
sht557="T:${sht556#??}; ACTION=call; return"
sht558="T:RPC=${sht557#??}"
eval "F$((FP+NP+0))=\"\${sht548}\""
eval "F$((FP+NP+1))=\"\${sht534}\""
eval "F$((FP+NP+2))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht555}\""
eval "F$((NFP+1))=\"\${sht558}\""
ARGC=2
CALLEE=emit
RPC=257; ACTION=call; return
;;
257)
eval "sht548=\"\$F$((FP+NP+0))\""
eval "sht534=\"\$F$((FP+NP+1))\""
eval "sht531=\"\$F$((FP+NP+2))\""
sht559="${R}"
sht560="${sht559}"
eval "F$((FP+NP+0))=\"\${sht560}\""
eval "F$((FP+NP+1))=\"\${sht548}\""
eval "F$((FP+NP+2))=\"\${sht534}\""
eval "F$((FP+NP+3))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht560}\""
eval "F$((NFP+1))=\"\${sht534}\""
ARGC=2
CALLEE=switch
RPC=258; ACTION=call; return
;;
258)
eval "sht560=\"\$F$((FP+NP+0))\""
eval "sht548=\"\$F$((FP+NP+1))\""
eval "sht534=\"\$F$((FP+NP+2))\""
eval "sht531=\"\$F$((FP+NP+3))\""
sht561="${R}"
sht562="${sht561}"
eval "F$((FP+NP+0))=\"\${sht562}\""
eval "F$((FP+NP+1))=\"\${sht560}\""
eval "F$((FP+NP+2))=\"\${sht548}\""
eval "F$((FP+NP+3))=\"\${sht534}\""
eval "F$((FP+NP+4))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht562}\""
ARGC=1
CALLEE=tmpn
RPC=259; ACTION=call; return
;;
259)
eval "sht562=\"\$F$((FP+NP+0))\""
eval "sht560=\"\$F$((FP+NP+1))\""
eval "sht548=\"\$F$((FP+NP+2))\""
eval "sht534=\"\$F$((FP+NP+3))\""
eval "sht531=\"\$F$((FP+NP+4))\""
sht563="${R}"
sht564="${sht563}"
eval "F$((FP+NP+0))=\"\${sht564}\""
eval "F$((FP+NP+1))=\"\${sht562}\""
eval "F$((FP+NP+2))=\"\${sht560}\""
eval "F$((FP+NP+3))=\"\${sht548}\""
eval "F$((FP+NP+4))=\"\${sht534}\""
eval "F$((FP+NP+5))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht562}\""
eval "F$((NFP+1))=\"\${p3}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=unspill
RPC=260; ACTION=call; return
;;
260)
eval "sht564=\"\$F$((FP+NP+0))\""
eval "sht562=\"\$F$((FP+NP+1))\""
eval "sht560=\"\$F$((FP+NP+2))\""
eval "sht548=\"\$F$((FP+NP+3))\""
eval "sht534=\"\$F$((FP+NP+4))\""
eval "sht531=\"\$F$((FP+NP+5))\""
sht565="${R}"
sht566="T:\${R}${G_DQ#??}"
sht567="T:${G_DQ#??}${sht566#??}"
sht568="T:=${sht567#??}"
sht569="T:${sht564#??}${sht568#??}"
eval "F$((FP+NP+0))=\"\${sht564}\""
eval "F$((FP+NP+1))=\"\${sht562}\""
eval "F$((FP+NP+2))=\"\${sht560}\""
eval "F$((FP+NP+3))=\"\${sht548}\""
eval "F$((FP+NP+4))=\"\${sht534}\""
eval "F$((FP+NP+5))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht565}\""
eval "F$((NFP+1))=\"\${sht569}\""
ARGC=2
CALLEE=emit
RPC=261; ACTION=call; return
;;
261)
eval "sht564=\"\$F$((FP+NP+0))\""
eval "sht562=\"\$F$((FP+NP+1))\""
eval "sht560=\"\$F$((FP+NP+2))\""
eval "sht548=\"\$F$((FP+NP+3))\""
eval "sht534=\"\$F$((FP+NP+4))\""
eval "sht531=\"\$F$((FP+NP+5))\""
sht570="${R}"
eval "F$((FP+NP+0))=\"\${sht570}\""
eval "F$((FP+NP+1))=\"\${sht564}\""
eval "F$((FP+NP+2))=\"\${sht562}\""
eval "F$((FP+NP+3))=\"\${sht560}\""
eval "F$((FP+NP+4))=\"\${sht548}\""
eval "F$((FP+NP+5))=\"\${sht534}\""
eval "F$((FP+NP+6))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
ARGC=1
CALLEE=lenl
RPC=262; ACTION=call; return
;;
262)
eval "sht570=\"\$F$((FP+NP+0))\""
eval "sht564=\"\$F$((FP+NP+1))\""
eval "sht562=\"\$F$((FP+NP+2))\""
eval "sht560=\"\$F$((FP+NP+3))\""
eval "sht548=\"\$F$((FP+NP+4))\""
eval "sht534=\"\$F$((FP+NP+5))\""
eval "sht531=\"\$F$((FP+NP+6))\""
sht571="${R}"
eval "F$((FP+NP+0))=\"\${sht564}\""
eval "F$((FP+NP+1))=\"\${sht562}\""
eval "F$((FP+NP+2))=\"\${sht560}\""
eval "F$((FP+NP+3))=\"\${sht548}\""
eval "F$((FP+NP+4))=\"\${sht534}\""
eval "F$((FP+NP+5))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht570}\""
eval "F$((NFP+1))=\"\${sht571}\""
ARGC=2
CALLEE=bsm
RPC=263; ACTION=call; return
;;
263)
eval "sht564=\"\$F$((FP+NP+0))\""
eval "sht562=\"\$F$((FP+NP+1))\""
eval "sht560=\"\$F$((FP+NP+2))\""
eval "sht548=\"\$F$((FP+NP+3))\""
eval "sht534=\"\$F$((FP+NP+4))\""
eval "sht531=\"\$F$((FP+NP+5))\""
sht572="${R}"
eval "F$((FP+NP+0))=\"\${sht564}\""
eval "F$((FP+NP+1))=\"\${sht562}\""
eval "F$((FP+NP+2))=\"\${sht560}\""
eval "F$((FP+NP+3))=\"\${sht548}\""
eval "F$((FP+NP+4))=\"\${sht534}\""
eval "F$((FP+NP+5))=\"\${sht531}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht572}\""
ARGC=1
CALLEE=bkzzP
RPC=264; ACTION=call; return
;;
264)
eval "sht564=\"\$F$((FP+NP+0))\""
eval "sht562=\"\$F$((FP+NP+1))\""
eval "sht560=\"\$F$((FP+NP+2))\""
eval "sht548=\"\$F$((FP+NP+3))\""
eval "sht534=\"\$F$((FP+NP+4))\""
eval "sht531=\"\$F$((FP+NP+5))\""
sht573="${R}"
eval "F$((FP+NP+0))=\"\${sht573}\""
eval "F$((FP+NP+1))=\"\${sht564}\""
eval "F$((FP+NP+2))=\"\${sht562}\""
eval "F$((FP+NP+3))=\"\${sht560}\""
eval "F$((FP+NP+4))=\"\${sht548}\""
eval "F$((FP+NP+5))=\"\${sht534}\""
eval "F$((FP+NP+6))=\"\${sht531}\""
hp_cons "S:loc" "${sht564}"
eval "sht573=\"\$F$((FP+NP+0))\""
eval "sht564=\"\$F$((FP+NP+1))\""
eval "sht562=\"\$F$((FP+NP+2))\""
eval "sht560=\"\$F$((FP+NP+3))\""
eval "sht548=\"\$F$((FP+NP+4))\""
eval "sht534=\"\$F$((FP+NP+5))\""
eval "sht531=\"\$F$((FP+NP+6))\""
sht574="${R}"
eval "F$((FP+NP+0))=\"\${sht564}\""
eval "F$((FP+NP+1))=\"\${sht562}\""
eval "F$((FP+NP+2))=\"\${sht560}\""
eval "F$((FP+NP+3))=\"\${sht548}\""
eval "F$((FP+NP+4))=\"\${sht534}\""
eval "F$((FP+NP+5))=\"\${sht531}\""
hp_cons "${sht573}" "${sht574}"
eval "sht564=\"\$F$((FP+NP+0))\""
eval "sht562=\"\$F$((FP+NP+1))\""
eval "sht560=\"\$F$((FP+NP+2))\""
eval "sht548=\"\$F$((FP+NP+3))\""
eval "sht534=\"\$F$((FP+NP+4))\""
eval "sht531=\"\$F$((FP+NP+5))\""
sht575="${R}"
R="${sht575}"; ACTION=ret; return
;;
265)
sht577="${R}"
sht578="${sht577}"
hp_cdr "${sht578}"
sht579="${R}"
hp_cdr "${sht579}"
sht580="${R}"
sht581="${sht580}"
hp_cdr "${sht578}"
sht582="${R}"
eval "F$((FP+NP+0))=\"\${sht581}\""
eval "F$((FP+NP+1))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht582}\""
eval "F$((NFP+1))=\"\${p3}\""
ARGC=2
CALLEE=addlive
RPC=266; ACTION=call; return
;;
266)
eval "sht581=\"\$F$((FP+NP+0))\""
eval "sht578=\"\$F$((FP+NP+1))\""
sht583="${R}"
sht584="${sht583}"
hp_cdr "${p0}"
sht585="${R}"
hp_car "${sht578}"
sht586="${R}"
eval "F$((FP+NP+0))=\"\${sht584}\""
eval "F$((FP+NP+1))=\"\${sht581}\""
eval "F$((FP+NP+2))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht585}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht586}\""
eval "F$((NFP+3))=\"\${sht584}\""
ARGC=4
CALLEE=largs
RPC=267; ACTION=call; return
;;
267)
eval "sht584=\"\$F$((FP+NP+0))\""
eval "sht581=\"\$F$((FP+NP+1))\""
eval "sht578=\"\$F$((FP+NP+2))\""
sht587="${R}"
sht588="${sht587}"
hp_car "${sht588}"
sht589="${R}"
eval "F$((FP+NP+0))=\"\${sht588}\""
eval "F$((FP+NP+1))=\"\${sht584}\""
eval "F$((FP+NP+2))=\"\${sht581}\""
eval "F$((FP+NP+3))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht589}\""
ARGC=1
CALLEE=b_npc
RPC=268; ACTION=call; return
;;
268)
eval "sht588=\"\$F$((FP+NP+0))\""
eval "sht584=\"\$F$((FP+NP+1))\""
eval "sht581=\"\$F$((FP+NP+2))\""
eval "sht578=\"\$F$((FP+NP+3))\""
sht590="${R}"
sht591="${sht590}"
hp_car "${sht588}"
sht592="${R}"
eval "F$((FP+NP+0))=\"\${sht591}\""
eval "F$((FP+NP+1))=\"\${sht588}\""
eval "F$((FP+NP+2))=\"\${sht584}\""
eval "F$((FP+NP+3))=\"\${sht581}\""
eval "F$((FP+NP+4))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht592}\""
ARGC=1
CALLEE=bnpczzP
RPC=269; ACTION=call; return
;;
269)
eval "sht591=\"\$F$((FP+NP+0))\""
eval "sht588=\"\$F$((FP+NP+1))\""
eval "sht584=\"\$F$((FP+NP+2))\""
eval "sht581=\"\$F$((FP+NP+3))\""
eval "sht578=\"\$F$((FP+NP+4))\""
sht593="${R}"
eval "F$((FP+NP+0))=\"\${sht591}\""
eval "F$((FP+NP+1))=\"\${sht588}\""
eval "F$((FP+NP+2))=\"\${sht584}\""
eval "F$((FP+NP+3))=\"\${sht581}\""
eval "F$((FP+NP+4))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht593}\""
eval "F$((NFP+1))=\"\${sht584}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=spill
RPC=270; ACTION=call; return
;;
270)
eval "sht591=\"\$F$((FP+NP+0))\""
eval "sht588=\"\$F$((FP+NP+1))\""
eval "sht584=\"\$F$((FP+NP+2))\""
eval "sht581=\"\$F$((FP+NP+3))\""
eval "sht578=\"\$F$((FP+NP+4))\""
sht594="${R}"
eval "F$((FP+NP+0))=\"\${sht591}\""
eval "F$((FP+NP+1))=\"\${sht588}\""
eval "F$((FP+NP+2))=\"\${sht584}\""
eval "F$((FP+NP+3))=\"\${sht581}\""
eval "F$((FP+NP+4))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht594}\""
STGV="T:NFP=\$FTOP"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=emit
RPC=271; ACTION=call; return
;;
271)
eval "sht591=\"\$F$((FP+NP+0))\""
eval "sht588=\"\$F$((FP+NP+1))\""
eval "sht584=\"\$F$((FP+NP+2))\""
eval "sht581=\"\$F$((FP+NP+3))\""
eval "sht578=\"\$F$((FP+NP+4))\""
sht595="${R}"
hp_cdr "${sht588}"
sht596="${R}"
eval "F$((FP+NP+0))=\"\${sht591}\""
eval "F$((FP+NP+1))=\"\${sht588}\""
eval "F$((FP+NP+2))=\"\${sht584}\""
eval "F$((FP+NP+3))=\"\${sht581}\""
eval "F$((FP+NP+4))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht595}\""
eval "F$((NFP+1))=\"\${sht596}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=stage
RPC=272; ACTION=call; return
;;
272)
eval "sht591=\"\$F$((FP+NP+0))\""
eval "sht588=\"\$F$((FP+NP+1))\""
eval "sht584=\"\$F$((FP+NP+2))\""
eval "sht581=\"\$F$((FP+NP+3))\""
eval "sht578=\"\$F$((FP+NP+4))\""
sht597="${R}"
sht598="T:${sht581#??}}"
sht599="T:CALLEE=\${${sht598#??}"
eval "F$((FP+NP+0))=\"\${sht591}\""
eval "F$((FP+NP+1))=\"\${sht588}\""
eval "F$((FP+NP+2))=\"\${sht584}\""
eval "F$((FP+NP+3))=\"\${sht581}\""
eval "F$((FP+NP+4))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht597}\""
eval "F$((NFP+1))=\"\${sht599}\""
ARGC=2
CALLEE=emit
RPC=273; ACTION=call; return
;;
273)
eval "sht591=\"\$F$((FP+NP+0))\""
eval "sht588=\"\$F$((FP+NP+1))\""
eval "sht584=\"\$F$((FP+NP+2))\""
eval "sht581=\"\$F$((FP+NP+3))\""
eval "sht578=\"\$F$((FP+NP+4))\""
sht600="${R}"
sht601="T:${sht591#??}"
sht602="T:${sht601#??}; ACTION=call; return"
sht603="T:RPC=${sht602#??}"
eval "F$((FP+NP+0))=\"\${sht591}\""
eval "F$((FP+NP+1))=\"\${sht588}\""
eval "F$((FP+NP+2))=\"\${sht584}\""
eval "F$((FP+NP+3))=\"\${sht581}\""
eval "F$((FP+NP+4))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht600}\""
eval "F$((NFP+1))=\"\${sht603}\""
ARGC=2
CALLEE=emit
RPC=274; ACTION=call; return
;;
274)
eval "sht591=\"\$F$((FP+NP+0))\""
eval "sht588=\"\$F$((FP+NP+1))\""
eval "sht584=\"\$F$((FP+NP+2))\""
eval "sht581=\"\$F$((FP+NP+3))\""
eval "sht578=\"\$F$((FP+NP+4))\""
sht604="${R}"
sht605="${sht604}"
eval "F$((FP+NP+0))=\"\${sht605}\""
eval "F$((FP+NP+1))=\"\${sht591}\""
eval "F$((FP+NP+2))=\"\${sht588}\""
eval "F$((FP+NP+3))=\"\${sht584}\""
eval "F$((FP+NP+4))=\"\${sht581}\""
eval "F$((FP+NP+5))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht605}\""
eval "F$((NFP+1))=\"\${sht591}\""
ARGC=2
CALLEE=switch
RPC=275; ACTION=call; return
;;
275)
eval "sht605=\"\$F$((FP+NP+0))\""
eval "sht591=\"\$F$((FP+NP+1))\""
eval "sht588=\"\$F$((FP+NP+2))\""
eval "sht584=\"\$F$((FP+NP+3))\""
eval "sht581=\"\$F$((FP+NP+4))\""
eval "sht578=\"\$F$((FP+NP+5))\""
sht606="${R}"
sht607="${sht606}"
eval "F$((FP+NP+0))=\"\${sht607}\""
eval "F$((FP+NP+1))=\"\${sht605}\""
eval "F$((FP+NP+2))=\"\${sht591}\""
eval "F$((FP+NP+3))=\"\${sht588}\""
eval "F$((FP+NP+4))=\"\${sht584}\""
eval "F$((FP+NP+5))=\"\${sht581}\""
eval "F$((FP+NP+6))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht607}\""
ARGC=1
CALLEE=tmpn
RPC=276; ACTION=call; return
;;
276)
eval "sht607=\"\$F$((FP+NP+0))\""
eval "sht605=\"\$F$((FP+NP+1))\""
eval "sht591=\"\$F$((FP+NP+2))\""
eval "sht588=\"\$F$((FP+NP+3))\""
eval "sht584=\"\$F$((FP+NP+4))\""
eval "sht581=\"\$F$((FP+NP+5))\""
eval "sht578=\"\$F$((FP+NP+6))\""
sht608="${R}"
sht609="${sht608}"
eval "F$((FP+NP+0))=\"\${sht609}\""
eval "F$((FP+NP+1))=\"\${sht607}\""
eval "F$((FP+NP+2))=\"\${sht605}\""
eval "F$((FP+NP+3))=\"\${sht591}\""
eval "F$((FP+NP+4))=\"\${sht588}\""
eval "F$((FP+NP+5))=\"\${sht584}\""
eval "F$((FP+NP+6))=\"\${sht581}\""
eval "F$((FP+NP+7))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht607}\""
eval "F$((NFP+1))=\"\${sht584}\""
eval "F$((NFP+2))=\"I:0\""
ARGC=3
CALLEE=unspill
RPC=277; ACTION=call; return
;;
277)
eval "sht609=\"\$F$((FP+NP+0))\""
eval "sht607=\"\$F$((FP+NP+1))\""
eval "sht605=\"\$F$((FP+NP+2))\""
eval "sht591=\"\$F$((FP+NP+3))\""
eval "sht588=\"\$F$((FP+NP+4))\""
eval "sht584=\"\$F$((FP+NP+5))\""
eval "sht581=\"\$F$((FP+NP+6))\""
eval "sht578=\"\$F$((FP+NP+7))\""
sht610="${R}"
sht611="T:\${R}${G_DQ#??}"
sht612="T:${G_DQ#??}${sht611#??}"
sht613="T:=${sht612#??}"
sht614="T:${sht609#??}${sht613#??}"
eval "F$((FP+NP+0))=\"\${sht609}\""
eval "F$((FP+NP+1))=\"\${sht607}\""
eval "F$((FP+NP+2))=\"\${sht605}\""
eval "F$((FP+NP+3))=\"\${sht591}\""
eval "F$((FP+NP+4))=\"\${sht588}\""
eval "F$((FP+NP+5))=\"\${sht584}\""
eval "F$((FP+NP+6))=\"\${sht581}\""
eval "F$((FP+NP+7))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht610}\""
eval "F$((NFP+1))=\"\${sht614}\""
ARGC=2
CALLEE=emit
RPC=278; ACTION=call; return
;;
278)
eval "sht609=\"\$F$((FP+NP+0))\""
eval "sht607=\"\$F$((FP+NP+1))\""
eval "sht605=\"\$F$((FP+NP+2))\""
eval "sht591=\"\$F$((FP+NP+3))\""
eval "sht588=\"\$F$((FP+NP+4))\""
eval "sht584=\"\$F$((FP+NP+5))\""
eval "sht581=\"\$F$((FP+NP+6))\""
eval "sht578=\"\$F$((FP+NP+7))\""
sht615="${R}"
eval "F$((FP+NP+0))=\"\${sht615}\""
eval "F$((FP+NP+1))=\"\${sht609}\""
eval "F$((FP+NP+2))=\"\${sht607}\""
eval "F$((FP+NP+3))=\"\${sht605}\""
eval "F$((FP+NP+4))=\"\${sht591}\""
eval "F$((FP+NP+5))=\"\${sht588}\""
eval "F$((FP+NP+6))=\"\${sht584}\""
eval "F$((FP+NP+7))=\"\${sht581}\""
eval "F$((FP+NP+8))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht584}\""
ARGC=1
CALLEE=lenl
RPC=279; ACTION=call; return
;;
279)
eval "sht615=\"\$F$((FP+NP+0))\""
eval "sht609=\"\$F$((FP+NP+1))\""
eval "sht607=\"\$F$((FP+NP+2))\""
eval "sht605=\"\$F$((FP+NP+3))\""
eval "sht591=\"\$F$((FP+NP+4))\""
eval "sht588=\"\$F$((FP+NP+5))\""
eval "sht584=\"\$F$((FP+NP+6))\""
eval "sht581=\"\$F$((FP+NP+7))\""
eval "sht578=\"\$F$((FP+NP+8))\""
sht616="${R}"
eval "F$((FP+NP+0))=\"\${sht609}\""
eval "F$((FP+NP+1))=\"\${sht607}\""
eval "F$((FP+NP+2))=\"\${sht605}\""
eval "F$((FP+NP+3))=\"\${sht591}\""
eval "F$((FP+NP+4))=\"\${sht588}\""
eval "F$((FP+NP+5))=\"\${sht584}\""
eval "F$((FP+NP+6))=\"\${sht581}\""
eval "F$((FP+NP+7))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht615}\""
eval "F$((NFP+1))=\"\${sht616}\""
ARGC=2
CALLEE=bsm
RPC=280; ACTION=call; return
;;
280)
eval "sht609=\"\$F$((FP+NP+0))\""
eval "sht607=\"\$F$((FP+NP+1))\""
eval "sht605=\"\$F$((FP+NP+2))\""
eval "sht591=\"\$F$((FP+NP+3))\""
eval "sht588=\"\$F$((FP+NP+4))\""
eval "sht584=\"\$F$((FP+NP+5))\""
eval "sht581=\"\$F$((FP+NP+6))\""
eval "sht578=\"\$F$((FP+NP+7))\""
sht617="${R}"
eval "F$((FP+NP+0))=\"\${sht609}\""
eval "F$((FP+NP+1))=\"\${sht607}\""
eval "F$((FP+NP+2))=\"\${sht605}\""
eval "F$((FP+NP+3))=\"\${sht591}\""
eval "F$((FP+NP+4))=\"\${sht588}\""
eval "F$((FP+NP+5))=\"\${sht584}\""
eval "F$((FP+NP+6))=\"\${sht581}\""
eval "F$((FP+NP+7))=\"\${sht578}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht617}\""
ARGC=1
CALLEE=bkzzP
RPC=281; ACTION=call; return
;;
281)
eval "sht609=\"\$F$((FP+NP+0))\""
eval "sht607=\"\$F$((FP+NP+1))\""
eval "sht605=\"\$F$((FP+NP+2))\""
eval "sht591=\"\$F$((FP+NP+3))\""
eval "sht588=\"\$F$((FP+NP+4))\""
eval "sht584=\"\$F$((FP+NP+5))\""
eval "sht581=\"\$F$((FP+NP+6))\""
eval "sht578=\"\$F$((FP+NP+7))\""
sht618="${R}"
eval "F$((FP+NP+0))=\"\${sht618}\""
eval "F$((FP+NP+1))=\"\${sht609}\""
eval "F$((FP+NP+2))=\"\${sht607}\""
eval "F$((FP+NP+3))=\"\${sht605}\""
eval "F$((FP+NP+4))=\"\${sht591}\""
eval "F$((FP+NP+5))=\"\${sht588}\""
eval "F$((FP+NP+6))=\"\${sht584}\""
eval "F$((FP+NP+7))=\"\${sht581}\""
eval "F$((FP+NP+8))=\"\${sht578}\""
hp_cons "S:loc" "${sht609}"
eval "sht618=\"\$F$((FP+NP+0))\""
eval "sht609=\"\$F$((FP+NP+1))\""
eval "sht607=\"\$F$((FP+NP+2))\""
eval "sht605=\"\$F$((FP+NP+3))\""
eval "sht591=\"\$F$((FP+NP+4))\""
eval "sht588=\"\$F$((FP+NP+5))\""
eval "sht584=\"\$F$((FP+NP+6))\""
eval "sht581=\"\$F$((FP+NP+7))\""
eval "sht578=\"\$F$((FP+NP+8))\""
sht619="${R}"
eval "F$((FP+NP+0))=\"\${sht609}\""
eval "F$((FP+NP+1))=\"\${sht607}\""
eval "F$((FP+NP+2))=\"\${sht605}\""
eval "F$((FP+NP+3))=\"\${sht591}\""
eval "F$((FP+NP+4))=\"\${sht588}\""
eval "F$((FP+NP+5))=\"\${sht584}\""
eval "F$((FP+NP+6))=\"\${sht581}\""
eval "F$((FP+NP+7))=\"\${sht578}\""
hp_cons "${sht618}" "${sht619}"
eval "sht609=\"\$F$((FP+NP+0))\""
eval "sht607=\"\$F$((FP+NP+1))\""
eval "sht605=\"\$F$((FP+NP+2))\""
eval "sht591=\"\$F$((FP+NP+3))\""
eval "sht588=\"\$F$((FP+NP+4))\""
eval "sht584=\"\$F$((FP+NP+5))\""
eval "sht581=\"\$F$((FP+NP+6))\""
eval "sht578=\"\$F$((FP+NP+7))\""
sht620="${R}"
R="${sht620}"; ACTION=ret; return
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
ARGC=0
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
ARGC=0
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
ARGC=0
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
ARGC=1
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
ARGC=4
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
ARGC=4
CALLEE=sh_esc_go
RPC=1; ACTION=call; return
;;
1)
sht1="${R}"
R="${sht1}"; ACTION=ret; return
;;
esac; }
SIZE_tok_text=1
tok_text() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_tok_text))
NP=1
case $PC in
0)
if [ "${p0#S:}" != "${p0}" ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
sht0="T:${p0#??}"
R="${sht0}"; ACTION=ret; return
;;
2)
if [ "${p0#T:}" != "${p0}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
R="${p0}"; ACTION=ret; return
;;
4)
if [ "${p0#I:}" != "${p0}" ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
sht1="T:${p0#??}"
R="${sht1}"; ACTION=ret; return
;;
6)
R="T:"; ACTION=ret; return
;;
esac; }
SIZE_join_toks=2
join_toks() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_join_toks))
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
ARGC=1
CALLEE=tok_text
RPC=3; ACTION=call; return
;;
3)
sht1="${R}"
hp_cdr "${p0}"
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht2}\""
ARGC=1
CALLEE=join_toks
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
SIZE_run_esc_at=2
run_esc_at() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_run_esc_at))
NP=1
case $PC in
0)
NFP=$FTOP
ARGC=0
CALLEE=bsl
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
if [ "${p0}" = "${sht0}" ]; then PC=2; else PC=3; fi
ACTION=jump; return
;;
2)
NFP=$FTOP
ARGC=0
CALLEE=bsl
RPC=4; ACTION=call; return
;;
3)
if [ "${p0}" = "T:\$" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
4)
sht1="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
NFP=$FTOP
ARGC=0
CALLEE=bsl
RPC=5; ACTION=call; return
;;
5)
eval "sht1=\"\$F$((FP+NP+0))\""
sht2="${R}"
sht3="T:${sht1#??}${sht2#??}"
R="${sht3}"; ACTION=ret; return
;;
6)
R="T:\\\$"; ACTION=ret; return
;;
7)
if [ "${p0}" = "${G_DQ}" ]; then PC=8; else PC=9; fi
ACTION=jump; return
;;
8)
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=10; ACTION=call; return
;;
9)
R="${p0}"; ACTION=ret; return
;;
10)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_run_esc_go=8
run_esc_go() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
FTOP=$((FP + SIZE_run_esc_go))
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
ARGC=1
CALLEE=run_esc_at
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
ARGC=4
PC=0; ACTION=tail; return
;;
esac; }
SIZE_run_esc=1
run_esc() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_run_esc))
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
ARGC=4
CALLEE=run_esc_go
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=2
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
ARGC=1
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
ARGC=1
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
ARGC=4
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
ARGC=4
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
ARGC=4
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
ARGC=4
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
ARGC=4
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
ARGC=1
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
ARGC=1
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
ARGC=2
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
ARGC=1
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
ARGC=4
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
ARGC=4
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
ARGC=4
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
ARGC=4
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=4
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=4
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=6
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
ARGC=4
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
ARGC=6
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=4
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
ARGC=1
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
ARGC=1
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
ARGC=2
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
ARGC=1
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
ARGC=1
CALLEE=cmpchzzQ
RPC=4; ACTION=call; return
;;
2)
sht0="NIL"
PC=3; ACTION=jump; return
;;
3)
if [ "${sht0}" != NIL ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
4)
sht2="${R}"
if [ "${sht2}" != NIL ]; then PC=5; else PC=6; fi
ACTION=jump; return
;;
5)
hp_cdr "${p0}"
sht4="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht4}\""
ARGC=1
CALLEE=extra_argszzQ
RPC=8; ACTION=call; return
;;
6)
sht3="NIL"
PC=7; ACTION=jump; return
;;
7)
sht0="${sht3}"
PC=3; ACTION=jump; return
;;
8)
sht5="${R}"
sht3="${sht5}"
PC=7; ACTION=jump; return
;;
9)
hp_car "${p0}"
sht6="${R}"
hp_cdr "${p0}"
sht7="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"\${sht7}\""
ARGC=2
CALLEE=chain_zzGand
RPC=11; ACTION=call; return
;;
10)
if [ "${p0#P:}" != "${p0}" ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
11)
sht8="${R}"
eval "F$((FP+0))=\"\${sht8}\""
eval "F$((FP+1))=\"\${p1}\""
eval "F$((FP+2))=\"\${p2}\""
eval "F$((FP+3))=\"\${p3}\""
ARGC=4
PC=0; ACTION=tail; return
;;
12)
hp_car "${p0}"
sht10="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
ARGC=1
CALLEE=predzzQ
RPC=15; ACTION=call; return
;;
13)
sht9="NIL"
PC=14; ACTION=jump; return
;;
14)
if [ "${sht9}" != NIL ]; then PC=16; else PC=17; fi
ACTION=jump; return
;;
15)
sht11="${R}"
sht9="${sht11}"
PC=14; ACTION=jump; return
;;
16)
hp_car "${p0}"
sht12="${R}"
if [ "${sht12}" = "S:null?" ]; then PC=18; else PC=19; fi
ACTION=jump; return
;;
17)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=53; ACTION=call; return
;;
18)
hp_cdr "${p0}"
sht13="${R}"
hp_car "${sht13}"
sht14="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=20; ACTION=call; return
;;
19)
hp_car "${p0}"
sht25="${R}"
if [ "${sht25}" = "S:eq?" ]; then PC=22; else PC=23; fi
ACTION=jump; return
;;
20)
sht15="${R}"
sht16="${sht15}"
hp_car "${sht16}"
sht17="${R}"
hp_cdr "${sht16}"
sht18="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht17}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
ARGC=1
CALLEE=shval
RPC=21; ACTION=call; return
;;
21)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht17=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
sht19="${R}"
sht20="T:${G_DQ#??} = NIL ]"
sht21="T:${sht19#??}${sht20#??}"
sht22="T:${G_DQ#??}${sht21#??}"
sht23="T:[ ${sht22#??}"
eval "F$((FP+NP+0))=\"\${sht16}\""
hp_cons "${sht17}" "${sht23}"
eval "sht16=\"\$F$((FP+NP+0))\""
sht24="${R}"
R="${sht24}"; ACTION=ret; return
;;
22)
hp_cdr "${p0}"
sht26="${R}"
hp_car "${sht26}"
sht27="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht27}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=24; ACTION=call; return
;;
23)
hp_car "${p0}"
sht50="${R}"
if [ "${sht50}" = "S:pair?" ]; then PC=28; else PC=29; fi
ACTION=jump; return
;;
24)
sht28="${R}"
sht29="${sht28}"
hp_cdr "${p0}"
sht30="${R}"
hp_cdr "${sht30}"
sht31="${R}"
hp_car "${sht31}"
sht32="${R}"
hp_car "${sht29}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht33}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=25; ACTION=call; return
;;
25)
eval "sht29=\"\$F$((FP+NP+0))\""
sht34="${R}"
sht35="${sht34}"
hp_car "${sht35}"
sht36="${R}"
hp_cdr "${sht29}"
sht37="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht36}\""
eval "F$((FP+NP+2))=\"\${sht35}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht37}\""
ARGC=1
CALLEE=shval
RPC=26; ACTION=call; return
;;
26)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht36=\"\$F$((FP+NP+1))\""
eval "sht35=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
sht38="${R}"
hp_cdr "${sht35}"
sht39="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht38}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht36}\""
eval "F$((FP+NP+5))=\"\${sht35}\""
eval "F$((FP+NP+6))=\"\${sht29}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
ARGC=1
CALLEE=shval
RPC=27; ACTION=call; return
;;
27)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht38=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht36=\"\$F$((FP+NP+4))\""
eval "sht35=\"\$F$((FP+NP+5))\""
eval "sht29=\"\$F$((FP+NP+6))\""
sht40="${R}"
sht41="T:${G_DQ#??} ]"
sht42="T:${sht40#??}${sht41#??}"
sht43="T:${G_DQ#??}${sht42#??}"
sht44="T: = ${sht43#??}"
sht45="T:${G_DQ#??}${sht44#??}"
sht46="T:${sht38#??}${sht45#??}"
sht47="T:${G_DQ#??}${sht46#??}"
sht48="T:[ ${sht47#??}"
eval "F$((FP+NP+0))=\"\${sht35}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
hp_cons "${sht36}" "${sht48}"
eval "sht35=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
sht49="${R}"
R="${sht49}"; ACTION=ret; return
;;
28)
hp_cdr "${p0}"
sht51="${R}"
hp_car "${sht51}"
sht52="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht52}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=30; ACTION=call; return
;;
29)
hp_car "${p0}"
sht59="${R}"
if [ "${sht59}" = "S:atom?" ]; then PC=32; else PC=33; fi
ACTION=jump; return
;;
30)
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
ARGC=2
CALLEE=tagtest
RPC=31; ACTION=call; return
;;
31)
eval "sht55=\"\$F$((FP+NP+0))\""
eval "sht54=\"\$F$((FP+NP+1))\""
sht57="${R}"
eval "F$((FP+NP+0))=\"\${sht54}\""
hp_cons "${sht55}" "${sht57}"
eval "sht54=\"\$F$((FP+NP+0))\""
sht58="${R}"
R="${sht58}"; ACTION=ret; return
;;
32)
hp_cdr "${p0}"
sht60="${R}"
hp_car "${sht60}"
sht61="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht61}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=34; ACTION=call; return
;;
33)
hp_car "${p0}"
sht68="${R}"
if [ "${sht68}" = "S:number?" ]; then PC=36; else PC=37; fi
ACTION=jump; return
;;
34)
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
STGV="T:P:"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=natagtest
RPC=35; ACTION=call; return
;;
35)
eval "sht64=\"\$F$((FP+NP+0))\""
eval "sht63=\"\$F$((FP+NP+1))\""
sht66="${R}"
eval "F$((FP+NP+0))=\"\${sht63}\""
hp_cons "${sht64}" "${sht66}"
eval "sht63=\"\$F$((FP+NP+0))\""
sht67="${R}"
R="${sht67}"; ACTION=ret; return
;;
36)
hp_cdr "${p0}"
sht69="${R}"
hp_car "${sht69}"
sht70="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht70}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=38; ACTION=call; return
;;
37)
hp_car "${p0}"
sht77="${R}"
if [ "${sht77}" = "S:string?" ]; then PC=40; else PC=41; fi
ACTION=jump; return
;;
38)
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
STGV="T:I:"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=tagtest
RPC=39; ACTION=call; return
;;
39)
eval "sht73=\"\$F$((FP+NP+0))\""
eval "sht72=\"\$F$((FP+NP+1))\""
sht75="${R}"
eval "F$((FP+NP+0))=\"\${sht72}\""
hp_cons "${sht73}" "${sht75}"
eval "sht72=\"\$F$((FP+NP+0))\""
sht76="${R}"
R="${sht76}"; ACTION=ret; return
;;
40)
hp_cdr "${p0}"
sht78="${R}"
hp_car "${sht78}"
sht79="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht79}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=42; ACTION=call; return
;;
41)
hp_car "${p0}"
sht86="${R}"
if [ "${sht86}" = "S:symbol?" ]; then PC=44; else PC=45; fi
ACTION=jump; return
;;
42)
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
STGV="T:T:"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=tagtest
RPC=43; ACTION=call; return
;;
43)
eval "sht82=\"\$F$((FP+NP+0))\""
eval "sht81=\"\$F$((FP+NP+1))\""
sht84="${R}"
eval "F$((FP+NP+0))=\"\${sht81}\""
hp_cons "${sht82}" "${sht84}"
eval "sht81=\"\$F$((FP+NP+0))\""
sht85="${R}"
R="${sht85}"; ACTION=ret; return
;;
44)
hp_cdr "${p0}"
sht87="${R}"
hp_car "${sht87}"
sht88="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht88}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=46; ACTION=call; return
;;
45)
hp_cdr "${p0}"
sht95="${R}"
hp_car "${sht95}"
sht96="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht96}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p2}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=48; ACTION=call; return
;;
46)
sht89="${R}"
sht90="${sht89}"
hp_car "${sht90}"
sht91="${R}"
hp_cdr "${sht90}"
sht92="${R}"
eval "F$((FP+NP+0))=\"\${sht91}\""
eval "F$((FP+NP+1))=\"\${sht90}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht92}\""
STGV="T:S:"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=tagtest
RPC=47; ACTION=call; return
;;
47)
eval "sht91=\"\$F$((FP+NP+0))\""
eval "sht90=\"\$F$((FP+NP+1))\""
sht93="${R}"
eval "F$((FP+NP+0))=\"\${sht90}\""
hp_cons "${sht91}" "${sht93}"
eval "sht90=\"\$F$((FP+NP+0))\""
sht94="${R}"
R="${sht94}"; ACTION=ret; return
;;
48)
sht97="${R}"
sht98="${sht97}"
hp_cdr "${p0}"
sht99="${R}"
hp_cdr "${sht99}"
sht100="${R}"
hp_car "${sht100}"
sht101="${R}"
hp_car "${sht98}"
sht102="${R}"
eval "F$((FP+NP+0))=\"\${sht98}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht101}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${sht102}\""
eval "F$((NFP+3))=\"\${p3}\""
ARGC=4
CALLEE=lval
RPC=49; ACTION=call; return
;;
49)
eval "sht98=\"\$F$((FP+NP+0))\""
sht103="${R}"
sht104="${sht103}"
hp_car "${sht104}"
sht105="${R}"
hp_cdr "${sht98}"
sht106="${R}"
eval "F$((FP+NP+0))=\"\${sht105}\""
eval "F$((FP+NP+1))=\"\${sht104}\""
eval "F$((FP+NP+2))=\"\${sht98}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht106}\""
ARGC=1
CALLEE=shdet
RPC=50; ACTION=call; return
;;
50)
eval "sht105=\"\$F$((FP+NP+0))\""
eval "sht104=\"\$F$((FP+NP+1))\""
eval "sht98=\"\$F$((FP+NP+2))\""
sht107="${R}"
hp_car "${p0}"
sht108="${R}"
eval "F$((FP+NP+0))=\"\${sht107}\""
eval "F$((FP+NP+1))=\"\${sht105}\""
eval "F$((FP+NP+2))=\"\${sht104}\""
eval "F$((FP+NP+3))=\"\${sht98}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht108}\""
ARGC=1
CALLEE=shcmp
RPC=51; ACTION=call; return
;;
51)
eval "sht107=\"\$F$((FP+NP+0))\""
eval "sht105=\"\$F$((FP+NP+1))\""
eval "sht104=\"\$F$((FP+NP+2))\""
eval "sht98=\"\$F$((FP+NP+3))\""
sht109="${R}"
hp_cdr "${sht104}"
sht110="${R}"
eval "F$((FP+NP+0))=\"\${sht109}\""
eval "F$((FP+NP+1))=\"\${sht107}\""
eval "F$((FP+NP+2))=\"\${sht105}\""
eval "F$((FP+NP+3))=\"\${sht104}\""
eval "F$((FP+NP+4))=\"\${sht98}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht110}\""
ARGC=1
CALLEE=shdet
RPC=52; ACTION=call; return
;;
52)
eval "sht109=\"\$F$((FP+NP+0))\""
eval "sht107=\"\$F$((FP+NP+1))\""
eval "sht105=\"\$F$((FP+NP+2))\""
eval "sht104=\"\$F$((FP+NP+3))\""
eval "sht98=\"\$F$((FP+NP+4))\""
sht111="${R}"
sht112="T:${sht111#??} ]"
sht113="T: ${sht112#??}"
sht114="T:${sht109#??}${sht113#??}"
sht115="T: ${sht114#??}"
sht116="T:${sht107#??}${sht115#??}"
sht117="T:[ ${sht116#??}"
eval "F$((FP+NP+0))=\"\${sht104}\""
eval "F$((FP+NP+1))=\"\${sht98}\""
hp_cons "${sht105}" "${sht117}"
eval "sht104=\"\$F$((FP+NP+0))\""
eval "sht98=\"\$F$((FP+NP+1))\""
sht118="${R}"
R="${sht118}"; ACTION=ret; return
;;
53)
sht119="${R}"
sht120="${sht119}"
hp_car "${sht120}"
sht121="${R}"
hp_cdr "${sht120}"
sht122="${R}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht121}\""
eval "F$((FP+NP+2))=\"\${sht120}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht122}\""
ARGC=1
CALLEE=shval
RPC=54; ACTION=call; return
;;
54)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht121=\"\$F$((FP+NP+1))\""
eval "sht120=\"\$F$((FP+NP+2))\""
sht123="${R}"
sht124="T:${G_DQ#??} != NIL ]"
sht125="T:${sht123#??}${sht124#??}"
sht126="T:${G_DQ#??}${sht125#??}"
sht127="T:[ ${sht126#??}"
eval "F$((FP+NP+0))=\"\${sht120}\""
hp_cons "${sht121}" "${sht127}"
eval "sht120=\"\$F$((FP+NP+0))\""
sht128="${R}"
R="${sht128}"; ACTION=ret; return
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
ARGC=4
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
ARGC=1
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
ARGC=1
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=6
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
ARGC=1
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
ARGC=2
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
ARGC=6
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
ARGC=1
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
ARGC=6
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
ARGC=1
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
ARGC=6
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
ARGC=1
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
ARGC=6
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
ARGC=1
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
ARGC=6
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
ARGC=1
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
ARGC=6
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
ARGC=2
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
ARGC=6
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
ARGC=2
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
ARGC=6
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
ARGC=2
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
ARGC=6
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
ARGC=2
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
ARGC=6
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
ARGC=6
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
ARGC=4
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
ARGC=6
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
ARGC=4
CALLEE=largs
RPC=87; ACTION=call; return
;;
86)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p1}\""
eval "F$((NFP+2))=\"\${p4}\""
eval "F$((NFP+3))=\"\${p5}\""
ARGC=4
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
ARGC=3
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
ARGC=2
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
ARGC=1
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
ARGC=2
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
ARGC=2
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
ARGC=0
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
ARGC=0
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=2
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
ARGC=3
CALLEE=caseblocks
RPC=5; ACTION=call; return
;;
5)
eval "sht5=\"\$F$((FP+NP+0))\""
sht7="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${sht7}\""
ARGC=2
CALLEE=append
RPC=6; ACTION=call; return
;;
6)
sht8="${R}"
R="${sht8}"; ACTION=ret; return
;;
esac; }
SIZE_va_collect_sh=5
va_collect_sh() {
FTOP=$((FP + SIZE_va_collect_sh))
NP=0
case $PC in
0)
sht0="T:${G_DQ#??} = 0 ]; then"
sht1="T:\$PC${sht0#??}"
sht2="T:${G_DQ#??}${sht1#??}"
sht3="T:if [ ${sht2#??}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=1; ACTION=call; return
;;
1)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${G_DQ}\""
eval "F$((FP+NP+3))=\"\${G_DQ}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=2; ACTION=call; return
;;
2)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "G_DQ=\"\$F$((FP+NP+2))\""
eval "G_DQ=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
sht5="${R}"
sht6="T:${G_DQ#??}; _vl=\$R; done"
sht7="T:\$_vl${sht6#??}"
sht8="T:${G_DQ#??}${sht7#??}"
sht9="T: ${sht8#??}"
sht10="T:${G_DQ#??}${sht9#??}"
sht11="T:\$_vv${sht10#??}"
sht12="T:${G_DQ#??}${sht11#??}"
sht13="T:; hp_cons ${sht12#??}"
sht14="T:${G_DQ#??}${sht13#??}"
sht15="T:${sht5#??}${sht14#??}"
sht16="T:\\\$F\$((FP+_vi))${sht15#??}"
sht17="T:${sht4#??}${sht16#??}"
sht18="T:_vv=${sht17#??}"
sht19="T:${G_DQ#??}${sht18#??}"
sht20="T: -gt 0 ]; do _vi=\$((_vi-1)); eval ${sht19#??}"
sht21="T:${G_DQ#??}${sht20#??}"
sht22="T:\$_vi${sht21#??}"
sht23="T:${G_DQ#??}${sht22#??}"
sht24="T:while [ ${sht23#??}"
eval "F$((FP+NP+0))=\"\${G_DQ}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=3; ACTION=call; return
;;
3)
eval "G_DQ=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht25="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${G_DQ}\""
eval "F$((FP+NP+2))=\"\${sht24}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
NFP=$FTOP
ARGC=0
CALLEE=eqt
RPC=4; ACTION=call; return
;;
4)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "G_DQ=\"\$F$((FP+NP+1))\""
eval "sht24=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
sht26="${R}"
sht27="T:${sht26#??}${G_DQ#??}"
sht28="T:\\\$_vl${sht27#??}"
sht29="T:${sht25#??}${sht28#??}"
sht30="T:F\$FP=${sht29#??}"
sht31="T:${G_DQ#??}${sht30#??}"
sht32="T:eval ${sht31#??}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht24}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
hp_cons "T:fi" "NIL"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht24=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht24}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
hp_cons "${sht32}" "${sht33}"
eval "sht24=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
hp_cons "${sht24}" "${sht34}"
eval "sht3=\"\$F$((FP+NP+0))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
hp_cons "T:_vi=\$ARGC; _vl=NIL" "${sht35}"
eval "sht3=\"\$F$((FP+NP+0))\""
sht36="${R}"
hp_cons "${sht3}" "${sht36}"
sht37="${R}"
R="${sht37}"; ACTION=ret; return
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
ARGC=1
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
ARGC=2
CALLEE=cap_loads_go
RPC=3; ACTION=call; return
;;
3)
eval "sht18=\"\$F$((FP+NP+0))\""
sht21="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
eval "F$((NFP+1))=\"\${sht21}\""
ARGC=2
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
ARGC=2
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
SIZE_compile_clambda=19
compile_clambda() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
eval "p5=\"\$F$((FP+5))\""
FTOP=$((FP + SIZE_compile_clambda))
NP=6
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=fs_list
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
ARGC=1
CALLEE=lenl
RPC=2; ACTION=call; return
;;
2)
sht1="${R}"
sht2="${sht1}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "S:__gfns" "${p4}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "S:__gvars" "${p5}"
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=fs_list
RPC=3; ACTION=call; return
;;
3)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"\${p2}\""
ARGC=2
CALLEE=append
RPC=4; ACTION=call; return
;;
4)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=pmap_fr
RPC=5; ACTION=call; return
;;
5)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht4}" "${sht7}"
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht8="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht3}" "${sht8}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht9="${R}"
sht10="${sht9}"
sht11="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${sht10}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht11}\""
ARGC=1
CALLEE=sh_mangle
RPC=6; ACTION=call; return
;;
6)
eval "sht10=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht12="${R}"
sht13="${sht12}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${p3}\""
eval "F$((FP+NP+4))=\"\${sht13}\""
eval "F$((FP+NP+5))=\"\${sht10}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
ARGC=6
CALLEE=mkb
RPC=7; ACTION=call; return
;;
7)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "p3=\"\$F$((FP+NP+3))\""
eval "sht13=\"\$F$((FP+NP+4))\""
eval "sht10=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht10}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht10}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht2}\""
eval "F$((NFP+4))=\"\${sht14}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
ARGC=6
CALLEE=ltail
RPC=8; ACTION=call; return
;;
8)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht10=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht15="${R}"
sht16="${sht15}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
ARGC=1
CALLEE=b_pc
RPC=9; ACTION=call; return
;;
9)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht13}\""
eval "F$((FP+NP+3))=\"\${sht10}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
ARGC=1
CALLEE=b_cur
RPC=10; ACTION=call; return
;;
10)
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht13=\"\$F$((FP+NP+2))\""
eval "sht10=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht13}\""
eval "F$((FP+NP+3))=\"\${sht10}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht18}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=rev
RPC=11; ACTION=call; return
;;
11)
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht13=\"\$F$((FP+NP+2))\""
eval "sht10=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
hp_cons "${sht17}" "${sht19}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht20}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht13}\""
eval "F$((FP+NP+3))=\"\${sht10}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
ARGC=1
CALLEE=b_blk
RPC=12; ACTION=call; return
;;
12)
eval "sht20=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht13=\"\$F$((FP+NP+2))\""
eval "sht10=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht21="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht13}\""
eval "F$((FP+NP+2))=\"\${sht10}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
hp_cons "${sht20}" "${sht21}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht13=\"\$F$((FP+NP+1))\""
eval "sht10=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht22="${R}"
sht23="${sht22}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht23}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht13}\""
eval "F$((FP+NP+4))=\"\${sht10}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
ARGC=1
CALLEE=b_smax
RPC=13; ACTION=call; return
;;
13)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht23=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht13=\"\$F$((FP+NP+3))\""
eval "sht10=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht24="${R}"
sht25="I:$(( ${sht2#??} + ${sht24#??} ))"
sht26="${sht25}"
sht27="T:${sht26#??}"
sht28="T:=${sht27#??}"
sht29="T:${sht13#??}${sht28#??}"
sht30="T:SIZE_${sht29#??}"
sht31="T:${sht13#??}() {"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht13}\""
eval "F$((FP+NP+6))=\"\${sht10}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=varargszzQ
RPC=14; ACTION=call; return
;;
14)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht13=\"\$F$((FP+NP+5))\""
eval "sht10=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht32="${R}"
if [ "${sht32}" != NIL ]; then PC=15; else PC=16; fi
ACTION=jump; return
;;
15)
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht13}\""
eval "F$((FP+NP+6))=\"\${sht10}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
ARGC=0
CALLEE=va_collect_sh
RPC=18; ACTION=call; return
;;
16)
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht13}\""
eval "F$((FP+NP+6))=\"\${sht10}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=ploads
RPC=22; ACTION=call; return
;;
17)
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht13}\""
eval "F$((FP+NP+7))=\"\${sht10}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht2}\""
ARGC=2
CALLEE=cap_loads
RPC=23; ACTION=call; return
;;
18)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht13=\"\$F$((FP+NP+5))\""
eval "sht10=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht34}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht13}\""
eval "F$((FP+NP+7))=\"\${sht10}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=fs_list
RPC=19; ACTION=call; return
;;
19)
eval "sht34=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht13=\"\$F$((FP+NP+6))\""
eval "sht10=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht34}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht13}\""
eval "F$((FP+NP+7))=\"\${sht10}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht35}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=ploads
RPC=20; ACTION=call; return
;;
20)
eval "sht34=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht13=\"\$F$((FP+NP+6))\""
eval "sht10=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht13}\""
eval "F$((FP+NP+6))=\"\${sht10}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${sht36}\""
ARGC=2
CALLEE=append
RPC=21; ACTION=call; return
;;
21)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht13=\"\$F$((FP+NP+5))\""
eval "sht10=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht37="${R}"
sht33="${sht37}"
PC=17; ACTION=jump; return
;;
22)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht13=\"\$F$((FP+NP+5))\""
eval "sht10=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht38="${R}"
sht33="${sht38}"
PC=17; ACTION=jump; return
;;
23)
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht13=\"\$F$((FP+NP+6))\""
eval "sht10=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht39="${R}"
sht40="T:${sht13#??}))"
sht41="T:FTOP=\$((FP + SIZE_${sht40#??}"
sht42="T:${sht2#??}"
sht43="T:NP=${sht42#??}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht43}\""
eval "F$((FP+NP+2))=\"\${sht41}\""
eval "F$((FP+NP+3))=\"\${sht39}\""
eval "F$((FP+NP+4))=\"\${sht33}\""
eval "F$((FP+NP+5))=\"\${sht31}\""
eval "F$((FP+NP+6))=\"\${sht30}\""
eval "F$((FP+NP+7))=\"\${sht26}\""
eval "F$((FP+NP+8))=\"\${sht23}\""
eval "F$((FP+NP+9))=\"\${sht16}\""
eval "F$((FP+NP+10))=\"\${sht13}\""
eval "F$((FP+NP+11))=\"\${sht10}\""
eval "F$((FP+NP+12))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht16}\""
ARGC=1
CALLEE=b_npc
RPC=24; ACTION=call; return
;;
24)
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht43=\"\$F$((FP+NP+1))\""
eval "sht41=\"\$F$((FP+NP+2))\""
eval "sht39=\"\$F$((FP+NP+3))\""
eval "sht33=\"\$F$((FP+NP+4))\""
eval "sht31=\"\$F$((FP+NP+5))\""
eval "sht30=\"\$F$((FP+NP+6))\""
eval "sht26=\"\$F$((FP+NP+7))\""
eval "sht23=\"\$F$((FP+NP+8))\""
eval "sht16=\"\$F$((FP+NP+9))\""
eval "sht13=\"\$F$((FP+NP+10))\""
eval "sht10=\"\$F$((FP+NP+11))\""
eval "sht2=\"\$F$((FP+NP+12))\""
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht43}\""
eval "F$((FP+NP+1))=\"\${sht41}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
eval "F$((FP+NP+5))=\"\${sht30}\""
eval "F$((FP+NP+6))=\"\${sht26}\""
eval "F$((FP+NP+7))=\"\${sht23}\""
eval "F$((FP+NP+8))=\"\${sht16}\""
eval "F$((FP+NP+9))=\"\${sht13}\""
eval "F$((FP+NP+10))=\"\${sht10}\""
eval "F$((FP+NP+11))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht44}\""
ARGC=3
CALLEE=caseblocks
RPC=25; ACTION=call; return
;;
25)
eval "sht43=\"\$F$((FP+NP+0))\""
eval "sht41=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
eval "sht30=\"\$F$((FP+NP+5))\""
eval "sht26=\"\$F$((FP+NP+6))\""
eval "sht23=\"\$F$((FP+NP+7))\""
eval "sht16=\"\$F$((FP+NP+8))\""
eval "sht13=\"\$F$((FP+NP+9))\""
eval "sht10=\"\$F$((FP+NP+10))\""
eval "sht2=\"\$F$((FP+NP+11))\""
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht43}\""
eval "F$((FP+NP+1))=\"\${sht41}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht31}\""
eval "F$((FP+NP+5))=\"\${sht30}\""
eval "F$((FP+NP+6))=\"\${sht26}\""
eval "F$((FP+NP+7))=\"\${sht23}\""
eval "F$((FP+NP+8))=\"\${sht16}\""
eval "F$((FP+NP+9))=\"\${sht13}\""
eval "F$((FP+NP+10))=\"\${sht10}\""
eval "F$((FP+NP+11))=\"\${sht2}\""
hp_cons "T:case \$PC in" "${sht45}"
eval "sht43=\"\$F$((FP+NP+0))\""
eval "sht41=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht31=\"\$F$((FP+NP+4))\""
eval "sht30=\"\$F$((FP+NP+5))\""
eval "sht26=\"\$F$((FP+NP+6))\""
eval "sht23=\"\$F$((FP+NP+7))\""
eval "sht16=\"\$F$((FP+NP+8))\""
eval "sht13=\"\$F$((FP+NP+9))\""
eval "sht10=\"\$F$((FP+NP+10))\""
eval "sht2=\"\$F$((FP+NP+11))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht41}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht31}\""
eval "F$((FP+NP+4))=\"\${sht30}\""
eval "F$((FP+NP+5))=\"\${sht26}\""
eval "F$((FP+NP+6))=\"\${sht23}\""
eval "F$((FP+NP+7))=\"\${sht16}\""
eval "F$((FP+NP+8))=\"\${sht13}\""
eval "F$((FP+NP+9))=\"\${sht10}\""
eval "F$((FP+NP+10))=\"\${sht2}\""
hp_cons "${sht43}" "${sht46}"
eval "sht41=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht31=\"\$F$((FP+NP+3))\""
eval "sht30=\"\$F$((FP+NP+4))\""
eval "sht26=\"\$F$((FP+NP+5))\""
eval "sht23=\"\$F$((FP+NP+6))\""
eval "sht16=\"\$F$((FP+NP+7))\""
eval "sht13=\"\$F$((FP+NP+8))\""
eval "sht10=\"\$F$((FP+NP+9))\""
eval "sht2=\"\$F$((FP+NP+10))\""
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht23}\""
eval "F$((FP+NP+6))=\"\${sht16}\""
eval "F$((FP+NP+7))=\"\${sht13}\""
eval "F$((FP+NP+8))=\"\${sht10}\""
eval "F$((FP+NP+9))=\"\${sht2}\""
hp_cons "${sht41}" "${sht47}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht23=\"\$F$((FP+NP+5))\""
eval "sht16=\"\$F$((FP+NP+6))\""
eval "sht13=\"\$F$((FP+NP+7))\""
eval "sht10=\"\$F$((FP+NP+8))\""
eval "sht2=\"\$F$((FP+NP+9))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht31}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht26}\""
eval "F$((FP+NP+5))=\"\${sht23}\""
eval "F$((FP+NP+6))=\"\${sht16}\""
eval "F$((FP+NP+7))=\"\${sht13}\""
eval "F$((FP+NP+8))=\"\${sht10}\""
eval "F$((FP+NP+9))=\"\${sht2}\""
hp_cons "T:R=\$_clrs" "${sht48}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht31=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht26=\"\$F$((FP+NP+4))\""
eval "sht23=\"\$F$((FP+NP+5))\""
eval "sht16=\"\$F$((FP+NP+6))\""
eval "sht13=\"\$F$((FP+NP+7))\""
eval "sht10=\"\$F$((FP+NP+8))\""
eval "sht2=\"\$F$((FP+NP+9))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht13}\""
eval "F$((FP+NP+7))=\"\${sht10}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht39}\""
eval "F$((NFP+1))=\"\${sht49}\""
ARGC=2
CALLEE=append
RPC=26; ACTION=call; return
;;
26)
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht13=\"\$F$((FP+NP+6))\""
eval "sht10=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht31}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht26}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht13}\""
eval "F$((FP+NP+7))=\"\${sht10}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
hp_cons "T:_clrs=\$R" "${sht50}"
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht31=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht26=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht13=\"\$F$((FP+NP+6))\""
eval "sht10=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht51="${R}"
eval "F$((FP+NP+0))=\"\${sht31}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht26}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht13}\""
eval "F$((FP+NP+6))=\"\${sht10}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
eval "F$((NFP+1))=\"\${sht51}\""
ARGC=2
CALLEE=append
RPC=27; ACTION=call; return
;;
27)
eval "sht31=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht26=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht13=\"\$F$((FP+NP+5))\""
eval "sht10=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht52="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht13}\""
eval "F$((FP+NP+5))=\"\${sht10}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "${sht31}" "${sht52}"
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht13=\"\$F$((FP+NP+4))\""
eval "sht10=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht53="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht23}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht13}\""
eval "F$((FP+NP+4))=\"\${sht10}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "${sht30}" "${sht53}"
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht23=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht13=\"\$F$((FP+NP+3))\""
eval "sht10=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht54="${R}"
eval "F$((FP+NP+0))=\"\${sht54}\""
eval "F$((FP+NP+1))=\"\${sht26}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht13}\""
eval "F$((FP+NP+5))=\"\${sht10}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "T:esac; }" "NIL"
eval "sht54=\"\$F$((FP+NP+0))\""
eval "sht26=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht13=\"\$F$((FP+NP+4))\""
eval "sht10=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht55="${R}"
eval "F$((FP+NP+0))=\"\${sht26}\""
eval "F$((FP+NP+1))=\"\${sht23}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht13}\""
eval "F$((FP+NP+4))=\"\${sht10}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht54}\""
eval "F$((NFP+1))=\"\${sht55}\""
ARGC=2
CALLEE=append
RPC=28; ACTION=call; return
;;
28)
eval "sht26=\"\$F$((FP+NP+0))\""
eval "sht23=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht13=\"\$F$((FP+NP+3))\""
eval "sht10=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht56="${R}"
R="${sht56}"; ACTION=ret; return
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
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
ARGC=1
CALLEE=fs_list
RPC=14; ACTION=call; return
;;
13)
hp_cdr "${p0}"
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht49}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=lift_program
RPC=18; ACTION=call; return
;;
14)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht30="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht16}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht29}\""
eval "F$((NFP+1))=\"\${sht30}\""
eval "F$((NFP+2))=\"\${p1}\""
ARGC=3
CALLEE=lift
RPC=15; ACTION=call; return
;;
15)
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht16=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht31="${R}"
sht32="${sht31}"
hp_car "${sht32}"
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht16}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
hp_cons "${sht33}" "NIL"
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht16=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht22}" "${sht34}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "S:lambda" "${sht35}"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht36="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht36}" "NIL"
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht16}" "${sht37}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht38="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "S:define" "${sht38}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht39="${R}"
hp_cdr "${sht32}"
sht40="${R}"
hp_car "${sht40}"
sht41="${R}"
hp_cdr "${p0}"
sht42="${R}"
hp_cdr "${sht32}"
sht43="${R}"
hp_cdr "${sht43}"
sht44="${R}"
hp_car "${sht44}"
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht41}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht16}\""
eval "F$((FP+NP+6))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht42}\""
eval "F$((NFP+1))=\"\${sht45}\""
ARGC=2
CALLEE=lift_program
RPC=16; ACTION=call; return
;;
16)
eval "sht41=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht16=\"\$F$((FP+NP+5))\""
eval "sht1=\"\$F$((FP+NP+6))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht16}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht41}\""
eval "F$((NFP+1))=\"\${sht46}\""
ARGC=2
CALLEE=append
RPC=17; ACTION=call; return
;;
17)
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht16=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht16}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht39}" "${sht47}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht16=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht48="${R}"
R="${sht48}"; ACTION=ret; return
;;
18)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht1}" "${sht50}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht51="${R}"
R="${sht51}"; ACTION=ret; return
;;
esac; }
SIZE_compile_fn_bb=17
compile_fn_bb() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_compile_fn_bb))
NP=5
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=fs_list
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht0}\""
ARGC=1
CALLEE=lenl
RPC=2; ACTION=call; return
;;
2)
sht1="${R}"
sht2="${sht1}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "S:__gfns" "${p3}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "S:__gvars" "${p4}"
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=fs_list
RPC=3; ACTION=call; return
;;
3)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht5="${R}"
eval "F$((FP+NP+0))=\"\${sht4}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht5}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=pmap_fr
RPC=4; ACTION=call; return
;;
4)
eval "sht4=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht3}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht4}" "${sht6}"
eval "sht3=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht7="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
hp_cons "${sht3}" "${sht7}"
eval "sht2=\"\$F$((FP+NP+0))\""
sht8="${R}"
sht9="${sht8}"
sht10="T:${p0#??}"
eval "F$((FP+NP+0))=\"\${sht9}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
ARGC=1
CALLEE=sh_mangle
RPC=5; ACTION=call; return
;;
5)
eval "sht9=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht11="${R}"
sht12="${sht11}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${p0}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${p2}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
NFP=$FTOP
STGV="NIL"
eval "F$((NFP+0))=\"\$STGV\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
eval "F$((NFP+2))=\"I:0\""
eval "F$((NFP+3))=\"I:1\""
eval "F$((NFP+4))=\"I:0\""
eval "F$((NFP+5))=\"I:0\""
ARGC=6
CALLEE=mkb
RPC=6; ACTION=call; return
;;
6)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "p0=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "p2=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht12}\""
eval "F$((FP+NP+1))=\"\${sht9}\""
eval "F$((FP+NP+2))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p2}\""
eval "F$((NFP+1))=\"\${sht9}\""
eval "F$((NFP+2))=\"\${p0}\""
eval "F$((NFP+3))=\"\${sht2}\""
eval "F$((NFP+4))=\"\${sht13}\""
STGV="NIL"
eval "F$((NFP+5))=\"\$STGV\""
ARGC=6
CALLEE=ltail
RPC=7; ACTION=call; return
;;
7)
eval "sht12=\"\$F$((FP+NP+0))\""
eval "sht9=\"\$F$((FP+NP+1))\""
eval "sht2=\"\$F$((FP+NP+2))\""
sht14="${R}"
sht15="${sht14}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
ARGC=1
CALLEE=b_pc
RPC=8; ACTION=call; return
;;
8)
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht16="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
ARGC=1
CALLEE=b_cur
RPC=9; ACTION=call; return
;;
9)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht17="${R}"
eval "F$((FP+NP+0))=\"\${sht16}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht17}\""
STGV="NIL"
eval "F$((NFP+1))=\"\$STGV\""
ARGC=2
CALLEE=rev
RPC=10; ACTION=call; return
;;
10)
eval "sht16=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht18="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
hp_cons "${sht16}" "${sht18}"
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht19="${R}"
eval "F$((FP+NP+0))=\"\${sht19}\""
eval "F$((FP+NP+1))=\"\${sht15}\""
eval "F$((FP+NP+2))=\"\${sht12}\""
eval "F$((FP+NP+3))=\"\${sht9}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
ARGC=1
CALLEE=b_blk
RPC=11; ACTION=call; return
;;
11)
eval "sht19=\"\$F$((FP+NP+0))\""
eval "sht15=\"\$F$((FP+NP+1))\""
eval "sht12=\"\$F$((FP+NP+2))\""
eval "sht9=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht20="${R}"
eval "F$((FP+NP+0))=\"\${sht15}\""
eval "F$((FP+NP+1))=\"\${sht12}\""
eval "F$((FP+NP+2))=\"\${sht9}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
hp_cons "${sht19}" "${sht20}"
eval "sht15=\"\$F$((FP+NP+0))\""
eval "sht12=\"\$F$((FP+NP+1))\""
eval "sht9=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht21="${R}"
sht22="${sht21}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
ARGC=1
CALLEE=b_smax
RPC=12; ACTION=call; return
;;
12)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht23="${R}"
sht24="I:$(( ${sht2#??} + ${sht23#??} ))"
sht25="${sht24}"
sht26="T:${sht25#??}"
sht27="T:=${sht26#??}"
sht28="T:${sht12#??}${sht27#??}"
sht29="T:SIZE_${sht28#??}"
sht30="T:${sht12#??}() {"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht25}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=varargszzQ
RPC=13; ACTION=call; return
;;
13)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht25=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht31="${R}"
if [ "${sht31}" != NIL ]; then PC=14; else PC=15; fi
ACTION=jump; return
;;
14)
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht25}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
ARGC=0
CALLEE=va_collect_sh
RPC=17; ACTION=call; return
;;
15)
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht25}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=ploads
RPC=21; ACTION=call; return
;;
16)
sht38="T:${sht12#??}))"
sht39="T:FTOP=\$((FP + SIZE_${sht38#??}"
sht40="T:${sht2#??}"
sht41="T:NP=${sht40#??}"
eval "F$((FP+NP+0))=\"\${sht22}\""
eval "F$((FP+NP+1))=\"\${sht41}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht32}\""
eval "F$((FP+NP+4))=\"\${sht30}\""
eval "F$((FP+NP+5))=\"\${sht29}\""
eval "F$((FP+NP+6))=\"\${sht25}\""
eval "F$((FP+NP+7))=\"\${sht22}\""
eval "F$((FP+NP+8))=\"\${sht15}\""
eval "F$((FP+NP+9))=\"\${sht12}\""
eval "F$((FP+NP+10))=\"\${sht9}\""
eval "F$((FP+NP+11))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht15}\""
ARGC=1
CALLEE=b_npc
RPC=22; ACTION=call; return
;;
17)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht25=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht33="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht25}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht9}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p1}\""
ARGC=1
CALLEE=fs_list
RPC=18; ACTION=call; return
;;
18)
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht25=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht9=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht34="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht25}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht9}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"I:0\""
ARGC=2
CALLEE=ploads
RPC=19; ACTION=call; return
;;
19)
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht25=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht9=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht35="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht25}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht33}\""
eval "F$((NFP+1))=\"\${sht35}\""
ARGC=2
CALLEE=append
RPC=20; ACTION=call; return
;;
20)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht25=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht36="${R}"
sht32="${sht36}"
PC=16; ACTION=jump; return
;;
21)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht25=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht37="${R}"
sht32="${sht37}"
PC=16; ACTION=jump; return
;;
22)
eval "sht22=\"\$F$((FP+NP+0))\""
eval "sht41=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht32=\"\$F$((FP+NP+3))\""
eval "sht30=\"\$F$((FP+NP+4))\""
eval "sht29=\"\$F$((FP+NP+5))\""
eval "sht25=\"\$F$((FP+NP+6))\""
eval "sht22=\"\$F$((FP+NP+7))\""
eval "sht15=\"\$F$((FP+NP+8))\""
eval "sht12=\"\$F$((FP+NP+9))\""
eval "sht9=\"\$F$((FP+NP+10))\""
eval "sht2=\"\$F$((FP+NP+11))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht41}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht25}\""
eval "F$((FP+NP+6))=\"\${sht22}\""
eval "F$((FP+NP+7))=\"\${sht15}\""
eval "F$((FP+NP+8))=\"\${sht12}\""
eval "F$((FP+NP+9))=\"\${sht9}\""
eval "F$((FP+NP+10))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht22}\""
eval "F$((NFP+1))=\"I:0\""
eval "F$((NFP+2))=\"\${sht42}\""
ARGC=3
CALLEE=caseblocks
RPC=23; ACTION=call; return
;;
23)
eval "sht41=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht25=\"\$F$((FP+NP+5))\""
eval "sht22=\"\$F$((FP+NP+6))\""
eval "sht15=\"\$F$((FP+NP+7))\""
eval "sht12=\"\$F$((FP+NP+8))\""
eval "sht9=\"\$F$((FP+NP+9))\""
eval "sht2=\"\$F$((FP+NP+10))\""
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht41}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht32}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht29}\""
eval "F$((FP+NP+5))=\"\${sht25}\""
eval "F$((FP+NP+6))=\"\${sht22}\""
eval "F$((FP+NP+7))=\"\${sht15}\""
eval "F$((FP+NP+8))=\"\${sht12}\""
eval "F$((FP+NP+9))=\"\${sht9}\""
eval "F$((FP+NP+10))=\"\${sht2}\""
hp_cons "T:case \$PC in" "${sht43}"
eval "sht41=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht32=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht29=\"\$F$((FP+NP+4))\""
eval "sht25=\"\$F$((FP+NP+5))\""
eval "sht22=\"\$F$((FP+NP+6))\""
eval "sht15=\"\$F$((FP+NP+7))\""
eval "sht12=\"\$F$((FP+NP+8))\""
eval "sht9=\"\$F$((FP+NP+9))\""
eval "sht2=\"\$F$((FP+NP+10))\""
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht32}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht29}\""
eval "F$((FP+NP+4))=\"\${sht25}\""
eval "F$((FP+NP+5))=\"\${sht22}\""
eval "F$((FP+NP+6))=\"\${sht15}\""
eval "F$((FP+NP+7))=\"\${sht12}\""
eval "F$((FP+NP+8))=\"\${sht9}\""
eval "F$((FP+NP+9))=\"\${sht2}\""
hp_cons "${sht41}" "${sht44}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht32=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht29=\"\$F$((FP+NP+3))\""
eval "sht25=\"\$F$((FP+NP+4))\""
eval "sht22=\"\$F$((FP+NP+5))\""
eval "sht15=\"\$F$((FP+NP+6))\""
eval "sht12=\"\$F$((FP+NP+7))\""
eval "sht9=\"\$F$((FP+NP+8))\""
eval "sht2=\"\$F$((FP+NP+9))\""
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht32}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht29}\""
eval "F$((FP+NP+3))=\"\${sht25}\""
eval "F$((FP+NP+4))=\"\${sht22}\""
eval "F$((FP+NP+5))=\"\${sht15}\""
eval "F$((FP+NP+6))=\"\${sht12}\""
eval "F$((FP+NP+7))=\"\${sht9}\""
eval "F$((FP+NP+8))=\"\${sht2}\""
hp_cons "${sht39}" "${sht45}"
eval "sht32=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht29=\"\$F$((FP+NP+2))\""
eval "sht25=\"\$F$((FP+NP+3))\""
eval "sht22=\"\$F$((FP+NP+4))\""
eval "sht15=\"\$F$((FP+NP+5))\""
eval "sht12=\"\$F$((FP+NP+6))\""
eval "sht9=\"\$F$((FP+NP+7))\""
eval "sht2=\"\$F$((FP+NP+8))\""
sht46="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht29}\""
eval "F$((FP+NP+2))=\"\${sht25}\""
eval "F$((FP+NP+3))=\"\${sht22}\""
eval "F$((FP+NP+4))=\"\${sht15}\""
eval "F$((FP+NP+5))=\"\${sht12}\""
eval "F$((FP+NP+6))=\"\${sht9}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht32}\""
eval "F$((NFP+1))=\"\${sht46}\""
ARGC=2
CALLEE=append
RPC=24; ACTION=call; return
;;
24)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht29=\"\$F$((FP+NP+1))\""
eval "sht25=\"\$F$((FP+NP+2))\""
eval "sht22=\"\$F$((FP+NP+3))\""
eval "sht15=\"\$F$((FP+NP+4))\""
eval "sht12=\"\$F$((FP+NP+5))\""
eval "sht9=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht47="${R}"
eval "F$((FP+NP+0))=\"\${sht29}\""
eval "F$((FP+NP+1))=\"\${sht25}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "${sht30}" "${sht47}"
eval "sht29=\"\$F$((FP+NP+0))\""
eval "sht25=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht48="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "${sht29}" "${sht48}"
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht49}\""
eval "F$((FP+NP+1))=\"\${sht25}\""
eval "F$((FP+NP+2))=\"\${sht22}\""
eval "F$((FP+NP+3))=\"\${sht15}\""
eval "F$((FP+NP+4))=\"\${sht12}\""
eval "F$((FP+NP+5))=\"\${sht9}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "T:esac; }" "NIL"
eval "sht49=\"\$F$((FP+NP+0))\""
eval "sht25=\"\$F$((FP+NP+1))\""
eval "sht22=\"\$F$((FP+NP+2))\""
eval "sht15=\"\$F$((FP+NP+3))\""
eval "sht12=\"\$F$((FP+NP+4))\""
eval "sht9=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht25}\""
eval "F$((FP+NP+1))=\"\${sht22}\""
eval "F$((FP+NP+2))=\"\${sht15}\""
eval "F$((FP+NP+3))=\"\${sht12}\""
eval "F$((FP+NP+4))=\"\${sht9}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht49}\""
eval "F$((NFP+1))=\"\${sht50}\""
ARGC=2
CALLEE=append
RPC=25; ACTION=call; return
;;
25)
eval "sht25=\"\$F$((FP+NP+0))\""
eval "sht22=\"\$F$((FP+NP+1))\""
eval "sht15=\"\$F$((FP+NP+2))\""
eval "sht12=\"\$F$((FP+NP+3))\""
eval "sht9=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht51="${R}"
R="${sht51}"; ACTION=ret; return
;;
esac; }
SIZE_compile_def_sh=3
compile_def_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_compile_def_sh))
NP=3
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
eval "F$((NFP+5))=\"\${p2}\""
ARGC=6
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
eval "F$((NFP+4))=\"\${p2}\""
ARGC=5
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
ARGC=1
CALLEE=gfn_names
RPC=8; ACTION=call; return
;;
7)
hp_cdr "${p0}"
sht16="${R}"
eval "F$((FP+0))=\"\${sht16}\""
ARGC=1
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
SIZE_gen1_sh=4
gen1_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_gen1_sh))
NP=3
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
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=compile_def_sh
RPC=3; ACTION=call; return
;;
2)
hp_cdr "${p0}"
sht4="${R}"
hp_car "${sht4}"
sht5="${R}"
sht6="T:${sht5#??}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht6}\""
ARGC=1
CALLEE=sh_mangle
RPC=4; ACTION=call; return
;;
3)
sht3="${R}"
R="${sht3}"; ACTION=ret; return
;;
4)
sht7="${R}"
hp_cdr "${p0}"
sht8="${R}"
hp_cdr "${sht8}"
sht9="${R}"
hp_car "${sht9}"
sht10="${R}"
eval "F$((FP+NP+0))=\"\${sht7}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht10}\""
ARGC=1
CALLEE=cval_sh
RPC=5; ACTION=call; return
;;
5)
eval "sht7=\"\$F$((FP+NP+0))\""
sht11="${R}"
sht12="T:${sht11#??}'"
sht13="T:='${sht12#??}"
sht14="T:${sht7#??}${sht13#??}"
sht15="T:G_${sht14#??}"
hp_cons "${sht15}" "NIL"
sht16="${R}"
R="${sht16}"; ACTION=ret; return
;;
esac; }
SIZE_compile_all_sh=4
compile_all_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
FTOP=$((FP + SIZE_compile_all_sh))
NP=3
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
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
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
eval "F$((NFP+2))=\"\${p2}\""
ARGC=3
CALLEE=compile_all_sh
RPC=4; ACTION=call; return
;;
4)
eval "sht1=\"\$F$((FP+NP+0))\""
sht3="${R}"
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht3}\""
ARGC=2
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
sht4="${R}"
R="${sht4}"; ACTION=ret; return
;;
esac; }
SIZE_gvar_names=3
gvar_names() {
eval "p0=\"\$F$((FP+0))\""
FTOP=$((FP + SIZE_gvar_names))
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
hp_cdr "${p0}"
sht11="${R}"
eval "F$((FP+0))=\"\${sht11}\""
ARGC=1
PC=0; ACTION=tail; return
;;
7)
hp_cdr "${sht1}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
hp_cdr "${p0}"
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht13}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht14}\""
ARGC=1
CALLEE=gvar_names
RPC=8; ACTION=call; return
;;
8)
eval "sht13=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht15="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
hp_cons "${sht13}" "${sht15}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht16="${R}"
R="${sht16}"; ACTION=ret; return
;;
esac; }
SIZE_compile_program_sh=6
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
ARGC=2
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
ARGC=1
CALLEE=gfn_names
RPC=2; ACTION=call; return
;;
2)
eval "sht1=\"\$F$((FP+NP+0))\""
eval "p1=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht2="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
eval "F$((FP+NP+2))=\"\${p1}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
ARGC=1
CALLEE=gvar_names
RPC=3; ACTION=call; return
;;
3)
eval "sht2=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
eval "p1=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht3="${R}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht1}\""
eval "F$((NFP+1))=\"\${sht2}\""
eval "F$((NFP+2))=\"\${sht3}\""
ARGC=3
CALLEE=compile_all_sh
RPC=4; ACTION=call; return
;;
4)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht1=\"\$F$((FP+NP+1))\""
sht4="${R}"
eval "F$((FP+NP+0))=\"\${sht1}\""
write_lines "${p1}" "${sht4}"
eval "sht1=\"\$F$((FP+NP+0))\""
sht5="${R}"
R="${sht5}"; ACTION=ret; return
;;
esac; }
SIZE_lift_program_c=10
lift_program_c() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
FTOP=$((FP + SIZE_lift_program_c))
NP=2
case $PC in
0)
if [ "${p0}" = NIL ]; then PC=1; else PC=2; fi
ACTION=jump; return
;;
1)
hp_cons "NIL" "${p1}"
sht0="${R}"
R="${sht0}"; ACTION=ret; return
;;
2)
hp_car "${p0}"
sht1="${R}"
sht2="${sht1}"
if [ "${sht2#P:}" != "${sht2}" ]; then PC=3; else PC=4; fi
ACTION=jump; return
;;
3)
hp_car "${sht2}"
sht4="${R}"
if [ "${sht4}" = "S:define" ]; then PC=6; else PC=7; fi
ACTION=jump; return
;;
4)
sht3="NIL"
PC=5; ACTION=jump; return
;;
5)
if [ "${sht3}" != NIL ]; then PC=12; else PC=13; fi
ACTION=jump; return
;;
6)
hp_cdr "${sht2}"
sht6="${R}"
hp_cdr "${sht6}"
sht7="${R}"
hp_car "${sht7}"
sht8="${R}"
if [ "${sht8#P:}" != "${sht8}" ]; then PC=9; else PC=10; fi
ACTION=jump; return
;;
7)
sht5="NIL"
PC=8; ACTION=jump; return
;;
8)
sht3="${sht5}"
PC=5; ACTION=jump; return
;;
9)
hp_cdr "${sht2}"
sht10="${R}"
hp_cdr "${sht10}"
sht11="${R}"
hp_car "${sht11}"
sht12="${R}"
hp_car "${sht12}"
sht13="${R}"
if [ "${sht13}" = "S:lambda" ]; then
sht14="S:t"
else
sht14="NIL"
fi
sht9="${sht14}"
PC=11; ACTION=jump; return
;;
10)
sht9="NIL"
PC=11; ACTION=jump; return
;;
11)
sht5="${sht9}"
PC=8; ACTION=jump; return
;;
12)
hp_cdr "${sht2}"
sht15="${R}"
hp_car "${sht15}"
sht16="${R}"
sht17="${sht16}"
hp_cdr "${sht2}"
sht18="${R}"
hp_cdr "${sht18}"
sht19="${R}"
hp_car "${sht19}"
sht20="${R}"
hp_cdr "${sht20}"
sht21="${R}"
hp_car "${sht21}"
sht22="${R}"
sht23="${sht22}"
hp_cdr "${sht2}"
sht24="${R}"
hp_cdr "${sht24}"
sht25="${R}"
hp_car "${sht25}"
sht26="${R}"
hp_cdr "${sht26}"
sht27="${R}"
hp_cdr "${sht27}"
sht28="${R}"
hp_car "${sht28}"
sht29="${R}"
sht30="${sht29}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht17}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht23}\""
ARGC=1
CALLEE=fs_list
RPC=14; ACTION=call; return
;;
13)
hp_cdr "${p0}"
sht54="${R}"
eval "F$((FP+NP+0))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht54}\""
eval "F$((NFP+1))=\"\${p1}\""
ARGC=2
CALLEE=lift_program_c
RPC=18; ACTION=call; return
;;
14)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht17=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht31="${R}"
eval "F$((FP+NP+0))=\"\${sht30}\""
eval "F$((FP+NP+1))=\"\${sht23}\""
eval "F$((FP+NP+2))=\"\${sht17}\""
eval "F$((FP+NP+3))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht30}\""
eval "F$((NFP+1))=\"\${sht31}\""
eval "F$((NFP+2))=\"\${p1}\""
ARGC=3
CALLEE=lift
RPC=15; ACTION=call; return
;;
15)
eval "sht30=\"\$F$((FP+NP+0))\""
eval "sht23=\"\$F$((FP+NP+1))\""
eval "sht17=\"\$F$((FP+NP+2))\""
eval "sht2=\"\$F$((FP+NP+3))\""
sht32="${R}"
sht33="${sht32}"
hp_cdr "${p0}"
sht34="${R}"
hp_cdr "${sht33}"
sht35="${R}"
hp_cdr "${sht35}"
sht36="${R}"
hp_car "${sht36}"
sht37="${R}"
eval "F$((FP+NP+0))=\"\${sht33}\""
eval "F$((FP+NP+1))=\"\${sht30}\""
eval "F$((FP+NP+2))=\"\${sht23}\""
eval "F$((FP+NP+3))=\"\${sht17}\""
eval "F$((FP+NP+4))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht34}\""
eval "F$((NFP+1))=\"\${sht37}\""
ARGC=2
CALLEE=lift_program_c
RPC=16; ACTION=call; return
;;
16)
eval "sht33=\"\$F$((FP+NP+0))\""
eval "sht30=\"\$F$((FP+NP+1))\""
eval "sht23=\"\$F$((FP+NP+2))\""
eval "sht17=\"\$F$((FP+NP+3))\""
eval "sht2=\"\$F$((FP+NP+4))\""
sht38="${R}"
sht39="${sht38}"
hp_car "${sht33}"
sht40="${R}"
eval "F$((FP+NP+0))=\"\${sht23}\""
eval "F$((FP+NP+1))=\"\${sht17}\""
eval "F$((FP+NP+2))=\"\${sht39}\""
eval "F$((FP+NP+3))=\"\${sht33}\""
eval "F$((FP+NP+4))=\"\${sht30}\""
eval "F$((FP+NP+5))=\"\${sht23}\""
eval "F$((FP+NP+6))=\"\${sht17}\""
eval "F$((FP+NP+7))=\"\${sht2}\""
hp_cons "${sht40}" "NIL"
eval "sht23=\"\$F$((FP+NP+0))\""
eval "sht17=\"\$F$((FP+NP+1))\""
eval "sht39=\"\$F$((FP+NP+2))\""
eval "sht33=\"\$F$((FP+NP+3))\""
eval "sht30=\"\$F$((FP+NP+4))\""
eval "sht23=\"\$F$((FP+NP+5))\""
eval "sht17=\"\$F$((FP+NP+6))\""
eval "sht2=\"\$F$((FP+NP+7))\""
sht41="${R}"
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht17}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "${sht23}" "${sht41}"
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht17=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht42="${R}"
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht17}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "S:lambda" "${sht42}"
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht17=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht43="${R}"
eval "F$((FP+NP+0))=\"\${sht17}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht17}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
hp_cons "${sht43}" "NIL"
eval "sht17=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht17=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht44="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht17}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "${sht17}" "${sht44}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht17=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht45="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht17}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "S:define" "${sht45}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht17=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht46="${R}"
hp_cdr "${sht33}"
sht47="${R}"
hp_car "${sht47}"
sht48="${R}"
hp_car "${sht39}"
sht49="${R}"
eval "F$((FP+NP+0))=\"\${sht46}\""
eval "F$((FP+NP+1))=\"\${sht39}\""
eval "F$((FP+NP+2))=\"\${sht33}\""
eval "F$((FP+NP+3))=\"\${sht30}\""
eval "F$((FP+NP+4))=\"\${sht23}\""
eval "F$((FP+NP+5))=\"\${sht17}\""
eval "F$((FP+NP+6))=\"\${sht2}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht48}\""
eval "F$((NFP+1))=\"\${sht49}\""
ARGC=2
CALLEE=append
RPC=17; ACTION=call; return
;;
17)
eval "sht46=\"\$F$((FP+NP+0))\""
eval "sht39=\"\$F$((FP+NP+1))\""
eval "sht33=\"\$F$((FP+NP+2))\""
eval "sht30=\"\$F$((FP+NP+3))\""
eval "sht23=\"\$F$((FP+NP+4))\""
eval "sht17=\"\$F$((FP+NP+5))\""
eval "sht2=\"\$F$((FP+NP+6))\""
sht50="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht17}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "${sht46}" "${sht50}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht17=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht51="${R}"
hp_cdr "${sht39}"
sht52="${R}"
eval "F$((FP+NP+0))=\"\${sht39}\""
eval "F$((FP+NP+1))=\"\${sht33}\""
eval "F$((FP+NP+2))=\"\${sht30}\""
eval "F$((FP+NP+3))=\"\${sht23}\""
eval "F$((FP+NP+4))=\"\${sht17}\""
eval "F$((FP+NP+5))=\"\${sht2}\""
hp_cons "${sht51}" "${sht52}"
eval "sht39=\"\$F$((FP+NP+0))\""
eval "sht33=\"\$F$((FP+NP+1))\""
eval "sht30=\"\$F$((FP+NP+2))\""
eval "sht23=\"\$F$((FP+NP+3))\""
eval "sht17=\"\$F$((FP+NP+4))\""
eval "sht2=\"\$F$((FP+NP+5))\""
sht53="${R}"
R="${sht53}"; ACTION=ret; return
;;
18)
eval "sht2=\"\$F$((FP+NP+0))\""
sht55="${R}"
sht56="${sht55}"
hp_car "${sht56}"
sht57="${R}"
eval "F$((FP+NP+0))=\"\${sht56}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht2}" "${sht57}"
eval "sht56=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht58="${R}"
hp_cdr "${sht56}"
sht59="${R}"
eval "F$((FP+NP+0))=\"\${sht56}\""
eval "F$((FP+NP+1))=\"\${sht2}\""
hp_cons "${sht58}" "${sht59}"
eval "sht56=\"\$F$((FP+NP+0))\""
eval "sht2=\"\$F$((FP+NP+1))\""
sht60="${R}"
R="${sht60}"; ACTION=ret; return
;;
esac; }
SIZE_repl_compile_sh=11
repl_compile_sh() {
eval "p0=\"\$F$((FP+0))\""
eval "p1=\"\$F$((FP+1))\""
eval "p2=\"\$F$((FP+2))\""
eval "p3=\"\$F$((FP+3))\""
eval "p4=\"\$F$((FP+4))\""
FTOP=$((FP + SIZE_repl_compile_sh))
NP=5
case $PC in
0)
NFP=$FTOP
eval "F$((NFP+0))=\"\${p0}\""
eval "F$((NFP+1))=\"\${p2}\""
ARGC=2
CALLEE=lift_program_c
RPC=1; ACTION=call; return
;;
1)
sht0="${R}"
sht1="${sht0}"
hp_car "${sht1}"
sht2="${R}"
sht3="${sht2}"
hp_cdr "${sht1}"
sht4="${R}"
sht5="${sht4}"
eval "F$((FP+NP+0))=\"\${p3}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
ARGC=1
CALLEE=gfn_names
RPC=2; ACTION=call; return
;;
2)
eval "p3=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht6="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht3}\""
eval "F$((FP+NP+2))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p3}\""
eval "F$((NFP+1))=\"\${sht6}\""
ARGC=2
CALLEE=append
RPC=3; ACTION=call; return
;;
3)
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht3=\"\$F$((FP+NP+1))\""
eval "sht1=\"\$F$((FP+NP+2))\""
sht7="${R}"
sht8="${sht7}"
eval "F$((FP+NP+0))=\"\${p4}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
ARGC=1
CALLEE=gvar_names
RPC=4; ACTION=call; return
;;
4)
eval "p4=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht9="${R}"
eval "F$((FP+NP+0))=\"\${sht8}\""
eval "F$((FP+NP+1))=\"\${sht5}\""
eval "F$((FP+NP+2))=\"\${sht3}\""
eval "F$((FP+NP+3))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${p4}\""
eval "F$((NFP+1))=\"\${sht9}\""
ARGC=2
CALLEE=append
RPC=5; ACTION=call; return
;;
5)
eval "sht8=\"\$F$((FP+NP+0))\""
eval "sht5=\"\$F$((FP+NP+1))\""
eval "sht3=\"\$F$((FP+NP+2))\""
eval "sht1=\"\$F$((FP+NP+3))\""
sht10="${R}"
sht11="${sht10}"
eval "F$((FP+NP+0))=\"\${p1}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
NFP=$FTOP
eval "F$((NFP+0))=\"\${sht3}\""
eval "F$((NFP+1))=\"\${sht8}\""
eval "F$((NFP+2))=\"\${sht11}\""
ARGC=3
CALLEE=compile_all_sh
RPC=6; ACTION=call; return
;;
6)
eval "p1=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht12="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
write_lines "${p1}" "${sht12}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht13="${R}"
eval "F$((FP+NP+0))=\"\${sht5}\""
eval "F$((FP+NP+1))=\"\${sht11}\""
eval "F$((FP+NP+2))=\"\${sht8}\""
eval "F$((FP+NP+3))=\"\${sht5}\""
eval "F$((FP+NP+4))=\"\${sht3}\""
eval "F$((FP+NP+5))=\"\${sht1}\""
hp_cons "${sht8}" "${sht11}"
eval "sht5=\"\$F$((FP+NP+0))\""
eval "sht11=\"\$F$((FP+NP+1))\""
eval "sht8=\"\$F$((FP+NP+2))\""
eval "sht5=\"\$F$((FP+NP+3))\""
eval "sht3=\"\$F$((FP+NP+4))\""
eval "sht1=\"\$F$((FP+NP+5))\""
sht14="${R}"
eval "F$((FP+NP+0))=\"\${sht11}\""
eval "F$((FP+NP+1))=\"\${sht8}\""
eval "F$((FP+NP+2))=\"\${sht5}\""
eval "F$((FP+NP+3))=\"\${sht3}\""
eval "F$((FP+NP+4))=\"\${sht1}\""
hp_cons "${sht5}" "${sht14}"
eval "sht11=\"\$F$((FP+NP+0))\""
eval "sht8=\"\$F$((FP+NP+1))\""
eval "sht5=\"\$F$((FP+NP+2))\""
eval "sht3=\"\$F$((FP+NP+3))\""
eval "sht1=\"\$F$((FP+NP+4))\""
sht15="${R}"
R="${sht15}"; ACTION=ret; return
;;
esac; }

# ---- native sh-emitter driver (TRAMPOLINE; identical to comp.sh's) ----------------------
GLOBAL=NIL
G_DQ='T:"'
write_lines()  { _f=${1#T:}; _l=$2; : > "$_f"; while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
append_lines() { _f=${1#T:}; _l=$2;          while [ "$_l" != NIL ]; do hp_car "$_l"; printf '%s\n' "${R#T:}" >> "$_f"; hp_cdr "$_l"; _l=$R; done; R="S:t"; }
gc()           { gc_run; R="S:t"; }
drive() {
  while [ "$CURFN" != HALT ]; do
    ACTION=; eval "$CURFN"
    case $ACTION in
      call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP"; RSP=$((RSP+1)); FP=$NFP; CURFN=$CALLEE; PC=0 ;;
      ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP"; fi ;;
      tail|jump) ;;
    esac
  done
}
# entry: compile-program-sh(forms, "T:<outfile>") -> writes native sh to <outfile>.
SRC=$(cat "$1"); rd_expr; _forms=$R
FP=0; F0=$_forms; F1="T:$2"; RSP=0; CURFN=compile_program_sh; PC=0
drive
