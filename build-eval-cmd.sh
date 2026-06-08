#!/bin/sh
# Assemble comp-cmd/eval-cmd.cmd -- the eval keystone (cmd): eval = compile + run, comp.cmd EMBEDDED.
# The cmd analog of eval-sh.sh. Reads ONE expression (already wrapped as a (define __ev (lambda ()
# EXPR)) thunk on one line), compiles it IN-PROCESS via the embedded comp.cmd (compile-program writes
# __ev's per-PC .cmd files into the cwd, comp-cmd/), then dispatches __ev through the trampoline.
# No :ev. Closures/named-fn-values dispatch via the K:/C:/RSL drive arms (tools/cmd-jit-runtime.txt,
# shared verbatim with the loader so they can never diverge). Result rendered like eval-sh show_val.
#
#   usage (on Windows, cwd = comp-cmd):  eval-cmd.cmd THUNK.lisp   -> prints the bare value
set -eu
cd "$(dirname "$0")"
[ -f comp-cmd/comp.cmd ] || sh build-comp-cmd.sh >/dev/null

python3 - comp-cmd/comp.cmd comp-cmd/eval-cmd.cmd tools/cmd-jit-runtime.txt <<'PY'
import sys
src, out, rt = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, 'rb').read().decode('latin-1')
runtime = open(rt).read()
# replace the boot's program-feed with a jump to our eval main
needle = 'if not "%~1"=="" call :feedfile "%~1" 0'
assert needle in s, "boot line not found"
s = s.replace(needle, 'goto :eval_main', 1)
# load the AOT stdlib const pool too, if installed (content-named -> idempotent with _consts.cmd).
s = s.replace('call _consts.cmd', 'call _consts.cmd\nif exist _consts_std.cmd call _consts_std.cmd', 1)
main = r'''
:eval_main
set "SP=0" & set "DEPTH=0"
rem read the one-line thunk WITHOUT evaluating (RDMODE=1 -> RDRESULT), then forms = (thunk)
set "RDMODE=1" & set "RDRESULT=NIL"
call :feedfile "%~1" 0
set "RDMODE="
call :hp_cons "!RDRESULT!" "NIL"
rem compile-program(forms, ".", "elmain.lisp") -> writes __ev_pc*.cmd into the cwd (comp-cmd)
set "F0=!R!" & set "F1=T:." & set "F2=T:elmain.lisp"
set "FP=0" & set "RSP=0" & set "CURFN=compile-program" & set "PC=0" & set "CLO="
call :el_drive
rem run the thunk
set "FP=0" & set "RSP=0" & set "CURFN=__ev" & set "PC=0" & set "CLO="
call :el_drive
rem render the result EXACTLY like eval-sh's show_val, then print bare.
call :el_relem 0 "!R!"
echo(!ELR!
exit /b 0

'''
s = s.rstrip('\r\n') + '\n' + main.replace('\r\n','\n') + runtime
s = s.replace('\r\n','\n').replace('\n','\r\n')
open(out,'wb').write(s.encode('latin-1'))
print("wrote comp-cmd/eval-cmd.cmd")
PY
echo "built comp-cmd/eval-cmd.cmd ($(wc -c < comp-cmd/eval-cmd.cmd) bytes)"
