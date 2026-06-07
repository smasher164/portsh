#!/bin/sh
# Flat-closure RUNTIME guard (cmd backend): compile a first-class-function program with the
# cmd Lisp->batch backend (src/compile.lisp), assemble a kernel-driver runner with the patched
# trampoline (ev_tcall_clo: K:<idx> -> CURFN from the closure record + CLO/RSL save-restore),
# and RUN it on a real Windows cmd. Validates the parts local inspection can't: the K: dispatch,
# the rdfield.cmd captured-var walk, and CLO save/restore across nested closure calls.
#
# Codegen is produced by the INTERPRETER running the current src/compile.lisp (same codegen
# comp.cmd emits once re-bootstrapped) -- so this guards the codegen + runtime without needing a
# rebuilt comp.cmd. VM-gated: set PORTSH_WIN_SSH=user@host. Skips loudly otherwise.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
if [ -z "${PORTSH_WIN_SSH:-}" ]; then
  echo "SKIP closures-cmd: set PORTSH_WIN_SSH=user@host (a real Windows box/VM) to run."
  exit 0
fi
VM=$PORTSH_WIN_SSH

[ -f portsh.cmd ] || sh build.sh >/dev/null 2>&1
[ -f portsh-full.cmd ] || sh build.sh >/dev/null 2>&1
[ -f portsh-runtime.cmd ] || sh build.sh >/dev/null 2>&1
grep -q ev_tcall_clo portsh.cmd || { echo "FAIL closures-cmd: portsh.cmd lacks the K: driver (rebuild)"; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
interp="$work/portsh.sh"; tr -d '\r' < portsh-full.cmd > "$interp"
run="$work/run"; mkdir -p "$run"

PROG='((define make-adder (lambda (n) (lambda (x) (+ x n))))
       (define apply1 (lambda (f a) (f a)))
       (define use-adder (lambda () (apply1 (make-adder 5) 3)))
       (define adder3 (lambda (a) (lambda (b) (lambda (c) (+ a (+ b c))))))
       (define go3 (lambda () (((adder3 1) 2) 3)))
       (define dbl-clo (lambda (k) ((lambda (x) (+ x k)) k))))'

# 1. compile PROG -> per-fn .cmd + _consts.cmd + main.lisp residual, via interpreted compile.lisp
python3 - src/stdlib.lisp src/compile.lisp "$work/drv.lisp" "$run" "$PROG" <<'PY'
import sys,re
stdlib,comp,outp,outdir,prog=sys.argv[1:6]
deps={'caar','cadr','caddr','not','append','reverse','assoc'}
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
keep=[f for f in forms(open(stdlib).read()) if (m:=re.match(r'\(define\s+([^\s()]+)',f)) and m.group(1) in deps]
with open(outp,'w') as o:
    o.write('\n'.join(keep)+'\n')
    o.write(open(comp).read())
    o.write('\n(compile-program (quote %s) "%s" "%s/main.lisp")(print (quote DONE))\n'%(prog,outdir,outdir))
PY
env NURSERY=999999999 PORTSH_COOKED=1 PORTSH_SELF="$interp" mksh "$interp" "$work/drv.lisp" </dev/null >/dev/null 2>&1
[ -f "$run/use-adder_pc0.cmd" ] || { echo "FAIL closures-cmd: codegen produced no use-adder"; exit 1; }
[ -f "$run/__lam0_pc0.cmd" ]    || { echo "FAIL closures-cmd: lambda-lift produced no __lam0"; exit 1; }

# 2. runtime split (rdfield/write-lines/append-lines/gc -> one file per entry, CRLF)
for entry in rdfield write-lines append-lines gc; do
  { printf 'goto :%s\r\n' "$entry"; cat portsh-runtime.cmd; } > "$run/$entry.cmd"
done
# 3. driver = bare kernel + `call _consts.cmd` after setup_global (mirrors build-comp-cmd.sh)
awk '{print} /call :setup_global\r?$/ && !done {print "call _consts.cmd"; done=1}' portsh.cmd \
  | grep -v '^__PORTSH_PAYLOAD__' | perl -pe 's/\r?\n/\r\n/' > "$run/driver.cmd"
# 4. wrapper = residual binds (make-compiled) + invoke each entry through the trampoline + print
{ tr -d '\r' < "$run/main.lisp"
  printf '(print (use-adder))\n(print (go3))\n(print (dbl-clo 10))\n'
} | perl -pe 's/\r?\n/\r\n/' > "$run/wrap.lisp"
rm -f "$run/main.lisp"

# 5. deploy + run on the VM (scp to home, then make clo_run + extract -- scp can't mkdir remotely)
tar czf "$work/run.tgz" -C "$run" .
ssh -n "$VM" 'powershell -c "taskkill /f /im cmd.exe 2>$null"' >/dev/null 2>&1 || true
scp -q "$work/run.tgz" "$VM:clo_run.tgz" >/dev/null 2>&1
ssh -n "$VM" 'cmd /c "(if exist clo_run rmdir /s /q clo_run) & mkdir clo_run & cd clo_run & tar -xzf ..\clo_run.tgz & del ..\clo_run.tgz"' >/dev/null 2>&1
out=$(ssh -n "$VM" 'cmd /c "cd clo_run && driver.cmd wrap.lisp"' 2>/dev/null | tr -d '\r')
echo "VM output:"; echo "$out" | sed 's/^/    /'

# 6. check the three results (print renders the I: number tag as a bare integer)
ok=0; bad=0
chk() { if echo "$out" | grep -qx "$2"; then ok=$((ok+1)); else bad=$((bad+1)); echo "  FAIL $1: expected line '$2'"; fi; }
chk use-adder 8
chk go3 6
chk dbl-clo 20
echo "closures-cmd: ok=$ok bad=$bad"
[ "$bad" -eq 0 ] && echo "closures-cmd: PASS (cmd flat closures run on Windows)"
[ "$bad" -eq 0 ]
