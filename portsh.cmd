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
set "HN=0" & set "FID=0" & set "SP=0" & set "FREE_HEAD=NIL" & set "MARKGEN=0"
rem file-backed heap dir (cells = %HD%\car<i>/cdr<i>). %RANDOM%-unique so concurrent
rem runs don't collide; inherited in-process by any compiled subs that touch the heap.
set "HD=ph_%RANDOM%%RANDOM%"
mkdir "!HD!" 2>nul
if not defined GC_THRESH set "GC_THRESH=150000"
rem Four sentinel bytes stand in for the chars cmd's expansion phases eat or mangle
rem inside string VALUES: 0x01='!' (delayed expansion eats it), 0x02='%' (percent
rem phase), 0x07='^' (caret/escape), 0x08='"' (the string delimiter -- encoded first
rem so it can't break the later replaces). Operators & | < > need NO sentinel: the
rem source is read RAW via `set /p` (:readall), which doesn't parse content, so all
rem of !,%,^,",&,|,<,> survive together; we then encode in dependency order. They
rem decode back to real chars only at I/O; the '"' delimiters are consumed by the
rem reader and never reach output (portsh strings have no '"' escape). 0x01/0x07/0x08
rem are baked in as literal bytes (build.sh //) where a `call`-based
rem inject would double a live '^'; 0x02 is fetched here for the delayed %-replaces.
for /F "delims=" %%a in ('forfiles /p "%~dp0." /m "%~nx0" /c "cmd /c echo 0x02"') do set "BANG2=%%a"
for /F "delims=" %%a in ('forfiles /p "%~dp0." /m "%~nx0" /c "cmd /c echo 0x08"') do set "BANG8=%%a"
rem BANG/BANG7 = literal 0x01/0x07 vars (baked by build.sh). Compiled subs reference
rem !BANG!/!BANG2! to materialise a data '!'/'%' that would otherwise be eaten by the
rem delayed-expansion pass when the value reaches a `set`; they decode to '!'/'%' at I/O.
set "BANG="
set "BANG7="
rem LT/GT/AMP/PIPE = the cmd operators < > & | as vars (baked literally inside
rem QUOTES, which protect them from tokenization at parse time). Compiled subs
rem reference !LT! etc. to place an operator into a value's text via delayed
rem expansion (post-tokenization), the only way a bare operator survives a `set`.
set "LT=<"
set "GT=>"
set "AMP=&"
set "PIPE=|"
call :setup_global

rem Boot order: minimal prelude -> baked-in payload (stdlib) after the marker ->
rem file-arg program. MK is built from fragments so the literal never appears here
rem (the self-scan would match the kernel, not the baked-in final-line marker).
rem Both payload and program go through :feedfile, which reads each line RAW with
rem `set /p` and encodes ! % ^ " to sentinels -- the only way to keep all of
rem !, operators, and " in one line (no for-var read mode does). Source then drains
rem through :addsrc; the reader keeps only the current line in SRC so parsing is
rem O(n), and the parse stack (ST_/SP/DEPTH) persists across lines for multi-line
rem forms.
set "SP=0" & set "DEPTH=0"
set "MK=__PORTSH"
set "MK=!MK!_PAYLOAD__"
set "MLINE=0"
findstr /c:"!MK!" "%~f0" >nul 2>&1 && for /f "delims=:" %%n in ('findstr /n /c:"!MK!" "%~f0"') do if "!MLINE!"=="0" set "MLINE=%%n"
if not "%MLINE%"=="0" call :feedfile "%~f0" %MLINE%
if not "%~1"=="" call :feedfile "%~1" 0
:done_boot
exit /b 0

rem feedfile (%1=file %2=#lines-to-skip): prefix every line with [N] via
rem `find /v /n ""` (so set/p never meets a blank line, which it can't tell from
rem EOF), then read each line RAW with set/p, discard the first %2 (to skip the
rem kernel's own text ahead of the baked-in payload), and encode+drain the rest.
:feedfile
type "%~1" | find /v /n "" > "%TEMP%\portsh_in.txt"
call :readall %2 < "%TEMP%\portsh_in.txt"
goto :eof

rem readall: set/p reads a raw line (all of ! % ^ " & | < > survive). NO `call` is
rem used (a `call` re-parses and DOUBLES any live '^'): " and ! are encoded with
rem literal sentinel bytes (=0x08, =0x01, baked by build.sh), and % and ^
rem with parse-time-injected forfiles bytes under delayed expansion. Order: " -> 0x08
rem FIRST (so the next quoted-set replaces aren't broken by an inner " exposing a &);
rem strip the [N] prefix; ! -> 0x01; then (delayed) % -> 0x02 and ^ -> 0x07. Operators
rem stay REAL, so the reader/eval see them as Lisp tokens (e.g. the '<' in `(< n 2)`).
:readall
set "rdskip=%1"
:rd_skip
if %rdskip% gtr 0 set /p "rddiscard=" & set /a rdskip-=1 & goto rd_skip
:rd_loop
set "line="
set /p "line=" || goto :eof
setlocal disableDelayedExpansion
set "line=%line:"=%"
set "line=%line:^=%"
set "line=%line:*]=%"
rem a blank source line is just "[N]" -> empty after the strip; skip it, else the
rem next replace runs on an undefined var and leaks the literal "=!" (a stray '=').
if not defined line (endlocal & goto rd_loop)
set "line=%line:!=%"
endlocal & set "ln=%line%"
setlocal enableDelayedExpansion
set "ln=!ln:%%=%BANG2%!"
endlocal & set "ln=%ln%"
call :addsrc
goto rd_loop

rem ============================ reader (iterative) ============================
:run_forms
:rf_loop
call :skipws
if "!SRC!"=="" goto :eof
set "ch=!SRC:~0,1!"
if "!ch!"=="(" goto rf_open
if "!ch!"==")" goto rf_close
if "!ch!"=="'" goto rf_quote
if "!ch!"=="!BANG8!" goto rf_string
goto rf_atom
:rf_quote
rem 'x -> (quote x): push a quote-marker; apply_quotes wraps the next datum
set "ST_!SP!=QM" & set /a SP+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_string
rem string literal "..." -> T:...  ('"' is the 0x08 sentinel by now; BANG8 ends it)
set "SRC=!SRC:~1!"
set "rfs="
:rfs_loop
if "!SRC!"=="" goto rfs_done
set "sc=!SRC:~0,1!"
if "!sc!"=="!BANG8!" set "SRC=!SRC:~1!" & goto rfs_done
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
rem digit classify via geq/leq (2 cmds) instead of a 10-iteration for-loop per
rem atom. A leading '-' followed by a digit is a number (bare '-' and '-foo' stay
rem symbols), matching the sh reader (which reads -1 as I:-1, not the symbol -1).
if "!c0!" geq "0" if "!c0!" leq "9" set "isnum=1"
if "!c0!"=="-" if "!t:~1,1!" geq "0" if "!t:~1,1!" leq "9" set "isnum=1"
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
if "!RDMODE!"=="1" set "RDRESULT=!R!" & set "SRC=" & goto :eof
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
rem Feed ONE line: strip its ';' comment (string-aware, so a ';' inside a "..."
rem survives — matching the sh reader), put just that line + a trailing space in
rem SRC, and drain it through the reader (goto rf_loop; the reader returns via
rem goto :eof when SRC empties). SRC holds at most one line, so the char advance
rem stays O(line) and parsing is O(n), not O(n^2). The parse stack persists
rem across calls, so multi-line forms work. Fast path: a line with no ';' skips
rem the char scan; comment lines hit the ';' almost immediately.
set "asLn=!ln!"
set "asTest=!asLn:;=!"
if "!asTest!"=="!asLn!" set "SRC=!asLn! " & goto rf_loop
set "asKept=" & set "asIn=0"
:as_loop
if "!asLn!"=="" goto as_done
set "asC=!asLn:~0,1!"
set "asLn=!asLn:~1!"
if "!asC!"=="!BANG8!" goto as_quote
if "!asIn!"=="1" goto as_keep
if "!asC!"==";" goto as_done
:as_keep
set "asKept=!asKept!!asC!"
goto as_loop
:as_quote
if "!asIn!"=="0" (set "asIn=1") else (set "asIn=0")
set "asKept=!asKept!!asC!"
goto as_loop
:as_done
set "SRC=!asKept! "
goto rf_loop

rem ===================== heap (FILES: %HD%\car<i> / %HD%\cdr<i>) =====================
rem cmd var ops are O(env-size), so an env-var heap makes cons O(N^2) to build and
rem every car/cdr O(heap). The filesystem is O(1) by name, so each cell is two files
rem car<i>/cdr<i> in %HD%. KEY: redirect targets are parsed BEFORE delayed expansion,
rem so the PATH uses %HD%/%HN%/%idx% (immediate); the value uses !..! (delayed,
rem post-parse) so operators (& | < >) and parens in a value never re-tokenize.
rem Files don't degrade with heap size, so GC is non-critical here (po_gc neutralised).
:hp_cons
set "hca=%~1" & set "hcd=%~2"
>%HD%\car%HN% echo(!hca!#
>%HD%\cdr%HN% echo(!hcd!#
set "R=P:%HN%"
set /a HN+=1
goto :eof
:hp_car
set "hcp=%~1"
if "!hcp:~0,2!" NEQ "P:" set "R=NIL" & goto :eof
set "hcp=!hcp:P:=!"
set /p R=<%HD%\car%hcp%
set "R=!R:~0,-1!"
goto :eof
:hp_cdr
set "hdp=%~1"
if "!hdp:~0,2!" NEQ "P:" set "R=NIL" & goto :eof
set "hdp=!hdp:P:=!"
set /p R=<%HD%\cdr%hdp%
set "R=!R:~0,-1!"
goto :eof
:hp_setcar
set "scp=%~1" & set "scp=!scp:P:=!" & set "sca=%~2"
>%HD%\car%scp% echo(!sca!#
goto :eof
:hp_setcdr
set "sdp=%~1" & set "sdp=!sdp:P:=!" & set "sda=%~2"
>%HD%\cdr%sdp% echo(!sda!#
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
set /p elkB=<%HD%\car%ei%
set "elkB=!elkB:~0,-1!"
set "elkPrev="
:elk_b
if "!elkB!"=="NIL" goto elk_next
set "bi=!elkB:P:=!"
set /p elkP=<%HD%\car%bi%
set "elkP=!elkP:~0,-1!"
set "pi=!elkP:P:=!"
set /p _pk=<%HD%\car%pi%
set "_pk=!_pk:~0,-1!"
if "!_pk!"=="!elkSym!" goto elk_found
set "elkPrev=!elkB!"
set /p elkB=<%HD%\cdr%bi%
set "elkB=!elkB:~0,-1!"
goto elk_b
:elk_next
set /p elkEnv=<%HD%\cdr%ei%
set "elkEnv=!elkEnv:~0,-1!"
goto elk_env
:elk_found
if "!elkPrev!"=="" goto elk_val
set /p elkNext=<%HD%\cdr%bi%
set "elkNext=!elkNext:~0,-1!"
call :hp_setcdr "!elkPrev!" "!elkNext!"
set /p elkHead=<%HD%\car%ei%
set "elkHead=!elkHead:~0,-1!"
call :hp_setcdr "!elkB!" "!elkHead!"
call :hp_setcar "!elkEnv!" "!elkB!"
:elk_val
set /p R=<%HD%\cdr%pi%
set "R=!R:~0,-1!"
goto :eof
:elk_unbound
set "elkU=!elkSym:S:=!"
1>&2 echo portsh: unbound symbol: !elkU!
set "R=NIL"
goto :eof

rem =============================== evaluator ===============================
rem TCO evaluator: a goto-loop (mirrors kernel.sh's ev). Tail positions (if-branch,
rem lambda body's last form, applicative unwrap) update _%1_x/_%1_env and `goto ev_top`
rem instead of recursing, so deep tail recursion does NOT grow cmd's call stack (was
rem the ~319 limit). Non-tail evals (combiner, operands, if-test, non-last body forms)
rem still `call :ev` with a fresh frame. LOOP STATE IS FRAME-SCOPED (_%1_x etc.): a
rem recursive call enters :ev at %1+1 and would clobber a global, so per-frame vars.
rem The combine/combine_oper/ev_seq/po_if functions below are now folded in here.
:ev
set "_%1_x=%~2" & set "_%1_env=%~3"
:ev_top
if "!_%1_x!"=="NIL" set "R=NIL" & goto :eof
set "evPre=!_%1_x:~0,2!"
if "!evPre!"=="I:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="F:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="R:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="O:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="A:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="S:" call :env_lookup "!_%1_env!" "!_%1_x!" & goto :eof
if not "!evPre!"=="P:" set "R=!_%1_x!" & goto :eof
rem combination: eval combiner (non-tail), read operands, dispatch on combiner type
set "eci=!_%1_x:P:=!"
set /p _eca=<%HD%\car%eci%
set "_eca=!_eca:~0,-1!"
set /a ND=%1+1 & call :ev !ND! "!_eca!" "!_%1_env!"
set "_%1_c=!R!"
set "eci=!_%1_x:P:=!"
set /p _%1_ops=<%HD%\cdr%eci%
set "_%1_ops=!_%1_ops:~0,-1!"
:ev_apply
set "cPre=!_%1_c:~0,2!"
if "!cPre!"=="A:" goto ev_appl
if "!cPre!"=="R:" goto ev_primapp
if "!cPre!"=="F:" goto ev_oper
if "!cPre!"=="O:" goto ev_compound
if "!cPre!"=="C:" goto ev_compiled
set "R=NIL" & goto :eof
:ev_appl
rem applicative A:<i> = wrap(combiner): unwrap, eval operands, loop on the unwrapped
call :hp_car "P:!_%1_c:~2!"
set "_%1_w=!R!"
set /a ND=%1+1 & call :eval_list !ND! "!_%1_ops!" "!_%1_env!"
set "_%1_ops=!R!" & set "_%1_c=!_%1_w!"
goto ev_apply
:ev_primapp
set /a ND=%1+1 & call :eval_list !ND! "!_%1_ops!" "!_%1_env!"
set "pn=!_%1_c:~2!"
set /a ND=%1+1 & call :prim_app !ND! "!pn!" "!R!"
goto :eof
:ev_oper
if "!_%1_c!"=="F:if" goto ev_if
set "pn=!_%1_c:~2!"
set /a ND=%1+1 & call :prim_oper !ND! "!pn!" "!_%1_ops!" "!_%1_env!"
goto :eof
:ev_compiled
rem C:<label> compiled combiner -> TRAMPOLINE. Eval operands into the frame stack F[0..], then run a
rem driver loop that `call`s the current fn's .cmd at DEPTH 1 (each compiled fn is a resumable
rem segment machine: it does one segment then yields via ACTION=call/ret/tail + `goto :eof`). Host
rem call-depth stays 1 regardless of logical recursion depth -- cmd's `call` overflows at ~341 deep.
set /a ND=%1+1 & call :eval_list !ND! "!_%1_ops!" "!_%1_env!"
set "ccL=!_%1_c:~2!"
set "ccN=0" & set "ccLst=!R!"
:ev_cc_loop
if "!ccLst!"=="NIL" goto ev_cc_run
call :hp_car "!ccLst!"
set "F!ccN!=!R!" & set /a ccN+=1
call :hp_cdr "!ccLst!"
set "ccLst=!R!"
goto ev_cc_loop
:ev_cc_run
set "FP=0" & set "RSP=0" & set "CURFN=!ccL!" & set "PC=0" & set "CLO="
:ev_tloop
if "!CURFN!"=="HALT" goto :eof
set "ACTION="
call "!CURFN!_pc!PC!.cmd"
if "!ACTION!"=="call" goto ev_tcall
if "!ACTION!"=="ret" goto ev_tret
goto ev_tloop
:ev_tcall
rem save caller frame (incl. closure-record ptr CLO) on the return stack
set "RSF!RSP!=!CURFN!" & set "RSC!RSP!=!RPC!" & set "RSB!RSP!=!FP!" & set "RSL!RSP!=!CLO!"
set /a RSP+=1
set "FP=!NFP!" & set "PC=0" & set "CLO="
rem K:<idx> = a flat closure: CURFN = the record's label (car), CLO = the record idx
if "!CALLEE:~0,2!"=="K:" goto ev_tcall_clo
rem C:<label> = a first-class NAMED fn value: dispatch straight to the label (no captured env)
if "!CALLEE:~0,2!"=="C:" set "CURFN=!CALLEE:~2!" & goto ev_tloop
set "CURFN=!CALLEE!"
goto ev_tloop
:ev_tcall_clo
set "CLO=!CALLEE:~2!"
call :hp_car "P:!CLO!"
set "CURFN=!R:~2!"
goto ev_tloop
:ev_tret
if !RSP!==0 ( set "CURFN=HALT" & goto ev_tloop )
set /a RSP-=1
call set "FP=%%RSB!RSP!%%" & call set "CURFN=%%RSF!RSP!%%" & call set "PC=%%RSC!RSP!%%" & call set "CLO=%%RSL!RSP!%%"
goto ev_tloop
:ev_if
rem (if test then else): eval test (non-tail); chosen branch is TAIL -> loop
call :hp_car "!_%1_ops!"
set /a ND=%1+1 & call :ev !ND! "!R!" "!_%1_env!"
set "_%1_t=!R!"
call :hp_cdr "!_%1_ops!"
set "_%1_r=!R!"
if "!_%1_t!"=="NIL" goto ev_if_else
call :hp_car "!_%1_r!"
set "_%1_x=!R!"
goto ev_top
:ev_if_else
call :hp_cdr "!_%1_r!"
call :hp_car "!R!"
set "_%1_x=!R!"
goto ev_top
:ev_compound
rem compound operative O:<i> = (formals eformal body senv): bind, eval body; last
rem body form is TAIL -> loop. operands are as-passed (pre-evaluated if reached via A:).
set "ci=!_%1_c:O:=!"
set /p _%1_f=<%HD%\car%ci%
set "_%1_f=!_%1_f:~0,-1!"
set /p cr1=<%HD%\cdr%ci%
set "cr1=!cr1:~0,-1!"
set "cr1=!cr1:P:=!"
set /p _%1_ef=<%HD%\car%cr1%
set "_%1_ef=!_%1_ef:~0,-1!"
set /p cr2=<%HD%\cdr%cr1%
set "cr2=!cr2:~0,-1!"
set "cr2=!cr2:P:=!"
set /p _%1_body=<%HD%\car%cr2%
set "_%1_body=!_%1_body:~0,-1!"
set /p _%1_senv=<%HD%\cdr%cr2%
set "_%1_senv=!_%1_senv:~0,-1!"
set /a ND=%1+1 & call :build_alist !ND! "!_%1_f!" "!_%1_ops!" "NIL"
set "_%1_al=!R!"
if "!_%1_ef!"=="S:#ignore" goto ev_co_noenv
call :hp_cons "!_%1_ef!" "!_%1_env!"
call :hp_cons "!R!" "!_%1_al!"
set "_%1_al=!R!"
:ev_co_noenv
call :hp_cons "!_%1_al!" "!_%1_senv!"
set "_%1_env=!R!"
:ev_co_bodyloop
if "!_%1_body!"=="NIL" set "R=NIL" & goto :eof
call :hp_cdr "!_%1_body!"
set "_%1_brest=!R!"
if "!_%1_brest!"=="NIL" goto ev_co_tail
call :hp_car "!_%1_body!"
set /a ND=%1+1 & call :ev !ND! "!R!" "!_%1_env!"
set "_%1_body=!_%1_brest!"
goto ev_co_bodyloop
:ev_co_tail
call :hp_car "!_%1_body!"
set "_%1_x=!R!"
goto ev_top

:combine
set "cmbC=%~2" & set "cmbPre=!cmbC:~0,2!"
if "!cmbPre!"=="F:" goto cmb_oper
if "!cmbPre!"=="R:" goto cmb_app
if "!cmbPre!"=="A:" goto cmb_appl
if "!cmbPre!"=="O:" goto cmb_compound
if "!cmbPre!"=="C:" goto cmb_compiled
set "R=NIL" & goto :eof
:cmb_compiled
rem C:<label> — a JIT-compiled applicative. Eval operands, strip tags to raw
rem args (A1..An), and call the generated batch sub. Multi-file: each compiled fn
rem is its own <label>.cmd (cmd's label scan is O(file-position), so one fn per file
rem keeps every entry at the top -> ~1ms calls regardless of program size).
set /a ND=%1+1 & call :eval_list !ND! "%~3" "%~4"
set "ccL=%~2" & set "ccL=!ccL:~2!"
set "ccN=0" & set "ccLst=!R!"
:cc_loop
if "!ccLst!"=="NIL" goto cc_call
call :hp_car "!ccLst!"
set /a ccN+=1 & set "A!ccN!=!R!"
call :hp_cdr "!ccLst!"
set "ccLst=!R!"
goto cc_loop
:cc_call
call "!ccL!.cmd"
goto :eof
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
set /p _ele=<%HD%\car%eli%
set "_ele=!_ele:~0,-1!"
set /a ND=%1+1 & call :ev !ND! "!_ele!" "%~3"
set "_%1_e=!R!"
set "eli=%~2" & set "eli=!eli:P:=!"
set /p _eld=<%HD%\cdr%eli%
set "_eld=!_eld:~0,-1!"
set /a ND=%1+1 & call :eval_list !ND! "!_eld!" "%~3"
call :hp_cons "!_%1_e!" "!R!"
goto :eof

:prim_oper
set "poN=%~2"
if "!poN!"=="vau" goto po_vau
if "!poN!"=="quote" goto po_quote
if "!poN!"=="lambda" goto po_lambda
if "!poN!"=="define" goto po_define
if "!poN!"=="if" goto po_if
if "!poN!"=="run" goto po_run
if "!poN!"=="run-capture" goto po_runcap
if "!poN!"=="gc" goto po_gc
set "R=NIL" & goto :eof
:po_gc
rem file-backed heap (cells are files in %HD%) does NOT degrade with heap size, so GC
rem is a no-op for now -- the heap just grows as files; reclamation would only matter
rem for disk/inode limits on very large runs. (Was a mark-sweep over CAR_/CDR_ vars.)
set "R=S:t"
goto :eof
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
rem Redirect-FIRST so NOTHING follows the quoted command. Otherwise the space
rem before a trailing token (`2>&1`/`|`) is absorbed into the command line and
rem echo emits a spurious trailing space (a cmd quote-stripping quirk that the
rem sh capture doesn't have). Capture raw, then prefix every line with "[N]" via
rem find (keeps blank/';' lines) in a separate step, then iterate.
> "%TEMP%\portsh_rc1.txt" 2>&1 cmd /c "!rcCmd!"
type "%TEMP%\portsh_rc1.txt" | find /v /n "" > "%TEMP%\portsh_rc.txt"
set "rcAcc=NIL"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rc.txt") do (
  set "rcLn=%%L" & set "rcLn=!rcLn:*]=!"
  call :hp_cons "T:!rcLn!" "!rcAcc!"
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
:po_quote
rem (quote x) -> x, unevaluated. Was a prelude macro; a primitive avoids parsing
rem the prelude every boot.
call :hp_car "%~3"
goto :eof
:po_lambda
rem (lambda formals . body) -> applicative wrapping a compound operative (a vau
rem with eformal=#ignore). Primitive form removes the big prelude lambda macro
rem (the dominant boot cost) and skips macro re-expansion per closure.
call :hp_car "%~3"
set "plF=!R!"
call :hp_cdr "%~3"
call :hp_cons "!R!" "%~4"
call :hp_cons "S:#ignore" "!R!"
call :hp_cons "!plF!" "!R!"
set "R=O:!R:P:=!"
call :hp_cons "!R!" "NIL"
set "R=A:!R:P:=!"
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
set /p _%1_f=<%HD%\car%ci%
set "_%1_f=!_%1_f:~0,-1!"
set /p cr1=<%HD%\cdr%ci%
set "cr1=!cr1:~0,-1!"
set "cr1=!cr1:P:=!"
set /p _%1_ef=<%HD%\car%cr1%
set "_%1_ef=!_%1_ef:~0,-1!"
set /p cr2=<%HD%\cdr%cr1%
set "cr2=!cr2:~0,-1!"
set "cr2=!cr2:P:=!"
set /p _%1_body=<%HD%\car%cr2%
set "_%1_body=!_%1_body:~0,-1!"
set /p _%1_senv=<%HD%\cdr%cr2%
set "_%1_senv=!_%1_senv:~0,-1!"
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
if "!paN!"=="dq" goto pa_dq
if "!paN!"=="make-compiled" goto pa_mkcompiled
if "!paN!"=="list" goto pa_list
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
if "!paN!"=="append-lines" goto pa_aplines
if "!paN!"=="hmark" goto pa_hmark
if "!paN!"=="hreset" goto pa_hreset
if "!paN!"=="read" goto pa_read
if "!paN!"=="type-of" goto pa_typeof
if "!paN!"=="split" goto pa_split
set "R=NIL" & goto :eof
:pa_split
rem Split a string on a (possibly multi-char) separator, empty fields preserved.
rem Native char-scan in batch (set/goto, no eval) — the whole point of making
rem this a primitive instead of a userspace per-char loop through the evaluator.
call :hp_car "%~3"
set "spS=!R:~2!"
call :hp_cdr "%~3" & call :hp_car "!R!"
set "spSep=!R:~2!"
set "spSL=0"
:sp_seplen
call set "spLC=%%spSep:~!spSL!,1%%"
if not "!spLC!"=="" set /a spSL+=1 & goto sp_seplen
if "!spSL!"=="0" call :hp_cons "T:!spS!" "NIL" & goto :eof
set "spAcc=NIL" & set "spCur=" & set "spI=0"
:sp_loop
call set "spCh=%%spS:~!spI!,1%%"
if "!spCh!"=="" goto sp_emit
call set "spChunk=%%spS:~!spI!,!spSL!%%"
if "!spChunk!"=="!spSep!" goto sp_match
set "spCur=!spCur!!spCh!" & set /a spI+=1
goto sp_loop
:sp_match
call :hp_cons "T:!spCur!" "!spAcc!"
set "spAcc=!R!" & set "spCur=" & set /a spI+=spSL
goto sp_loop
:sp_emit
call :hp_cons "T:!spCur!" "!spAcc!"
set "spAcc=!R!"
call :list_reverse "!spAcc!"
goto :eof
:pa_read
rem Parse one datum from a string WITHOUT evaluating. Reuse the kernel reader by
rem pointing SRC at the string and running it in RDMODE (emit_top captures the
rem first top-level datum into RDRESULT and clears SRC to stop). The outer
rem reader's state (SRC/SP/DEPTH) is saved/restored; its stack is empty here
rem because a top-level datum is fully reduced before eval runs.
call :hp_car "%~3"
set "raStr=!R:~2!"
set "_raSRC=!SRC!" & set "_raSP=!SP!" & set "_raDEPTH=!DEPTH!"
set "SRC=!raStr!" & set "SP=0" & set "DEPTH=0" & set "RDMODE=1" & set "RDRESULT=NIL"
call :run_forms
set "RDMODE="
set "R=!RDRESULT!"
set "SRC=!_raSRC!" & set "SP=!_raSP!" & set "DEPTH=!_raDEPTH!"
goto :eof
:pa_typeof
call :hp_car "%~3"
set "toV=!R!"
if "!toV!"=="NIL" set "R=S:nil" & goto :eof
set "toP=!toV:~0,2!"
if "!toP!"=="I:" set "R=S:number" & goto :eof
if "!toP!"=="S:" set "R=S:symbol" & goto :eof
if "!toP!"=="T:" set "R=S:string" & goto :eof
if "!toP!"=="P:" set "R=S:pair" & goto :eof
if "!toP!"=="O:" set "R=S:operative" & goto :eof
if "!toP!"=="F:" set "R=S:operative" & goto :eof
if "!toP!"=="A:" set "R=S:applicative" & goto :eof
if "!toP!"=="R:" set "R=S:applicative" & goto :eof
set "R=S:unknown" & goto :eof
:pa_rdlines
call :hp_car "%~3"
set "rlF=!R:~2!" & set "rlAcc=NIL"
rem `type file | find /v /n ""` prefixes EVERY line (blanks + ';'-leading
rem included) with "[N]", so for/f keeps them; !ln:*]=! strips that prefix.
rem This is what makes read-lines preserve blank/';' lines exactly like the sh
rem kernel. (find /v /n "" matches all lines; piping via type avoids find's
rem filename header, and avoids findstr's "^" being eaten in this nested context.)
rem Run the pipe as a normal redirect FIRST, then iterate the prefixed file with
rem a plain for/f. A pipe INSIDE for/f deadlocks in this deep call/redirect
rem context, so the pipe must stand alone. The "[N]" prefix on every line keeps
rem blank/';'-leading lines visible to for/f; !ln:*]=! strips it back off.
type "!rlF!" | find /v /n "" > "%TEMP%\portsh_rl.txt"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rl.txt") do (
  set "rlLn=%%L" & set "rlLn=!rlLn:*]=!"
  call :hp_cons "T:!rlLn!" "!rlAcc!"
  set "rlAcc=!R!"
)
rem NOTE: this for/f read eats a literal '!' in file content (delayed expansion), so
rem read-lines of a '!'-bearing data file loses the '!' -- a known consistency gap.
rem The set/p raw reader used for source/programs can't be reused here: read-lines is
rem called DEEP in the eval chain, where `call :sub < file` (stdin redirect) fails.
call :list_reverse "!rlAcc!"
goto :eof
:pa_aplines
rem append-lines: like write-lines but does NOT truncate (region reclamation: cp
rem appends each fn's output, then resets the heap). Shares the wl loop + wl_emit.
call :hp_car "%~3"
set "wlF=!R:~2!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set "wlL=!R!"
goto pa_wl_loop
:pa_hmark
set "R=I:!HN!"
goto :eof
:pa_hreset
call :hp_car "%~3"
set "HN=!R:~2!"
set "R=S:t"
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
rem decode 0x01 -> '!' and append the line. Under disabled expansion a literal '!'
rem is safe; set/p's quoted prompt keeps '&' < > '"' verbatim, and the codegen is
rem quote-free so '"' never appears in generated batch. echo( adds the line break.
rem a blank line leaves wlLine undefined, and %wlLine:..=..% on an undefined var
rem leaks "=!" into wlD -- so guard on the SOURCE (wlLine), not the decoded result:
rem for a blank line just write the line break, so it round-trips as empty.
if defined wlLine goto wl_enc
>>"%~1" echo(
goto :eof
:wl_enc
rem Robust line writer (handles ! % ^ " AND operators & | < >). The decode runs in
rem QUOTED sets (safe for operators -- quotes protect them; the value never holds a
rem real '"' since '"' is the 0x08 sentinel until the end). Operators are CARET-escaped
rem and 0x07->^^ so an UNQUOTED set/p can emit them; 0x01->!, 0x02->%, 0x08->@PQ@ then
rem ->'"' inline at the set/p (an unquoted prompt takes a bare '"', verified). No quoted
rem prompt, so a '"' in the line writes fine.
setlocal enableDelayedExpansion
set "w=!wlLine:&=^&!"
set "w=!w:|=^|!"
set "w=!w:<=^<!"
set "w=!w:>=^>!"
set "w=!w:=^^!"
set "w=!w:%BANG2%=%%!"
endlocal & set "wcar=%w%"
setlocal disableDelayedExpansion
set "wlD=%wcar:=!%"
set "wlD=%wlD:=@PQ@%"
>>"%~1" <nul set /p =%wlD:@PQ@="%
>>"%~1" echo(
endlocal
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
rem Empty string must be special-cased: `set "slS="` UNSETS slS, and
rem %slS:~0,1% on an undefined var never yields "", so the scan would loop
rem forever. (sh's ${#x} has no such trap.)
if "!slS!"=="" set "R=I:0" & goto :eof
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
:pa_list
rem list returns its already-evaluated args as-is (applicative). Was a prelude
rem macro; a primitive keeps the prelude empty so boot doesn't parse it.
set "R=%~3"
goto :eof
:pa_mkcompiled
rem (make-compiled "label") -> C:label, a combiner that calls the compiled sub.
call :hp_car "%~3"
set "R=C:!R:~2!"
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
:pa_dq
rem (dq) -> a '"'-valued string. 0x08 is our '"' sentinel; it decodes to a real
rem '"' at output (write-lines), letting generated code quote an `if` comparison
rem so operator chars (& | < >) in a value don't break the line.
set "R=T:!BANG8!"
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
rem decode 0x02 -> '%' (enabled; '%%' is the replacement), carry out (percent
rem expansion is single-pass so the real '%' survives), then 0x01 -> '!' (disabled,
rem where a literal '!' is safe). set/p then emits; the content has no '"' so its
rem quoted prompt holds, and '& | < > ^ ( )' pass through verbatim.
rem an empty string leaves R undefined; %R:..=..% on an undefined var leaks the
rem literal "=!", so skip the decode and just emit the newline for empty output.
if not defined R goto pr_nl
setlocal enableDelayedExpansion
set "pdec=!R:%BANG2%=%%!"
endlocal & set "pcar=%pdec%"
setlocal disableDelayedExpansion
set "pout=%pcar:=^%"
set "pout=%pout:=!%"
<nul set /p "=%pout%"
endlocal
:pr_nl
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
call :env_define "!GLOBAL!" "S:quote" "F:quote"
call :env_define "!GLOBAL!" "S:lambda" "F:lambda"
call :env_define "!GLOBAL!" "S:list" "R:list"
call :env_define "!GLOBAL!" "S:define" "F:define"
call :env_define "!GLOBAL!" "S:if" "F:if"
call :env_define "!GLOBAL!" "S:gc" "F:gc"
call :env_define "!GLOBAL!" "S:cons" "R:cons"
call :env_define "!GLOBAL!" "S:car" "R:car"
call :env_define "!GLOBAL!" "S:cdr" "R:cdr"
call :env_define "!GLOBAL!" "S:eq?" "R:eq?"
call :env_define "!GLOBAL!" "S:dq" "R:dq"
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
call :env_define "!GLOBAL!" "S:append-lines" "R:append-lines"
call :env_define "!GLOBAL!" "S:hmark" "R:hmark"
call :env_define "!GLOBAL!" "S:hreset" "R:hreset"
call :env_define "!GLOBAL!" "S:read" "R:read"
call :env_define "!GLOBAL!" "S:type-of" "R:type-of"
call :env_define "!GLOBAL!" "S:split" "R:split"
call :env_define "!GLOBAL!" "S:run" "F:run"
call :env_define "!GLOBAL!" "S:run-capture" "F:run-capture"
call :env_define "!GLOBAL!" "S:t" "S:t"
call :env_define "!GLOBAL!" "S:nil" "NIL"
rem --- JIT integration (WIP): CFILE holds the generated subs; make-compiled mints
rem --- a C:<label> binding so a program can install compiled functions.
set "CFILE=compiled.cmd"
call :env_define "!GLOBAL!" "S:make-compiled" "R:make-compiled"
goto :eof
__PORTSH_PAYLOAD__
