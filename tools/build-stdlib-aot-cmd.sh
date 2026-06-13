#!/bin/sh
# Compile the AOT-able applicative subset of src/stdlib.lisp to NATIVE cmd per-PC .cmd files and
# install them into comp-cmd/, so eval-cmd/load-cmd can call map/foldl/filter/zip/... BY NAME -- no
# interpreter, no per-run stdlib load. The cmd analog of tools/build-stdlib-aot.sh (which emits the
# single src/stdlib-aot.sh for the sh side). Uses comp.sh (native, byte-identical, fast).
#
# SKIPS (same as the sh side): vau forms, the comp-inlined tpreds (number?/string?/symbol?/pair?).
# Variadic lambdas (begin/str) ARE compiled (value position; call position stays a comp form).
# ALSO skips comp's own 7 deps (caar/cadr/caddr/not/append/reverse/
# assoc) -- those are ALREADY compiled into comp-cmd/ by build-comp-cmd.sh; the stdlib fns reach them
# via `call <dep>_pc0.cmd` just like comp does.
#
# Lifted lambdas are renamed __lam -> __sl (files + refs) so they can't COLLIDE with a user program's
# own __lamN, which load-cmd compiles fresh into the same dir at runtime (both counters start at 0).
# Consts land in _consts_std.cmd (content-named, so idempotent with comp's _consts.cmd); build-eval-cmd
# / build-load-cmd inject a `call _consts_std.cmd` at boot.
set -eu
cd "$(dirname "$0")/.."
[ -f comp.sh ] || sh build-comp.sh >/dev/null
[ -d comp-cmd ] || sh build-comp-cmd.sh >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - src/stdlib.lisp "$work/sub.lisp" "$work/reg.cmd" <<'PY'
import sys, re
src_path, out, regp = sys.argv[1], sys.argv[2], sys.argv[3]
skip = {'number?','string?','symbol?','pair?',          # comp inlines these (tpreds)
        '<=','>','>=',                                  # call-position = n-ary builtin chains; value-position = __p_ story (mirror the sh installer)
        'caar','cadr','caddr','not','append','reverse','assoc'}  # already in comp-cmd/
deps = ['caar','cadr','caddr','not','append','reverse','assoc']  # ...but registered below like the rest
def forms(s):
    i=0;n=len(s)
    while i<n:
        while i<n and s[i]!='(':
            if i<n and s[i]==';':
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
for f in forms(open(src_path).read()):
    m=re.match(r'\(define\s+([^\s()]+)\s+(.*)', f, re.S)
    if not m: continue
    name, body = m.group(1), m.group(2).lstrip()
    if name in skip: continue
    if body.startswith('(vau'): continue
    keep.append(f)
open(out,'w').write('('+'\n'.join(keep)+'\n)')
# G_ registrations (-> _consts_std.cmd, called at every engine boot): a stdlib fn referenced from a
# user program is an unknown global there -- compiled code reads !G_<name>! (raw key, cmd vars allow
# -/?) and the interp's iresolve falls back to G_<name>. C:<label> routes to <label>_pc<n>.cmd.
# Registration covers the kept fns AND comp's 7 deps (their files come from build-comp-cmd.sh).
def cmdmangle(s):
    return ''.join({'>':'zzG','<':'zzL','&':'zzA','|':'zzP','*':'zzS','?':'zzQ'}.get(c,c) for c in s)
names = [re.match(r'\(define\s+([^\s()]+)', f).group(1) for f in keep] + deps
with open(regp,'w') as r:
    r.write('rem G_ registrations: stdlib fns as first-class globals (cross-unit value/operator refs)\n')
    for n in names:
        r.write('set "G_%s=C:%s"\n' % (n, cmdmangle(n)))
sys.stderr.write("AOT stdlib fns (cmd): %d (+%d G_ registrations)\n" % (len(keep), len(names)))
PY

mkdir "$work/out"
env NURSERY=999999999 mksh comp.sh "$work/sub.lisp" "$work/out" "$work/out/main.lisp"
rm -f "$work/out/main.lisp"

# namespace the lifted closures __lam -> __sl (filenames first, then refs in every file).
for f in "$work/out"/__lam*.cmd; do [ -e "$f" ] || continue; mv "$f" "$(echo "$f" | sed 's/__lam/__sl/')"; done
for f in "$work/out"/*.cmd; do perl -i -pe 's/__lam/__sl/g' "$f"; done

# install: consts + G_ registrations -> _consts_std.cmd (idempotent merge at boot), fn files -> comp-cmd/.
[ -f "$work/out/_consts.cmd" ] || : > "$work/out/_consts.cmd"
cat "$work/reg.cmd" >> "$work/out/_consts.cmd"
mv "$work/out/_consts.cmd" comp-cmd/_consts_std.cmd
cp "$work/out"/*.cmd comp-cmd/
nfn=$(ls "$work/out"/*.cmd | grep -vc '__sl')
# _rt.lst: the pc files a RUNTIME-ONLY tree needs beyond the non-pc side files -- this installer's
# outputs (incl. __sl lifts) plus comp's 7 stdlib deps (compiled by build-comp-cmd.sh, but reached
# at runtime by the stdlib fns themselves). build-prims-aot-cmd.sh APPENDS its files; consumed by
# `tools/pack-comp-cmd.sh rt` (the minimal selfx packed apps embed). Lives in-tree so a comp-cmd
# regen drops list and files together.
{ ls "$work/out"
  for d in caar cadr caddr not append reverse assoc; do (cd comp-cmd && ls "${d}"_pc*.cmd); done
} | sort -u > comp-cmd/_rt.lst
echo "installed stdlib into comp-cmd/: $(ls "$work/out"/*.cmd | wc -l | tr -d ' ') .cmd files + _consts_std.cmd; wrote _rt.lst"
