#!/bin/sh
# Assemble comp-cmd/interp-cmd.cmd -- the resumable INTERPRETER loader (cmd), P4 of the OSR substrate-
# unification: the cmd mirror of interp-sh.sh. Reads a program, drives the COMPILED comp's
# mexpand-program (cond/and/or/when/unless/case/let*/str/list -> core) + lift-program (inner lambdas ->
# make-closure/clambda) on the shared el_drive, REGISTERS each fn's AST + layout (ILAM_* variables), then
# INTERPRETS top-level forms via the :interp executor (tools/cmd-interp-runtime.txt) on the same
# trampoline as compiled code -- shared frames/RS/heap, route-by-registry (the OSR dispatch).
#
#   usage (on Windows, cwd = comp-cmd):  interp-cmd.cmd PROGRAM.lisp
set -eu
cd "$(dirname "$0")"
[ -f comp-cmd/comp.cmd ] || sh build-comp-cmd.sh >/dev/null

python3 - comp-cmd/comp.cmd comp-cmd/interp-cmd.cmd tools/cmd-interp-runtime.txt tools/cmd-jit-runtime.txt <<'PY'
import sys
src, out, irt, jrt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src, 'rb').read().decode('latin-1')
interp_rt = open(irt).read()
jit_rt = open(jrt).read()
# the interp runtime carries its own (unified) el_drive; take only the renderer tail of the
# jit runtime (everything from the value-renderer marker on), so :el_drive isn't duplicated.
marker = 'rem ---- value renderer'
jit_tail = jit_rt[jit_rt.index(marker):]
needle = 'if not "%~1"=="" call :feedfile "%~1" 0'
assert needle in s, "boot line not found"
s = s.replace(needle, 'goto :in_main', 1)
s = s.replace('call _consts.cmd', 'call _consts.cmd\nif exist _consts_std.cmd call _consts_std.cmd', 1)
# REPL hooks on the kernel reader's per-line loop (readall): (1) in RDMODE, stop once a complete top-
# level form is captured (RDRESULT set) so the REPL gets one form per call -- harmless in file mode,
# where the pre-pushed outer LP keeps DEPTH>0 so RDRESULT stays NIL until the trailing ')' (fed
# separately, not via readall). (2) print a depth-aware prompt to stderr when PORTSH_REPL is set.
n_addsrc = 'call :addsrc'
assert s.count(n_addsrc) == 1, "addsrc not unique"
s = s.replace(n_addsrc, 'call :addsrc\r\nif defined RDMODE if not "!RDRESULT!"=="NIL" goto :eof', 1)
main = r'''
:in_main
rem CTR threads the lambda-lift counter, NN the thunk counter -- both persist across proc_forms calls so
rem successive REPL inputs don't collide __lamN / __evN (which would clobber live closures/defs).
set "CTR=0" & set "NN=0"
if defined PORTSH_OSRDIR set "PATH=!PORTSH_OSRDIR!;!PATH!"
if "%~1"=="" goto in_repl
rem file mode: read ALL top-level forms into ONE list (pre-open an outer list so every datum accumulates
rem at DEPTH>=1, then feed ')' so emit_top captures RDRESULT = (form1 form2 ...)).
set "SP=0" & set "DEPTH=0" & set "ST_0=LP" & set "SP=1" & set "DEPTH=1" & set "RDMODE=1" & set "RDRESULT=NIL"
call :feedfile "%~1" 0
set "SRC=) " & call :run_forms
set "RDMODE="
set "PFIN=!RDRESULT!"
call :proc_forms
exit /b 0

:in_repl
rem interactive REPL: readall in RDMODE returns after each complete top-level form (one form/submit);
rem interpret it on the SAME engine, show the value. State (CTR/NN/ILAM_*/G_*/heap) persists across forms.
1>&2 echo portsh cmd interp repl -- ctrl-z then enter to exit.
:irl_loop
set "SP=0" & set "DEPTH=0" & set "RDMODE=1" & set "RDRESULT=NIL" & set "PORTSH_REPL=1"
call :readall 0
set "PORTSH_REPL=" & set "RDMODE="
if "!RDRESULT!"=="NIL" goto irl_eof
call :hp_cons "!RDRESULT!" "NIL"
set "PFIN=!R!"
call :proc_forms
goto irl_loop
:irl_eof
1>&2 echo.
exit /b 0

rem ---- process one batch of top-level forms (PFIN) ------------------------------------------------
:proc_forms
rem partition: lambda defines + atom defines kept; computed defines + bare expressions thunk-wrapped as
rem (define __evNN (lambda () BODY)) BEFORE mexpand/lift (so inner lambdas get hoisted). Mirrors load-cmd.
set "XF=NIL"
set "THUNKS="
set "CUR=!PFIN!"
:in_part
if "!CUR!"=="NIL" goto in_expand
call :hp_car "!CUR!"
set "FORM=!R!"
call :hp_cdr "!CUR!"
set "CUR=!R!"
set "LHD=NIL"
if "!FORM:~0,2!"=="P:" call :in_head "!FORM!"
if "!LHD!"=="S:define" goto in_keep
call :in_wrap "!FORM!"
set "THUNKS=!THUNKS! __ev!NN!=S"
set /a NN+=1
goto in_part
:in_keep
call :hp_cdr "!FORM!"
set "NV=!R!"
call :hp_car "!NV!"
set "DNAME=!R!"
if not "!DNAME:~0,2!"=="S:" (echo portsh: skipping malformed define 1>&2 & goto in_part)
call :hp_cdr "!NV!"
set "VV=!R!"
call :hp_car "!VV!"
set "DVAL=!R!"
if not "!DVAL:~0,2!"=="P:" goto in_keepform
call :hp_car "!DVAL!"
set "DVHD=!R!"
if "!DVHD!"=="S:lambda" goto in_keepform
call :in_wrap "!DVAL!"
set "THUNKS=!THUNKS! __ev!NN!=G:!DNAME:~2!"
set /a NN+=1
goto in_part
:in_keepform
call :hp_cons "!FORM!" "!XF!"
set "XF=!R!"
goto in_part
:in_head
call :hp_car "%~1"
set "LHD=!R!"
goto :eof
:in_wrap
rem %1 = body heap-ref -> cons (define __evNN (lambda () body)) onto XF
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

:in_expand
rem COMPILE-ONLY mode (the front-end's background program-warmer): compile the partitioned forms to
rem per-PC .cmd artifacts in %PORTSH_OSRCOMPILE% and exit -- no register, no run. Same partition code
rem path as the interp run, so fn labels + __lamN/__evN numbering match what a running interp expects.
if defined PORTSH_OSRCOMPILE goto in_compileonly
rem mexpand (derived forms -> core) then lift (inner lambdas -> make-closure/clambda), via the COMPILED
rem comp on the shared driver. After this the interp only needs the core machine.
set "F0=!XF!"
set "FP=0" & set "RSP=0" & set "CURFN=map-mexpand" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
rem lift-program-c (not lift-program): returns (lifted . end-ctr) so the REPL threads CTR across inputs.
set "F0=!R!" & set "F1=I:!CTR!"
set "FP=0" & set "RSP=0" & set "CURFN=lift-program-c" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
set "LPR=!R!"
call :hp_car "!LPR!"
set "LIFTED=!R!"
call :hp_cdr "!LPR!"
set "CTR=!R:~2!"

rem register every define: lambda/clambda -> ILAM_<mangled>_{np,ncap,vars,body}; atom -> G_<raw>.
rem _vars is the heap LIST of param (then capture) symbols -- iresolve walks it (no string globbing).
set "LF=!LIFTED!"
:in_reg
if "!LF!"=="NIL" goto in_run0
call :hp_car "!LF!"
set "DEF=!R!"
call :hp_cdr "!LF!"
set "LF=!R!"
call :hp_cdr "!DEF!"
set "NV=!R!"
call :hp_car "!NV!"
set "NMRAW=!R:~2!"
call :hp_cdr "!NV!"
call :hp_car "!R!"
set "DVAL=!R!"
set "DVHD=NIL"
if "!DVAL:~0,2!"=="P:" (call :hp_car "!DVAL!" & set "DVHD=!R!")
if "!DVHD!"=="S:lambda" goto in_reg_lam
if "!DVHD!"=="S:clambda" goto in_reg_clam
set "G_!NMRAW!=!DVAL!"
goto in_reg
:in_reg_lam
call :hp_cdr "!DVAL!"
set "C1=!R!"
call :hp_car "!C1!"
set "PS=!R!"
call :hp_cdr "!C1!"
call :hp_car "!R!"
set "BODY=!R!"
set "IMS=!NMRAW!"
call :imangle
set "MN=!R!"
set "ILL=!PS!"
call :ilen
set "ILAM_!MN!_np=!R!"
set "ILAM_!MN!_ncap=0"
set "ILAM_!MN!_vars=!PS!"
set "ILAM_!MN!_body=!BODY!"
goto in_reg
:in_reg_clam
rem (clambda (params) (caps) body)
call :hp_cdr "!DVAL!"
set "C1=!R!"
call :hp_car "!C1!"
set "PS=!R!"
call :hp_cdr "!C1!"
set "C2=!R!"
call :hp_car "!C2!"
set "CAPS=!R!"
call :hp_cdr "!C2!"
call :hp_car "!R!"
set "BODY=!R!"
rem vars = append(PS, CAPS): reverse PS, cons onto CAPS
set "RV=NIL"
set "PL=!PS!"
:in_rc_rev
if "!PL!"=="NIL" goto in_rc_app
call :hp_car "!PL!"
call :hp_cons "!R!" "!RV!"
set "RV=!R!"
call :hp_cdr "!PL!"
set "PL=!R!"
goto in_rc_rev
:in_rc_app
set "APP=!CAPS!"
:in_rc_a2
if "!RV!"=="NIL" goto in_rc_done
call :hp_car "!RV!"
call :hp_cons "!R!" "!APP!"
set "APP=!R!"
call :hp_cdr "!RV!"
set "RV=!R!"
goto in_rc_a2
:in_rc_done
set "IMS=!NMRAW!"
call :imangle
set "MN=!R!"
set "ILL=!PS!"
call :ilen
set "ILAM_!MN!_np=!R!"
set "ILL=!CAPS!"
call :ilen
set "ILAM_!MN!_ncap=!R!"
set "ILAM_!MN!_vars=!APP!"
set "ILAM_!MN!_body=!BODY!"
goto in_reg

:in_compileonly
if not exist "!PORTSH_OSRCOMPILE!" mkdir "!PORTSH_OSRCOMPILE!"
set "F0=!XF!" & set "F1=T:!PORTSH_OSRCOMPILE!" & set "F2=T:!PORTSH_OSRCOMPILE!/_main"
set "FP=0" & set "RSP=0" & set "CURFN=compile-program" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
exit /b 0

:in_run0
rem --- OSR flip (keystone, mirror of sh P2 PORTSH_OSR): compile XF to per-PC .cmd files in osrout/ (a
rem SEPARATE dir -- compile-program also writes _consts.cmd, which in cwd would clobber the comp's own),
rem put osrout/ on PATH so el_drive's `call <fn>_pc<n>.cmd` finds the compiled user fns (comp fns stay in
rem cwd, distinct names), then mark each PORTSH_OSR fn COMPILED so its next call routes to compiled code.
rem The interp's register already set the user's atom-const G_<name> globals the compiled code reads. ---
if not defined PORTSH_OSR goto in_runq
if not exist osrout mkdir osrout
rem F2 (lisppath) is the compiled "main" manifest -- compile-program TRUNCATES + writes it. It must NOT be
rem the user's program file (that would clobber it -- cross-process the next reader gets the manifest); the
rem route calls the per-PC files in cmdpath (F1) directly and never needs main, so write it inside osrout.
set "F0=!XF!" & set "F1=T:osrout" & set "F2=T:osrout/_main"
set "FP=0" & set "RSP=0" & set "CURFN=compile-program" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
set "PATH=!CD!\osrout;!PATH!"
set "OSRQ=!PORTSH_OSR!"
:in_osr_flip
set "OF="
for /f "tokens=1*" %%a in ("!OSRQ!") do (set "OF=%%a" & set "OSRQ=%%b")
if "!OF!"=="" goto in_runq
set "IMS=!OF!" & call :imangle
set "COMPILED_!R!=1"
goto in_osr_flip
:in_runq
set "RUNQ=!THUNKS!"
:in_run
set "ENT="
for /f "tokens=1*" %%a in ("!RUNQ!") do (set "ENT=%%a" & set "RUNQ=%%b")
if "!ENT!"=="" goto in_done
for /f "tokens=1,2 delims==" %%x in ("!ENT!") do (set "TN=%%x" & set "TA=%%y")
set "FP=0" & set "RSP=0" & set "CURFN=interp" & set "ICUR=!TN!" & set "PC=0" & set "CLO="
call :el_drive
if "!TA!"=="S" goto in_show
set "G_!TA:~2!=!R!"
goto in_run
:in_show
if defined PORTSH_SCRIPT goto in_run
call :el_relem 0 "!R!"
echo(!ELR!
goto in_run
:in_done
goto :eof

'''
s = s.rstrip('\r\n') + '\n' + main.replace('\r\n','\n') + interp_rt + '\n' + jit_tail
s = s.replace('\r\n','\n').replace('\n','\r\n')
open(out,'wb').write(s.encode('latin-1'))
print("wrote comp-cmd/interp-cmd.cmd")
PY
echo "built comp-cmd/interp-cmd.cmd ($(wc -c < comp-cmd/interp-cmd.cmd) bytes)"
