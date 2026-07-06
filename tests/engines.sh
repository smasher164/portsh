#!/bin/sh
# Cross-ENGINE differential conformance: every fixture in tests/engines/*.lisp runs on every engine and
# must be byte-identical to its golden .out. This is the conformance metric for the REAL execution
# stack (the vau-kernel fixtures in tests/lisp/ cover the bootstrap evaluator separately).
#
#   local (always):  sh JIT (load-sh.sh)          sh interpreter (interp-sh.sh)
#                    the shipping polyglot's sh half (portsh.cmd)
#   VM   (optional): cmd JIT (load-cmd.cmd)       cmd interpreter (interp-cmd.cmd)
#                    PORTSH_WIN_SSH=user@host sh tests/engines.sh
#
# The VM legs run through generated DRIVER scripts: the comp-cmd tree is uploaded once per content
# hash (t_<hash>, persistent across runs), the fixtures are partitioned across PENG_PAR parallel ssh
# sessions, and each session loops its fixtures VM-side (one round-trip instead of ~40). Outputs come
# back as one tarball and are diffed locally.
#
# PORTSH_FAST=1: per-fixture compiled artifacts persist on the VM keyed by fixture hash; a populated
# cache re-runs via the warm PORTSH_OSRDIR path instead of recompiling. This is the fast DEV loop --
# it skips the compile path for unchanged fixtures, so the FULL (default) mode remains the
# conformance bar and must be what gates a release.
#
# Fixtures are deliberately SMALL: the cmd interpreter runs each in seconds.
set -u
cd "$(dirname "$0")/.."
root=$(pwd)
[ -f load-sh.sh ]   || sh build-load-sh.sh >/dev/null
[ -f interp-sh.sh ] || sh tools/build-interp-sh.sh >/dev/null
[ -f portsh.cmd ]   || sh build-polyglot.sh >/dev/null
SH=${PORTSH_SH:-mksh}
pass=0; fail=0
chk() {  # $1 engine-name, $2 fixture, $3 actual-output
  exp=$(cat "${2%.lisp}.out")
  if [ "$3" = "$exp" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf 'FAIL %-12s %s\n  want: %s\n  got : %s\n' "$1" "$(basename "$2")" "$(printf %s "$exp" | tr '\n' '|')" "$(printf %s "$3" | tr '\n' '|')"
  fi
}
for f in tests/engines/*.lisp; do
  chk "sh-jit"    "$f" "$(PORTSH_SCRIPT=1 PORTSH_TEST_VAR=hello $SH load-sh.sh "$f" alpha beta-42 2>&1 | tr -d '\r')"
  chk "sh-interp" "$f" "$(PORTSH_SCRIPT=1 PORTSH_TEST_VAR=hello $SH interp-sh.sh "$f" alpha beta-42 2>&1 | tr -d '\r')"
  chk "polyglot"  "$f" "$(PORTSH_SCRIPT=1 PORTSH_TEST_VAR=hello sh portsh.cmd "$f" alpha beta-42 2>&1 | tr -d '\r')"
done
# (exit n) must set the SCRIPT's exit code (output is goldened above; the code needs its own check)
xchk() { if [ "$2" = 3 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %-12s exitcode (got %s, want 3)\n' "$1" "$2"; fi; }
PORTSH_SCRIPT=1 $SH load-sh.sh tests/engines/exitcode.lisp >/dev/null 2>&1; xchk "sh-jit" "$?"
PORTSH_SCRIPT=1 $SH interp-sh.sh tests/engines/exitcode.lisp >/dev/null 2>&1; xchk "sh-interp" "$?"
PORTSH_SCRIPT=1 sh portsh.cmd tests/engines/exitcode.lisp >/dev/null 2>&1; xchk "polyglot" "$?"
if [ -n "${PORTSH_WIN_SSH:-}" ]; then
  VM=$PORTSH_WIN_SSH
  PAR=${PENG_PAR:-4}
  t0=$(date +%s)
  # build-comp-cmd.sh regenerates comp-cmd/ with rm -rf, dropping the loader and interp; rebuild
  # whichever is missing (load-cmd.cmd is deliberately NOT in the selfx pack -- it exists for these
  # engine-differential legs).
  [ -f comp-cmd/interp-cmd.cmd ] || sh build-interp-cmd.sh >/dev/null
  [ -f comp-cmd/load-cmd.cmd ]   || sh build-load-cmd.sh >/dev/null
  [ -f comp-cmd/map_pc0.cmd ]    || sh tools/build-stdlib-aot-cmd.sh >/dev/null
  [ -f comp-cmd/__p_add_pc0.cmd ] || sh tools/build-prims-aot-cmd.sh >/dev/null
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  # content key of the shipped toolchain: upload once per hash, reuse forever after
  TREEH=$(find comp-cmd -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  RUN="o_$$"
  TDIR="%USERPROFILE%\\peng\\t_$TREEH"
  crlf() { perl -pe 's/\r?\n/\r\n/'; }
  # ---- setup.cmd: prune stale trees/outputs, extract the tree if this hash is new, fresh fixtures --
  {
    echo '@echo off'
    echo 'setlocal enabledelayedexpansion'
    echo 'if not exist "%USERPROFILE%\peng" mkdir "%USERPROFILE%\peng"'
    echo 'cd /d %USERPROFILE%\peng'
    echo "for /d %%d in (t_*) do if not \"%%d\"==\"t_$TREEH\" rmdir /s /q \"%%d\""
    echo "if not exist t_$TREEH\\.ok ("
    echo "  rmdir /s /q t_$TREEH 2>nul"
    echo "  mkdir t_$TREEH"
    echo "  cd t_$TREEH"
    echo '  tar -xzf %USERPROFILE%\engt.tgz'
    echo '  break>.ok'
    echo "  cd .."
    echo ')'
    echo "cd t_$TREEH"
    echo 'for /d %%d in (o_*) do rmdir /s /q "%%d"'
    echo "mkdir $RUN"
    echo 'rmdir /s /q fx 2>nul'
    echo 'mkdir fx'
    echo 'cd fx'
    echo 'tar -xzf %USERPROFILE%\engfx.tgz'
    echo 'exit /b 0'
  } | crlf > "$work/setup.cmd"
  # ---- driver partitions: each loops its fixtures VM-side (interp leg FIRST so a warm-mode
  # PORTSH_OSRDIR can never leak into an interpretation run) ----
  i=0
  while [ $i -lt "$PAR" ]; do
    {
      echo '@echo off'
      echo 'setlocal enabledelayedexpansion'
      echo "cd /d $TDIR"
      echo 'set "PATH=%CD%;%PATH%"'
      echo 'set "PORTSH_SCRIPT=1"'
      echo 'set "PORTSH_TEST_VAR=hello"'
    } > "$work/d$i.raw"
    i=$((i+1))
  done
  n=0
  for f in tests/engines/*.lisp; do
    b=$(basename "$f" .lisp)
    fh=$(shasum -a 256 "$f" | cut -c1-16)
    d="$work/d$((n % PAR)).raw"
    {
      echo "> $RUN\\$b.itp.txt 2>&1 cmd /c \"call interp-cmd.cmd fx\\$b.lisp alpha beta-42\""
      echo "> $RUN\\$b.itp.rc echo !errorlevel!"
      if [ -n "${PORTSH_FAST:-}" ]; then
        # populate on miss with a PACKCOMPILE (compile-only) pass into a CLEAN dir -- normal
        # load-cmd runs emit no _thunks, and recompiling into a dirty dir lets the stale fixture
        # _consts.cmd shadow the comp's own constant pool at boot (nulled sentinels -> unmangled
        # names). Then ALWAYS run warm off the cache (the same path packed apps use).
        echo "if exist c_$fh\\_thunks goto warm_$b"
        echo "rmdir /s /q c_$fh 2>nul"
        echo "mkdir c_$fh"
        echo "cd c_$fh"
        echo 'set "PORTSH_PACKCOMPILE=1"'
        echo ">nul 2>&1 cmd /c \"call load-cmd.cmd ..\\fx\\$b.lisp\""
        echo 'set "PORTSH_PACKCOMPILE="'
        echo "cd .."
        echo ":warm_$b"
        echo "set \"PORTSH_OSRDIR=%CD%\\c_$fh\""
        echo "> $RUN\\$b.jit.txt 2>&1 cmd /c \"call interp-cmd.cmd fx\\$b.lisp alpha beta-42\""
        echo "> $RUN\\$b.jit.rc echo !errorlevel!"
        echo "set \"PORTSH_OSRDIR=\""
      else
        echo "rmdir /s /q c_$fh 2>nul"
        echo "mkdir c_$fh"
        echo "cd c_$fh"
        echo "> ..\\$RUN\\$b.jit.txt 2>&1 cmd /c \"call load-cmd.cmd ..\\fx\\$b.lisp alpha beta-42\""
        echo "> ..\\$RUN\\$b.jit.rc echo !errorlevel!"
        echo "cd .."
      fi
    } >> "$d"
    n=$((n+1))
  done
  i=0
  while [ $i -lt "$PAR" ]; do
    { cat "$work/d$i.raw"; echo 'exit /b 0'; } | crlf > "$work/d$i.cmd"
    i=$((i+1))
  done
  # ---- ship: tree (only if the VM doesn't have this hash yet), fixtures, setup, drivers ----
  tar czf "$work/engfx.tgz" -C tests/engines .
  if ! ssh -n "$VM" "cmd /c \"if exist $TDIR\\.ok (exit /b 0) else exit /b 1\"" >/dev/null 2>&1; then
    tar czf "$work/engt.tgz" -C comp-cmd .
    scp -q "$work/engt.tgz" "${VM}:engt.tgz"
  fi
  ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null; exit 0"' >/dev/null 2>&1 || true
  sleep 2
  DRVS=""; i=0
  while [ $i -lt "$PAR" ]; do DRVS="$DRVS $work/d$i.cmd"; i=$((i+1)); done
  scp -q "$work/engfx.tgz" "$work/setup.cmd" $DRVS "${VM}:"
  ssh -n "$VM" 'cmd /c call %USERPROFILE%\setup.cmd' >/dev/null 2>&1
  # ---- run the partitions in parallel; wait for all ----
  i=0
  while [ $i -lt "$PAR" ]; do
    ssh -n "$VM" "cmd /c call %USERPROFILE%\\d$i.cmd" >/dev/null 2>&1 &
    i=$((i+1))
  done
  wait
  # ---- collect one results tarball; diff locally ----
  ssh -n "$VM" "cmd /c \"cd /d $TDIR & tar -czf %USERPROFILE%\\engout.tgz $RUN\"" >/dev/null 2>&1
  scp -q "${VM}:engout.tgz" "$work/engout.tgz"
  ( cd "$work" && tar xzf engout.tgz )
  for f in tests/engines/*.lisp; do
    b=$(basename "$f" .lisp)
    chk "cmd-jit"    "$f" "$(tr -d '\r' < "$work/$RUN/$b.jit.txt" 2>/dev/null)"
    chk "cmd-interp" "$f" "$(tr -d '\r' < "$work/$RUN/$b.itp.txt" 2>/dev/null)"
  done
  for leg in jit itp; do
    rc=$(tr -dc 0-9 < "$work/$RUN/exitcode.$leg.rc" 2>/dev/null)
    if [ "$rc" = 3 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL cmd-%s exitcode (got %s, want 3)\n' "$leg" "${rc:-none}"; fi
  done
  ssh -n "$VM" "cmd /c \"cd /d $TDIR & rmdir /s /q $RUN\"" >/dev/null 2>&1 || true
  printf 'vm legs: %ss (%s mode, %s-way)\n' "$(( $(date +%s) - t0 ))" "$([ -n "${PORTSH_FAST:-}" ] && echo fast || echo full)" "$PAR"
fi
printf '\nengines: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
