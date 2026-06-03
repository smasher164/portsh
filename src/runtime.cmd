rem portsh compiled-program RUNTIME, appended to every compiled.cmd (the heap vars
rem and sentinels come from the host kernel; these are the I/O helpers a compiled
rem program calls). Hand-written + build-baked (@B1@/@B2@/@B7@/@B8@ -> the sentinel
rem bytes 0x01/0x02/0x07/0x08, like the kernel) so it can use literal bytes and ".
rem Kept OUT of comp's source/output so its patterns never collide with program data:
rem write-lines can therefore reproduce this runtime verbatim (the comp(comp) case).
rem
rem :rdfield -- operator-safe heap read: set R = !<prefix><idx>! (delayed expansion,
rem so a & | < > in the value lands as data, not a separator). Used for car/cdr.
:rdfield
set R=!%1%2!
goto :eof
rem :write-lines -- A1=path (T:..), A2=list. Truncate, then per line decode+append.
:write-lines
set wlf=!A1:~2!
set wll=!A2!
break > !wlf!
:wl_loop_c
if !wll!==NIL (set R=S:t & goto :eof)
set wli=!wll:~2!
call :rdfield CAR_ !wli!
set wlline=!R:~2!
call :wl_emit_c !wlf!
call :rdfield CDR_ !wli!
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
