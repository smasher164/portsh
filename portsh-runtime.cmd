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
rem :replay_take -- two-tier handoff REPLAY (cmd JIT). load-cmd's :replay_init read the log into
rem RP_L0..RP_L<RP_TOT-1> and set RP_CUR=0 / RP_ON=1 (when PORTSH_REPLAY is set). %1 = expected op ->
rem RP_HIT=1 (replaying: RP_N + RP_P0.. are set, cursor advanced) or 0 (live: log exhausted / off).
:replay_take
set "RP_HIT=0"
if not "!RP_ON!"=="1" goto :eof
if !RP_CUR! geq !RP_TOT! (set "RP_ON=0" & goto :eof)
call set "RP_OP=%%RP_L!RP_CUR!%%"
set /a RP_CUR+=1
call set "RP_N=%%RP_L!RP_CUR!%%"
set /a RP_CUR+=1
if not "!RP_OP!"=="%~1" (>&2 echo replay desync: want %~1 got !RP_OP! & exit 1)
set "rpi=0"
:rt_pl
if !rpi! geq !RP_N! (set "RP_HIT=1" & goto :eof)
call set "RP_P!rpi!=%%RP_L!RP_CUR!%%"
set /a RP_CUR+=1 & set /a rpi+=1
goto rt_pl
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
call :replay_take append-lines
if "!RP_HIT!"=="1" (set "R=S:t" & goto :eof)
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
call :replay_take write-lines
if "!RP_HIT!"=="1" (set "R=S:t" & goto :eof)
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
call :replay_take print
if "!RP_HIT!"=="1" goto print_rp
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
rem replay: render the value, VERIFY it equals the logged text (self-validation -- a render/parity
rem divergence is caught here), then SUPPRESS (it was already emitted by :ev).
:print_rp
call :pr_write 0 "!A1!"
if not "!R!"=="!RP_P0!" (>&2 echo replay mismatch print: log[!RP_P0!] jit[!R!] & exit 1)
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
call :replay_take read-lines
if "!RP_HIT!"=="1" goto rdl_rp
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
rem replay: rebuild the logged line-list from RP_P0..RP_P<RP_N-1> (return logged result, no file read).
:rdl_rp
set "rlAcc=NIL" & set "rdi=0"
:rdl_rp_loop
if !rdi! geq !RP_N! goto rdl_rp_rev
call set "rdv=%%RP_P!rdi!%%"
call :rl_cons "T:!rdv!" "!rlAcc!"
set "rlAcc=!R!" & set /a rdi+=1
goto rdl_rp_loop
:rdl_rp_rev
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
call :replay_take file-exists?
if "!RP_HIT!"=="1" (set "R=!RP_P0!" & goto :eof)
set "fexP=!A1:~2!"
if exist "!fexP!" (set "R=S:t") else (set "R=NIL")
goto :eof
rem :run_cmd -- A1 = T:<command> (baked by comp via enc-mc, the SAME sentinel encoding the reader
rem applies to heap tokens). So  cmd /c "!A1:~2!"  is byte-identical to the interpreter's po_run
rem ( cmd /c "!rcCmd!" ): operators are real bytes inside the quotes -> live, sentinels pass through
rem exactly as :ev passes them. R = I:errorlevel.
:run_cmd
call :replay_take run
if "!RP_HIT!"=="1" (set "R=!RP_P0!" & goto :eof)
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
call :replay_take run-capture
if "!RP_HIT!"=="1" goto rc_rp
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
rem replay: rebuild the logged captured-output list (do NOT re-execute the command).
:rc_rp
set "rcAcc=NIL" & set "rci=0"
:rc_rp_loop
if !rci! geq !RP_N! goto rc_rp_rev
call set "rcv=%%RP_P!rci!%%"
call :rl_cons "T:!rcv!" "!rcAcc!"
set "rcAcc=!R!" & set /a rci+=1
goto rc_rp_loop
:rc_rp_rev
call :rl_reverse "!rcAcc!"
goto :eof
rem :read -- A1 = T:<source>. Parse the FIRST datum from the string (mirrors the kernel's pa_read): save
rem reader state, point SRC at A1's content, run the reader in RDMODE (emit_top captures the first datum
rem into RDRESULT and clears SRC to stop), then restore. R = the parsed datum (heap value). The reader
rem below is EMBEDDED here because a `call`ed prim file cannot reach comp.cmd's reader labels; it allocates
rem into the SHARED heap via :rl_cons. *** KEEP IN SYNC with src/kernel.cmd's reader (run_forms / rf_* /
rem read_atom / reduce_list / emit_top / apply_quotes) -- this is a copy; build-time sharing is a TODO. ***
:read
set "_rdSRC=!SRC!" & set "_rdSP=!SP!" & set "_rdDEPTH=!DEPTH!"
set "SRC=!A1:~2!" & set "SP=0" & set "DEPTH=0" & set "RDMODE=1" & set "RDRESULT=NIL"
call :run_forms
set "RDMODE="
set "R=!RDRESULT!"
set "SRC=!_rdSRC!" & set "SP=!_rdSP!" & set "DEPTH=!_rdDEPTH!"
goto :eof
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
set "ST_!SP!=QM" & set /a SP+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_string
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
if "!c0!" geq "0" if "!c0!" leq "9" set "isnum=1"
if "!c0!"=="-" if "!t:~1,1!" geq "0" if "!t:~1,1!" leq "9" set "isnum=1"
if "!isnum!"=="1" (set "R=I:!t!") else (set "R=S:!t!")
goto :eof
:reduce_list
set "acc=NIL"
:rdl_loop
set /a SP-=1
call set "top=%%ST_!SP!%%"
if "!top!"=="LP" set /a DEPTH-=1 & set "R=!acc!" & goto :eof
call :rl_cons "!top!" "!acc!"
set "acc=!R!"
goto rdl_loop
:emit_top
call :apply_quotes
if !DEPTH! GTR 0 goto et_push
set "RDRESULT=!R!" & set "SRC=" & goto :eof
:et_push
set "ST_!SP!=!R!" & set /a SP+=1
goto :eof
:apply_quotes
:aq_loop
if "!SP!"=="0" goto :eof
set /a aqsp=SP-1
call set "aqtop=%%ST_!aqsp!%%"
if not "!aqtop!"=="QM" goto :eof
set "SP=!aqsp!"
call :rl_cons "!R!" "NIL"
call :rl_cons "S:quote" "!R!"
goto aq_loop
