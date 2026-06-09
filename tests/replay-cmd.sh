#!/bin/sh
# Record-and-replay handoff (cmd) -- the cmd mirror of tests/replay.sh, the two-tier model's core. The
# cmd interpreter (:ev, portsh-full.cmd) RECORDS its I/O effects to a log and can ABANDON after K ops
# (PORTSH_LOG_STOP -- the deterministic test stand-in for "the JIT extracted/warmed", which the real
# front-end signals via the .ok marker). The cmd JIT (load-cmd.cmd) then RE-RUNS from source in REPLAY
# mode (PORTSH_REPLAY): output ops verify+suppress, world ops return the logged result, until the log
# is exhausted, then LIVE. Validates: split K=2 (:ev prefix + JIT replay-then-live == full); exactly-
# once for a file APPEND (suppressed on replay -- not doubled); a world op returning the LOGGED list
# even after the file is deleted; and the cmd JIT completing deep recursion that cmd :ev overflows.
# VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP replay-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH
[ -d comp-cmd ] || sh build-comp-cmd.sh >/dev/null
[ -f comp-cmd/load-cmd.cmd ] || sh build-load-cmd.sh >/dev/null
[ -f portsh-full.cmd ] || sh build.sh >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

printf '(print 1)(print 2)(print 3)(print 4)' > "$work/io.lisp"
printf 'aa\nbb\ncc\n'                          > "$work/data.txt"
printf '(define d (read-lines "data.txt"))(print d)' > "$work/wd.lisp"
printf '(append-lines "acc.txt" (list "X"))(print "ok")' > "$work/ap.lisp"
printf '(define sumr (lambda (n) (if (eq? n 0) 0 (+ n (sumr (- n 1))))))(print "computing")(print (sumr 2000))' > "$work/rec.lisp"
cp portsh-full.cmd "$work/psf.cmd"
tar czf "$work/run.tgz" -C comp-cmd . -C "$work" io.lisp data.txt wd.lisp ap.lisp rec.lisp psf.cmd
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "$VM:rcrun.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "cd /d %USERPROFILE% & (if exist rc rmdir /s /q rc) & mkdir rc & cd rc & tar -xzf ..\rcrun.tgz & del ..\rcrun.tgz"' >/dev/null 2>&1
# run a cmd command line in the deployed dir; env vars use `set X=v&` (no quotes, no trailing space --
# a trailing space turns numeric `geq` into a string compare). exit 42 (abandon) kills the cmd /c, fine.
vm() { ssh -n -o ConnectTimeout=90 "$VM" "cmd /c \"cd /d %USERPROFILE%\\rc & $1\"" 2>/dev/null | tr -d '\r'; }
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  %-34s PASS\n' "$1"
       else fail=$((fail+1)); printf '  %-34s FAIL\n    want[%s]\n    got [%s]\n' "$1" "$3" "$2"; fi; }

vm 'set PORTSH_SCRIPT=1&call load-cmd.cmd io.lisp' > "$work/full"        # reference: JIT does it all
vm 'del log 2>nul&set PORTSH_LOG=log&set PORTSH_LOG_STOP=2&call psf.cmd io.lisp' > "$work/prefix"  # :ev, abandon@2
vm 'set PORTSH_REPLAY=log&call load-cmd.cmd io.lisp' > "$work/suffix"     # JIT replay prefix + live
cat "$work/prefix" "$work/suffix" > "$work/got"
ck "split K=2 (prefix+replay==full)" "$(cat "$work/got")" "$(cat "$work/full")"

# exactly-once: :ev appends X then abandons; replay must NOT re-append (acc.txt stays 1 line).
vm 'break>acc.txt&del aplog 2>nul&set PORTSH_LOG=aplog&set PORTSH_LOG_STOP=1&call psf.cmd ap.lisp' >/dev/null
vm 'set PORTSH_REPLAY=aplog&call load-cmd.cmd ap.lisp' >/dev/null
ck "exactly-once append-lines" "$(vm 'find /c /v "" acc.txt' | sed -n 's/.*: *//p')" "1"

# world op: record read-lines, DELETE the file, replay must return the LOGGED list (live print shows it).
vm 'del wdlog 2>nul&set PORTSH_LOG=wdlog&set PORTSH_LOG_STOP=1&call psf.cmd wd.lisp' >/dev/null
ck "read-lines returns logged (file gone)" "$(vm 'del data.txt 2>nul&set PORTSH_REPLAY=wdlog&call load-cmd.cmd wd.lisp')" "(aa bb cc)"

# the cmd JIT completes deep recursion that cmd :ev overflows (the crash-handoff foundation).
ck "cmd JIT deep recursion (sumr 2000)" "$(vm 'set PORTSH_SCRIPT=1&call load-cmd.cmd rec.lisp')" "$(printf 'computing\n2001000')"

printf 'replay-cmd: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
