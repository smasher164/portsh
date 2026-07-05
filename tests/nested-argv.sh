#!/bin/sh
# Nested portsh invocations (sh half): a child portsh.cmd launched via `run` must see ITS OWN
# argv/argv0, not the parent's. The parent exports PORTSH_ARGC/PORTSH_ARGV_*/PORTSH_ARGV0, which
# would satisfy the loader's capture guards in the child -- the shipped polyglot recaptures
# unconditionally at its dispatch (mirroring the cmd half's :pargs, which always recaptures).
set -u
cd "$(dirname "$0")/.."
[ -f portsh.cmd ] || sh build-polyglot.sh >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
{
  echo '(print (argv))'
  echo '(print (car (split (car (reverse (split (argv0) "/"))) ".")))'
} > "$work/child.lisp"
printf '(print (run-capture sh portsh.cmd %s childarg))\n' "$work/child.lisp" > "$work/parent.lisp"
out=$(sh portsh.cmd "$work/parent.lisp" parentarg 2>&1 | tr -d '\r')
want='((childarg) child)'
if [ "$out" = "$want" ]; then
  printf '\nnested-argv: pass=1 fail=0\n'; exit 0
else
  printf 'FAIL nested-argv\n  want: %s\n  got : %s\n' "$want" "$out"
  printf '\nnested-argv: pass=0 fail=1\n'; exit 1
fi
