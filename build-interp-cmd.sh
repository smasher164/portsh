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
# the interp runtime carries its own (unified) el_drive; take only the renderer + replay tail of the
# jit runtime (everything from the value-renderer marker on), so :el_drive isn't duplicated.
marker = 'rem ---- value renderer'
jit_tail = jit_rt[jit_rt.index(marker):]
needle = 'if not "%~1"=="" call :feedfile "%~1" 0'
assert needle in s, "boot line not found"
s = s.replace(needle, 'goto :in_main', 1)
s = s.replace('call _consts.cmd', 'call _consts.cmd\nif exist _consts_std.cmd call _consts_std.cmd', 1)
main = r'''
:in_main
rem read ALL top-level forms into ONE list (same trick as load-cmd: pre-open an outer list so every
rem datum accumulates at DEPTH>=1, then feed ')' so emit_top captures RDRESULT = (form1 form2 ...)).
set "SP=0" & set "DEPTH=0"
set "ST_0=LP" & set "SP=1" & set "DEPTH=1"
set "RDMODE=1" & set "RDRESULT=NIL"
call :feedfile "%~1" 0
set "SRC=) " & call :run_forms
set "RDMODE="
rem partition: lambda defines + atom defines kept; computed defines + bare expressions thunk-wrapped as
rem (define __evNN (lambda () BODY)) BEFORE mexpand/lift (so inner lambdas get hoisted). Mirrors load-cmd.
set "XF=NIL"
set "THUNKS="
set "NN=0"
set "CUR=!RDRESULT!"
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
rem mexpand (derived forms -> core) then lift (inner lambdas -> make-closure/clambda), via the COMPILED
rem comp on the shared driver. After this the interp only needs the core machine.
set "F0=!XF!"
set "FP=0" & set "RSP=0" & set "CURFN=map-mexpand" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
set "F0=!R!" & set "F1=I:0"
set "FP=0" & set "RSP=0" & set "CURFN=lift-program" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
set "LIFTED=!R!"

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

:in_run0
call :replay_init
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
if defined PORTSH_REPLAY goto in_run
if defined PORTSH_SCRIPT goto in_run
call :el_relem 0 "!R!"
echo(!ELR!
goto in_run
:in_done
exit /b 0

'''
s = s.rstrip('\r\n') + '\n' + main.replace('\r\n','\n') + interp_rt + '\n' + jit_tail
s = s.replace('\r\n','\n').replace('\n','\r\n')
open(out,'wb').write(s.encode('latin-1'))
print("wrote comp-cmd/interp-cmd.cmd")
PY
echo "built comp-cmd/interp-cmd.cmd ($(wc -c < comp-cmd/interp-cmd.cmd) bytes)"
