rem portsh compiled-program RUNTIME, appended to every compiled.cmd (the heap vars
rem and sentinels come from the host kernel; these are the I/O helpers a compiled
rem program calls). Hand-written + build-baked (/// -> the sentinel
rem bytes 0x01/0x02/0x07/0x08, like the kernel) so it can use literal bytes and ".
rem Kept OUT of comp's source/output so its patterns never collide with program data:
rem write-lines can therefore reproduce this runtime verbatim (the comp(comp) case).
rem
rem :rdfield -- file-backed heap read: %1=car|cdr, %2=index -> R = first line of
rem %HD%\<%1><%2>. set /p reads raw (operators &|<> in the value survive). Redirect
rem path uses %1/%2/%HD% (immediate; parsed before delayed expansion). Used for car/cdr.
rem Cells are written with a trailing GUARD byte (#) because set /p STRIPS trailing
rem control bytes (0x01=! 0x08=") -- the guard takes that hit, then we drop it here so
rem values ending in !/" survive intact. Writers must append the same guard.
:rdfield
set /p R=<%HD%\%1%2
set "R=!R:~0,-1!"
goto :eof
rem :gc -- compiled-program GC. For now a no-op: returns without collecting, which is
rem CORRECT (gc only reclaims, never changes values) and fine for small inputs. A real
rem collector for compiled programs is TODO -- the interpreter's gc roots from the env
rem chain, which compiled code lacks; a compiled-runtime gc would root from the STK
rem save-stack + the current frame's live vars instead.
:gc
set R=NIL
goto :eof
rem :append-lines -- A1=path, A2=list. Like write-lines but does NOT truncate
rem (incremental output: comp's cp appends each fn's lines as it compiles them).
:append-lines
set wlf=!A1:~2!
set "wlf=!wlf:/=\!"
set wll=!A2!
:al_loop_c
if !wll!==NIL (set R=S:t & goto :eof)
set wli=!wll:~2!
call :rdfield car !wli!
set wlline=!R:~2!
call :wl_emit_c !wlf!
call :rdfield cdr !wli!
set wll=!R!
goto al_loop_c
rem :write-lines -- A1=path (T:..), A2=list. Truncate, then per line decode+append.
:write-lines
set wlf=!A1:~2!
rem cmd redirection needs backslashes; the codegen builds paths with '/' (sh-native),
rem so normalise here. The line write (wl_emit_c) gets the already-normalised wlf.
set "wlf=!wlf:/=\!"
set wll=!A2!
break > !wlf!
:wl_loop_c
if !wll!==NIL (set R=S:t & goto :eof)
set wli=!wll:~2!
call :rdfield car !wli!
set wlline=!R:~2!
call :wl_emit_c !wlf!
call :rdfield cdr !wli!
set wll=!R!
goto wl_loop_c
rem :wl_emit_c -- write one line (in wlline) to the file (%1). A line can hold
rem ! % ^ " and operators & | < >. Decode in QUOTED sets (safe for operators --
rem quotes protect them; the value holds no real " yet, only the 0x08 sentinel),
rem caret-escaping operators and 0x07->^^ so an UNQUOTED set/p can emit them; then
rem 0x01->!, 0x02->%, and 0x08->" inline at the set/p (an unquoted prompt takes a
rem bare ", verified). No quoted prompt => a " in the line writes fine.
:wl_emit_c
if defined wlline goto wl_enc_c
>>%~1 echo(
goto :eof
:wl_enc_c
setlocal enableDelayedExpansion
set "w=!wlline:&=^&!"
set "w=!w:|=^|!"
set "w=!w:<=^<!"
set "w=!w:>=^>!"
set "w=!w:=^^!"
set "w=!w:=%%!"
endlocal & set "wcar=%w%"
setlocal disableDelayedExpansion
set "wd=%wcar:=!%"
>>%~1 <nul set /p =%wd:="%
>>%~1 echo(
endlocal
goto :eof
rem :print -- A1 = a tagged value. Render it (byte-identical to the interpreter's print /
rem the sh JIT's _relem) into R, then decode sentinels and emit to STDOUT + newline; R=NIL.
rem :pr_write/:pr_list mirror the kernel's lisp_write/render_list but (a) read car/cdr via
rem :rdfield (file heap) instead of hp_car/hp_cdr, and (b) render DOTTED pairs ((a . b)) and
rem closures (<closure>/<fn:..>) like the sh side -- the kernel's render_list omits dotted-tail
rem handling (a latent sh/cmd print divergence); this is the corrected canonical renderer. The
rem emit mirrors pa_print exactly: ->'%' (delayed), then ->'^' and ->'!' (disabled),
rem a QUOTED set/p (operators & | < > ^ ( ) pass verbatim), then a newline.
:print
call :pr_write 0 "!A1!"
if not defined R goto pr_nl
setlocal enableDelayedExpansion
set "pdec=!R:=%%!"
endlocal & set "pcar=%pdec%"
setlocal disableDelayedExpansion
set "pout=%pcar:=^%"
set "pout=%pout:=!%"
<nul set /p "=%pout%"
endlocal
:pr_nl
echo(
set "R=NIL"
goto :eof
:pr_write
set "lwV=%~2"
if "!lwV!"=="NIL" set "R=()" & goto :eof
set "lwPre=!lwV:~0,2!"
if "!lwPre!"=="I:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="S:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="T:" set "R=!lwV:~2!" & goto :eof
if "!lwPre!"=="K:" set "R=<closure>" & goto :eof
if "!lwPre!"=="C:" set "R=<fn:!lwV:~2!>" & goto :eof
if "!lwPre!"=="P:" goto pr_pair
set "R=#<obj>" & goto :eof
:pr_pair
set /a PRND=%1+1 & call :pr_list !PRND! "%~2"
set "R=(!R!)"
goto :eof
:pr_list
set "_pw%1_lst=%~2"
set "_pw%1_acc="
set "_pw%1_first=1"
:prl2
set "_pw%1_i=!_pw%1_lst:~2!"
call :rdfield car !_pw%1_i!
set /a PRND=%1+1 & call :pr_write !PRND! "!R!"
if "!_pw%1_first!"=="1" (set "_pw%1_acc=!R!") else (set "_pw%1_acc=!_pw%1_acc! !R!")
set "_pw%1_first=0"
call :rdfield cdr !_pw%1_i!
set "_pw%1_tl=!R!"
if "!_pw%1_tl!"=="NIL" set "R=!_pw%1_acc!" & goto :eof
if "!_pw%1_tl:~0,2!"=="P:" set "_pw%1_lst=!_pw%1_tl!" & goto prl2
set /a PRND=%1+1 & call :pr_write !PRND! "!_pw%1_tl!"
set "R=!_pw%1_acc! . !R!"
goto :eof
rem :read-lines -- A1 = path (T:..). Read each line -> a list of T: cells, in file order.
rem Mirrors the kernel's read-lines (pa_rdlines): `type file | find /v /n ""` prefixes every
rem line with "[N]" (so blank/';'-leading lines survive for/f), strip it with !rlLn:*]=!, cons
rem each onto an accumulator, then reverse. Cells are allocated like the codegen's cons (bump
rem HN, write car/cdr at %HN% with the trailing guard byte '#'). KNOWN GAP (identical to :ev):
rem for/f eats a literal '!' in file content (delayed expansion) -- a separately-tracked sh/cmd
rem read-lines divergence, not introduced here.
:read-lines
set "rlF=!A1:~2!"
set "rlF=!rlF:/=\!"
set "rlAcc=NIL"
type "!rlF!" | find /v /n "" > "%TEMP%\portsh_rl.txt"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rl.txt") do (
  set "rlLn=%%L" & set "rlLn=!rlLn:*]=!"
  call :rl_cons "T:!rlLn!" "!rlAcc!"
  set "rlAcc=!R!"
)
call :rl_reverse "!rlAcc!"
goto :eof
:rl_cons
set "hca=%~1" & set "hcd=%~2"
set /a HN+=1
>%HD%\car%HN% echo(!hca!#
>%HD%\cdr%HN% echo(!hcd!#
set "R=P:%HN%"
goto :eof
:rl_reverse
set "lrL=%~1" & set "lrAcc=NIL"
:rl_lr
if "!lrL!"=="NIL" set "R=!lrAcc!" & goto :eof
set "lr_i=!lrL:~2!"
call :rdfield car !lr_i!
set "lr_hd=!R!"
call :rdfield cdr !lr_i!
set "lrL=!R!"
call :rl_cons "!lr_hd!" "!lrAcc!"
set "lrAcc=!R!"
goto rl_lr
rem :file-existszzQ -- A1 = path (T:..). R = S:t if it exists, else NIL. Matches pa_fex (no
rem slash normalisation -- consistent with the interpreter; write-lines normalises, fex does not).
:file-existszzQ
set "fexP=!A1:~2!"
if exist "!fexP!" (set "R=S:t") else (set "R=NIL")
goto :eof
rem :run_cmd -- A1 = T:<command> (baked by comp via enc-mc, the SAME sentinel encoding the reader
rem applies to heap tokens). So  cmd /c "!A1:~2!"  is byte-identical to the interpreter's po_run
rem ( cmd /c "!rcCmd!" ): operators are real bytes inside the quotes -> live, sentinels pass through
rem exactly as :ev passes them. R = I:errorlevel.
:run_cmd
call :rc_unesc
cmd /c "!RCMD!"
set "R=I:!errorlevel!"
goto :eof
rem :rc_unesc -- A1 = T:<command>. comp bakes the command via enc-mc, but at comp.cmd RUNTIME the
rem operator bytes survive as RAW & | < > (a comp.cmd self-host quirk -- enc-mc encodes operators in
rem build-time string literals but not in a runtime-built command), so write-lines CARET-escapes them
rem (^& ^| ^< ^>) when emitting the set "A1=..." line. Undo that here so cmd /c sees LIVE operators,
rem matching the interpreter's cmd /c "!rcCmd!" (which has raw operator bytes). -> RCMD.
:rc_unesc
set "RCMD=!A1:~2!"
set "RCMD=!RCMD:^&=&!"
set "RCMD=!RCMD:^|=|!"
set "RCMD=!RCMD:^<=<!"
set "RCMD=!RCMD:^>=>!"
goto :eof
rem :run_capture -- like :run_cmd but capture stdout+stderr as a line-list (mirrors po_runcap exactly:
rem redirect-FIRST with 2>&1 so no trailing token absorbs into the command line; then prefix every line
rem with "[N]" via find /v /n "" (keeps blank/';' lines), iterate, strip the prefix, cons, reverse).
rem Cells allocated via :rl_cons / reversed via :rl_reverse (shared with :read-lines). KNOWN GAP (same
rem as :ev/read-lines): for/f eats a literal '!' in captured output.
:run_capture
call :rc_unesc
> "%TEMP%\portsh_rc1.txt" 2>&1 cmd /c "!RCMD!"
type "%TEMP%\portsh_rc1.txt" | find /v /n "" > "%TEMP%\portsh_rc.txt"
set "rcAcc=NIL"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rc.txt") do (
  set "rcLn=%%L" & set "rcLn=!rcLn:*]=!"
  call :rl_cons "T:!rcLn!" "!rcAcc!"
  set "rcAcc=!R!"
)
call :rl_reverse "!rcAcc!"
goto :eof
