#!/bin/sh
# Assemble comp-cmd/load-cmd.cmd -- the read->compile->run loader (cmd). Generalises eval-cmd to a
# WHOLE PROGRAM: top-level (define ...) forms compile into the runtime (per-PC .cmd fns) and top-level
# EXPRESSIONS evaluate in order (each wrapped as a 0-arg thunk referencing prior defines). eval =
# compile + run, comp EMBEDDED; no :ev interpreter. The cmd analog of load-sh.sh; shares the K:/C:/RSL
# trampoline + renderer with eval-cmd verbatim (tools/cmd-jit-runtime.txt).
#
#   usage (on Windows, cwd = comp-cmd):  load-cmd.cmd PROGRAM.lisp
#       prints the value of each top-level expression, in order.
set -eu
cd "$(dirname "$0")"
[ -f comp-cmd/comp.cmd ] || sh build-comp-cmd.sh >/dev/null

python3 - comp-cmd/comp.cmd comp-cmd/load-cmd.cmd tools/cmd-jit-runtime.txt <<'PY'
import sys
src, out, rt = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, 'rb').read().decode('latin-1')
runtime = open(rt).read()
needle = 'if not "%~1"=="" call :feedfile "%~1" 0'
assert needle in s, "boot line not found"
s = s.replace(needle, 'goto :load_main', 1)
# load the AOT stdlib const pool too, if installed (content-named -> idempotent with _consts.cmd).
s = s.replace('call _consts.cmd', 'call _consts.cmd\nif exist _consts_std.cmd call _consts_std.cmd', 1)
main = r'''
:load_main
rem capture user args (after the program path) into PORTSH_ARGV_<n>/PORTSH_ARGC for (argv),
rem unless a front-end already did.
if defined PORTSH_ARGC goto lc_args_done
set "PORTSH_ARGC=0"
:lc_args
if "%~2"=="" goto lc_args_done
set "PORTSH_ARGV_!PORTSH_ARGC!=%~2"
set /a PORTSH_ARGC+=1
shift /2
goto lc_args
:lc_args_done
rem read ALL top-level forms into ONE list: pre-open an outer list on the parse stack so every
rem top-level datum accumulates at DEPTH>=1 (never eval'd), then feed a closing ')' so emit_top at
rem DEPTH 0 captures RDRESULT = (form1 form2 ...) in source order.
set "SP=0" & set "DEPTH=0"
set "ST_0=LP" & set "SP=1" & set "DEPTH=1"
set "RDMODE=1" & set "RDRESULT=NIL"
call :feedfile "%~1" 0
set "SRC=) " & call :run_forms
set "RDMODE="

rem partition: defines kept as-is; expressions wrapped as (define __evNN (lambda () EXPR)). Build the
rem combined forms list XF (order irrelevant for codegen) + THUNKS (thunk fn names, SOURCE order).
rem NOTE: capture R on a SEPARATE line after each `call` (the kernel never does `call X & set Y=!R!`),
rem and NEVER name a local var HD/HN/SP/... -- HD is the kernel's HEAP DIR (%HD%\car<i>); clobbering
rem it makes every hp_cons/hp_car target a bogus path. The form HEAD here is LHD.
set "XF=NIL"
set "THUNKS="
set "NN=0"
set "CUR=!RDRESULT!"
:lm_part
if "!CUR!"=="NIL" goto lm_compile
call :hp_car "!CUR!"
set "FORM=!R!"
call :hp_cdr "!CUR!"
set "CUR=!R!"
set "LHD=NIL"
if "!FORM:~0,2!"=="P:" call :lm_head "!FORM!"
if "!LHD!"=="S:define" goto lm_keep
rem bare expression -> (define __evNN (lambda () FORM)), shown (=S)
call :lm_wrap "!FORM!"
set "THUNKS=!THUNKS! __ev!NN!=S"
set /a NN+=1
goto lm_part
:lm_keep
rem (define NAME VALUE): lambda VALUE -> compiled fn; atom VALUE -> G_<name> const; compound VALUE ->
rem a thunk run in program order whose result is bound to G_<name> (the last :ev-only gap).
call :hp_cdr "!FORM!"
set "NV=!R!"
call :hp_car "!NV!"
set "DNAME=!R!"
call :hp_cdr "!NV!"
set "VV=!R!"
call :hp_car "!VV!"
set "DVAL=!R!"
if not "!DVAL:~0,2!"=="P:" goto lm_keepform
call :hp_car "!DVAL!"
set "DVHD=!R!"
if "!DVHD!"=="S:lambda" goto lm_keepform
rem placeholder (define <name> nil) onto XF so gvarnames sees <name> as a global VAR -> a later call of
rem it in operator position loads !G_<name>! and applies (the thunk below binds G_<name> to the closure).
call :hp_cons "S:nil" "NIL"
set "LPH=!R!"
call :hp_cons "!DNAME!" "!LPH!"
set "LPH=!R!"
call :hp_cons "S:define" "!LPH!"
set "LPH=!R!"
call :hp_cons "!LPH!" "!XF!"
set "XF=!R!"
rem compound non-lambda value -> thunk binding G_<name> (=G:<name>)
call :lm_wrap "!DVAL!"
set "THUNKS=!THUNKS! __ev!NN!=G:!DNAME:~2!"
set /a NN+=1
goto lm_part
:lm_keepform
call :hp_cons "!FORM!" "!XF!"
set "XF=!R!"
goto lm_part
:lm_head
call :hp_car "%~1"
set "LHD=!R!"
goto :eof
:lm_wrap
rem %1 = body heap-ref -> cons (define __evNN (lambda () body)) onto XF (uses NN, sets XF)
call :hp_cons "%~1" "NIL"
set "B=!R!"
call :hp_cons "NIL" "!B!"
set "LL=!R!"
call :hp_cons "S:lambda" "!LL!"
set "LAM=!R!"
call :hp_cons "!LAM!" "NIL"
set "D3=!R!"
call :hp_cons "S:__ev!NN!" "!D3!"
set "D2=!R!"
call :hp_cons "S:define" "!D2!"
set "DEF=!R!"
call :hp_cons "!DEF!" "!XF!"
set "XF=!R!"
goto :eof

:lm_compile
rem compile ALL forms in-process -> per-PC .cmd fns in the cwd.
set "F0=!XF!" & set "F1=T:." & set "F2=T:elmain.lisp"
set "FP=0" & set "RSP=0" & set "CURFN=compile-program" & set "PC=0" & set "CLO="
call :el_drive
rem run each top-level expression's thunk, in SOURCE order, via a goto-loop over THUNKS (avoid
rem calling el_drive's goto-machine from inside a for-body). Render each like eval-sh show_val.
set "RUNQ=!THUNKS!"
:lm_run
set "ENT="
for /f "tokens=1*" %%a in ("!RUNQ!") do (set "ENT=%%a" & set "RUNQ=%%b")
if "!ENT!"=="" goto lm_done
for /f "tokens=1,2 delims==" %%x in ("!ENT!") do (set "TN=%%x" & set "TA=%%y")
set "FP=0" & set "RSP=0" & set "CURFN=!TN!" & set "PC=0" & set "CLO="
call :el_drive
if "!TA!"=="S" goto lm_show
rem TA = G:<name> -> bind G_<name> = result (compiled code reads !G_<name>!)
set "G_!TA:~2!=!R!"
goto lm_run
:lm_show
rem SCRIPT/REPLAY mode: a real program's output is only its explicit print/write-lines, matching the
rem :ev recorder (which doesn't echo top-level values). The auto-echo is just the REPL-style loader.
if defined PORTSH_SCRIPT goto lm_run
call :el_relem 0 "!R!"
echo(!ELR!
goto lm_run
:lm_done
exit /b 0

'''
s = s.rstrip('\r\n') + '\n' + main.replace('\r\n','\n') + runtime
s = s.replace('\r\n','\n').replace('\n','\r\n')
open(out,'wb').write(s.encode('latin-1'))
print("wrote comp-cmd/load-cmd.cmd")
PY
echo "built comp-cmd/load-cmd.cmd ($(wc -c < comp-cmd/load-cmd.cmd) bytes)"
