#!/bin/sh
# eval keystone guard (sh): eval = compile + run, comp EMBEDDED in the runtime (no interpreter).
# eval-sh.sh wraps each expression as a 0-arg thunk, compiles it in-process via the embedded
# native Lisp->sh compiler (comp-sh-compiled.sh), sources it, and dispatches via the closure-
# capable trampoline. Covers arith, lambda application, let, NESTED CLOSURES, control forms,
# cells, predicates, strings. This is the JIT core: run(compile(form)).
set -eu
cd "$(dirname "$0")/.."
[ -f eval-sh.sh ] || sh build-eval-sh.sh >/dev/null 2>&1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ok=0; bad=0
ck() {  # $1 = expr, $2 = expected
  printf '%s' "$1" > "$work/e.lisp"
  got=$(env NURSERY=999999999 mksh eval-sh.sh "$work/e.lisp" 2>&1) || got="<error>"
  if [ "$got" = "$2" ]; then ok=$((ok+1)); else bad=$((bad+1)); printf '  FAIL %s\n    exp [%s] got [%s]\n' "$1" "$2" "$got"; fi
}

ck '(+ 1 2)' '3'
ck '(* 6 7)' '42'
ck '((lambda (x) (* x x)) 5)' '25'
ck '(let ((x 5) (y 3)) (+ x y))' '8'
ck '(let* ((x 2) (y (* x 3))) (+ x y))' '8'
ck '(((lambda (a) (lambda (b) (+ a b))) 3) 4)' '7'
ck '((((lambda (a) (lambda (b) (lambda (c) (+ a (+ b c))))) 1) 2) 3)' '6'
ck '(case 2 (1 (quote one)) (2 (quote two)) (else (quote other)))' 'two'
ck '(cond ((< 5 3) (quote a)) ((< 3 5) (quote b)) (t (quote c)))' 'b'
ck '(when (< 1 2) (quote yes))' 'yes'
ck '(unless (< 1 2) (quote no))' 'nil'
ck '(and (< 1 2) (< 2 3))' 't'
ck '(or nil (quote fallback))' 'fallback'
ck '(if (eq? (quote x) (quote x)) 42 0)' '42'
ck '(car (cdr (cons 1 (cons 2 (cons 3 nil)))))' '2'
ck '(str "hello " "world")' 'hello world'
ck '(null? nil)' 't'
ck '(pair? (cons 1 2))' 't'
# primitives as first-class VALUES (prim-wrap -> C:__p_<op>): + cons car * passed to HOFs.
ck '(foldr + 0 (cons 1 (cons 2 (cons 3 nil))))' '6'
ck '(foldr cons nil (cons 1 (cons 2 nil)))' '(1 2)'
ck '(map car (cons (cons 1 2) (cons (cons 3 4) nil)))' '(1 3)'
ck '(foldl * 1 (cons 2 (cons 3 (cons 4 nil))))' '24'

printf 'eval: ok=%d bad=%d\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
