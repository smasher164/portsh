#!/bin/sh
# Two-tier parity guard (sh): the COLD path (:ev interpreter) and the WARM path (JIT = compile+run)
# must produce IDENTICAL output for the same program -- otherwise a program would change behavior
# between its first run (:ev) and every run after (JIT). This is the core invariant of the two-tier
# model (:ev cold-start + JIT warm). Each case = defines + ONE final expr; we render the expr's value
# via :ev (explicit (print ...)) and via the JIT (auto-print) and assert they MATCH each other AND the
# expected text. Covers arith/control/closures/lists/nil/computed-defines/prims-as-values/apply/stdlib.
set -eu
cd "$(dirname "$0")/.."
[ -f load-sh.sh ] || sh build-load-sh.sh >/dev/null 2>&1
[ -f portsh-full.cmd ] || sh build.sh >/dev/null 2>&1
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
interp="$work/interp.sh"; tr -d '\r' < portsh-full.cmd > "$interp"
ok=0; bad=0
ck() {  # $1 = defines (maybe empty), $2 = final expr, $3 = expected text
  printf '%s (print %s)' "$1" "$2" > "$work/ev.lisp"
  printf '%s %s'         "$1" "$2" > "$work/jit.lisp"
  iv=$(env NURSERY=999999999 PORTSH_COOKED=1 PORTSH_SELF="$interp" mksh "$interp" "$work/ev.lisp" </dev/null 2>&1) || iv="<ev-error>"
  jt=$(env NURSERY=999999999 mksh load-sh.sh "$work/jit.lisp" 2>&1) || jt="<jit-error>"
  if [ "$iv" = "$jt" ] && [ "$iv" = "$3" ]; then ok=$((ok+1))
  else bad=$((bad+1)); printf '  FAIL [%s] %s\n    exp[%s]  :ev[%s]  JIT[%s]\n' "$1" "$2" "$3" "$iv" "$jt"; fi
}
ck ''                                              '(+ 1 2)'                                          '3'
ck ''                                              '(if (< 1 2) (quote y) (quote n))'                 'y'
ck ''                                              '(cond ((< 5 3) 1) (t 2))'                         '2'
ck ''                                              '(unless (< 1 2) 9)'                               '()'
ck ''                                              '(and (< 1 2) (< 2 3))'                            't'
ck ''                                              'nil'                                              '()'
ck ''                                              '(cons 1 (cons 2 nil))'                            '(1 2)'
ck ''                                              '(cons 1 2)'                                       '(1 . 2)'
ck ''                                              '(cons (cons 1 2) (cons 3 nil))'                   '((1 . 2) 3)'
ck '(define sq (lambda (x) (* x x)))'              '(sq 7)'                                           '49'
ck '(define add (lambda (n) (lambda (x) (+ x n))))' '((add 10) 5)'                                    '15'
ck '(define x (+ 2 3))'                            '(* x x)'                                          '25'
ck ''                                              '(foldr + 0 (cons 1 (cons 2 (cons 3 nil))))'       '6'
ck ''                                              '(apply cons (cons 1 (cons 2 nil)))'               '(1 . 2)'
ck ''                                              '(apply (lambda (a b c) (+ a (+ b c))) (cons 1 (cons 2 (cons 3 nil))))' '6'
ck ''                                              '(map (lambda (x) (* x x)) (cons 1 (cons 2 (cons 3 nil))))' '(1 4 9)'
ck ''                                              '(reverse (cons 1 (cons 2 (cons 3 nil))))'         '(3 2 1)'
ck ''                                              '(length (filter (lambda (x) (< x 3)) (cons 1 (cons 2 (cons 3 nil)))))' '2'
printf 'parity(sh :ev==JIT): ok=%d bad=%d\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
