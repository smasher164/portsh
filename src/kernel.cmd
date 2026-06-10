@echo off
rem portsh — batch-hosted Lisp kernel (operative / vau core), port of kernel.sh.
rem FAST heap: cons cells live in variables CAR_<i>/CDR_<i> (O(1) read/write),
rem so there is NO setlocal anywhere in the eval chain (endlocal would revert
rem the heap). Recursion-safe locals use frame ids: a caller does
rem `set /a ND=%1+1 & call :fn !ND! args`, the callee's id is %1, inputs are
rem %2.. (stable across sub-calls), and any value held ACROSS a sub-call is
rem stored as _%1_name. Reader is iterative (mutates global SRC + parse stack).
rem MUST be CRLF (label lookup) and uses goto-dispatch (values contain parens).
setlocal enabledelayedexpansion
set "HN=0" & set "FID=0" & set "SP=0" & set "FREE_HEAD=NIL" & set "MARKGEN=0"
rem file-backed heap dir (cells = %HD%\car<i>/cdr<i>), inherited in-process by any compiled subs
rem that touch the heap. %RANDOM% alone is NOT enough: it's seeded from the wall-clock SECOND, so two
rem processes launched together (e.g. the front-end's fg interp + bg program warmer) get the SAME
rem sequence -> same dir -> shared/corrupted heap. mkdir is the atomic claim: it FAILS if the dir
rem exists, and the loser retries with fresh entropy (centiseconds + an advanced RANDOM).
:hd_claim
set "HD=ph_%RANDOM%%TIME:~9,2%%RANDOM%"
set "HD=!HD:,=!"
mkdir "!HD!" 2>nul
if errorlevel 1 goto hd_claim
if not defined GC_THRESH set "GC_THRESH=150000"
rem Four sentinel bytes stand in for the chars cmd's expansion phases eat or mangle
rem inside string VALUES: 0x01='!' (delayed expansion eats it), 0x02='%' (percent
rem phase), 0x07='^' (caret/escape), 0x08='"' (the string delimiter -- encoded first
rem so it can't break the later replaces). Operators & | < > need NO sentinel: the
rem source is read RAW via `set /p` (:readall), which doesn't parse content, so all
rem of !,%,^,",&,|,<,> survive together; we then encode in dependency order. They
rem decode back to real chars only at I/O; the '"' delimiters are consumed by the
rem reader and never reach output (portsh strings have no '"' escape). 0x01/0x07/0x08
rem are baked in as literal bytes (build.sh @B1@/@B7@/@B8@) where a `call`-based
rem inject would double a live '^'; 0x02 is fetched here for the delayed %-replaces.
for /F "delims=" %%a in ('forfiles /p "%~dp0." /m "%~nx0" /c "cmd /c echo 0x02"') do set "BANG2=%%a"
for /F "delims=" %%a in ('forfiles /p "%~dp0." /m "%~nx0" /c "cmd /c echo 0x08"') do set "BANG8=%%a"
rem BANG/BANG7 = literal 0x01/0x07 vars (baked by build.sh). Compiled subs reference
rem !BANG!/!BANG2! to materialise a data '!'/'%' that would otherwise be eaten by the
rem delayed-expansion pass when the value reaches a `set`; they decode to '!'/'%' at I/O.
set "BANG=@B1@"
set "BANG7=@B7@"
rem LT/GT/AMP/PIPE = the cmd operators < > & | as vars (baked literally inside
rem QUOTES, which protect them from tokenization at parse time). Compiled subs
rem reference !LT! etc. to place an operator into a value's text via delayed
rem expansion (post-tokenization), the only way a bare operator survives a `set`.
set "LT=@LT@"
set "GT=@GT@"
set "AMP=@AMP@"
set "PIPE=@PIPE@"
call :setup_global

rem Boot order: minimal prelude -> baked-in payload (stdlib) after the marker ->
rem file-arg program. MK is built from fragments so the literal never appears here
rem (the self-scan would match the kernel, not the baked-in final-line marker).
rem Both payload and program go through :feedfile, which reads each line RAW with
rem `set /p` and encodes ! % ^ " to sentinels -- the only way to keep all of
rem !, operators, and " in one line (no for-var read mode does). Source then drains
rem through :addsrc; the reader keeps only the current line in SRC so parsing is
rem O(n), and the parse stack (ST_/SP/DEPTH) persists across lines for multi-line
rem forms.
set "SP=0" & set "DEPTH=0"
set "MK=__PORTSH"
set "MK=!MK!_PAYLOAD__"
set "MLINE=0"
findstr /c:"!MK!" "%~f0" >nul 2>&1 && for /f "delims=:" %%n in ('findstr /n /c:"!MK!" "%~f0"') do if "!MLINE!"=="0" set "MLINE=%%n"
if not "%MLINE%"=="0" call :feedfile "%~f0" %MLINE%
if not "%~1"=="" call :feedfile "%~1" 0
:done_boot
exit /b 0

rem feedfile (%1=file %2=#lines-to-skip): prefix every line with [N] via
rem `find /v /n ""` (so set/p never meets a blank line, which it can't tell from
rem EOF), then read each line RAW with set/p, discard the first %2 (to skip the
rem kernel's own text ahead of the baked-in payload), and encode+drain the rest.
:feedfile
type "%~1" | find /v /n "" > "%TEMP%\portsh_in_!HD!.txt"
call :readall %2 < "%TEMP%\portsh_in_!HD!.txt"
goto :eof

rem readall: set/p reads a raw line (all of ! % ^ " & | < > survive). NO `call` is
rem used (a `call` re-parses and DOUBLES any live '^'): " and ! are encoded with
rem literal sentinel bytes (@B8@=0x08, @B1@=0x01, baked by build.sh), and % and ^
rem with parse-time-injected forfiles bytes under delayed expansion. Order: " -> 0x08
rem FIRST (so the next quoted-set replaces aren't broken by an inner " exposing a &);
rem strip the [N] prefix; ! -> 0x01; then (delayed) % -> 0x02 and ^ -> 0x07. Operators
rem stay REAL, so the reader/eval see them as Lisp tokens (e.g. the '<' in `(< n 2)`).
:readall
set "rdskip=%1"
:rd_skip
if %rdskip% gtr 0 set /p "rddiscard=" & set /a rdskip-=1 & goto rd_skip
:rd_loop
set "line="
set /p "line=" || goto :eof
setlocal disableDelayedExpansion
set "line=%line:"=@B8@%"
set "line=%line:^=@B7@%"
set "line=%line:*]=%"
rem a blank source line is just "[N]" -> empty after the strip; skip it, else the
rem next replace runs on an undefined var and leaks the literal "=!" (a stray '=').
if not defined line (endlocal & goto rd_loop)
set "line=%line:!=@B1@%"
endlocal & set "ln=%line%"
setlocal enableDelayedExpansion
set "ln=!ln:%%=%BANG2%!"
endlocal & set "ln=%ln%"
call :addsrc
goto rd_loop

rem ============================ reader (iterative) ============================
:run_forms
:rf_loop
call :skipws
if "!SRC!"=="" goto :eof
set "ch=!SRC:~0,1!"
if "!ch!"=="(" goto rf_open
if "!ch!"==")" goto rf_close
if "!ch!"=="'" goto rf_quote
if "!ch!"=="!BANG8!" goto rf_string
goto rf_atom
:rf_quote
rem 'x -> (quote x): push a quote-marker; apply_quotes wraps the next datum
set "ST_!SP!=QM" & set /a SP+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_string
rem string literal "..." -> T:...  ('"' is the 0x08 sentinel by now; BANG8 ends it)
set "SRC=!SRC:~1!"
set "rfs="
:rfs_loop
if "!SRC!"=="" goto rfs_done
set "sc=!SRC:~0,1!"
if "!sc!"=="!BANG8!" set "SRC=!SRC:~1!" & goto rfs_done
set "rfs=!rfs!!sc!" & set "SRC=!SRC:~1!"
goto rfs_loop
:rfs_done
set "R=T:!rfs!"
call :emit_top "!R!"
goto rf_loop
:rf_open
set "ST_!SP!=LP" & set /a SP+=1 & set /a DEPTH+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_close
set "SRC=!SRC:~1!"
call :reduce_list
call :emit_top "!R!"
goto rf_loop
:rf_atom
call :read_atom
call :emit_top "!R!"
goto rf_loop

:skipws
if "!SRC!"=="" goto :eof
if "!SRC:~0,1!"==" " set "SRC=!SRC:~1!" & goto :skipws
goto :eof

:read_atom
set "tok="
:ra_loop
if "!SRC!"=="" goto ra_done
set "ch=!SRC:~0,1!"
if "!ch!"==" " goto ra_done
if "!ch!"=="(" goto ra_done
if "!ch!"==")" goto ra_done
set "tok=!tok!!ch!" & set "SRC=!SRC:~1!"
goto ra_loop
:ra_done
set "t=!tok!"
if "!t!"=="" set "R=S:" & goto :eof
set "c0=!t:~0,1!"
set "isnum=0"
rem digit classify via geq/leq (2 cmds) instead of a 10-iteration for-loop per
rem atom. A leading '-' followed by a digit is a number (bare '-' and '-foo' stay
rem symbols), matching the sh reader (which reads -1 as I:-1, not the symbol -1).
if "!c0!" geq "0" if "!c0!" leq "9" set "isnum=1"
if "!c0!"=="-" if "!t:~1,1!" geq "0" if "!t:~1,1!" leq "9" set "isnum=1"
if "!isnum!"=="1" (set "R=I:!t!") else (set "R=S:!t!")
goto :eof

:reduce_list
set "acc=NIL"
:rl_loop
set /a SP-=1
call set "top=%%ST_!SP!%%"
if "!top!"=="LP" set /a DEPTH-=1 & set "R=!acc!" & goto :eof
call :hp_cons "!top!" "!acc!"
set "acc=!R!"
goto rl_loop

:emit_top
call :apply_quotes
if !DEPTH! GTR 0 goto et_push
if "!RDMODE!"=="1" set "RDRESULT=!R!" & set "SRC=" & goto :eof
call :ev 1 "!R!" "!GLOBAL!"
goto :eof
:et_push
set "ST_!SP!=!R!" & set /a SP+=1
goto :eof
:apply_quotes
rem while a quote-marker sits on top of the stack, wrap R as (quote R)
:aq_loop
if "!SP!"=="0" goto :eof
set /a aqsp=SP-1
call set "aqtop=%%ST_!aqsp!%%"
if not "!aqtop!"=="QM" goto :eof
set "SP=!aqsp!"
call :hp_cons "!R!" "NIL"
call :hp_cons "S:quote" "!R!"
goto aq_loop

:addsrc
rem Feed ONE line: strip its ';' comment (string-aware, so a ';' inside a "..."
rem survives — matching the sh reader), put just that line + a trailing space in
rem SRC, and drain it through the reader (goto rf_loop; the reader returns via
rem goto :eof when SRC empties). SRC holds at most one line, so the char advance
rem stays O(line) and parsing is O(n), not O(n^2). The parse stack persists
rem across calls, so multi-line forms work. Fast path: a line with no ';' skips
rem the char scan; comment lines hit the ';' almost immediately.
set "asLn=!ln!"
set "asTest=!asLn:;=!"
if "!asTest!"=="!asLn!" set "SRC=!asLn! " & goto rf_loop
set "asKept=" & set "asIn=0"
:as_loop
if "!asLn!"=="" goto as_done
set "asC=!asLn:~0,1!"
set "asLn=!asLn:~1!"
if "!asC!"=="!BANG8!" goto as_quote
if "!asIn!"=="1" goto as_keep
if "!asC!"==";" goto as_done
:as_keep
set "asKept=!asKept!!asC!"
goto as_loop
:as_quote
if "!asIn!"=="0" (set "asIn=1") else (set "asIn=0")
set "asKept=!asKept!!asC!"
goto as_loop
:as_done
set "SRC=!asKept! "
goto rf_loop

rem ===================== heap (FILES: %HD%\car<i> / %HD%\cdr<i>) =====================
rem cmd var ops are O(env-size), so an env-var heap makes cons O(N^2) to build and
rem every car/cdr O(heap). The filesystem is O(1) by name, so each cell is two files
rem car<i>/cdr<i> in %HD%. KEY: redirect targets are parsed BEFORE delayed expansion,
rem so the PATH uses %HD%/%HN%/%idx% (immediate); the value uses !..! (delayed,
rem post-parse) so operators (& | < >) and parens in a value never re-tokenize.
rem Files don't degrade with heap size, so GC is non-critical here (po_gc neutralised).
:hp_cons
set "hca=%~1" & set "hcd=%~2"
>%HD%\car%HN% echo(!hca!#
>%HD%\cdr%HN% echo(!hcd!#
set "R=P:%HN%"
set /a HN+=1
goto :eof
:hp_car
set "hcp=%~1"
if "!hcp:~0,2!" NEQ "P:" set "R=NIL" & goto :eof
set "hcp=!hcp:P:=!"
set /p R=<%HD%\car%hcp%
set "R=!R:~0,-1!"
goto :eof
:hp_cdr
set "hdp=%~1"
if "!hdp:~0,2!" NEQ "P:" set "R=NIL" & goto :eof
set "hdp=!hdp:P:=!"
set /p R=<%HD%\cdr%hdp%
set "R=!R:~0,-1!"
goto :eof
:hp_setcar
set "scp=%~1" & set "scp=!scp:P:=!" & set "sca=%~2"
>%HD%\car%scp% echo(!sca!#
goto :eof
:hp_setcdr
set "sdp=%~1" & set "sdp=!sdp:P:=!" & set "sda=%~2"
>%HD%\cdr%sdp% echo(!sda!#
goto :eof
:list_reverse
rem reverse a list (flat helper; never re-enters :ev, so plain temps are safe)
set "lrL=%~1" & set "lrAcc=NIL"
:lr_loop
if "!lrL!"=="NIL" set "R=!lrAcc!" & goto :eof
call :hp_car "!lrL!"
set "lrV=!R!"
call :hp_cdr "!lrL!"
set "lrL=!R!"
call :hp_cons "!lrV!" "!lrAcc!"
set "lrAcc=!R!"
goto lr_loop

rem ============================== environment ==============================
:env_new
call :hp_cons "NIL" "%~1"
goto :eof

:env_define
call :hp_car "%~1"
set "edB=!R!"
call :hp_cons "%~2" "%~3"
call :hp_cons "!R!" "!edB!"
call :hp_setcar "%~1" "!R!"
goto :eof

:env_lookup
rem Hot path: heap accessors are INLINED here (no call overhead). Walk frames;
rem within a frame walk the binding alist; on a hit past the head, splice to
rem front (move-to-front) so hot symbols settle into a single-set lookup.
set "elkEnv=%~1" & set "elkSym=%~2"
:elk_env
if "!elkEnv!"=="NIL" goto elk_unbound
set "ei=!elkEnv:P:=!"
set /p elkB=<%HD%\car%ei%
set "elkB=!elkB:~0,-1!"
set "elkPrev="
:elk_b
if "!elkB!"=="NIL" goto elk_next
set "bi=!elkB:P:=!"
set /p elkP=<%HD%\car%bi%
set "elkP=!elkP:~0,-1!"
set "pi=!elkP:P:=!"
set /p _pk=<%HD%\car%pi%
set "_pk=!_pk:~0,-1!"
if "!_pk!"=="!elkSym!" goto elk_found
set "elkPrev=!elkB!"
set /p elkB=<%HD%\cdr%bi%
set "elkB=!elkB:~0,-1!"
goto elk_b
:elk_next
set /p elkEnv=<%HD%\cdr%ei%
set "elkEnv=!elkEnv:~0,-1!"
goto elk_env
:elk_found
if "!elkPrev!"=="" goto elk_val
set /p elkNext=<%HD%\cdr%bi%
set "elkNext=!elkNext:~0,-1!"
call :hp_setcdr "!elkPrev!" "!elkNext!"
set /p elkHead=<%HD%\car%ei%
set "elkHead=!elkHead:~0,-1!"
call :hp_setcdr "!elkB!" "!elkHead!"
call :hp_setcar "!elkEnv!" "!elkB!"
:elk_val
set /p R=<%HD%\cdr%pi%
set "R=!R:~0,-1!"
goto :eof
:elk_unbound
set "elkU=!elkSym:S:=!"
1>&2 echo portsh: unbound symbol: !elkU!
set "R=NIL"
goto :eof

rem =============================== evaluator ===============================
rem TCO evaluator: a goto-loop (mirrors kernel.sh's ev). Tail positions (if-branch,
rem lambda body's last form, applicative unwrap) update _%1_x/_%1_env and `goto ev_top`
rem instead of recursing, so deep tail recursion does NOT grow cmd's call stack (was
rem the ~319 limit). Non-tail evals (combiner, operands, if-test, non-last body forms)
rem still `call :ev` with a fresh frame. LOOP STATE IS FRAME-SCOPED (_%1_x etc.): a
rem recursive call enters :ev at %1+1 and would clobber a global, so per-frame vars.
rem The combine/combine_oper/ev_seq/po_if functions below are now folded in here.
:ev
set "_%1_x=%~2" & set "_%1_env=%~3"
:ev_top
if "!_%1_x!"=="NIL" set "R=NIL" & goto :eof
set "evPre=!_%1_x:~0,2!"
if "!evPre!"=="I:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="F:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="R:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="O:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="A:" set "R=!_%1_x!" & goto :eof
if "!evPre!"=="S:" call :env_lookup "!_%1_env!" "!_%1_x!" & goto :eof
if not "!evPre!"=="P:" set "R=!_%1_x!" & goto :eof
rem combination: eval combiner (non-tail), read operands, dispatch on combiner type
set "eci=!_%1_x:P:=!"
set /p _eca=<%HD%\car%eci%
set "_eca=!_eca:~0,-1!"
set /a ND=%1+1 & call :ev !ND! "!_eca!" "!_%1_env!"
set "_%1_c=!R!"
set "eci=!_%1_x:P:=!"
set /p _%1_ops=<%HD%\cdr%eci%
set "_%1_ops=!_%1_ops:~0,-1!"
:ev_apply
set "cPre=!_%1_c:~0,2!"
if "!cPre!"=="A:" goto ev_appl
if "!cPre!"=="R:" goto ev_primapp
if "!cPre!"=="F:" goto ev_oper
if "!cPre!"=="O:" goto ev_compound
if "!cPre!"=="C:" goto ev_compiled
set "R=NIL" & goto :eof
:ev_appl
rem applicative A:<i> = wrap(combiner): unwrap, eval operands, loop on the unwrapped
call :hp_car "P:!_%1_c:~2!"
set "_%1_w=!R!"
set /a ND=%1+1 & call :eval_list !ND! "!_%1_ops!" "!_%1_env!"
set "_%1_ops=!R!" & set "_%1_c=!_%1_w!"
goto ev_apply
:ev_primapp
set /a ND=%1+1 & call :eval_list !ND! "!_%1_ops!" "!_%1_env!"
set "pn=!_%1_c:~2!"
set /a ND=%1+1 & call :prim_app !ND! "!pn!" "!R!"
goto :eof
:ev_oper
if "!_%1_c!"=="F:if" goto ev_if
set "pn=!_%1_c:~2!"
set /a ND=%1+1 & call :prim_oper !ND! "!pn!" "!_%1_ops!" "!_%1_env!"
goto :eof
:ev_compiled
rem C:<label> compiled combiner -> TRAMPOLINE. Eval operands into the frame stack F[0..], then run a
rem driver loop that `call`s the current fn's .cmd at DEPTH 1 (each compiled fn is a resumable
rem segment machine: it does one segment then yields via ACTION=call/ret/tail + `goto :eof`). Host
rem call-depth stays 1 regardless of logical recursion depth -- cmd's `call` overflows at ~341 deep.
set /a ND=%1+1 & call :eval_list !ND! "!_%1_ops!" "!_%1_env!"
set "ccL=!_%1_c:~2!"
set "ccN=0" & set "ccLst=!R!"
:ev_cc_loop
if "!ccLst!"=="NIL" goto ev_cc_run
call :hp_car "!ccLst!"
set "F!ccN!=!R!" & set /a ccN+=1
call :hp_cdr "!ccLst!"
set "ccLst=!R!"
goto ev_cc_loop
:ev_cc_run
set "FP=0" & set "RSP=0" & set "CURFN=!ccL!" & set "PC=0" & set "CLO="
:ev_tloop
if "!CURFN!"=="HALT" goto :eof
set "ACTION="
call "!CURFN!_pc!PC!.cmd"
if "!ACTION!"=="call" goto ev_tcall
if "!ACTION!"=="ret" goto ev_tret
goto ev_tloop
:ev_tcall
rem save caller frame (incl. closure-record ptr CLO) on the return stack
set "RSF!RSP!=!CURFN!" & set "RSC!RSP!=!RPC!" & set "RSB!RSP!=!FP!" & set "RSL!RSP!=!CLO!"
set /a RSP+=1
set "FP=!NFP!" & set "PC=0" & set "CLO="
rem K:<idx> = a flat closure: CURFN = the record's label (car), CLO = the record idx
if "!CALLEE:~0,2!"=="K:" goto ev_tcall_clo
rem C:<label> = a first-class NAMED fn value: dispatch straight to the label (no captured env)
if "!CALLEE:~0,2!"=="C:" set "CURFN=!CALLEE:~2!" & goto ev_tloop
set "CURFN=!CALLEE!"
goto ev_tloop
:ev_tcall_clo
set "CLO=!CALLEE:~2!"
call :hp_car "P:!CLO!"
set "CURFN=!R:~2!"
goto ev_tloop
:ev_tret
if !RSP!==0 ( set "CURFN=HALT" & goto ev_tloop )
set /a RSP-=1
call set "FP=%%RSB!RSP!%%" & call set "CURFN=%%RSF!RSP!%%" & call set "PC=%%RSC!RSP!%%" & call set "CLO=%%RSL!RSP!%%"
goto ev_tloop
:ev_if
rem (if test then else): eval test (non-tail); chosen branch is TAIL -> loop
call :hp_car "!_%1_ops!"
set /a ND=%1+1 & call :ev !ND! "!R!" "!_%1_env!"
set "_%1_t=!R!"
call :hp_cdr "!_%1_ops!"
set "_%1_r=!R!"
if "!_%1_t!"=="NIL" goto ev_if_else
call :hp_car "!_%1_r!"
set "_%1_x=!R!"
goto ev_top
:ev_if_else
call :hp_cdr "!_%1_r!"
call :hp_car "!R!"
set "_%1_x=!R!"
goto ev_top
:ev_compound
rem compound operative O:<i> = (formals eformal body senv): bind, eval body; last
rem body form is TAIL -> loop. operands are as-passed (pre-evaluated if reached via A:).
set "ci=!_%1_c:O:=!"
set /p _%1_f=<%HD%\car%ci%
set "_%1_f=!_%1_f:~0,-1!"
set /p cr1=<%HD%\cdr%ci%
set "cr1=!cr1:~0,-1!"
set "cr1=!cr1:P:=!"
set /p _%1_ef=<%HD%\car%cr1%
set "_%1_ef=!_%1_ef:~0,-1!"
set /p cr2=<%HD%\cdr%cr1%
set "cr2=!cr2:~0,-1!"
set "cr2=!cr2:P:=!"
set /p _%1_body=<%HD%\car%cr2%
set "_%1_body=!_%1_body:~0,-1!"
set /p _%1_senv=<%HD%\cdr%cr2%
set "_%1_senv=!_%1_senv:~0,-1!"
set /a ND=%1+1 & call :build_alist !ND! "!_%1_f!" "!_%1_ops!" "NIL"
set "_%1_al=!R!"
if "!_%1_ef!"=="S:#ignore" goto ev_co_noenv
call :hp_cons "!_%1_ef!" "!_%1_env!"
call :hp_cons "!R!" "!_%1_al!"
set "_%1_al=!R!"
:ev_co_noenv
call :hp_cons "!_%1_al!" "!_%1_senv!"
set "_%1_env=!R!"
:ev_co_bodyloop
if "!_%1_body!"=="NIL" set "R=NIL" & goto :eof
call :hp_cdr "!_%1_body!"
set "_%1_brest=!R!"
if "!_%1_brest!"=="NIL" goto ev_co_tail
call :hp_car "!_%1_body!"
set /a ND=%1+1 & call :ev !ND! "!R!" "!_%1_env!"
set "_%1_body=!_%1_brest!"
goto ev_co_bodyloop
:ev_co_tail
call :hp_car "!_%1_body!"
set "_%1_x=!R!"
goto ev_top

:combine
set "cmbC=%~2" & set "cmbPre=!cmbC:~0,2!"
if "!cmbPre!"=="F:" goto cmb_oper
if "!cmbPre!"=="R:" goto cmb_app
if "!cmbPre!"=="A:" goto cmb_appl
if "!cmbPre!"=="O:" goto cmb_compound
if "!cmbPre!"=="C:" goto cmb_compiled
set "R=NIL" & goto :eof
:cmb_compiled
rem C:<label> — a JIT-compiled applicative. Eval operands, strip tags to raw
rem args (A1..An), and call the generated batch sub. Multi-file: each compiled fn
rem is its own <label>.cmd (cmd's label scan is O(file-position), so one fn per file
rem keeps every entry at the top -> ~1ms calls regardless of program size).
set /a ND=%1+1 & call :eval_list !ND! "%~3" "%~4"
set "ccL=%~2" & set "ccL=!ccL:~2!"
set "ccN=0" & set "ccLst=!R!"
:cc_loop
if "!ccLst!"=="NIL" goto cc_call
call :hp_car "!ccLst!"
set /a ccN+=1 & set "A!ccN!=!R!"
call :hp_cdr "!ccLst!"
set "ccLst=!R!"
goto cc_loop
:cc_call
call "!ccL!.cmd"
goto :eof
:cmb_oper
set "cmbN=%~2" & set "cmbN=!cmbN:~2!"
set /a ND=%1+1 & call :prim_oper !ND! "!cmbN!" "%~3" "%~4"
goto :eof
:cmb_app
set /a ND=%1+1 & call :eval_list !ND! "%~3" "%~4"
set "cmbN=%~2" & set "cmbN=!cmbN:~2!"
set /a ND=%1+1 & call :prim_app !ND! "!cmbN!" "!R!"
goto :eof
:cmb_appl
set "cmbC=%~2"
call :hp_car "P:!cmbC:~2!"
set "_%1_u=!R!"
set /a ND=%1+1 & call :eval_list !ND! "%~3" "%~4"
set /a ND=%1+1 & call :combine !ND! "!_%1_u!" "!R!" "%~4"
goto :eof
:cmb_compound
set /a ND=%1+1 & call :combine_oper !ND! "%~2" "%~3" "%~4"
goto :eof

:eval_list
if "%~2"=="NIL" set "R=NIL" & goto :eof
set "eli=%~2" & set "eli=!eli:P:=!"
set /p _ele=<%HD%\car%eli%
set "_ele=!_ele:~0,-1!"
set /a ND=%1+1 & call :ev !ND! "!_ele!" "%~3"
set "_%1_e=!R!"
set "eli=%~2" & set "eli=!eli:P:=!"
set /p _eld=<%HD%\cdr%eli%
set "_eld=!_eld:~0,-1!"
set /a ND=%1+1 & call :eval_list !ND! "!_eld!" "%~3"
call :hp_cons "!_%1_e!" "!R!"
goto :eof

:prim_oper
set "poN=%~2"
if "!poN!"=="vau" goto po_vau
if "!poN!"=="quote" goto po_quote
if "!poN!"=="lambda" goto po_lambda
if "!poN!"=="define" goto po_define
if "!poN!"=="if" goto po_if
if "!poN!"=="run" goto po_run
if "!poN!"=="run-capture" goto po_runcap
if "!poN!"=="gc" goto po_gc
set "R=NIL" & goto :eof
:po_gc
rem file-backed heap (cells are files in %HD%) does NOT degrade with heap size, so GC
rem is a no-op for now -- the heap just grows as files; reclamation would only matter
rem for disk/inode limits on very large runs. (Was a mark-sweep over CAR_/CDR_ vars.)
set "R=S:t"
goto :eof
:po_runcap
rem render operands into a command line, run it, capture stdout as a line list
set "rcCmd=" & set "rcLst=%~3"
:rc_loop
if "!rcLst!"=="NIL" goto rc_exec
call :hp_car "!rcLst!"
set "rcTok=!R!"
set "rcCmd=!rcCmd! !rcTok:~2!"
call :hp_cdr "!rcLst!"
set "rcLst=!R!"
goto rc_loop
:rc_exec
rem Redirect-FIRST so NOTHING follows the quoted command. Otherwise the space
rem before a trailing token (`2>&1`/`|`) is absorbed into the command line and
rem echo emits a spurious trailing space (a cmd quote-stripping quirk that the
rem sh capture doesn't have). Capture raw, then prefix every line with "[N]" via
rem find (keeps blank/';' lines) in a separate step, then iterate.
> "%TEMP%\portsh_rc1_!HD!.txt" 2>&1 cmd /c "!rcCmd!"
type "%TEMP%\portsh_rc1_!HD!.txt" | find /v /n "" > "%TEMP%\portsh_rc_!HD!.txt"
set "rcAcc=NIL"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rc_!HD!.txt") do (
  set "rcLn=%%L" & set "rcLn=!rcLn:*]=!"
  call :hp_cons "T:!rcLn!" "!rcAcc!"
  set "rcAcc=!R!"
)
call :list_reverse "!rcAcc!"
set "lgRC=!R!" & call :lg_list run-capture "!lgRC!" & set "R=!lgRC!"
goto :eof
:po_run
rem render unevaluated operands (symbols/ints) into a command line, execute it
set "porCmd=" & set "porLst=%~3"
:po_run_loop
if "!porLst!"=="NIL" goto po_run_exec
call :hp_car "!porLst!"
set "porTok=!R!"
set "porCmd=!porCmd! !porTok:~2!"
call :hp_cdr "!porLst!"
set "porLst=!R!"
goto po_run_loop
:po_run_exec
cmd /c "!porCmd!"
set "R=I:!errorlevel!"
call :lg_out run
goto :eof
:po_vau
call :hp_car "%~3"
set "poF=!R!"
call :hp_cdr "%~3"
set "poR1=!R!"
call :hp_car "!poR1!"
set "poEf=!R!"
call :hp_cdr "!poR1!"
set "poBody=!R!"
call :hp_cons "!poBody!" "%~4"
call :hp_cons "!poEf!" "!R!"
call :hp_cons "!poF!" "!R!"
set "poRes=!R!"
set "R=O:!poRes:P:=!"
goto :eof
:po_quote
rem (quote x) -> x, unevaluated. Was a prelude macro; a primitive avoids parsing
rem the prelude every boot.
call :hp_car "%~3"
goto :eof
:po_lambda
rem (lambda formals . body) -> applicative wrapping a compound operative (a vau
rem with eformal=#ignore). Primitive form removes the big prelude lambda macro
rem (the dominant boot cost) and skips macro re-expansion per closure.
call :hp_car "%~3"
set "plF=!R!"
call :hp_cdr "%~3"
call :hp_cons "!R!" "%~4"
call :hp_cons "S:#ignore" "!R!"
call :hp_cons "!plF!" "!R!"
set "R=O:!R:P:=!"
call :hp_cons "!R!" "NIL"
set "R=A:!R:P:=!"
goto :eof
:po_define
call :hp_car "%~3"
set "_%1_sym=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
call :env_define "%~4" "!_%1_sym!" "!R!"
set "R=!_%1_sym!"
goto :eof
:po_if
call :hp_car "%~3"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
set "poT=!R!"
call :hp_cdr "%~3"
set "poR1=!R!"
if "!poT!"=="NIL" goto po_if_else
call :hp_car "!poR1!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
goto :eof
:po_if_else
call :hp_cdr "!poR1!"
call :hp_car "!R!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~4"
goto :eof

:combine_oper
set "ci=%~2" & set "ci=!ci:O:=!"
set /p _%1_f=<%HD%\car%ci%
set "_%1_f=!_%1_f:~0,-1!"
set /p cr1=<%HD%\cdr%ci%
set "cr1=!cr1:~0,-1!"
set "cr1=!cr1:P:=!"
set /p _%1_ef=<%HD%\car%cr1%
set "_%1_ef=!_%1_ef:~0,-1!"
set /p cr2=<%HD%\cdr%cr1%
set "cr2=!cr2:~0,-1!"
set "cr2=!cr2:P:=!"
set /p _%1_body=<%HD%\car%cr2%
set "_%1_body=!_%1_body:~0,-1!"
set /p _%1_senv=<%HD%\cdr%cr2%
set "_%1_senv=!_%1_senv:~0,-1!"
set /a ND=%1+1 & call :build_alist !ND! "!_%1_f!" "%~3" "NIL"
set "_%1_al=!R!"
if "!_%1_ef!"=="S:#ignore" goto co_noenv
call :hp_cons "!_%1_ef!" "%~4"
call :hp_cons "!R!" "!_%1_al!"
set "_%1_al=!R!"
:co_noenv
call :hp_cons "!_%1_al!" "!_%1_senv!"
set /a ND=%1+1 & call :ev_seq !ND! "!_%1_body!" "!R!"
goto :eof

:build_alist
if "%~2"=="NIL" set "R=%~4" & goto :eof
set "baF=%~2"
if "!baF:~0,2!"=="S:" goto ba_rest
call :hp_car "%~2"
set "_%1_p=!R!"
call :hp_car "%~3"
call :hp_cons "!_%1_p!" "!R!"
call :hp_cons "!R!" "%~4"
set "_%1_acc=!R!"
call :hp_cdr "%~2"
set "_%1_ft=!R!"
call :hp_cdr "%~3"
set /a ND=%1+1 & call :build_alist !ND! "!_%1_ft!" "!R!" "!_%1_acc!"
goto :eof
:ba_rest
call :hp_cons "%~2" "%~3"
call :hp_cons "!R!" "%~4"
goto :eof

:ev_seq
set "_%1_lst=%~2"
set "_%1_val=NIL"
:es_loop
if "!_%1_lst!"=="NIL" set "R=!_%1_val!" & goto :eof
call :hp_car "!_%1_lst!"
set /a ND=%1+1 & call :ev !ND! "!R!" "%~3"
set "_%1_val=!R!"
call :hp_cdr "!_%1_lst!"
set "_%1_lst=!R!"
goto es_loop

rem ---- record-and-replay log (the two-tier handoff): when PORTSH_LOG is set, :ev RECORDS each I/O
rem effect, in order, so the warm cmd JIT can re-run from source, REPLAY the logged prefix (suppress
rem output / return logged world results), and go LIVE where the log ends -- each effect exactly once.
rem Format: an op line, a count line, then <count> payload lines (no separator -- cmd-friendly). The
rem value to log rides in R, written verbatim (sentinel bytes 0x01/0x02/0x08 are not cmd metachars, so
rem they survive echo; a raw operator in a payload is a documented gap, like read-lines' '!'-loss). With
rem PORTSH_LOG unset every helper is a no-op. lg_tick runs AFTER the effect+record, the only safe place
rem to abandon: at PORTSH_LOG_STOP=K ops (deterministic test stand-in) or when the .ok marker appears
rem (the real "JIT warm" signal). Abandon = `exit 42` (NOT exit /b, which only returns one call level) --
rem :ev runs in its own cmd process, so this exits it with 42 for the front-end to detect.
:lg_tick
set /a LG_N+=1
if defined PORTSH_LOG_STOP if !LG_N! geq !PORTSH_LOG_STOP! exit 42
if defined PORTSH_OK if exist "!PORTSH_OK!" exit 42
goto :eof
:lg_out
if not defined PORTSH_LOG goto :eof
>>"!PORTSH_LOG!" echo(%~1
>>"!PORTSH_LOG!" echo(1
>>"!PORTSH_LOG!" echo(!R!
goto lg_tick
:lg_logv
rem like lg_out but the value is given explicitly in %2 (used by print: it must EMIT first, then log the
rem saved rendered text, so an abandon at lg_tick leaves the print both emitted AND logged). Doesn't touch R.
if not defined PORTSH_LOG goto :eof
>>"!PORTSH_LOG!" echo(%~1
>>"!PORTSH_LOG!" echo(1
>>"!PORTSH_LOG!" echo(%~2
goto lg_tick
:lg_mark
if not defined PORTSH_LOG goto :eof
>>"!PORTSH_LOG!" echo(%~1
>>"!PORTSH_LOG!" echo(0
goto lg_tick
:lg_list
rem %1=op, %2=heap list of T: strings. Clobbers R -- callers save/restore.
if not defined PORTSH_LOG goto :eof
set "lgL=%~2" & set "lgC=0"
:lg_count
if "!lgL!"=="NIL" goto lg_emit
call :hp_cdr "!lgL!" & set "lgL=!R!" & set /a lgC+=1
goto lg_count
:lg_emit
>>"!PORTSH_LOG!" echo(%~1
>>"!PORTSH_LOG!" echo(!lgC!
set "lgL=%~2"
:lg_emit2
if "!lgL!"=="NIL" goto lg_tick
call :hp_car "!lgL!" & set "lgE=!R:~2!"
>>"!PORTSH_LOG!" echo(!lgE!
call :hp_cdr "!lgL!" & set "lgL=!R!"
goto lg_emit2

rem =========================== primitives (applicative) ===========================
:prim_app
set "paN=%~2"
if "!paN!"=="dq" goto pa_dq
if "!paN!"=="make-compiled" goto pa_mkcompiled
if "!paN!"=="list" goto pa_list
if "!paN!"=="cons" goto pa_cons
if "!paN!"=="car" goto pa_car
if "!paN!"=="cdr" goto pa_cdr
if "!paN!"=="eq?" goto pa_eq
if "!paN!"=="null?" goto pa_null
if "!paN!"=="atom?" goto pa_atom
if "!paN!"=="+" goto pa_add
if "!paN!"=="-" goto pa_sub
if "!paN!"=="*" goto pa_mul
if "!paN!"=="<" goto pa_lt
if "!paN!"=="=" goto pa_numeq
if "!paN!"=="wrap" goto pa_wrap
if "!paN!"=="unwrap" goto pa_unwrap
if "!paN!"=="eval" goto pa_eval
if "!paN!"=="print" goto pa_print
if "!paN!"=="file-exists?" goto pa_fex
if "!paN!"=="string-append" goto pa_strapp
if "!paN!"=="string-length" goto pa_strlen
if "!paN!"=="substring" goto pa_substr
if "!paN!"=="symbol->string" goto pa_sym2str
if "!paN!"=="string->symbol" goto pa_str2sym
if "!paN!"=="number->string" goto pa_num2str
if "!paN!"=="string->number" goto pa_str2num
if "!paN!"=="read-lines" goto pa_rdlines
if "!paN!"=="write-lines" goto pa_wrlines
if "!paN!"=="append-lines" goto pa_aplines
if "!paN!"=="hmark" goto pa_hmark
if "!paN!"=="hreset" goto pa_hreset
if "!paN!"=="read" goto pa_read
if "!paN!"=="type-of" goto pa_typeof
if "!paN!"=="split" goto pa_split
set "R=NIL" & goto :eof
:pa_split
rem Split a string on a (possibly multi-char) separator, empty fields preserved.
rem Native char-scan in batch (set/goto, no eval) — the whole point of making
rem this a primitive instead of a userspace per-char loop through the evaluator.
call :hp_car "%~3"
set "spS=!R:~2!"
call :hp_cdr "%~3" & call :hp_car "!R!"
set "spSep=!R:~2!"
set "spSL=0"
:sp_seplen
call set "spLC=%%spSep:~!spSL!,1%%"
if not "!spLC!"=="" set /a spSL+=1 & goto sp_seplen
if "!spSL!"=="0" call :hp_cons "T:!spS!" "NIL" & goto :eof
set "spAcc=NIL" & set "spCur=" & set "spI=0"
:sp_loop
call set "spCh=%%spS:~!spI!,1%%"
if "!spCh!"=="" goto sp_emit
call set "spChunk=%%spS:~!spI!,!spSL!%%"
if "!spChunk!"=="!spSep!" goto sp_match
set "spCur=!spCur!!spCh!" & set /a spI+=1
goto sp_loop
:sp_match
call :hp_cons "T:!spCur!" "!spAcc!"
set "spAcc=!R!" & set "spCur=" & set /a spI+=spSL
goto sp_loop
:sp_emit
call :hp_cons "T:!spCur!" "!spAcc!"
set "spAcc=!R!"
call :list_reverse "!spAcc!"
goto :eof
:pa_read
rem Parse one datum from a string WITHOUT evaluating. Reuse the kernel reader by
rem pointing SRC at the string and running it in RDMODE (emit_top captures the
rem first top-level datum into RDRESULT and clears SRC to stop). The outer
rem reader's state (SRC/SP/DEPTH) is saved/restored; its stack is empty here
rem because a top-level datum is fully reduced before eval runs.
call :hp_car "%~3"
set "raStr=!R:~2!"
set "_raSRC=!SRC!" & set "_raSP=!SP!" & set "_raDEPTH=!DEPTH!"
set "SRC=!raStr!" & set "SP=0" & set "DEPTH=0" & set "RDMODE=1" & set "RDRESULT=NIL"
call :run_forms
set "RDMODE="
set "R=!RDRESULT!"
set "SRC=!_raSRC!" & set "SP=!_raSP!" & set "DEPTH=!_raDEPTH!"
goto :eof
:pa_typeof
call :hp_car "%~3"
set "toV=!R!"
if "!toV!"=="NIL" set "R=S:nil" & goto :eof
set "toP=!toV:~0,2!"
if "!toP!"=="I:" set "R=S:number" & goto :eof
if "!toP!"=="S:" set "R=S:symbol" & goto :eof
if "!toP!"=="T:" set "R=S:string" & goto :eof
if "!toP!"=="P:" set "R=S:pair" & goto :eof
if "!toP!"=="O:" set "R=S:operative" & goto :eof
if "!toP!"=="F:" set "R=S:operative" & goto :eof
if "!toP!"=="A:" set "R=S:applicative" & goto :eof
if "!toP!"=="R:" set "R=S:applicative" & goto :eof
set "R=S:unknown" & goto :eof
:pa_rdlines
call :hp_car "%~3"
set "rlF=!R:~2!" & set "rlAcc=NIL"
rem `type file | find /v /n ""` prefixes EVERY line (blanks + ';'-leading
rem included) with "[N]", so for/f keeps them; !ln:*]=! strips that prefix.
rem This is what makes read-lines preserve blank/';' lines exactly like the sh
rem kernel. (find /v /n "" matches all lines; piping via type avoids find's
rem filename header, and avoids findstr's "^" being eaten in this nested context.)
rem Run the pipe as a normal redirect FIRST, then iterate the prefixed file with
rem a plain for/f. A pipe INSIDE for/f deadlocks in this deep call/redirect
rem context, so the pipe must stand alone. The "[N]" prefix on every line keeps
rem blank/';'-leading lines visible to for/f; !ln:*]=! strips it back off.
type "!rlF!" | find /v /n "" > "%TEMP%\portsh_rl_!HD!.txt"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rl_!HD!.txt") do (
  set "rlLn=%%L" & set "rlLn=!rlLn:*]=!"
  call :hp_cons "T:!rlLn!" "!rlAcc!"
  set "rlAcc=!R!"
)
rem NOTE: this for/f read eats a literal '!' in file content (delayed expansion), so
rem read-lines of a '!'-bearing data file loses the '!' -- a known consistency gap.
rem The set/p raw reader used for source/programs can't be reused here: read-lines is
rem called DEEP in the eval chain, where `call :sub < file` (stdin redirect) fails.
call :list_reverse "!rlAcc!"
set "lgRL=!R!" & call :lg_list read-lines "!lgRL!" & set "R=!lgRL!"
goto :eof
:pa_aplines
rem append-lines: like write-lines but does NOT truncate (region reclamation: cp
rem appends each fn's output, then resets the heap). Shares the wl loop + wl_emit.
call :hp_car "%~3"
set "wlF=!R:~2!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set "wlL=!R!"
set "wlOp=append-lines"
goto pa_wl_loop
:pa_hmark
set "R=I:!HN!"
goto :eof
:pa_hreset
call :hp_car "%~3"
set "HN=!R:~2!"
set "R=S:t"
goto :eof
:pa_wrlines
call :hp_car "%~3"
set "wlF=!R:~2!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set "wlL=!R!"
break > "!wlF!"
set "wlOp=write-lines"
:pa_wl_loop
if "!wlL!"=="NIL" goto pa_wl_done
call :hp_car "!wlL!"
set "wlLine=!R:~2!"
call :wl_emit "!wlF!"
call :hp_cdr "!wlL!"
set "wlL=!R!"
goto pa_wl_loop
:pa_wl_done
set "R=S:t"
call :lg_mark "!wlOp!"
goto :eof
:wl_emit
rem decode 0x01 -> '!' and append the line. Under disabled expansion a literal '!'
rem is safe; set/p's quoted prompt keeps '&' < > '"' verbatim, and the codegen is
rem quote-free so '"' never appears in generated batch. echo( adds the line break.
rem a blank line leaves wlLine undefined, and %wlLine:..=..% on an undefined var
rem leaks "=!" into wlD -- so guard on the SOURCE (wlLine), not the decoded result:
rem for a blank line just write the line break, so it round-trips as empty.
if defined wlLine goto wl_enc
>>"%~1" echo(
goto :eof
:wl_enc
rem Robust line writer (handles ! % ^ " AND operators & | < >). The decode runs in
rem QUOTED sets (safe for operators -- quotes protect them; the value never holds a
rem real '"' since '"' is the 0x08 sentinel until the end). Operators are CARET-escaped
rem and 0x07->^^ so an UNQUOTED set/p can emit them; 0x01->!, 0x02->%, 0x08->@PQ@ then
rem ->'"' inline at the set/p (an unquoted prompt takes a bare '"', verified). No quoted
rem prompt, so a '"' in the line writes fine.
setlocal enableDelayedExpansion
set "w=!wlLine:&=^&!"
set "w=!w:|=^|!"
set "w=!w:<=^<!"
set "w=!w:>=^>!"
set "w=!w:@B7@=^^!"
set "w=!w:%BANG2%=%%!"
endlocal & set "wcar=%w%"
setlocal disableDelayedExpansion
set "wlD=%wcar:@B1@=!%"
set "wlD=%wlD:@B8@=@PQ@%"
>>"%~1" <nul set /p =%wlD:@PQ@="%
>>"%~1" echo(
endlocal
goto :eof
:pa_fex
call :hp_car "%~3"
set "fexP=!R:~2!"
if exist "!fexP!" (set "R=S:t") else (set "R=NIL")
call :lg_out file-exists?
goto :eof
:pa_strapp
set "saS=" & set "saL=%~3"
:pa_sa_loop
if "!saL!"=="NIL" set "R=T:!saS!" & goto :eof
call :hp_car "!saL!"
set "saV=!R!" & set "saS=!saS!!saV:~2!"
call :hp_cdr "!saL!"
set "saL=!R!"
goto pa_sa_loop
:pa_strlen
call :hp_car "%~3"
set "slS=!R:~2!" & set "slN=0"
rem Empty string must be special-cased: `set "slS="` UNSETS slS, and
rem %slS:~0,1% on an undefined var never yields "", so the scan would loop
rem forever. (sh's ${#x} has no such trap.)
if "!slS!"=="" set "R=I:0" & goto :eof
:pa_sl_loop
call set "slC=%%slS:~!slN!,1%%"
if "!slC!"=="" set "R=I:!slN!" & goto :eof
set /a slN+=1
goto pa_sl_loop
:pa_substr
call :hp_car "%~3"
set "ssS=!R:~2!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set "ssO=!R:~2!"
call :hp_cdr "%~3"
call :hp_cdr "!R!"
call :hp_car "!R!"
set "ssN=!R:~2!"
call set "R=T:%%ssS:~!ssO!,!ssN!%%"
goto :eof
:pa_sym2str
call :hp_car "%~3" & set "R=T:!R:~2!"
goto :eof
:pa_str2sym
call :hp_car "%~3" & set "R=S:!R:~2!"
goto :eof
:pa_num2str
call :hp_car "%~3" & set "R=T:!R:~2!"
goto :eof
:pa_str2num
call :hp_car "%~3" & set "R=I:!R:~2!"
goto :eof
:pa_list
rem list returns its already-evaluated args as-is (applicative). Was a prelude
rem macro; a primitive keeps the prelude empty so boot doesn't parse it.
set "R=%~3"
goto :eof
:pa_mkcompiled
rem (make-compiled "label") -> C:label, a combiner that calls the compiled sub.
call :hp_car "%~3"
set "R=C:!R:~2!"
goto :eof
:pa_cons
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
call :hp_cons "!paA1!" "!R!"
goto :eof
:pa_car
call :hp_car "%~3"
call :hp_car "!R!"
goto :eof
:pa_cdr
call :hp_car "%~3"
call :hp_cdr "!R!"
goto :eof
:pa_dq
rem (dq) -> a '"'-valued string. 0x08 is our '"' sentinel; it decodes to a real
rem '"' at output (write-lines), letting generated code quote an `if` comparison
rem so operator chars (& | < >) in a value don't break the line.
set "R=T:!BANG8!"
goto :eof
:pa_eq
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
if "!paA1!"=="!R!" (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_null
call :hp_car "%~3"
if "!R!"=="NIL" (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_atom
call :hp_car "%~3"
if "!R:~0,2!"=="P:" (set "R=NIL") else (set "R=S:t")
goto :eof
:pa_add
set "paSum=0" & set "paLst=%~3"
:pa_add_loop
if "!paLst!"=="NIL" set "R=I:!paSum!" & goto :eof
call :hp_car "!paLst!"
set "paV=!R!" & set /a paSum=paSum+!paV:~2!
call :hp_cdr "!paLst!"
set "paLst=!R!"
goto pa_add_loop
:pa_mul
set "paProd=1" & set "paLst=%~3"
:pa_mul_loop
if "!paLst!"=="NIL" set "R=I:!paProd!" & goto :eof
call :hp_car "!paLst!"
set "paV=!R!" & set /a paProd=paProd*!paV:~2!
call :hp_cdr "!paLst!"
set "paLst=!R!"
goto pa_mul_loop
:pa_sub
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a paD=!paA1:~2! - !R:~2!
set "R=I:!paD!"
goto :eof
:pa_lt
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a paX1=!paA1:~2!, paX2=!R:~2!
if !paX1! LSS !paX2! (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_numeq
call :hp_car "%~3"
set "paA1=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a paX1=!paA1:~2!, paX2=!R:~2!
if !paX1! EQU !paX2! (set "R=S:t") else (set "R=NIL")
goto :eof
:pa_wrap
call :hp_car "%~3"
call :hp_cons "!R!" "NIL"
set "R=A:!R:P:=!"
goto :eof
:pa_unwrap
call :hp_car "%~3"
set "paA1=!R!"
call :hp_car "P:!paA1:A:=!"
goto :eof
:pa_eval
call :hp_car "%~3"
set "paEx=!R!"
call :hp_cdr "%~3"
call :hp_car "!R!"
set /a ND=%1+1 & call :ev !ND! "!paEx!" "!R!"
goto :eof
:pa_print
call :hp_car "%~3"
set /a ND=%1+1 & call :lisp_write !ND! "!R!"
set "lgPV=!R!"
rem decode 0x02 -> '%' (enabled; '%%' is the replacement), carry out (percent
rem expansion is single-pass so the real '%' survives), then 0x01 -> '!' (disabled,
rem where a literal '!' is safe). set/p then emits; the content has no '"' so its
rem quoted prompt holds, and '& | < > ^ ( )' pass through verbatim.
rem an empty string leaves R undefined; %R:..=..% on an undefined var leaks the
rem literal "=!", so skip the decode and just emit the newline for empty output.
if not defined R goto pr_nl
setlocal enableDelayedExpansion
set "pdec=!R:%BANG2%=%%!"
endlocal & set "pcar=%pdec%"
setlocal disableDelayedExpansion
set "pout=%pcar:@B7@=^%"
set "pout=%pout:@B1@=!%"
<nul set /p "=%pout%"
endlocal
:pr_nl
echo(
set "R=NIL"
call :lg_logv print "!lgPV!"
goto :eof

rem ================================ printer ================================
:lisp_write
set "lwV=%~2"
if "!lwV!"=="NIL" set "R=()" & goto :eof
set "lwPre=!lwV:~0,2!"
if "!lwPre!"=="I:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="S:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="T:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="P:" goto lw_pair
set "R=#<obj>" & goto :eof
:lw_pair
set /a ND=%1+1 & call :render_list !ND! "%~2"
set "R=(!R!)"
goto :eof

:render_list
set "_%1_lst=%~2"
set "_%1_acc="
set "_%1_first=1"
:rl2
call :hp_car "!_%1_lst!"
set /a ND=%1+1 & call :lisp_write !ND! "!R!"
set "_%1_piece=!R!"
if "!_%1_first!"=="1" (set "_%1_acc=!_%1_piece!") else (set "_%1_acc=!_%1_acc! !_%1_piece!")
set "_%1_first=0"
call :hp_cdr "!_%1_lst!"
set "_%1_tl=!R!"
rem proper-list end -> done; another pair -> keep walking; atom tail -> emit " . tail" (dotted).
rem (render_list previously dropped the dotted tail, rendering (a . b) as "(a ())" -- a sh/cmd
rem print divergence; this matches the sh kernel's lisp_write and both JIT renderers.)
if "!_%1_tl!"=="NIL" set "R=!_%1_acc!" & goto :eof
if "!_%1_tl:~0,2!"=="P:" set "_%1_lst=!_%1_tl!" & goto rl2
set /a ND=%1+1 & call :lisp_write !ND! "!_%1_tl!"
set "R=!_%1_acc! . !R!"
goto :eof

rem ================================ bootstrap ================================
:setup_global
call :env_new "NIL"
set "GLOBAL=!R!"
call :env_define "!GLOBAL!" "S:vau" "F:vau"
call :env_define "!GLOBAL!" "S:quote" "F:quote"
call :env_define "!GLOBAL!" "S:lambda" "F:lambda"
call :env_define "!GLOBAL!" "S:list" "R:list"
call :env_define "!GLOBAL!" "S:define" "F:define"
call :env_define "!GLOBAL!" "S:if" "F:if"
call :env_define "!GLOBAL!" "S:gc" "F:gc"
call :env_define "!GLOBAL!" "S:cons" "R:cons"
call :env_define "!GLOBAL!" "S:car" "R:car"
call :env_define "!GLOBAL!" "S:cdr" "R:cdr"
call :env_define "!GLOBAL!" "S:eq?" "R:eq?"
call :env_define "!GLOBAL!" "S:dq" "R:dq"
call :env_define "!GLOBAL!" "S:null?" "R:null?"
call :env_define "!GLOBAL!" "S:atom?" "R:atom?"
call :env_define "!GLOBAL!" "S:+" "R:+"
call :env_define "!GLOBAL!" "S:-" "R:-"
call :env_define "!GLOBAL!" "S:*" "R:*"
call :env_define "!GLOBAL!" "S:<" "R:<"
call :env_define "!GLOBAL!" "S:=" "R:="
call :env_define "!GLOBAL!" "S:wrap" "R:wrap"
call :env_define "!GLOBAL!" "S:unwrap" "R:unwrap"
call :env_define "!GLOBAL!" "S:eval" "R:eval"
call :env_define "!GLOBAL!" "S:print" "R:print"
call :env_define "!GLOBAL!" "S:file-exists?" "R:file-exists?"
call :env_define "!GLOBAL!" "S:string-append" "R:string-append"
call :env_define "!GLOBAL!" "S:string-length" "R:string-length"
call :env_define "!GLOBAL!" "S:substring" "R:substring"
call :env_define "!GLOBAL!" "S:symbol->string" "R:symbol->string"
call :env_define "!GLOBAL!" "S:string->symbol" "R:string->symbol"
call :env_define "!GLOBAL!" "S:number->string" "R:number->string"
call :env_define "!GLOBAL!" "S:string->number" "R:string->number"
call :env_define "!GLOBAL!" "S:read-lines" "R:read-lines"
call :env_define "!GLOBAL!" "S:write-lines" "R:write-lines"
call :env_define "!GLOBAL!" "S:append-lines" "R:append-lines"
call :env_define "!GLOBAL!" "S:hmark" "R:hmark"
call :env_define "!GLOBAL!" "S:hreset" "R:hreset"
call :env_define "!GLOBAL!" "S:read" "R:read"
call :env_define "!GLOBAL!" "S:type-of" "R:type-of"
call :env_define "!GLOBAL!" "S:split" "R:split"
call :env_define "!GLOBAL!" "S:run" "F:run"
call :env_define "!GLOBAL!" "S:run-capture" "F:run-capture"
call :env_define "!GLOBAL!" "S:t" "S:t"
call :env_define "!GLOBAL!" "S:nil" "NIL"
rem --- JIT integration (WIP): CFILE holds the generated subs; make-compiled mints
rem --- a C:<label> binding so a program can install compiled functions.
set "CFILE=compiled.cmd"
call :env_define "!GLOBAL!" "S:make-compiled" "R:make-compiled"
goto :eof
