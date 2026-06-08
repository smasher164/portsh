#!/bin/sh
# Stdlib AOT guard (sh): the applicative stdlib (src/stdlib-aot.sh, compiled by comp-sh.sh) is
# embedded in the runtime, so programs call map/foldl/filter/reverse/assoc/... by name -- no
# interpreter, no per-run stdlib load. Exercises higher-order fns with BOTH named fns and closures,
# composition, list/pair rendering, and the namespaced lifted closures (no __lam collision).
set -eu
cd "$(dirname "$0")/.."
[ -f load-sh.sh ] || sh build-load-sh.sh >/dev/null 2>&1
[ -f src/stdlib-aot.sh ] || sh tools/build-stdlib-aot.sh >/dev/null 2>&1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ok=0; bad=0
ck() {  # $1 = program, $2 = expected output
  printf '%s' "$1" > "$work/p.lisp"
  got=$(env NURSERY=999999999 mksh load-sh.sh "$work/p.lisp" 2>&1) || got="<error>"
  if [ "$got" = "$2" ]; then ok=$((ok+1)); else bad=$((bad+1)); printf '  FAIL %s\n    exp [%s] got [%s]\n' "$1" "$2" "$got"; fi
}
L='(cons 1 (cons 2 (cons 3 nil)))'   # [1 2 3]

ck "(sum $L)" '6'
ck "(product (cons 1 (cons 2 (cons 3 (cons 4 nil)))))" '24'
ck "(reverse $L)" '(3 2 1)'
ck "(length $L)" '3'
ck "(map (lambda (x) (* x x)) $L)" '(1 4 9)'
ck "(length (filter (lambda (x) (< x 3)) (cons 1 (cons 2 (cons 3 (cons 4 nil))))))" '2'
ck "(foldl (lambda (a x) (+ a x)) 0 $L)" '6'
ck "(foldr (lambda (x a) (cons x a)) nil $L)" '(1 2 3)'
ck "(zip (cons 1 (cons 2 nil)) (cons (quote a) (cons (quote b) nil)))" '((1 . a) (2 . b))'
ck "(assoc (quote b) (cons (cons (quote a) 1) (cons (cons (quote b) 2) nil)))" '(b . 2)'
ck "(nth (cons 10 (cons 20 (cons 30 nil))) 1)" '20'
ck "(last $L)" '3'
ck "(take (cons 1 (cons 2 (cons 3 (cons 4 nil)))) 2)" '(1 2)'
ck "(max (max 3 7) 5)" '7'
ck "(abs (- 0 9))" '9'
ck "(sum (map (lambda (x) (* x 10)) $L))" '60'           # composed HOFs + closure
ck "(define dbl (lambda (x) (* x 2))) (sum (map dbl $L))" '12'   # named fn passed to map (C:)

printf 'stdlib: ok=%d bad=%d\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
