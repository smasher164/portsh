#!/bin/sh
# Pack a portsh program into a SINGLE self-contained polyglot app that starts WARM on first run:
#
#   sh tools/pack-app.sh prog.lisp app.cmd
#
# app.cmd is one file, valid as both POSIX sh and Windows batch (same dual-validity trick as
# build-polyglot.sh):
#   sh  half: the always-JIT loader (load-sh.sh) with the program source embedded as a heredoc --
#             sh compilation is sub-second, so the sh side just compiles at run.
#   cmd half: the program is AOT-COMPILED here at pack time (comp.sh, the sh-hosted cmd emitter --
#             byte-identical to the native comp by the parity guards) and the per-PC artifacts +
#             _consts.cmd + _thunks are EMBEDDED as a second self-extractor arm (__pextract). First
#             run extracts the shared tooling cache (same build id as portsh.cmd -- the two share
#             %LOCALAPPDATA%\portsh\<build>) and the program artifacts (instant, no compiling), then
#             every run including the first executes the existing WARM fast path (in_warmrun):
#             no interpreter curtain, no background warmer, no compile -- ever.
#
# The program cache dir is keyed by the sha256 of prog.lisp, the SAME key the portsh.cmd front-end
# computes with certutil -- a packed app and a watcher-warmed `portsh.cmd prog.lisp` share the cache.
#
# The pack-time PARTITION below must mirror the loader's :in_part (build-interp-cmd.sh) EXACTLY --
# including accumulating kept forms in REVERSE (the __lamN lift numbering depends on form order), so
# packed artifacts are interchangeable with watcher-produced ones. tests/pack.sh guards this by
# diffing packed-app output against the unpacked engines.
set -eu
cd "$(dirname "$0")/.."
PROG=${1:?usage: sh tools/pack-app.sh prog.lisp app.cmd}
OUT=${2:?usage: sh tools/pack-app.sh prog.lisp app.cmd}
[ -f "$PROG" ] || { echo "pack-app: $PROG not found" >&2; exit 1; }
[ -f load-sh.sh ] || sh build-load-sh.sh >/dev/null
[ -f comp.sh ] || sh build-comp.sh >/dev/null
[ -f comp-cmd/interp-cmd.cmd ] || sh build-interp-cmd.sh >/dev/null
if [ ! -f comp-cmd.selfx.cmd ] || [ comp-cmd/interp-cmd.cmd -nt comp-cmd.selfx.cmd ]; then
  sh tools/pack-comp-cmd.sh >/dev/null
fi
BUILD=$(sed -n 's/^set "PORTSH_BUILD=\([0-9a-f][0-9a-f]*\)".*/\1/p' comp-cmd.selfx.cmd | head -1)
[ -n "$BUILD" ] || { echo "pack-app: could not read build id" >&2; exit 1; }
H=$(shasum -a 256 "$PROG" | cut -c1-16)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# ---- 1. partition (MIRROR of :in_part): defines of lambdas + atom defines kept verbatim; computed
# defines -> (define __evN (lambda () VAL)) with thunk action G:<name>; bare expressions -> thunk
# with action S. Kept/wrapped forms accumulate REVERSED (in_part conses onto XF). ----
python3 - "$PROG" "$work/partitioned.lisp" "$work/thunks" <<'PY'
import sys
prog, outp, thunksp = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(prog).read()
def forms(s):
    i = 0; n = len(s)
    while i < n:
        while i < n and s[i] != '(':
            if i < n and s[i] == ';':
                while i < n and s[i] != '\n': i += 1
            i += 1
        if i >= n: break
        d = 0; j = i; instr = False; cm = False
        while j < n:
            c = s[j]
            if cm:
                if c == '\n': cm = False
            elif instr:
                if c == '"': instr = False
            else:
                if c == ';': cm = True
                elif c == '"': instr = True
                elif c == '(': d += 1
                elif c == ')':
                    d -= 1
                    if d == 0: j += 1; break
            j += 1
        yield s[i:j]; i = j
def elements(f):
    # top-level elements of one (...) form, as text spans
    assert f[0] == '(' and f[-1] == ')'
    s = f[1:-1]; i = 0; n = len(s); out = []
    while i < n:
        while i < n and s[i] in ' \t\n\r': i += 1
        if i >= n: break
        if s[i] == '(' or (s[i] == "'" and i+1 < n and s[i+1] == '('):
            d = 0; j = i; instr = False
            while j < n:
                c = s[j]
                if instr:
                    if c == '"': instr = False
                else:
                    if c == '"': instr = True
                    elif c == '(': d += 1
                    elif c == ')':
                        d -= 1
                        if d == 0: j += 1; break
                j += 1
            out.append(s[i:j]); i = j
        elif s[i] == '"':
            j = i + 1
            while j < n and s[j] != '"': j += 1
            out.append(s[i:j+1]); i = j + 1
        else:
            j = i
            while j < n and s[j] not in ' \t\n\r()': j += 1
            out.append(s[i:j]); i = j
    return out
