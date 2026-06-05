rem portsh compiled-program RUNTIME, appended to every compiled.cmd (the heap vars
rem and sentinels come from the host kernel; these are the I/O helpers a compiled
rem program calls). Hand-written + build-baked (@B1@/@B2@/@B7@/@B8@ -> the sentinel
rem bytes 0x01/0x02/0x07/0x08, like the kernel) so it can use literal bytes and ".
rem Kept OUT of comp's source/output so its patterns never collide with program data:
rem write-lines can therefore reproduce this runtime verbatim (the comp(comp) case).
rem
rem :rdfield -- file-backed heap read: %1=car|cdr, %2=index -> R = first line of
rem %HD%\<%1><%2>. set /p reads raw (operators &|<> in the value survive). Redirect
rem path uses %1/%2/%HD% (immediate; parsed before delayed expansion). Used for car/cdr.
:rdfield
set /p R=<%HD%\%1%2
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
set "w=!w:@B7@=^^!"
set "w=!w:@B2@=%%!"
endlocal & set "wcar=%w%"
setlocal disableDelayedExpansion
set "wd=%wcar:@B1@=!%"
>>%~1 <nul set /p =%wd:@B8@="%
>>%~1 echo(
endlocal
goto :eof
