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
# the vau GLOBAL env is :ev-only and :ev is unreachable here (the reader's emit_top ev-branch is
# guarded in reader.cmd; all other :ev calls are its own recursion). setup_global's ~46 env_define
# calls cost ~2.4s of EVERY boot (each `call :env_define`/`call :hp_setcar` label-scans past the
# ~40KB hot blob) -- skip it. The resumable interp resolves via ILAM_*/G_*/iprim instead.
assert s.count('call :setup_global') == 1
s = s.replace('call :setup_global', 'rem setup_global SKIPPED (vau env unused by the resumable interp; ~2.4s/boot)', 1)
s = s.replace('call _consts.cmd', 'call _consts.cmd\nif exist _consts_std.cmd (call _consts_std.cmd) else for %%c in (_consts_std.cmd) do if exist "%%~$PATH:c" call "%%~$PATH:c"', 1)
# REPL hooks on the kernel reader's per-line loop (readall): (1) in RDMODE, stop once a complete top-
# level form is captured (RDRESULT set) so the REPL gets one form per call -- harmless in file mode,
# where the pre-pushed outer LP keeps DEPTH>0 so RDRESULT stays NIL until the trailing ')' (fed
# separately, not via readall). (2) print a depth-aware prompt to stderr when PORTSH_REPL is set.
n_addsrc = 'call :addsrc'
assert s.count(n_addsrc) == 1, "addsrc not unique"
s = s.replace(n_addsrc, 'call :addsrc\r\nif defined RDMODE if not "!RDRESULT!"=="NIL" goto :eof', 1)
# (3) REPL session capture: append each raw input line to the session file RIGHT AFTER set /p, before
# any sentinel encoding (delayed expansion is still on; a single !line! term expands without rescanning
# the value, so the bytes go out faithfully). The bg warmer recompiles this file.
n_setp = 'set /p "line=" || goto :eof'
assert s.count(n_setp) == 1, "readall set/p not unique"
s = s.replace(n_setp, n_setp + '\r\nif defined PORTSH_REPL if defined PORTSH_SESS >>"!PORTSH_SESS!" echo(!line!', 1)
main = r'''
:in_main
rem CTR threads the lambda-lift counter, NN the thunk counter -- both persist across proc_forms calls so
rem successive REPL inputs don't collide __lamN / __evN (which would clobber live closures/defs).
set "CTR=0" & set "NN=0"
rem the runtime dir (= the tooling cache when running from it): setenv re-prepends this to PATH
rem after a user PATH set, since compiled prims resolve through PATH at runtime.
set "PORTSH_RTDIR=%~dp0"
if defined PORTSH_OSRDIR set "PATH=!PORTSH_OSRDIR!;!PATH!"
if "%~1"=="" goto in_repl
rem capture user args (after the program path) into PORTSH_ARGV_<n>/PORTSH_ARGC for (argv), unless a
rem front-end already did (env vars inherit into this process -- no arg re-quoting anywhere).
if defined PORTSH_ARGC goto in_args_done
set "PORTSH_ARGC=0"
:in_args
if "%~2"=="" goto in_args_done
set "PORTSH_ARGV_!PORTSH_ARGC!=%~2"
set /a PORTSH_ARGC+=1
shift /2
goto in_args
:in_args_done
rem WARM FAST PATH: the program cache has the thunk run-list -> execute the program STRAIGHT from the
rem cache (program consts + compiled thunks on el_drive). No reader, no mexpand, no lift, no register --
rem the pipeline is pure waste when every fn is already compiled. Content-hash keying makes this safe
rem (an edited program lands in a different cache dir).
if defined PORTSH_OSRDIR if exist "!PORTSH_OSRDIR!\_thunks" goto in_warmrun
rem file mode: read ALL top-level forms into ONE list (pre-open an outer list so every datum accumulates
rem at DEPTH>=1, then feed ')' so emit_top captures RDRESULT = (form1 form2 ...)).
set "SP=0" & set "DEPTH=0" & set "ST_0=LP" & set "SP=1" & set "DEPTH=1" & set "RDMODE=1" & set "RDRESULT=NIL"
call :feedfile "%~1" 0
set "SRC=) " & call :run_forms
set "RDMODE="
set "PFIN=!RDRESULT!"
call :proc_forms
exit /b 0

:in_warmrun
rem the program's atom-const globals (FULL path -- a bare `call _consts.cmd` would resolve in PATH order
rem and could hit the comp's own _consts.cmd in the tooling cache)
if exist "!PORTSH_OSRDIR!\_consts.cmd" call "!PORTSH_OSRDIR!\_consts.cmd"
set "RUNQ="
for /f "usebackq delims=" %%t in ("!PORTSH_OSRDIR!\_thunks") do set "RUNQ=%%t"
:in_wr_loop
set "ENT="
for /f "tokens=1*" %%a in ("!RUNQ!") do (set "ENT=%%a" & set "RUNQ=%%b")
if "!ENT!"=="" exit /b 0
for /f "tokens=1,2 delims==" %%x in ("!ENT!") do (set "TN=%%x" & set "TA=%%y")
set "FP=0" & set "RSP=0" & set "CURFN=!TN!" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
if "!TA!"=="S" goto in_wr_show
set "G_!TA:~2!=!R!"
goto in_wr_loop
:in_wr_show
if defined PORTSH_SCRIPT goto in_wr_loop
call :el_relem 0 "!R!"
echo(!ELR!
goto in_wr_loop

:in_repl
rem interactive REPL: readall in RDMODE returns after each complete top-level form (one form/submit);
rem interpret it on the SAME engine, show the value. State (CTR/NN/ILAM_*/G_*/heap) persists across forms.
rem
rem PER-INPUT OSR WARM: every raw input line is appended to a SESSION FILE (readall does it -- the line
rem is captured right after set /p, before any sentinel encoding, so it's byte-faithful). After each
rem input, a BACKGROUND warmer recompiles the whole session file (compile-only + grow-only publish into
rem the session cache); the live route (PORTSH_OSRDIR) flips defined fns to compiled at their next call.
rem Whole-session recompile means the warmer's __lamN/__evN numbering always matches the live session's
rem threaded counters (whole-file lift == per-input threading over the same forms). A lock file skips
rem spawning while a warmer runs; the next input re-spawns, covering everything up to then.
set "IC_SELF=%~f0"
set "PORTSH_SESS=%TEMP%\psess_!HD!.lsp"
set "SESSC=%TEMP%\psessc_!HD!"
set "SESSLOCK=%TEMP%\psessw_!HD!.lock"
set "SESSW=%TEMP%\psessw_!HD!.cmd"
break>"!PORTSH_SESS!"
> "!SESSW!" echo @echo off
>>"!SESSW!" echo set "PORTSH_OSRCOMPILE=%%~1"
>>"!SESSW!" echo set "PORTSH_OSRPUB=%%~2"
>>"!SESSW!" echo set "PORTSH_OSRDIR="
>>"!SESSW!" echo call "!IC_SELF!" "%%~3"
>>"!SESSW!" echo del "%%~4" 2^>nul
set "PORTSH_OSRDIR=!SESSC!"
set "PATH=!SESSC!;!PATH!"
set "WARMN=0"
1>&2 echo portsh cmd interp repl -- ctrl-z then enter to exit.
:irl_loop
set "SP=0" & set "DEPTH=0" & set "RDMODE=1" & set "RDRESULT=NIL" & set "PORTSH_REPL=1"
call :readall 0
set "PORTSH_REPL=" & set "RDMODE="
if "!RDRESULT!"=="NIL" goto irl_eof
call :hp_cons "!RDRESULT!" "NIL"
set "PFIN=!R!"
call :proc_forms
rem spawn the session warmer (skip if one is already running; it covers inputs up to its spawn)
if exist "!SESSLOCK!" goto irl_loop
break>"!SESSLOCK!"
set /a WARMN+=1
start "" /b cmd /c ""!SESSW!" "!SESSC!.t!WARMN!" "!SESSC!" "!PORTSH_SESS!" "!SESSLOCK!"" >nul 2>&1
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
rem computed define: ALSO emit a (define <name> nil) placeholder so gvar-names sees <name> as a
rem global VAR -- a later call of it in operator position loads G_<name> and applies (the thunk's
rem value is a closure); without this the comp emits a direct call to a fn that doesn't exist
rem (d2_pc0.cmd not recognized -- caught by tests/pack.sh on closures.lisp). Mirrors load-sh.sh.
call :hp_cons "S:nil" "NIL"
set "PH=!R!"
call :hp_cons "!DNAME!" "!PH!"
set "PH=!R!"
call :hp_cons "S:define" "!PH!"
call :hp_cons "!R!" "!XF!"
set "XF=!R!"
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
rem REDEFINITION: any cached compiled artifact for this name is now STALE -- never flip it again this
rem session (OSRSKIP) and un-memoize a prior flip. Semantics stay exact; the fn just stays interpreted.
if defined ILAM_!MN!_body (set "OSRSKIP_!MN!=1" & set "COMPILED_!MN!=")
if "!PS:~0,2!"=="S:" goto in_reg_lam_va
set "ILL=!PS!"
call :ilen
set "ILAM_!MN!_np=!R!"
set "ILAM_!MN!_ncap=0"
set "ILAM_!MN!_vars=!PS!"
set "ILAM_!MN!_body=!BODY!"
goto in_reg
:in_reg_lam_va
rem variadic (lambda args body): one rest slot; itk_fresh collects F[FP..ARGC) into it
call :hp_cons "!PS!" "NIL"
set "ILAM_!MN!_np=1"
set "ILAM_!MN!_va=1"
set "ILAM_!MN!_ncap=0"
set "ILAM_!MN!_vars=!R!"
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
rem variadic clambda: convert the symbol formals to a 1-list (rest slot) + mark va; the rest of
rem the registration (rev/append/ilen) then works unchanged with np=1.
set "VAFL="
if "!PS:~0,2!"=="S:" (set "VAFL=1" & call :hp_cons "!PS!" "NIL" & set "PS=!R!")
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
if defined ILAM_!MN!_body (set "OSRSKIP_!MN!=1" & set "COMPILED_!MN!=")
set "ILL=!PS!"
call :ilen
set "ILAM_!MN!_np=!R!"
if defined VAFL set "ILAM_!MN!_va=1"
set "ILL=!CAPS!"
call :ilen
set "ILAM_!MN!_ncap=!R!"
set "ILAM_!MN!_vars=!APP!"
set "ILAM_!MN!_body=!BODY!"
goto in_reg

:in_compileonly
if not exist "!PORTSH_OSRCOMPILE!" mkdir "!PORTSH_OSRCOMPILE!"
rem persist the thunk run-list (order + actions) -- the warm fast path executes the program straight
rem from the cache (boot -> _consts -> these thunks on el_drive), skipping read/mexpand/lift/register.
>"!PORTSH_OSRCOMPILE!\_thunks" echo(!THUNKS!
set "F0=!XF!" & set "F1=T:!PORTSH_OSRCOMPILE!" & set "F2=T:!PORTSH_OSRCOMPILE!/_main"
set "FP=0" & set "RSP=0" & set "CURFN=compile-program" & set "PC=0" & set "CLO=" & set "ICUR="
call :el_drive
rem optional GROW-ONLY publish (the REPL session warmer). Never move/delete in place -- a live session
rem may have memoized flips into existing artifacts (yanking them mid-call would halt it). Copy only
rem files that don't exist yet, and each fn's _pc0 LAST: the route keys its flip on _pc0, so a fn only
rem becomes flippable once its full pc-set is present. Stale artifacts of REDEFINED names stay but are
rem unreachable (the session OSRSKIPs redefined names).
if not defined PORTSH_OSRPUB exit /b 0
if not exist "!PORTSH_OSRPUB!" mkdir "!PORTSH_OSRPUB!"
for %%f in ("!PORTSH_OSRCOMPILE!\*.cmd") do (
  echo %%~nxf | findstr /e "_pc0.cmd" >nul || if not exist "!PORTSH_OSRPUB!\%%~nxf" copy "%%f" "!PORTSH_OSRPUB!\%%~nxf" >nul
)
for %%f in ("!PORTSH_OSRCOMPILE!\*_pc0.cmd") do (
  if not exist "!PORTSH_OSRPUB!\%%~nxf" copy "%%f" "!PORTSH_OSRPUB!\%%~nxf" >nul
)
rmdir /s /q "!PORTSH_OSRCOMPILE!" 2>nul
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
# LAYOUT IS PERFORMANCE: cmd `call :label` is O(label byte-offset) and `goto` is a forward-then-wrap
# scan -- a dispatch loop living at the END of the file pays a FULL-FILE scan per iteration (measured:
# 0.45ms at the top vs 10.7ms after 90KB). So the HOT code (el_drive + the interp machine, then the
# loader main, then the renderer) is INSERTED right after the kernel's hp_* block (~13KB in): the
# per-char reader and the per-op heap stay at the front, and what gets pushed deep is the cold vau-:ev
# half of the kernel that the interp path never calls. Appending at the end (the old layout) made every
# interp step and every comp-driving dispatch ~10ms.
# within the hot blob, the MACHINE (interp + itk_* handlers + ips/iresolve/iprim -- called per eval
# step) goes BEFORE the driver: el_drive is entered rarely and its chunk works inline, so its label
# position barely matters, while every task dispatch pays the handlers' call offsets.
rt_machine_at = interp_rt.index('\nrem ---- resumable interpreter')
rt_driver, rt_machine = interp_rt[:rt_machine_at], interp_rt[rt_machine_at:]
# MACHINE EXTRACTION (perf): per-task handler dispatch is `call :itk_*`, and `call :label` costs
# O(label offset) -- inside the ~85KB interp-cmd.cmd that's ~1-2ms PER TASK of label-scan tax.
# The machine lives in its own ~25KB side file (same trick as reader.cmd, which made the reader 5x
# faster): `call interp-machine.cmd` shares the process env, handler calls scan only the small file,
# and the machine's only external label deps (hp_cons/hp_car/hp_cdr) are duplicated at its front.
rt_driver = rt_driver.replace('if "!CURFN!"=="interp" (call :interp) else call "!CURFN!_pc!PC!.cmd"',
                              'if "!CURFN!"=="interp" (call interp-machine.cmd) else call "!CURFN!_pc!PC!.cmd"')
assert rt_driver.count('call interp-machine.cmd') == 1, rt_driver.count('call interp-machine.cmd')
# the loader's registration (in_reg) also uses :ilen/:imangle -- keep verbatim copies in the
# big file (the machine has its own; both read/write only their il*/img* scratch + R).
helper_a = rt_machine.index('\n:ilen\n'); helper_b = rt_machine.index('\n:ipush_args\n')
helper_c = rt_machine.index('\n:imangle\n'); helper_d = rt_machine.index('\n:iresolve\n')
loader_helpers = rt_machine[helper_a:helper_b] + rt_machine[helper_c:helper_d]
hot = '\n' + rt_driver + '\n' + loader_helpers + '\n' + main.replace('\r\n','\n') + '\n' + jit_tail + '\n' 
s_lf = s.replace('\r\n','\n')
# FRONT-DUP the heap primitives: `call :label` scans from the top, so a duplicate of hp_cons/hp_car/
# hp_cdr right after the boot jump (~2.5KB) shadows the kernel originals (~10KB) for every one of the
# interp's ~136 call sites -- ~1ms saved per call, no handler edits. First-match-from-top wins; the
# originals become dead shadows. Verbatim copies, so behavior is identical.
hpa = s_lf.index('\n:hp_cons\n')
hpb = s_lf.index('\n:hp_setcar\n')
hp_dup = s_lf[hpa:hpb]
bj = 'goto :in_main'
j = s_lf.index(bj) + len(bj)
s_lf = s_lf[:j] + hp_dup + s_lf[j:]
anchor = '\n:hp_setcar\n'
i = s_lf.index(anchor)
s = s_lf[:i] + hot + s_lf[i:]
machine_cmd = '@goto interp\n' + hp_dup + '\n' + rt_machine + '\n'
open('comp-cmd/interp-machine.cmd','wb').write(machine_cmd.replace('\r\n','\n').replace('\n','\r\n').encode('latin-1'))

# ---- READER EXTRACTION (perf): the reader is a per-CHARACTER backward-goto machine, and a cmd
# backward goto costs a FULL-FILE scan (~8ms in this ~80KB file) -- measured ~8s of an ~72s cold run,
# ~270ms per source line. Relocating readall+reader into a SMALL side file (comp-cmd/reader.cmd,
# ~5KB) makes each of those gotos ~0.4ms: `call reader.cmd` shares the process env (SRC, the parse
# stack ST_n/SP/DEPTH, RDRESULT, the heap), the redirected stdin follows the call, and `goto :eof`
# returns to the caller. Entries: `ra <skip>` = readall (line loop), `rf` = run_forms (drain SRC).
# The only label dependencies are hp_cons (open-coded below, PRE-inc) and emit_top's non-RDMODE
# :ev branch (dead here -- every interp-cmd read runs RDMODE=1; guarded with an error echo).
ra_start = s.index('\nrem readall: set/p reads a raw line')
rd_marker = '\nrem ============================ reader (iterative) ============================\n'
rf_start = s.index(rd_marker)
heap_marker = '\nrem ===================== heap (FILES:'
rf_end = s.index(heap_marker)
readall_txt = s[ra_start:rf_start]
reader_txt = s[rf_start:rf_end]
# skip-count arg shifts: entry arg 1 is the dispatch tag
readall_txt = readall_txt.replace('set "rdskip=%1"', 'set "rdskip=%~2"')
# open-code the two hp_cons sites (PRE-increment, guard byte '#', %HN% parse-time per line)
old = 'call :hp_cons "!top!" "!acc!"\nset "acc=!R!"'
assert reader_txt.count(old) == 1
reader_txt = reader_txt.replace(old, '''set /a HN+=1
>%HD%\\car%HN% echo(!top!#
>%HD%\\cdr%HN% echo(!acc!#
set "acc=P:%HN%"''')
old = 'call :hp_cons "!R!" "NIL"\ncall :hp_cons "S:quote" "!R!"'
assert reader_txt.count(old) == 1
reader_txt = reader_txt.replace(old, '''set /a HN+=1
>%HD%\\car%HN% echo(!R!#
>%HD%\\cdr%HN% echo(NIL#
set "aqq=P:%HN%"
set /a HN+=1
>%HD%\\car%HN% echo(S:quote#
>%HD%\\cdr%HN% echo(!aqq!#
set "R=P:%HN%"''')
old = 'call :ev 1 "!R!" "!GLOBAL!"'
assert reader_txt.count(old) == 1
reader_txt = reader_txt.replace(old, 'echo reader.cmd: non-RDMODE emit unsupported 1>&2')
reader_cmd = ('@if "%~1"=="rf" goto run_forms\n@goto readall\n'
              + readall_txt + reader_txt + '\n')
open('comp-cmd/reader.cmd','wb').write(reader_cmd.replace('\n','\r\n').encode('latin-1'))
# excise the moved blocks and retarget the three call sites
s = s[:ra_start] + '\n' + s[rf_end:]
old = 'call :readall %2 < "%TEMP%\\portsh_in_!HD!.txt"'
assert s.count(old) == 1
s = s.replace(old, 'call reader.cmd ra %2 < "%TEMP%\\portsh_in_!HD!.txt"')
old = 'call :readall 0'
assert s.count(old) == 1
s = s.replace(old, 'call reader.cmd ra 0')
assert s.count('call :run_forms') == 2
s = s.replace('call :run_forms', 'call reader.cmd rf')

s = s.replace('\n','\r\n')
open(out,'wb').write(s.encode('latin-1'))
print("wrote comp-cmd/interp-cmd.cmd + comp-cmd/reader.cmd")
PY
echo "built comp-cmd/interp-cmd.cmd ($(wc -c < comp-cmd/interp-cmd.cmd) bytes)"
