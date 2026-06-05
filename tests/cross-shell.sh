#!/bin/sh
# Cross-shell consistency guard for the portsh sh kernel.
# ---------------------------------------------------------------------------
# portsh's promise is identical behavior on every POSIX sh. The subtle bugs that
# break it (a "local" left global on ksh93, a missed gc root that frees a live
# cell only on dash/bash/zsh under memory pressure, a `for x in $var` that won't
# split on zsh, zsh's FUNCNEST aborting deep recursion) are INVISIBLE on the
# happy-path shell and only surface under load. This guard makes them loud.
#
# It runs the kernel GENUINELY under every shell we can find -- cook the polyglot
# (strip CR) and set PORTSH_COOKED=1 so the first line does NOT re-exec into
# /bin/sh -- and asserts:
#   1. every lisp fixture matches its golden output, on every shell;
#   2. gc-stress programs are byte-identical ACROSS shells AND identical with gc
#      off vs heavy gc (catches root-miss / positional-frame clobbering);
#   3. comp's compiled output is byte-identical across shells.
# ---------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
work="$here/.work-xshell"; rm -rf "$work"; mkdir -p "$work"

# Build + cook the kernel (cooked = CR-stripped; bypasses the polyglot re-exec).
( cd "$root" && sh build.sh >/dev/null 2>&1 )
kernel="$work/portsh.sh"
tr -d '\r' < "$root/portsh-full.cmd" > "$kernel"

# Every shell we can find. ksh93 + zsh are the ones the no-local / FUNCNEST /
# word-split fixes were for; busybox-ash if present.
shells=""
for s in dash bash mksh zsh ksh; do command -v "$s" >/dev/null 2>&1 && shells="$shells $s"; done
command -v busybox >/dev/null 2>&1 && shells="$shells busybox"

# Genuine per-shell run: $1=shell $2=lispfile [$3=NURSERY]. COOKED=1 => no re-exec.
run() {
  _s=$1; _f=$2; _n=${3:-50000}; _r=$_s
  [ "$_s" = busybox ] && _r="busybox ash"
  env NURSERY="$_n" PORTSH_COOKED=1 PORTSH_SELF="$kernel" $_r "$kernel" "$_f" 2>&1
}

pass=0 fail=0
ck() { # $1=label $2=expected $3=actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL %s\n      exp: %s\n      got: %s\n' "$1" "$2" "$3"
  fi
}

printf 'cross-shell guard; shells:%s\n' "$shells"

# 1. lisp fixtures match golden on EVERY shell --------------------------------
for f in "$root"/tests/lisp/*.lisp; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .lisp); g="$root/tests/lisp/$n.out"; [ -f "$g" ] || continue
  exp=$(cat "$g")
  for s in $shells; do ck "fixture $n [$s]" "$exp" "$(run "$s" "$f")"; done
done

# 2. gc-stress: byte-identical across shells AND gc-off == heavy-gc -----------
# reverse(iota) exercises deep non-tail recursion + cons churn (the case that
# corrupted under the old set-scan gc); special chars cover the value path.
cat > "$work/gcstress.lisp" <<'L'
(define iota (lambda (n a) (if (< n 1) a (iota (- n 1) (cons n a)))))
(define suml (lambda (xs a) (if (null? xs) a (suml (cdr xs) (+ a (car xs))))))
(print (suml (reverse (iota 120 nil)) 0))
(print (length (append (iota 40 nil) (iota 40 nil))))
(print (str "ops[" "!" "&" "<" ">" "]"))
L
ref=""
for s in $shells; do
  off=$(run "$s" "$work/gcstress.lisp" 999999999)   # gc effectively off
  on=$(run "$s" "$work/gcstress.lisp" 20)           # gc fires constantly
  [ -z "$ref" ] && ref=$off
  ck "gcstress gc-off==heavy-gc [$s]" "$off" "$on"
  ck "gcstress cross-shell      [$s]" "$ref" "$on"
done

# 3. comp's compiled output byte-identical across shells ----------------------
cat "$root/src/compile.lisp" > "$work/gen.lisp"
printf '\n(compile-program (quote ((define inc (lambda (x) (+ x 1)))(define sumto (lambda (n a) (if (< n 1) a (sumto (- n 1) (+ a n))))))) "%s/out" "%s/out/p.lisp")(print (quote OK))\n' "$work" "$work" >> "$work/gen.lisp"
cref=""
for s in $shells; do
  rm -rf "$work/out"; mkdir -p "$work/out"
  run "$s" "$work/gen.lisp" 30 >/dev/null
  h=$(cat "$work/out/sumto.cmd" "$work/out/inc.cmd" 2>/dev/null | cksum)
  [ -z "$cref" ] && cref=$h
  ck "compile cross-shell [$s]" "$cref" "$h"
done

echo
printf 'cross-shell: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
