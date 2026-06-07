#!/bin/sh
# Guard: a lambda parameter (or let binding) whose NAME shadows a special-form/macro head
# -- cond, str, list, quote, if, let, lambda, define -- must still resolve to the PARAMETER,
# not be mistaken for that form. This is an ABSOLUTE correctness check (not a comp.sh-vs-
# interpreter diff): the mexpand param-list bug made BOTH agree while WRONG, so a differential
# test can't catch it. We assert the compiled body reads the param (!p0!) and never leaks an
# undefined global G_<name>.
#
# Regression: mexpand walked the whole tree and rewrote (cond ...) by car, INCLUDING ifjump's
# (lambda (cond n) ...) param list -> ifjump lost its params -> body refs fell through to
# G_cond/G_n -> the malformed `if ~2`. The sh backend (no mexpand) was always correct.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
[ -f comp.sh ] || sh build-comp.sh >/dev/null 2>&1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
out="$work/out"; mkdir -p "$out"

names="cond str list quote if let lambda define begin car cdr"
{ printf '('
  for n in $names; do printf '(define p_%s (lambda (%s) %s))' "$n" "$n" "$n"; done
  printf ')'
} > "$work/prog.lisp"

mksh "$root/comp.sh" "$work/prog.lisp" "$out" "$out/main.lisp" >/dev/null 2>&1

pass=0; fail=0
for n in $names; do
  f="$out/p_${n}_pc0.cmd"
  if [ ! -f "$f" ]; then echo "FAIL p_$n: no output file"; fail=$((fail+1)); continue; fi
  # the body is just the param `n` -> must return it: `set "R=!p0!"`. Must NOT reference G_<n>.
  if grep -q 'set "R=!p0!"' "$f" && ! grep -q "G_$n" "$f"; then
    pass=$((pass+1))
  else
    echo "FAIL p_$n: param '$n' did not resolve to p0 (special-form-name shadowing bug)"
    sed -n '4,$p' "$f" | head -4
    fail=$((fail+1))
  fi
done

echo "binding-names: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
