#!/bin/sh
# Native-comp equivalence guard.
# ---------------------------------------------------------------------------
# The native (compiled) comp -- comp's own source compiled to sh by the Lisp->sh
# backend (src/compile-sh.lisp), assembled by build-comp.sh into comp.sh -- MUST
# produce byte-identical batch output to the interpreter running src/compile.lisp.
# It is the only check that exercises the compiled execution model end-to-end.
#
# This guard exists because the trampoline-codegen rewrite shipped a cluster of bugs
# that are INVISIBLE to a static scan and only corrupt comp's OUTPUT at runtime:
#   * NFP = FP + SIZE_<callee> instead of SIZE_<current-fn> -> callee frames overlap and
#     clobber the caller's params (surfaced as a path "P:35" instead of the outdir);
#   * unquoted RHS in the frame load/store evals and in `hp_cons a b` -> any value with a
#     SPACE (every "set x=y" / "goto :eof" batch line comp emits) word-splits -> a single
#     output line becomes "set" + a stray NIL;
#   * dropped sh-mangle chars (*/=), shdet not detagging cst (double-tag T:T:), ctest with
#     no truthiness fallback, global-constant refs -> ${NIL}.
# Every one of these makes native output != interpreter output, so the diff below is loud.
#
# The test programs deliberately force the failure modes: string literals WITH SPACES
# (-> word-split), deep-ish self-recursion (-> frame reuse), nested non-tail calls (-> live
# spill/restore), cond/eq?/</arith, and string-append/substring.
# ---------------------------------------------------------------------------
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
cd "$root"
work="$here/.work-native"; rm -rf "$work"; mkdir -p "$work"

# Build the native compiler (comp.sh) + a cooked kernel for the interpreter reference.
sh build-comp.sh >/dev/null 2>&1
kernel="$work/portsh.sh"; tr -d '\r' < portsh-full.cmd > "$kernel"

# The program under test: a bare sequence of top-level (define ...) forms. Note the string
# literals containing spaces -- those are exactly what the word-split bug shredded.
cat > "$work/prog.forms" <<'L'
(define inc (lambda (x) (+ x 1)))
(define sumto (lambda (n a) (if (< n 1) a (sumto (- n 1) (+ a n)))))
(define greet (lambda (s) (str "Hello " s ", welcome!")))
(define classify (lambda (x) (cond ((< x 0) "is negative") ((= x 0) "is zero") (t "is positive"))))
(define rjoin (lambda (xs acc) (if (null? xs) acc (rjoin (cdr xs) (str acc " " (car xs))))))
(define depth (lambda (n) (if (< n 1) 0 (+ 1 (depth (- n 1))))))
L

pass=0 fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  exp:%s\n  got:%s\n' "$1" "$2" "$3"; fi; }

# 1. interpreter reference: load compile.lisp, call compile-program on the (quoted) forms.
ref="$work/ref"; mkdir -p "$ref"
{ cat src/compile.lisp
  printf '\n(compile-program (quote ('; cat "$work/prog.forms"; printf ')) "%s" "%s/main.lisp")(print (quote OK))\n' "$ref" "$ref"
} > "$work/ref.lisp"
env NURSERY=999999999 PORTSH_COOKED=1 PORTSH_SELF="$kernel" mksh "$kernel" "$work/ref.lisp" </dev/null >/dev/null 2>&1

# 2. native comp.sh: same forms, wrapped as ONE parenthesised list (comp.sh's input contract).
out="$work/out"; mkdir -p "$out"
{ printf '('; cat "$work/prog.forms"; printf ')'; } > "$work/prog.lisp"
mksh "$root/comp.sh" "$work/prog.lisp" "$out" "$out/main.lisp" >/dev/null 2>&1

# 3. byte-identical? (compare every emitted file)
ck "native comp.sh ran (produced files)" "yes" "$([ -n "$(ls "$out" 2>/dev/null)" ] && echo yes || echo no)"
if diff -r "$ref" "$out" >"$work/diff.txt" 2>&1; then
  pass=$((pass+1)); echo "native == interpreter: BYTE-IDENTICAL ($(ls "$out" | wc -l | tr -d ' ') files)"
else
  fail=$((fail+1)); echo "FAIL native != interpreter:"; head -40 "$work/diff.txt"
fi

# 4. the word-split canary, made explicit: greet emits a line with spaces -> it must survive intact.
ck "spaces preserved (greet line has 'Hello ')" \
   "$(grep -c 'Hello ' "$ref/greet.cmd" 2>/dev/null || echo 0)" \
   "$(grep -c 'Hello ' "$out/greet.cmd" 2>/dev/null || echo 0)"

printf 'native-comp: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
