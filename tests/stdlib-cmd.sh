#!/bin/sh
# Stdlib AOT guard (CMD): the applicative stdlib (compiled to per-PC .cmd by tools/build-stdlib-aot-cmd.sh)
# lives in comp-cmd/, so programs call map/foldl/filter/reverse/assoc/... BY NAME -- no interpreter,
# no per-run stdlib load. Runs via load-cmd.cmd on real Windows. Corpus MIRRORS tests/stdlib.sh so
# sh/cmd parity is provable line-for-line. Exercises HOFs with lambdas AND named fns (C: values),
# composition, list/pair rendering, and the namespaced lifted closures (__sl, no __lam collision).
# VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP stdlib-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH
[ -f comp-cmd/load-cmd.cmd ] || sh build-load-cmd.sh >/dev/null
[ -f comp-cmd/map_pc0.cmd ]  || sh tools/build-stdlib-aot-cmd.sh >/dev/null

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
L='(cons 1 (cons 2 (cons 3 nil)))'

i=0; progs=""; exp_all=""
add() { printf '%s' "$1" > "$work/p$i.lisp"; progs="$progs p$i.lisp"; exp_all="$exp_all===p$i===
$2
"; i=$((i+1)); }
add "(sum $L)" '6'
add "(product (cons 1 (cons 2 (cons 3 (cons 4 nil)))))" '24'
add "(reverse $L)" '(3 2 1)'
add "(length $L)" '3'
add "(map (lambda (x) (* x x)) $L)" '(1 4 9)'
add "(length (filter (lambda (x) (< x 3)) (cons 1 (cons 2 (cons 3 (cons 4 nil))))))" '2'
add "(foldl (lambda (a x) (+ a x)) 0 $L)" '6'
add "(foldr (lambda (x a) (cons x a)) nil $L)" '(1 2 3)'
add "(zip (cons 1 (cons 2 nil)) (cons (quote a) (cons (quote b) nil)))" '((1 . a) (2 . b))'
add "(assoc (quote b) (cons (cons (quote a) 1) (cons (cons (quote b) 2) nil)))" '(b . 2)'
add "(nth (cons 10 (cons 20 (cons 30 nil))) 1)" '20'
add "(last $L)" '3'
add "(take (cons 1 (cons 2 (cons 3 (cons 4 nil)))) 2)" '(1 2)'
add "(max (max 3 7) 5)" '7'
add "(abs (- 0 9))" '9'
add "(sum (map (lambda (x) (* x 10)) $L))" '60'
add "(define dbl (lambda (x) (* x 2))) (sum (map dbl $L))" '12'

tar czf "$work/run.tgz" -C comp-cmd . -C "$work" $progs
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "${VM}:slc_run.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist slc_run rmdir /s /q slc_run) & mkdir slc_run & cd slc_run & tar -xzf ..\slc_run.tgz & del ..\slc_run.tgz"' >/dev/null 2>&1
script=""
for p in $progs; do tag=$(printf '%s' "$p" | sed 's/\.lisp$//'); script="$script(echo ===$tag===) & (call load-cmd.cmd $p) & "; done
out=$(ssh -n "$VM" "cmd /c \"cd /d %USERPROFILE%\\slc_run & ${script}rem done\"" 2>/dev/null | tr -d '\r')

printf '%s\n' "$out" > "$work/got.txt"
printf '%s' "$exp_all" > "$work/exp.txt"
if diff -u "$work/exp.txt" "$work/got.txt" >/dev/null 2>&1; then
  echo "stdlib-cmd: PASS (cmd stdlib matches tests/stdlib.sh line-for-line on Windows)"
else
  echo "stdlib-cmd: MISMATCH"; diff -u "$work/exp.txt" "$work/got.txt" | sed 's/^/  /' | head -50
  exit 1
fi
