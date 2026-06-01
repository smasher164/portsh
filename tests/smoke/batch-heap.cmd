@echo off
rem portsh batch heap module — increment 1.
rem cons cells live in a FILE (one cell per line: "car cdr"), because file
rem appends survive setlocal/endlocal where a variable heap would not.
rem The cell index is the line number, derived from the line count — so there's
rem no allocation counter to be reverted by endlocal. Values are space-free
rem tagged tokens (NIL / I:n / S:name / P:idx); strings get an intern table later.
setlocal enabledelayedexpansion
set "HEAP=%TEMP%\portsh_heap.dat"
type nul > "%HEAP%"

rem --- build the list (1 2) = cons(I:1, cons(I:2, NIL)) ---
call :hp_cons I:2 NIL   & set "c0=!R!"
call :hp_cons I:1 !c0!  & set "c1=!R!"
echo c0=!c0! c1=!c1!

call :hp_car !c1!                  & echo car(c1)=!R!
call :hp_cdr !c1!   & set "t=!R!"  & echo cdr(c1)=!t!
call :hp_car !t!                   & echo car(cdr(c1))=!R!
call :hp_cdr !t!                   & echo cdr(cdr(c1))=!R!
exit /b 0

:hp_cons
rem %1=car %2=cdr -> R=P:<idx>
setlocal enabledelayedexpansion
set "a=%~1" & set "d=%~2"
for /f %%c in ('type "%HEAP%" ^| find /c /v ""') do set "idx=%%c"
>> "%HEAP%" echo(!a! !d!
endlocal & set "R=P:%idx%"
goto :eof

:hp_car
rem %1=P:idx -> R=car
setlocal enabledelayedexpansion
set "p=%~1" & set "idx=!p:P:=!"
set /a target=idx+1
set "i=0" & set "out="
for /f "usebackq tokens=1,2 delims= " %%A in ("%HEAP%") do (
  set /a i+=1
  if !i! EQU !target! set "out=%%A"
)
endlocal & set "R=%out%"
goto :eof

:hp_cdr
rem %1=P:idx -> R=cdr
setlocal enabledelayedexpansion
set "p=%~1" & set "idx=!p:P:=!"
set /a target=idx+1
set "i=0" & set "out="
for /f "usebackq tokens=1,2 delims= " %%A in ("%HEAP%") do (
  set /a i+=1
  if !i! EQU !target! set "out=%%B"
)
endlocal & set "R=%out%"
goto :eof
