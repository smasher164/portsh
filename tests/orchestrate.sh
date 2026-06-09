#!/bin/sh
# Prototype of the REAL two-tier front-end handoff (not the simulated PORTSH_LOG_STOP). For a cold run, the
# JIT "warms" in the BACKGROUND (here a timer stands in for cmd's ~3s self-extract) while :ev runs in the
# FOREGROUND in LOG mode, emitting the prefix the user sees instantly. :ev checks the .ok marker after each
# effect; the moment the background warmer drops it, :ev ABANDONS (exit 42). The driver then runs the warm
# JIT in REPLAY mode: it replays the logged prefix (each effect suppressed / returned from the log) and goes
# LIVE for the rest. Three :ev exit paths, all handled:
#   42    = warm mid-run            -> hand off, JIT replays prefix + finishes live
#   crash = stack overflow (deep recursion :ev can't do) -> hand off, trampolined JIT completes
#   0     = program finished before the JIT warmed -> no handoff, :ev's output is the whole thing
# In every case total output == a straight (fully-JIT) run, every effect exactly once.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# the cold-run driver: prints the program's output, reports the path taken via $LAST_PATH.
LAST_PATH=
run_handoff() {  # $1 = program file (in $work), $2 = warmup seconds (timer stand-in for JIT extraction)
  : > "$work/log"; rm -f "$work/ok"; : > "$work/pre"; : > "$work/suf"
  ( sleep "$2"; : > "$work/ok" ) & warmer=$!
  set +e
  ( cd "$work" && PORTSH_LOG="$work/log" PORTSH_OK="$work/ok" PORTSH_SCRIPT=1 mksh "$ROOT/portsh-full.cmd" "$1" ) > "$work/pre" 2>/dev/null
  evrc=$?
  set -e
  wait "$warmer" 2>/dev/null || true
  if [ "$evrc" -eq 0 ]; then LAST_PATH="finished-on-:ev (rc=0, no handoff)"
  else
    [ "$evrc" -eq 42 ] && LAST_PATH="warm-abandon (rc=42) -> JIT" || LAST_PATH="crash (rc=$evrc, overflow) -> JIT"
    ( cd "$work" && PORTSH_REPLAY="$work/log" mksh "$ROOT/load-sh.sh" "$1" ) > "$work/suf" 2>/dev/null
  fi
  cat "$work/pre" "$work/suf"
}
fulljit() { ( cd "$work" && PORTSH_SCRIPT=1 mksh "$ROOT/load-sh.sh" "$1" ); }   # reference: the JIT does it all

pass=0; fail=0
chk() {  # $1=label $2=prog $3=warmup  -- handoff output must equal the straight-JIT output
  fulljit "$2" > "$work/full" 2>/dev/null
  run_handoff "$2" "$3" > "$work/got"
  if diff -q "$work/full" "$work/got" >/dev/null 2>&1; then pass=$((pass+1)); res=PASS; else fail=$((fail+1)); res=FAIL; fi
  printf '  %-26s %-4s  path: %s\n' "$1" "$res" "$LAST_PATH"
  if [ "$res" = FAIL ]; then echo "    --- full ---"; sed 's/^/    /' "$work/full"; echo "    --- got ---"; sed 's/^/    /' "$work/got"; fi
}

printf '(print 1)(print 2)(print 3)(print 4)(print 5)' > "$work/io.lisp"
cat > "$work/rec.lisp" <<'LISP'
(define sumr (lambda (n) (if (eq? n 0) 0 (+ n (sumr (- n 1))))))
(print "computing")
(print (sumr 2000))
LISP

echo "two-tier front-end handoff (real concurrent warm signal):"
chk "warm mid-run -> JIT"       io.lisp  0.1   # JIT warms almost immediately -> :ev abandons early, JIT finishes
chk ":ev finishes first"        io.lisp  30    # JIT 'never' warms in time -> :ev does the whole short program
chk "overflow crash -> JIT"     rec.lisp 30    # :ev SEGFAULTS on deep recursion before warm -> JIT completes it
printf 'handoff: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
