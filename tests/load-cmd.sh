#!/bin/sh
# Loader guard (CMD): read->compile->run for whole programs, on real Windows. load-cmd.cmd embeds the
# comp per-PC trampoline; top-level (define ...) forms compile to fns and top-level EXPRESSIONS are
# wrapped as thunks and evaluated in order, referencing prior defines. eval = compile + run, no :ev.
# Corpus MIRRORS tests/load.sh so sh/cmd parity is provable line-for-line.
# VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP load-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH
[ -f comp-cmd/load-cmd.cmd ] || sh build-load-cmd.sh >/dev/null

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# corpus: (program, expected-lines) -- EXACTLY tests/load.sh. Each program is one .lisp file; its
# expected output is the newline-joined values of its top-level expressions.
i=0; progs=""; exp_all=""
add() { printf '%s' "$1" > "$work/p$i.lisp"; progs="$progs p$i.lisp"; exp_all="$exp_all===p$i===
$2
"; i=$((i+1)); }
add '(define sq (lambda (x) (* x x))) (sq 7)' '49'
add '(define fact (lambda (n) (if (< n 2) 1 (* n (fact (- n 1)))))) (fact 5) (fact 6)' '120
720'
add '(define adder (lambda (n) (lambda (x) (+ x n)))) ((adder 10) 5) (let ((inc (adder 1))) (inc 99))' '15
100'
add '(define len (lambda (xs) (if (null? xs) 0 (+ 1 (len (cdr xs)))))) (len (cons 1 (cons 2 (cons 3 nil))))' '3'
add '(define classify (lambda (x) (cond ((< x 0) (quote neg)) ((eq? x 0) (quote zero)) (t (quote pos))))) (classify 5) (classify 0)' 'pos
zero'
add '(define map1 (lambda (f xs) (if (null? xs) nil (cons (f (car xs)) (map1 f (cdr xs)))))) (define dbl (lambda (x) (* x 2))) (define len (lambda (xs) (if (null? xs) 0 (+ 1 (len (cdr xs)))))) (len (map1 dbl (cons 1 (cons 2 (cons 3 nil)))))' '3'
add '(define x (+ 2 3)) (define y (* x x)) y' '25'
add '(define sq (lambda (n) (* n n))) (define a (sq 6)) (+ a 1)' '37'
add '(define xs (cons 1 (cons 2 (cons 3 nil)))) (define n (length xs)) (* n 10)' '30'

# deploy comp-cmd/ (per-PC fns + load-cmd.cmd) + the program files into one dir on the VM.
tar czf "$work/run.tgz" -C comp-cmd . -C "$work" $progs
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "${VM}:ldc_run.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist ldc_run rmdir /s /q ldc_run) & mkdir ldc_run & cd ldc_run & tar -xzf ..\ldc_run.tgz & del ..\ldc_run.tgz"' >/dev/null 2>&1
# run each program through load-cmd.cmd in ONE session; delimit each program's block with ===pN===.
script=""
for p in $progs; do tag=$(printf '%s' "$p" | sed 's/\.lisp$//'); script="$script(echo ===$tag===) & (call load-cmd.cmd $p) & "; done
out=$(ssh -n "$VM" "cmd /c \"cd /d %USERPROFILE%\\ldc_run & ${script}rem done\"" 2>/dev/null | tr -d '\r')

printf '%s\n' "$out" > "$work/got.txt"
printf '%s' "$exp_all" > "$work/exp.txt"
# compare block-by-block keyed on the ===pN=== delimiters (robust to per-program line counts).
if diff -u "$work/exp.txt" "$work/got.txt" >/dev/null 2>&1; then
  echo "load-cmd: PASS (cmd loader matches load-sh line-for-line on Windows)"
else
  echo "load-cmd: MISMATCH"; diff -u "$work/exp.txt" "$work/got.txt" | sed 's/^/  /' | head -40
  exit 1
fi
