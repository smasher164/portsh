#!/bin/sh
# Record-and-replay handoff (sh) -- the core of the two-tier model. The interpreter (:ev) RECORDS its
# I/O effects to a log in execution order and can ABANDON after any K ops (PORTSH_LOG_STOP = the
# deterministic test stand-in for "the JIT became warm"; the real cold path checks the .ok marker). The
# JIT (load-sh) then RE-RUNS the program from source in REPLAY mode (PORTSH_REPLAY): each output op
# VERIFIES its computed value == the log then SUPPRESSES (already emitted by :ev); each world op RETURNS
# the logged result (the world is touched once, by :ev); when the log is exhausted it runs LIVE.
#
# INVARIANT, for EVERY split K: (:ev's first-K-ops output) + (JIT replay-then-live output) == the full
# program output, every effect happening exactly once. Also: world ops return the LOGGED result even if
# the world changed (we delete the file before replay), and a CORRUPTED log is caught at replay.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
[ -f load-sh.sh ] || sh build-load-sh.sh >/dev/null
[ -f portsh-full.cmd ] || sh build.sh >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
TAB=$(printf '\t')
printf 'alpha\nbeta\ngamma\n' > "$work/data.txt"
# mixed I/O: prints (output ops) interleaved with read-lines + file-exists? (world ops).
cat > "$work/p.lisp" <<'LISP'
(print 1)
(print (read-lines "data.txt"))
(print (file-exists? "data.txt"))
(print 2)
(print (file-exists? "nope.txt"))
(print 3)
LISP
ev()  { ( cd "$work" && env "$@" PORTSH_SCRIPT=1 mksh "$ROOT/portsh-full.cmd" p.lisp ); }
jit() { ( cd "$work" && env "$@" mksh "$ROOT/load-sh.sh" p.lisp ); }

ev > "$work/full" 2>/dev/null
ev PORTSH_LOG="$work/full.log" >/dev/null 2>&1 || true   # :ev exits 0 (no stop); full log
nops=$(grep -c "$TAB" "$work/full.log")
echo "full output ($nops I/O ops):"; sed 's/^/  /' "$work/full"

ok=0; bad=0
K=1
while [ "$K" -le "$nops" ]; do
  : > "$work/log"   # fresh log each run (lg_out APPENDS; a real run always starts from an empty log)
  ev PORTSH_LOG="$work/log" PORTSH_LOG_STOP="$K" > "$work/prefix" 2>/dev/null || true
  jit PORTSH_REPLAY="$work/log" > "$work/suffix" 2>/dev/null || true
  cat "$work/prefix" "$work/suffix" > "$work/got"
  if diff -q "$work/full" "$work/got" >/dev/null 2>&1; then ok=$((ok+1))
  else bad=$((bad+1)); printf '  FAIL split K=%s:\n' "$K"; diff "$work/full" "$work/got" | sed 's/^/    /'; fi
  K=$((K+1))
done
echo "split invariant: ok=$ok bad=$bad (over K=1..$nops)"

# world op returns the LOGGED result even if the world changed: full log, delete data.txt, replay.
ev PORTSH_LOG="$work/wlog" >/dev/null 2>&1 || true
rm -f "$work/data.txt"
if jit PORTSH_REPLAY="$work/wlog" >/dev/null 2>&1; then world_ok=PASS; else world_ok="FAIL (replay re-touched the deleted file)"; fi
printf 'world-op replay (file deleted): %s\n' "$world_ok"
printf 'alpha\nbeta\ngamma\n' > "$work/data.txt"

# self-validation: corrupt an output record -> replay must DETECT the mismatch and fail.
ev PORTSH_LOG="$work/clog" >/dev/null 2>&1 || true
sed 's/^3$/999/' "$work/clog" > "$work/clog2"   # log now claims a print emitted 999; JIT computes 3
if jit PORTSH_REPLAY="$work/clog2" >/dev/null 2>&1; then mism="FAIL (mismatch NOT detected)"; else mism=PASS; fi
printf 'self-validation (corrupt log detected): %s\n' "$mism"

# THE point of the two-tier model: the interpreter gives INSTANT startup but OVERFLOWS the host stack on
# deep non-tail recursion; the trampolined JIT completes it. So :ev records its prefix output then
# SEGFAULTS in the recursion (the "crash = abandon" handoff path, vs the PORTSH_LOG_STOP "warm = abandon"
# path above) -- and the JIT re-runs, replays the prefix, goes LIVE, and FINISHES the recursion :ev could
# not. Total handoff output must equal a straight (fully-JIT) run.
cat > "$work/rec.lisp" <<'LISP'
(define sumr (lambda (n) (if (eq? n 0) 0 (+ n (sumr (- n 1))))))
(print "computing")
(print (sumr 2000))
LISP
recev()  { ( cd "$work" && env "$@" PORTSH_SCRIPT=1 mksh "$ROOT/portsh-full.cmd" rec.lisp ); }
recjit() { ( cd "$work" && env "$@" mksh "$ROOT/load-sh.sh" rec.lisp ); }
recjit PORTSH_SCRIPT=1 > "$work/rfull" 2>/dev/null     # the JIT alone handles the whole thing (reference)
: > "$work/rlog"
recev PORTSH_LOG="$work/rlog" > "$work/rprefix" 2>/dev/null || true   # :ev logs "computing" then SEGFAULTS in sumr
recjit PORTSH_REPLAY="$work/rlog" > "$work/rsuffix" 2>/dev/null || true   # JIT replays prefix, completes sumr live
cat "$work/rprefix" "$work/rsuffix" > "$work/rgot"
ev_overflowed=$([ -s "$work/rprefix" ] && ! grep -q 2001000 "$work/rprefix" && echo y || echo n)  # :ev emitted prefix but NOT the sum
if diff -q "$work/rfull" "$work/rgot" >/dev/null 2>&1 && [ "$ev_overflowed" = y ]; then rec=PASS; else rec=FAIL; fi
printf 'recursion handoff (:ev overflows -> JIT completes): %s\n' "$rec"
[ "$rec" = PASS ] && { printf '  full (JIT-only):   '; tr '\n' '|' < "$work/rfull"; echo
                       printf '  :ev prefix (crash):'; tr '\n' '|' < "$work/rprefix"; echo
                       printf '  JIT replay+live:   '; tr '\n' '|' < "$work/rsuffix"; echo; }

[ "$bad" -eq 0 ] && [ "$world_ok" = PASS ] && [ "$mism" = PASS ] && [ "$rec" = PASS ]
