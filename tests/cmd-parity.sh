#!/bin/sh
# COMPILER parity guard: comp.cmd (native cmd self-host, run on Windows) must emit the
# SAME batch as comp.sh (the Lisp->cmd compiler running on sh, our trusted reference --
# comp.sh is itself guarded byte-identical to the interpreter by native-comp.sh).
#
# WHY this exists: the `~2` bug (mexpand corrupting a `cond`-named param list) made comp.cmd
# mis-compile EVERY predicate test, yet slipped through because the only differential guard
# compared comp.sh-vs-interpreter and NEVER ran comp.cmd's own output. This guard closes that
# gap with a corpus that exercises the codegen surface -- arith, all predicates, cells, the
# nested-call pattern `(car (cdr x))` that exposed `~2`, string ops, control forms, quote,
# recursion, special chars, and special-form-named params (cond/str/list -- mexpand regression).
#
# VM-gated: needs a real Windows cmd to run comp.cmd. Set PORTSH_WIN_SSH=user@host (e.g. the
# UTM Win11-ARM VM). Skips loudly otherwise. Deploys a fresh comp-cmd/ each run (tarball; with
# a taskkill first -- scp silently no-ops when comp.cmd is locked by a running cmd.exe).
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP cmd-parity: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH

[ -f comp.sh ] || sh build-comp.sh >/dev/null 2>&1
[ -d comp-cmd ] || sh build-comp-cmd.sh >/dev/null 2>&1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# ---- corpus: each fn exercises one codegen path; collisions avoided by distinct names. -----
# The names deliberately include cond/str/list params (mexpand regression) and (car (cdr x)).
cat > "$work/corpus.forms" <<'LISP'
(define t_add (lambda (a b) (+ a b)))
(define t_sub (lambda (a b) (- a b)))
(define t_mul (lambda (a b) (* a b)))
(define t_lt (lambda (a b) (if (< a b) (quote yes) (quote no))))
(define t_numeq (lambda (a b) (if (= a b) (quote yes) (quote no))))
(define t_eq (lambda (x) (if (eq? x (quote foo)) 1 2)))
(define t_null (lambda (x) (if (null? x) 1 2)))
(define t_pair (lambda (x) (if (pair? x) 1 2)))
(define t_atom (lambda (x) (if (atom? x) 1 2)))
(define t_num (lambda (x) (if (number? x) 1 2)))
(define t_strp (lambda (x) (if (string? x) 1 2)))
(define t_symp (lambda (x) (if (symbol? x) 1 2)))
(define t_car (lambda (x) (car x)))
(define t_cdr (lambda (x) (cdr x)))
(define t_cons (lambda (a b) (cons a b)))
(define t_cadr (lambda (x) (car (cdr x))))
(define t_caddr (lambda (x) (car (cdr (cdr x)))))
(define t_nestpred (lambda (f) (if (eq? (car f) (quote eq?)) 1 2)))
(define t_str (lambda (s) (str "a" s "b")))
(define t_sapp (lambda (a b) (string-append a b)))
(define t_strlen (lambda (s) (string-length s)))
(define t_substr (lambda (s) (substring s 1 2)))
(define t_sym2s (lambda (x) (symbol->string x)))
(define t_num2s (lambda (n) (number->string n)))
(define t_let (lambda (x) (let ((y (+ x 1))) (+ y y))))
(define t_cond2 (lambda (x) (cond ((eq? x 0) (quote z)) ((eq? x 1) (quote o)) (t (quote m)))))
(define t_begin (lambda (x) (begin (+ x 1) (+ x 2))))
(define t_ifnest (lambda (x) (if (if (pair? x) (null? (cdr x)) nil) 1 2)))
(define t_quote (lambda () (quote (a b c))))
(define t_qnest (lambda () (quote (a (b c) d))))
(define t_ops (lambda () (str "<" ">" "&" "|")))
(define t_loop (lambda (n acc) (if (eq? n 0) acc (t_loop (- n 1) (+ acc 1)))))
(define t_sumr (lambda (n) (if (eq? n 0) 0 (+ n (t_sumr (- n 1))))))
(define t_pcond (lambda (cond) cond))
(define t_pstr (lambda (str) str))
(define t_plist (lambda (list) list))
LISP

# ---- reference: comp.sh (local) ----
ref="$work/ref"; mkdir -p "$ref"
{ printf '('; cat "$work/corpus.forms"; printf ')'; } > "$work/prog.lisp"
mksh "$root/comp.sh" "$work/prog.lisp" "$ref" "$ref/main.lisp" >/dev/null 2>&1
nref=$(ls "$ref" | wc -l | tr -d ' ')
echo "comp.sh reference: $nref files"

# ---- deploy fresh comp-cmd to the VM (taskkill -> unlock -> extract) ----
tar czf "$work/comp-cmd.tgz" -C comp-cmd .
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; Remove-Item -Recurse -Force comp-cmd -EA SilentlyContinue; New-Item -ItemType Directory comp-cmd | Out-Null"' >/dev/null 2>&1 || true
scp -q "$work/comp-cmd.tgz" "$VM:comp-cmd/" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd comp-cmd && tar -xzf comp-cmd.tgz && del comp-cmd.tgz"' >/dev/null 2>&1

# ---- compile the corpus via comp.cmd on the VM (wrapper binds compile-program) ----
{ printf '(define compile-program (make-compiled "compile-program"))\r\n'
  printf '(compile-program (quote ('; cat "$work/corpus.forms"; printf ')) "cp_out" "cp_out/main.lisp")\r\n'
} > "$work/wrap.lisp"
scp -q "$work/wrap.lisp" "$VM:cp_wrap.lisp" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd comp-cmd && (if exist cp_out rmdir /s /q cp_out) && mkdir cp_out && comp.cmd ..\cp_wrap.lisp >nul 2>&1 & echo done"' >/dev/null 2>&1

# ---- fetch comp.cmd output, CR-normalise ----
out="$work/out"; mkdir -p "$out"
scp -q "$VM:comp-cmd/cp_out/*" "$out/" >/dev/null 2>&1 || true
for f in "$out"/*; do [ -f "$f" ] && tr -d '\r' <"$f" >"$f.lf" && mv "$f.lf" "$f"; done
nout=$(ls "$out" 2>/dev/null | wc -l | tr -d ' ')
echo "comp.cmd (VM) output: $nout files"

# ---- diff every file ----
if [ "$nout" = 0 ]; then
  echo "FAIL cmd-parity: comp.cmd produced no output (deploy/VM problem)"; exit 1
fi
fail=0
if diff -r "$ref" "$out" >"$work/diff.txt" 2>&1; then
  echo "cmd-parity: comp.cmd == comp.sh BYTE-IDENTICAL ($nout files)"
else
  echo "FAIL cmd-parity: comp.cmd DIVERGES from comp.sh:"
  head -40 "$work/diff.txt"
  fail=1
fi
[ "$fail" -eq 0 ]