xf = []          # accumulated kept/wrapped forms; in_part CONSES -> reversed at the end
thunks = []      # source-order run list: __evN=S | __evN=G:<name>
nn = 0
def head_is(f, sym):
    e = elements(f)
    return len(e) > 0 and e[0] == sym, e
for f in forms(src):
    isdef, e = head_is(f, 'define')
    if not isdef:
        xf.append('(define __ev%d (lambda () %s))' % (nn, f))
        thunks.append('__ev%d=S' % nn); nn += 1
        continue
    if len(e) < 3 or e[1].startswith('(') or e[1].startswith('"') or e[1][0].isdigit() or (e[1][0] == '-' and len(e[1]) > 1 and e[1][1].isdigit()):
        sys.stderr.write('pack-app: skipping malformed define: %s\n' % f[:60]); continue
    name, val = e[1], e[2]
    if val.startswith('('):
        ev = elements(val)
        if len(ev) > 0 and ev[0] == 'lambda':
            xf.append(f)                       # lambda define: kept verbatim
        else:                                  # computed define -> placeholder + thunk binds G_<name>
            xf.append('(define %s nil)' % name)   # so gvar-names sees a global VAR (mirror in_keep)
            xf.append('(define __ev%d (lambda () %s))' % (nn, val))
            thunks.append('__ev%d=G:%s' % (nn, name)); nn += 1
    elif val.startswith("'"):                  # 'x reads as (quote x) = a pair -> computed
        xf.append('(define %s nil)' % name)
        xf.append('(define __ev%d (lambda () %s))' % (nn, val))
        thunks.append('__ev%d=G:%s' % (nn, name)); nn += 1
    else:
        xf.append(f)                           # atom define: kept verbatim -> G_<name> const
open(outp, 'w').write('(' + '\n'.join(reversed(xf)) + '\n)')
# _thunks: ONE line, entries space-separated with a LEADING space (mirror `set "THUNKS=!THUNKS! ..."`)
open(thunksp, 'w').write((' ' + ' '.join(thunks)) if thunks else '')
sys.stderr.write('pack-app: %d forms, %d thunks\n' % (len(xf), len(thunks)))
PY

# ---- 2. AOT-compile for cmd (gc off, like build-comp-cmd.sh) ----
mkdir "$work/art"
env NURSERY=999999999 mksh comp.sh "$work/partitioned.lisp" "$work/art" "$work/art/_main" >/dev/null
rm -f "$work/art/_main"
{ printf '%s\n' "$(cat "$work/thunks")"; } > "$work/art/_thunks"
echo "pack-app: $(ls "$work/art" | wc -l | tr -d ' ') cmd artifacts"

# ---- 3. weave app.cmd ----
python3 - load-sh.sh comp-cmd.selfx.cmd "$PROG" "$work/art" "$OUT" "$BUILD" "$H" <<'PY'
import sys, os
loadsh, selfx, prog, artdir, out, build, phash = sys.argv[1:8]

hdr = (
  ''':;[ -n "${PORTSH_COOKED-}" ]||{ t=$(mktemp);tr -d '\\r'<"$0">"$t";PORTSH_COOKED=1 PORTSH_SELF="$0" sh "$t" "$@";r=$?;rm -f "$t";exit $r; } #\n'''
  ''':<<'::CMDLITERAL'\n'''
  '''@echo off\n'''
  '''goto :CMDSTART\n'''
  '''::CMDLITERAL\n'''
)

# sh half: load-sh with the program embedded; materialize to a temp file and rewrite $@ so the
# stock file-mode dispatch runs it. Script semantics (prints only) to match the cmd front-end.
sh_half = open(loadsh, 'rb').read().decode('latin-1')
anchor = 'if [ "$#" -lt 1 ]; then jit_repl; exit $?; fi'
assert sh_half.count(anchor) == 1, "load-sh dispatch anchor not found"
progsrc = open(prog, 'rb').read().decode('latin-1')
marker = '__PORTSH_PACKED_SRC__'
assert marker not in progsrc, "program text collides with the heredoc marker"
packed_block = (
  '# ---- packed program (generated by tools/pack-app.sh) ----\n'
  '_pk=$(mktemp)\n'
  "trap 'rm -f \"$_pk\"' EXIT\n"
  "cat > \"$_pk\" <<'" + marker + "'\n"
  + progsrc.rstrip('\n') + '\n'
  + marker + '\n'
  'PORTSH_SCRIPT=${PORTSH_SCRIPT-1}\n'
  'set -- "$_pk" "$@"\n'
)
sh_half = sh_half.replace(anchor, packed_block + anchor)

