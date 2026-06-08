#!/bin/sh
# eval keystone guard (CMD): eval = compile + run, comp EMBEDDED (no interpreter), on real Windows.
# comp-cmd/eval-cmd.cmd reads ONE thunk file `(define __ev (lambda () EXPR))`, compiles it in-process
# by trampolining through comp's per-PC .cmd files (compile-program), then dispatches __ev via the
# same K:/C:/RSL drive. Renders the result byte-identically to eval-sh's show_val. This is the cmd
# half of the JIT core, and the corpus MIRRORS tests/eval.sh so sh/cmd parity is provable.
# VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP eval-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH
[ -f comp-cmd/eval-cmd.cmd ] || sh build-eval-cmd.sh >/dev/null

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# corpus: (expr, expected) -- EXACTLY tests/eval.sh so sh and cmd must agree line-for-line.
i=0; exprs=""; exps=""
add() { printf '(define __ev (lambda () %s))' "$1" > "$work/t$i.lisp"; exprs="$exprs t$i.lisp"; exps="$exps$2
"; i=$((i+1)); }
add '(+ 1 2)' '3'
add '(* 6 7)' '42'
add '((lambda (x) (* x x)) 5)' '25'
add '(let ((x 5) (y 3)) (+ x y))' '8'
add '(let* ((x 2) (y (* x 3))) (+ x y))' '8'
add '(((lambda (a) (lambda (b) (+ a b))) 3) 4)' '7'
add '((((lambda (a) (lambda (b) (lambda (c) (+ a (+ b c))))) 1) 2) 3)' '6'
add '(case 2 (1 (quote one)) (2 (quote two)) (else (quote other)))' 'two'
add '(cond ((< 5 3) (quote a)) ((< 3 5) (quote b)) (t (quote c)))' 'b'
add '(when (< 1 2) (quote yes))' 'yes'
add '(unless (< 1 2) (quote no))' 'nil'
add '(and (< 1 2) (< 2 3))' 't'
add '(or nil (quote fallback))' 'fallback'
add '(if (eq? (quote x) (quote x)) 42 0)' '42'
add '(car (cdr (cons 1 (cons 2 (cons 3 nil)))))' '2'
add '(str "hello " "world")' 'hello world'
add '(null? nil)' 't'
add '(pair? (cons 1 2))' 't'

# deploy: comp-cmd/ (per-PC files + eval-cmd.cmd) + the thunk files, into one dir on the VM.
tar czf "$work/run.tgz" -C comp-cmd . -C "$work" $exprs
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "${VM}:evc_run.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist evc_run rmdir /s /q evc_run) & mkdir evc_run & cd evc_run & tar -xzf ..\evc_run.tgz & del ..\evc_run.tgz"' >/dev/null 2>&1
# run each thunk through eval-cmd.cmd in ONE session; one bare-value line per thunk, in order.
forlist=$(printf '%s' "$exprs" | sed 's/^ //')
out=$(ssh -n "$VM" "cmd /c \"cd /d %USERPROFILE%\\evc_run & (for %f in ($forlist) do @call eval-cmd.cmd %f)\"" 2>/dev/null | tr -d '\r')

# compare line-for-line.
ok=0; bad=0; n=0
echo "$exps" | while IFS= read -r exp; do :; done   # (no-op; keep shellcheck calm)
gotn=0
printf '%s\n' "$out" > "$work/got.txt"
printf '%s' "$exps" > "$work/exp.txt"
while IFS= read -r exp; do
  [ -n "$exp" ] || continue
  got=$(sed -n "$((n+1))p" "$work/got.txt")
  if [ "$got" = "$exp" ]; then ok=$((ok+1)); else bad=$((bad+1)); printf '  FAIL #%d: exp [%s] got [%s]\n' "$n" "$exp" "$got"; fi
  n=$((n+1))
done < "$work/exp.txt"
printf 'eval-cmd: ok=%d bad=%d\n' "$ok" "$bad"
[ "$bad" -eq 0 ] && echo "eval-cmd: PASS (cmd JIT matches eval-sh line-for-line on Windows)"
[ "$bad" -eq 0 ]
