#!/bin/sh
# Regenerate src/comp-compiled.sh: comp (src/compile.lisp) + its stdlib deps, compiled to
# native sh by the Lisp->sh backend (src/compile-sh.lisp). This is the one-time, ~15-min
# self-compile (the Futamura bootstrap); run it ONLY when compile.lisp or compile-sh.lisp
# change. Normal use just consumes the checked-in src/comp-compiled.sh via build-comp.sh.
#
# Strategy: compile each top-level form in ITS OWN process (one fn = tiny heap, no gc-thrash),
# fanned out across cores. gc-OFF for the compile (the big string-heavy fns are 2-5x faster
# without the O(HEAP_N) sweep, and a single fn's heap is small anyway).
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
# Parameterized: SRC = the Lisp file to compile to native sh (default comp itself);
# OUT = the output .sh; DEPS = stdlib helper names to prepend (DEPS="" = none, e.g. when SRC
# is self-contained). Defaults reproduce the comp.sh bootstrap exactly. With SRC=compile-sh.lisp
# this self-hosts the Lisp->sh backend -> the native sh-emitter (see build-comp-sh.sh).
SRC="${SRC:-src/compile.lisp}"
OUT="${OUT:-src/comp-compiled.sh}"
DEPS="${DEPS-caar cadr caddr not append reverse assoc}"
# WORK=<dir> keeps a persistent (resumable) workdir: a crash on one form (e.g. cexpr OOM/stack)
# won't wipe the other 85 already-compiled outputs. Unset -> ephemeral mktemp, cleaned on exit.
if [ -n "${WORK:-}" ]; then work=$WORK; mkdir -p "$work"; else work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; fi

[ -f portsh-full.cmd ] || sh build.sh >/dev/null
tr -d '\r' < portsh-full.cmd > "$work/pf.sh"
par=$(( $(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) - 2 ))
[ "$par" -lt 1 ] && par=1

# gen1: a top-level (define ...) -> sh. A lambda -> compile-def-sh; an atom const -> a G_<name> init.
cat > "$work/gen1.lisp" <<'L'
(define cval (lambda (v) (cond ((string? v) (str "T:" v)) ((number? v) (str "I:" (number->string v))) (t (str "S:" (symbol->string v))))))
(define gen1 (lambda (f)
  (if (if (pair? (car (cdr (cdr f)))) (eq? (car (car (cdr (cdr f)))) (quote lambda)) nil)
    (compile-def-sh f)
    (list (str "G_" (symbol->string (car (cdr f))) "='" (cval (car (cdr (cdr f)))) "'")))))
L

# Extract top-level paren-balanced forms (skipping ; comments and "strings") from a .lisp file.
# stdlib gives comp the 7 deps it calls that live there (caar/cadr/caddr/not/append/reverse/assoc).
extract() {  # $1 = lisp file, $2 = output dir, $3 = optional space-list of names to keep (else all)
  python3 - "$1" "$2" "${3:-}" <<'PY'
import sys, os, re
src=open(sys.argv[1]).read(); outdir=sys.argv[2]; keep=sys.argv[3].split() if sys.argv[3] else None
os.makedirs(outdir, exist_ok=True)
i=0; n=len(src); k=0
while i<n:
    while i<n and src[i]!='(':
        if src[i]==';':
            while i<n and src[i]!='\n': i+=1
        i+=1
    if i>=n: break
    depth=0; j=i; instr=False; comment=False
    while j<n:
        c=src[j]
        if comment:
            if c=='\n': comment=False
        elif instr:
            if c=='"': instr=False
        else:
            if c==';': comment=True
            elif c=='"': instr=True
            elif c=='(': depth+=1
            elif c==')':
                depth-=1
                if depth==0: j+=1; break
        j+=1
    form=src[i:j]; i=j
    m=re.match(r'\(define\s+([^\s()]+)', form)
    nm=m.group(1) if m else None
    if keep is not None and nm not in keep: continue
    open(f'{outdir}/{k:03d}.lisp','w').write(form); k+=1
print(k)
PY
}

mkdir -p "$work/forms" "$work/std" "$work/out"
nf=$(extract "$root/$SRC" "$work/forms")
if [ -n "$DEPS" ]; then ns=$(extract "$root/src/stdlib.lisp" "$work/std" "$DEPS"); else ns=0; fi
echo "extracted $nf forms from $SRC + $ns stdlib deps; compiling gc-off, P=$par ..."

# per-form compiler (own process, gc-off); reads compile-sh.lisp FRESH so edits are picked up
cat > "$work/one.sh" <<EOF
#!/bin/sh
d=\$1; k=\$2
[ -s "\$d/\$k.sh" ] && exit 0   # resume: already compiled this form (persistent WORK)
{ cat "$root/src/compile-sh.lisp" "$work/gen1.lisp"
  printf '(write-lines "%s/%s.sh" (gen1 (quote ' "\$d" "\$k"; cat "\$d/\$k.lisp"; printf ')))(print (quote OK))\n'
} > "\$d/\$k.drv.lisp"
# The codegen runs INTERPRETED (mksh shell-function recursion = C-stack); the 2 biggest comp
# fns (cexpr/csubstr) overflow the default 8MB stack -- the trampoline codegen recurses deeper
# than the old direct-call one, so cexpr segfaults without this bump. 65500KB = macOS hard cap.
ulimit -s 65500 2>/dev/null || true
env NURSERY=999999999 PORTSH_COOKED=1 PORTSH_SELF="$work/pf.sh" mksh "$work/pf.sh" "\$d/\$k.drv.lisp" </dev/null >/dev/null 2>&1
EOF
chmod +x "$work/one.sh"

[ -n "$DEPS" ] && ls "$work/std"/*.lisp | sed 's|.*/||;s|\.lisp$||' | xargs -P "$par" -I{} "$work/one.sh" "$work/std" {}
ls "$work/forms"/*.lisp | sed 's|.*/||;s|\.lisp$||' | xargs -P "$par" -I{} "$work/one.sh" "$work/forms" {}

# assemble: header + stdlib (sorted) + comp forms (in source order)
{
  echo "# $OUT — $SRC + its stdlib deps, compiled to native sh by the Lisp->sh backend"
  echo "# (src/compile-sh.lisp). GENERATED by tools/bootstrap-comp.sh (SRC=$SRC)."
  for f in $(ls "$work/std"/*.sh 2>/dev/null | sort); do cat "$f"; done
  for k in $(seq -f '%03g' 0 $((nf-1))); do cat "$work/forms/$k.sh"; done
} > "$root/$OUT"
echo "wrote $OUT ($(wc -l < "$root/$OUT") lines, $(grep -c ') {' "$root/$OUT") functions)"
