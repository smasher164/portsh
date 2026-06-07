#!/bin/sh
# Flat-closure guard (sh backend): compile a program with inline lambdas + first-class functions
# via compile-sh.lisp (interpreted), assemble with the trampoline driver, and run on every sh.
# Exercises the whole path: lambda-lift, capture (single + multi-level), make-closure record,
# computed call (named + expression callee), the driver K:/CLO dispatch, captured-from-record load.
# Pure-local (no VM). Validates the codegen behind first-class functions for the build-script Lisp.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
[ -f portsh-full.cmd ] || sh build.sh >/dev/null 2>&1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
interp="$work/portsh.sh"; tr -d '\r' < portsh-full.cmd > "$interp"

PROG='((define make-adder (lambda (n) (lambda (x) (+ x n))))
       (define apply1 (lambda (f a) (f a)))
       (define adder3 (lambda (a) (lambda (b) (lambda (c) (+ a (+ b c))))))
       (define go3 (lambda () (((adder3 1) 2) 3)))
       (define dbl-clo (lambda (k) ((lambda (x) (+ x k)) k)))
       (define use-adder (lambda () (apply1 (make-adder 5) 3))))'

{ cat src/compile-sh.lisp
  printf '\n(define compile-all (lambda (defs) (if (null? defs) nil (append (compile-def-sh (car defs)) (compile-all (cdr defs))))))'
  printf '\n(write-lines "%s/fns.sh" (compile-all (lift-program (quote %s) 0)))(print (quote OK))\n' "$work" "$PROG"
} > "$work/gen.lisp"
env NURSERY=999999999 PORTSH_COOKED=1 PORTSH_SELF="$interp" mksh "$interp" "$work/gen.lisp" </dev/null >/dev/null 2>&1
[ -s "$work/fns.sh" ] || { echo "FAIL closures: compile-sh.lisp produced no code"; exit 1; }

{ tr -d '\r' < portsh-full.cmd | awk 'NR==1{next} /^main "\$@"$/{exit} {print}'
  cat "$work/fns.sh"
  cat <<'DRV'
drive() { while [ "$CURFN" != HALT ]; do ACTION=; eval "$CURFN"
  [ -z "$ACTION" ] && { echo "  DRIVE-STUCK: $CURFN set no ACTION (bad fn name?)"; return 1; }
  case $ACTION in
  call) eval "RSF$RSP=\$CURFN; RSC$RSP=\$RPC; RSB$RSP=\$FP; RSL$RSP=\$CLO"; RSP=$((RSP+1)); FP=$NFP; PC=0; CLO=""
        case $CALLEE in K:*) _ri=${CALLEE#K:}; hp_car "P:$_ri"; CURFN=${R#S:}; CLO=$_ri ;; *) CURFN=$CALLEE ;; esac ;;
  ret)  if [ "$RSP" -eq 0 ]; then CURFN=HALT; else RSP=$((RSP-1)); eval "FP=\$RSB$RSP; CURFN=\$RSF$RSP; PC=\$RSC$RSP; CLO=\$RSL$RSP"; fi ;;
  tail|jump) ;;
esac; done; }
run1() { FP=0; RSP=0; PC=0; CLO=""; CURFN=$1; shift; _i=0; for a in "$@"; do eval "F$_i=\$a"; _i=$((_i+1)); done; drive; }
ok=0; bad=0
chk() { if [ "$2" = "$3" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "  FAIL $1: got $2 want $3"; fi; }
run1 use_adder;            chk use-adder "$R" I:8
run1 go3;                  chk go3 "$R" I:6
run1 dbl_clo I:10;         chk dbl-clo "$R" I:20
echo "closures-run: ok=$ok bad=$bad"
[ "$bad" -eq 0 ] || exit 1
DRV
} > "$work/run.sh"

fail=0
for s in mksh dash bash; do
  command -v "$s" >/dev/null 2>&1 || continue
  out=$("$s" "$work/run.sh" 2>&1) || true
  if echo "$out" | grep -q 'bad=0'; then echo "closures [$s]: PASS"; else echo "closures [$s]: FAIL"; echo "$out" | sed 's/^/    /'; fail=1; fi
done
[ "$fail" -eq 0 ]
