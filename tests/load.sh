#!/bin/sh
# Loader guard (sh): read->compile->run for whole programs. load-sh.sh embeds the native Lisp->sh
# compiler; top-level (define ...) forms become compiled fns and top-level EXPRESSIONS are wrapped
# as thunks and evaluated in order, referencing prior defines. eval = compile + run; no interpreter.
#
# COVERS: lambda defines + call, self-recursion, multiple top-level exprs, let-bound first-class
# functions, closure-returning defines used via an expression.
# NOT YET (first-class GLOBAL functions -- needs comp's global env): passing a NAMED top-level fn as
# a value (map dbl xs), and computed top-level defines (define x (f y)). Those fail loudly (the
# driver's empty-ACTION guard), they don't hang.
set -eu
cd "$(dirname "$0")/.."
[ -f load-sh.sh ] || sh build-load-sh.sh >/dev/null 2>&1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ok=0; bad=0
ckprog() {  # $1 = program text, $2 = expected output (newline-joined)
  printf '%s' "$1" > "$work/p.lisp"
  got=$(env NURSERY=999999999 mksh load-sh.sh "$work/p.lisp" 2>&1) || got="<error>"
  if [ "$got" = "$2" ]; then ok=$((ok+1)); else bad=$((bad+1)); printf '  FAIL:\n    prog: %s\n    exp [%s] got [%s]\n' "$1" "$2" "$got"; fi
}

ckprog '(define sq (lambda (x) (* x x))) (sq 7)' '49'
ckprog '(define fact (lambda (n) (if (< n 2) 1 (* n (fact (- n 1)))))) (fact 5) (fact 6)' '120
720'
ckprog '(define adder (lambda (n) (lambda (x) (+ x n)))) ((adder 10) 5) (let ((inc (adder 1))) (inc 99))' '15
100'
ckprog '(define len (lambda (xs) (if (null? xs) 0 (+ 1 (len (cdr xs)))))) (len (cons 1 (cons 2 (cons 3 nil))))' '3'
ckprog '(define classify (lambda (x) (cond ((< x 0) (quote neg)) ((eq? x 0) (quote zero)) (t (quote pos))))) (classify 5) (classify 0)' 'pos
zero'

printf 'load: ok=%d bad=%d\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
