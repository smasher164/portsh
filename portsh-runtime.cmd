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
call :wl_emit_c "!wlf!"
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
rem QUOTED path everywhere below: an unquoted spacey path split at the redirect/call (the kernel's
rem wl_emit always quoted; this compiled-path copy didn't -- latent until spacey filenames).
break > "!wlf!"
:wl_loop_c
if !wll!==NIL (set R=S:t & goto :eof)
set wli=!wll:~2!
call :rdfield car !wli!
set wlline=!R:~2!
call :wl_emit_c "!wlf!"
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
>>"%~1" echo(
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
>>"%~1" <nul set /p =%wd:="%
>>"%~1" echo(
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
type "!rlF!" | find /v /n "" > "%TEMP%\portsh_rl_!HD!.txt"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rl_!HD!.txt") do (
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
set "fexP=!fexP:/=\!"
if exist "!fexP!" (set "R=S:t") else (set "R=NIL")
goto :eof
rem :split -- A1 = T:string, A2 = T:separator. R = list of T: pieces (mirrors the kernel/interp split).
rem Char-scan (handles multi-char separators); empty separator -> single-element list. Cells via :rl_cons.
:split
set "spS=!A1:~2!"
set "spSep=!A2:~2!"
if not defined spSep (call :rl_cons "T:!spS!" "NIL" & goto :eof)
set "spAcc=NIL"
set "spH="
set "spR=!spS!"
:sp_scan
if not defined spR goto sp_last
set "spT=!spR!"
set "spP=!spSep!"
:sp_cmp
if not defined spP goto sp_hit
if not defined spT goto sp_adv
if not "!spT:~0,1!"=="!spP:~0,1!" goto sp_adv
set "spT=!spT:~1!"
set "spP=!spP:~1!"
goto sp_cmp
:sp_hit
call :rl_cons "T:!spH!" "!spAcc!"
set "spAcc=!R!"
set "spH="
set "spR=!spT!"
goto sp_scan
:sp_adv
set "spH=!spH!!spR:~0,1!"
set "spR=!spR:~1!"
goto sp_scan
:sp_last
call :rl_cons "T:!spH!" "!spAcc!"
set "spAcc=!R!"
call :rl_reverse "!spAcc!"
goto :eof
rem :type-of -- A1 = a tagged value. R = its type symbol (mirrors the kernel/interp type-of). Pure (no
rem The comp emits this as a builtin call (call type-of.cmd) for (type-of x).
:type-of
if "!A1!"=="NIL" (set "R=S:nil" & goto :eof)
set "toT=!A1:~0,2!"
if "!toT!"=="I:" (set "R=S:number" & goto :eof)
if "!toT!"=="S:" (set "R=S:symbol" & goto :eof)
if "!toT!"=="T:" (set "R=S:string" & goto :eof)
if "!toT!"=="P:" (set "R=S:pair" & goto :eof)
set "R=S:unknown"
goto :eof
rem :exit -- A1 = I:code. Bare `exit` (no /b) terminates the whole cmd.exe instance -- exactly the
rem semantics we want: the front-end's `cmd /c` child dies with this code and the front-end
rem propagates it as the script's exit code.
:exit
exit !A1:~2!
rem :setenv -- A1 = T:name, A2 = T:value. ""-value UNSETS (cmd cannot store an empty env var; the
rem sh side mirrors this). Name restricted to A-Za-z0-9_ (mirror getenv). R = S:t, or NIL on a bad
rem name. PATH is special-cased: the engine resolves its compiled prims THROUGH PATH at runtime, so
rem after a user PATH set we re-prepend the program cache (PORTSH_OSRDIR) and the tooling runtime
rem dir (PORTSH_RTDIR, set at boot) -- run children already saw those dirs before, so inheritance
rem semantics are unchanged.
:setenv
set "seN=!A1:~2!"
if not defined seN (set "R=NIL" & goto :eof)
set "seT=!seN!"
:se_chk
if not defined seT goto se_ok
set "seC=!seT:~0,1!"
set "seT=!seT:~1!"
if "!seC!" GEQ "a" if "!seC!" LEQ "z" goto se_chk
if "!seC!" GEQ "A" if "!seC!" LEQ "Z" goto se_chk
if "!seC!" GEQ "0" if "!seC!" LEQ "9" goto se_chk
if "!seC!"=="_" goto se_chk
set "R=NIL"
goto :eof
:se_ok
set "seV=!A2:~2!"
if defined seV (set "!seN!=!seV!") else (set "!seN!=")
if /i "!seN!"=="PATH" (
  if defined PORTSH_RTDIR set "PATH=!PORTSH_RTDIR!;!PATH!"
  if defined PORTSH_OSRDIR set "PATH=!PORTSH_OSRDIR!;!PATH!"
)
set "R=S:t"
goto :eof
rem :make-dir -- A1 = T:path ('/' normalised). mkdir -p semantics: parents created (cmd extensions
rem do this), already-exists is success. :delete-file -- rm -f semantics: missing -> t (the desired
rem state); still-exists after del -> NIL. :copy-file -- overwrite; R by result.
:make-dir
set "mdP=!A1:~2!"
set "mdP=!mdP:/=\!"
if exist "!mdP!\" (set "R=S:t" & goto :eof)
mkdir "!mdP!" 2>nul
if exist "!mdP!\" (set "R=S:t") else (set "R=NIL")
goto :eof
:delete-file
set "dfP=!A1:~2!"
set "dfP=!dfP:/=\!"
if not exist "!dfP!" (set "R=S:t" & goto :eof)
del /f /q "!dfP!" 2>nul
if exist "!dfP!" (set "R=NIL") else (set "R=S:t")
goto :eof
:copy-file
set "cfS=!A1:~2!"
set "cfS=!cfS:/=\!"
set "cfD=!A2:~2!"
set "cfD=!cfD:/=\!"
copy /y "!cfS!" "!cfD!" >nul 2>nul
if exist "!cfD!" (set "R=S:t") else (set "R=NIL")
goto :eof
rem :argv -- R = list of the user arguments (T: strings), built per call from PORTSH_ARGV_<n> /
rem PORTSH_ARGC (set by the front-end or the engine's own arg capture). REPL/no-args -> NIL.
rem Values with ! are best-effort on cmd (delayed expansion); see docs/limitations.md.
:argv
set "avL=NIL"
if not defined PORTSH_ARGC (set "R=NIL" & goto :eof)
set /a avI=PORTSH_ARGC
:av_loop
if !avI! LEQ 0 (set "R=!avL!" & goto :eof)
set /a avI-=1
call set "avV=%%PORTSH_ARGV_!avI!%%"
call :rl_cons "T:!avV!" "!avL!"
set "avL=!R!"
goto av_loop
rem :argv0 -- R = T:<program path> (the file the user invoked: a packed app = the app itself). Set
rem by the front-end / engine arg capture into PORTSH_ARGV0, forward slashes. REPL/unset -> NIL.
:argv0
if not defined PORTSH_ARGV0 (set "R=NIL" & goto :eof)
set "R=T:!PORTSH_ARGV0!"
goto :eof
rem :getenv -- A1 = T:name. R = T:value, or NIL when unset (cmd cannot store an empty env var, so
rem empty == unset == nil -- the sh side matches). Name must be A-Za-z0-9_ (mirror sh). The value is
rem read from `set <name>` output so & | < > survive; ! is best-effort (delayed expansion).
:getenv
set "gnN=!A1:~2!"
if not defined gnN (set "R=NIL" & goto :eof)
set "gnT=!gnN!"
:gn_chk
if not defined gnT goto gn_ok
set "gnC=!gnT:~0,1!"
set "gnT=!gnT:~1!"
if "!gnC!" GEQ "a" if "!gnC!" LEQ "z" goto gn_chk
if "!gnC!" GEQ "A" if "!gnC!" LEQ "Z" goto gn_chk
if "!gnC!" GEQ "0" if "!gnC!" LEQ "9" goto gn_chk
if "!gnC!"=="_" goto gn_chk
set "R=NIL"
goto :eof
:gn_ok
if not defined !gnN! (set "R=NIL" & goto :eof)
set "R=NIL"
for /f "tokens=1* delims==" %%a in ('set !gnN! 2^>nul') do if /i "%%a"=="!gnN!" set "R=T:%%b"
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
rem :run-argv -- A1 = a LIST of tokens (T:/I:/S:). Each element becomes EXACTLY ONE child argument
rem (double-quoted; a portsh string cannot contain a quote, so no escaping is needed) -- the
rem execv-style counterpart of :run_cmd's joined literal string: spaces in tokens survive.
rem ! and % remain best-effort on cmd (delayed expansion); see docs/limitations.md.
:run-argv
call :rav_build
cmd /c "!RAC!"
set "R=I:!errorlevel!"
goto :eof
:rav_build
set "RAC="
set "ravFIRST=1"
set "ravL=!A1!"
:rav_loop
if "!ravL!"=="NIL" goto :eof
set "rav_i=!ravL:~2!"
call :rdfield car !rav_i!
set "ravT=!R:~2!"
if not "!ravFIRST!"=="1" goto rav_arg
set "ravFIRST=0"
rem the COMMAND token: cmd's INTERNAL commands (mkdir/rmdir/echo/...) are not recognized when
rem quoted -- quote it only when it needs quoting (contains a space; an internal command never
rem does). Arguments are always quoted (quoted args to internal commands are fine).
if not "!ravT: =!"=="!ravT!" goto rav_arg
set "RAC=!ravT!"
goto rav_next
:rav_arg
set "RAC=!RAC! "!ravT!""
:rav_next
call :rdfield cdr !rav_i!
set "ravL=!R!"
goto rav_loop
rem :run-capture-argv -- :run-argv's capture twin (tail mirrors :run_capture).
:run-capture-argv
call :rav_build
> "%TEMP%\portsh_rc1_!HD!.txt" 2>&1 cmd /c "!RAC!"
type "%TEMP%\portsh_rc1_!HD!.txt" | find /v /n "" > "%TEMP%\portsh_rc_!HD!.txt"
set "rcAcc=NIL"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rc_!HD!.txt") do (
  set "rcLn=%%L" & set "rcLn=!rcLn:*]=!"
  call :rl_cons "T:!rcLn!" "!rcAcc!"
  set "rcAcc=!R!"
)
call :rl_reverse "!rcAcc!"
goto :eof
rem :run_capture -- like :run_cmd but capture stdout+stderr as a line-list (mirrors po_runcap exactly:
rem redirect-FIRST with 2>&1 so no trailing token absorbs into the command line; then prefix every line
rem with "[N]" via find /v /n "" (keeps blank/';' lines), iterate, strip the prefix, cons, reverse).
rem Cells allocated via :rl_cons / reversed via :rl_reverse (shared with :read-lines). KNOWN GAP (same
rem as :ev/read-lines): for/f eats a literal '!' in captured output.
:run_capture
call :rc_unesc
> "%TEMP%\portsh_rc1_!HD!.txt" 2>&1 cmd /c "!RCMD!"
type "%TEMP%\portsh_rc1_!HD!.txt" | find /v /n "" > "%TEMP%\portsh_rc_!HD!.txt"
set "rcAcc=NIL"
for /f "usebackq delims=" %%L in ("%TEMP%\portsh_rc_!HD!.txt") do (
  set "rcLn=%%L" & set "rcLn=!rcLn:*]=!"
  call :rl_cons "T:!rcLn!" "!rcAcc!"
  set "rcAcc=!R!"
)
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