# embedded extractors: the tooling selfx (rebound to %~2, same as build-polyglot.sh) ...
sx = open(selfx, 'rb').read().decode('latin-1').replace('\r\n', '\n')
sx_lines = sx.split('\n')
start = next(i for i, l in enumerate(sx_lines) if l.startswith('setlocal disableDelayedExpansion'))
body = []
for l in sx_lines[start:]:
    if l.startswith('set "PSDIR=%~1"'):
        body.append('set "PSDIR=%~2"')
    elif l.startswith('if "%PSDIR%"=="" '):
        continue
    else:
        body.append(l)
sx_body = '\n'.join(body).rstrip('\n')

# ... and the program-artifact selfx (same escaper as tools/pack-comp-cmd.sh)
def esc(s):
    o = []; inq = False
    for c in s:
        if c == '"':   o.append('"'); inq = not inq
        elif c == '%': o.append('%%')
        elif c == '^': o.append('^' if inq else '^^')
        elif c in '&|<>()': o.append(c if inq else '^' + c)
        else: o.append(c)
    return ''.join(o)
px = ['setlocal disableDelayedExpansion', 'set "PSDIR=%~2"', 'if not exist "%PSDIR%" md "%PSDIR%"']
for f in sorted(os.listdir(artdir)):
    data = open(os.path.join(artdir, f), 'rb').read().decode('latin-1')
    if data == '':
        px.append('break>"%%PSDIR%%\\%s"' % f)
        continue
    lines = data.split('\n')
    if lines and lines[-1] == '':
        lines = lines[:-1]
    px.append('>"%%PSDIR%%\\%s" (' % f)
    for ln in lines:
        px.append('echo(' + esc(ln.rstrip('\r')))
    px.append(')')
px.append('endlocal')
px_body = '\n'.join(px)

cmd_half = '''@echo off
rem ====== portsh PACKED APP front-end (build {B}, prog {H}) -- generated by tools/pack-app.sh ======
if "%~1"=="__extract" goto :PSELFX
if "%~1"=="__pextract" goto :PPROG
setlocal enabledelayedexpansion
set "SELF=%~f0"
rem ALL args are the program's (argv) -- capture into env (inherited by the interp child).
rem shift /1 (NOT plain shift: that rotates %0 too, breaking the %~f0 self-extract calls).
set "PORTSH_ARGC=0"
:pargs
if "%~1"=="" goto pargs_done
set "PORTSH_ARGV_!PORTSH_ARGC!=%~1"
set /a PORTSH_ARGC+=1
shift /1
goto pargs
:pargs_done
set "CACHE=%LOCALAPPDATA%\\portsh\\{B}"
if exist "%CACHE%\\.ok" goto pcache_ok
rem tooling cold: extract the embedded comp-cmd tree once per build (shared with portsh.cmd)
if exist "%CACHE%.tmp" rmdir /s /q "%CACHE%.tmp"
cmd /c call "!SELF!" __extract "%CACHE%.tmp" >nul 2>&1
move "%CACHE%.tmp" "%CACHE%" >nul 2>&1
rem promote only a COMPLETE extraction (a failed extract/move must not poison the cache with .ok)
if exist "%CACHE%\\interp-cmd.cmd" break>"%CACHE%\\.ok"
:pcache_ok
set "PATH=%CACHE%;%PATH%"
set "PCACHE=%CACHE%\\p\\{H}"
if exist "!PCACHE!\\.ok" goto prun
rem program cold: extract the EMBEDDED precompiled artifacts (no compiling -- the program was
rem AOT-compiled at pack time); every run including the first is the warm fast path.
if not exist "%CACHE%\\p" mkdir "%CACHE%\\p"
if exist "!PCACHE!.tmp" rmdir /s /q "!PCACHE!.tmp"
cmd /c call "!SELF!" __pextract "!PCACHE!.tmp" >nul 2>&1
move "!PCACHE!.tmp" "!PCACHE!" >nul 2>&1
if exist "!PCACHE!\\_thunks" break>"!PCACHE!\\.ok"
:prun
if not exist "!PCACHE!\\_thunks" (echo packed app: program artifacts missing 1>&2 & endlocal & exit /b 1)
set "PORTSH_OSRDIR=!PCACHE!"
set "PORTSH_SCRIPT=1"
cmd /c "call interp-cmd.cmd __packedrun"
set "RC=!errorlevel!"
endlocal & exit /b %RC%
:PPROG
{PX}
exit /b 0
:PSELFX
{SX}
exit /b 0
'''.replace('{B}', build).replace('{H}', phash).replace('{PX}', px_body).replace('{SX}', sx_body)

whole = hdr + sh_half.rstrip('\n') + '\nexit $?\n:CMDSTART\n' + cmd_half
whole = whole.replace('\r\n', '\n').replace('\n', '\r\n')
open(out, 'wb').write(whole.encode('latin-1'))
PY
chmod +x "$OUT"
echo "packed $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes, build $BUILD, prog $H)"
