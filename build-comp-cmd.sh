#!/bin/sh
# Assemble comp-cmd/ -- the NATIVE (compiled) cmd compiler, the cmd analog of build-comp.sh.
#
# comp.sh (sh side) is ONE file: kernel + comp-compiled.sh + a trampoline driver.
# The cmd side is MULTI-FILE: comp compiles each of its own functions to its own <label>.cmd
# (compile-program's multi-file codegen), and a compiled fn reaches the others via
# `call <label>.cmd` -- O(1) file open, which sidesteps cmd's O(file-position) `call :label`
# scan that made the old single-file comp.cmd crawl.
#
# Layout produced in comp-cmd/:
#   comp.cmd        -- driver: the cmd kernel (heap/reader/eval/sentinels) + `call _consts.cmd`,
#                      run as  `comp.cmd WRAPPER.lisp`  where WRAPPER binds compile-program to its
#                      compiled .cmd via make-compiled and invokes it on the input forms.
#   <label>.cmd     -- comp's own functions, compiled to batch by comp(comp).
#   _consts.cmd     -- comp's G_ constants (call'ed once at startup; uses kernel sentinels).
#   rdfield.cmd write-lines.cmd append-lines.cmd gc.cmd -- the I/O runtime, split one file per
#                      entry (compiled code calls them as separate files).
#
# Usage:  sh build-comp-cmd.sh         (regenerates comp-cmd/ from comp.sh + portsh-runtime.cmd)
set -eu
cd "$(dirname "$0")"
root=$(pwd)
out="$root/comp-cmd"

[ -f comp.sh ] || sh build-comp.sh >/dev/null
[ -f portsh-runtime.cmd ] || sh build.sh >/dev/null
[ -f portsh-full.cmd ] || sh build.sh >/dev/null

rm -rf "$out"; mkdir -p "$out"

# 1. comp(comp): compile comp's own source (src/compile.lisp) to batch -- one <label>.cmd per fn,
#    + _consts.cmd, + a residual main.lisp -- straight into comp-cmd/. Use the native comp.sh
#    (fast, gc-off) since it's byte-identical to the interpreter.
#    comp ALSO calls 7 helpers that live in stdlib.lisp, not compile.lisp (caar/cadr/caddr/not/
#    append/reverse/assoc) -- they MUST be compiled too or the native comp `call assoc.cmd`s a
#    missing file (silent fail -> heap garbage). Same 7 the sh-side bootstrap (tools/bootstrap-comp.sh)
#    pulls in. Prepend them to comp's forms.
python3 - src/stdlib.lisp src/compile.lisp "$out/.compile.wrapped.lisp" <<'PY'
import sys,re
stdlib,comp,outp=sys.argv[1],sys.argv[2],sys.argv[3]
deps={'caar','cadr','caddr','not','append','reverse','assoc'}
def forms(s):
    i=0;n=len(s)
    while i<n:
        while i<n and s[i]!='(':
            if s[i]==';':
                while i<n and s[i]!='\n': i+=1
            i+=1
        if i>=n: break
        d=0;j=i;instr=False;cm=False
        while j<n:
            c=s[j]
            if cm:
                if c=='\n': cm=False
            elif instr:
                if c=='"': instr=False
            else:
                if c==';': cm=True
                elif c=='"': instr=True
                elif c=='(': d+=1
                elif c==')':
                    d-=1
                    if d==0: j+=1; break
            j+=1
        yield s[i:j]; i=j
keep=[]
for f in forms(open(stdlib).read()):
    m=re.match(r'\(define\s+([^\s()]+)',f)
    if m and m.group(1) in deps: keep.append(f)
with open(outp,'w') as o:
    o.write('('); o.write('\n'.join(keep)); o.write('\n'); o.write(open(comp).read()); o.write(')')
PY
env NURSERY=999999999 mksh comp.sh "$out/.compile.wrapped.lisp" "$out" "$out/main.lisp"
rm -f "$out/.compile.wrapped.lisp"
nfn=$(ls "$out"/*.cmd | grep -vc '_consts.cmd')
echo "comp(comp): $nfn compiled fn .cmd files + _consts.cmd"

# 2. Split the baked runtime (portsh-runtime.cmd: labels :rdfield :write-lines :append-lines :gc)
#    into one file per entry. `call X.cmd` runs from line 1, so each file just `goto`s its entry
#    then falls through the full runtime body (all the internal :wl_emit_c/:al_loop_c labels are
#    present for the same-file `call :helper`/`goto` to resolve). No setlocal -> R reaches caller,
#    and delayed expansion + !HD!/!BANG!/!LT!/G_* are inherited in-process from comp.cmd.
for entry in rdfield write-lines append-lines gc print read-lines file-existszzQ; do
  { printf 'goto :%s\r\n' "$entry"; cat portsh-runtime.cmd; } > "$out/$entry.cmd"
done
echo "runtime: rdfield.cmd write-lines.cmd append-lines.cmd gc.cmd print.cmd read-lines.cmd file-existszzQ.cmd"

# 3. Driver comp.cmd = the BARE cmd kernel (portsh.cmd, NOT portsh-full.cmd) + `call _consts.cmd`.
#    Crucially NO stdlib: the native comp needs only the reader + eval dispatch + heap, and comp's
#    own stdlib deps (caar/cadr/...) are compiled to their own .cmd files. Booting the interpreted
#    stdlib is the single slowest thing on the VM (linear env lookups over a file-backed heap), so
#    dropping it makes startup ~instant. The wrapper's make-compiled binding routes the
#    compile-program call to compile-program.cmd via :ev_compiled. Inject _consts right after
#    `call :setup_global` (sentinels are set by then; _consts references !BANG!/!LT!/...).
#    Also DROP the __PORTSH_PAYLOAD__ marker: with it, boot wastes time `set /p`-skipping the whole
#    kernel looking for a (nonexistent) stdlib payload -- pure overhead on the slow VM.
awk '
  { print }
  /call :setup_global\r?$/ && !done { print "call _consts.cmd"; done=1 }
' portsh.cmd | grep -v '^__PORTSH_PAYLOAD__' | perl -pe 's/\r?\n/\r\n/' > "$out/comp.cmd"
echo "driver: comp.cmd ($(wc -c < "$out/comp.cmd") bytes)"

echo "built comp-cmd/ ($(ls "$out" | wc -l | tr -d ' ') files)"
