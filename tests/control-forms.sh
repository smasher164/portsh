#!/bin/sh
# Derived control-form guard (sh backend): case / let* / when / unless / or compiled via the
# Lisp->sh backend (src/compile-sh.lisp) and RUN on every sh. These are compiler-known rewrites
# (no vau): case->cond(eq?), let*->nested-lets, when/unless->if, or->single-eval-let. Guards the
# sh-backend parity added alongside the cmd backend's mexpand (and the dsg-or double-eval fix).
# Pure-local (no VM).
set -eu
cd "$(dirname "$0")/.."
[ -f portsh-full.cmd ] || sh build.sh >/dev/null 2>&1
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
interp="$work/portsh.sh"; tr -d '\r' < portsh-full.cmd > "$interp"

PROG='((define tc (lambda (x) (case x (1 (quote one)) (2 (quote two)) (else (quote other)))))
       (define tl (lambda (a) (let* ((x (+ a 1)) (y (+ x 1))) (+ x y))))
       (define tw (lambda (x) (when (< x 5) (quote small))))
       (define tu (lambda (x) (unless (< x 5) (quote big))))
       (define to (lambda (a b) (or a b)))
       (define tcm (lambda (x) (cond ((< x 0) (quote neg) (quote n2)) (t (quote pos))))))'

{ cat src/compile-sh.lisp
  printf '\n(define ca (lambda (ds) (if (null? ds) nil (append (compile-def-sh (car ds)) (ca (cdr ds))))))'
  printf '\n(write-lines "%s/fns.sh" (ca (lift-program (quote %s) 0)))(print (quote OK))\n' "$work" "$PROG"
} > "$work/gen.lisp"
env NURSERY=999999999 PORTSH_COOKED=1 PORTSH_SELF="$interp" mksh "$interp" "$work/gen.lisp" </dev/null >/dev/null 2>&1
[ -s "$work/fns.sh" ] || { echo "FAIL control-forms: no codegen"; exit 1; }

{ tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat "$work/fns.sh"
  cat <<'DRV'
drive() { while [ "$CURFN" != HALT ]; do ACTION=; eval "$CURFN"; case $ACTION in
  call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
        case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; *) CURFN=$CALLEE ;; esac ;;
  ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
  tail|jump) ;;
esac; done; }
run1() { FP=0; RSP=0; PC=0; CLO=""; CURFN=$1; shift; _i=0; for a in "$@"; do eval "F$_i=\$a"; _i=$((_i+1)); done; drive; }
ok=0;bad=0; ck(){ if [ "$2" = "$3" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "  FAIL $1: got $2 want $3"; fi; }
run1 tc I:1; ck case1 "$R" S:one
run1 tc I:2; ck case2 "$R" S:two
run1 tc I:9; ck caseE "$R" S:other
run1 tl I:10; ck let* "$R" I:23
run1 tw I:3; ck when-t "$R" S:small
run1 tw I:9; ck when-f "$R" NIL
run1 tu I:3; ck unless-f "$R" NIL
run1 tu I:9; ck unless-t "$R" S:big
run1 to NIL I:5; ck or-1 "$R" I:5
run1 to I:3 I:9; ck or-2 "$R" I:3
run1 tcm I:7; ck cond-multi "$R" S:pos
echo "control-forms-run: ok=$ok bad=$bad"
[ "$bad" -eq 0 ] || exit 1
DRV
} > "$work/run.sh"

fail=0
for s in mksh dash bash; do
  command -v "$s" >/dev/null 2>&1 || continue
  out=$("$s" "$work/run.sh" 2>&1) || true
  if echo "$out" | grep -q 'bad=0'; then echo "control-forms [$s]: PASS"; else echo "control-forms [$s]: FAIL"; echo "$out" | sed 's/^/    /'; fail=1; fi
done
[ "$fail" -eq 0 ]
