@echo off
rem Does a value containing cmd metachars (< > & |) survive echo->file->read?
rem Hypothesis: yes, because delayed-expanded (!a!) content is NOT re-scanned
rem for redirection/operators. If so, we can keep standard < > operators.
setlocal enabledelayedexpansion
set "HEAP=%TEMP%\portsh_meta.dat"
type nul > "%HEAP%"

call :hp_cons "S:<" "S:>"  & set "c0=!R!"
call :hp_cons "S:&" "S:|"  & set "c1=!R!"
call :hp_car "!c0!" & set "a0=!R!"
call :hp_cdr "!c0!" & set "d0=!R!"
call :hp_car "!c1!" & set "a1=!R!"
call :hp_cdr "!c1!" & set "d1=!R!"
<nul set /p "=cell0: car=!a0! cdr=!d0!" & echo(
<nul set /p "=cell1: car=!a1! cdr=!d1!" & echo(
exit /b 0

:hp_cons
setlocal enabledelayedexpansion
set "a=%~1" & set "d=%~2"
for /f %%c in ('type "%HEAP%" ^| find /c /v ""') do set "idx=%%c"
>> "%HEAP%" echo(!a! !d!
endlocal & set "R=P:%idx%"
goto :eof

:hp_car
setlocal enabledelayedexpansion
set "p=%~1" & set "idx=!p:P:=!" & set /a target=idx+1 & set "i=0" & set "out="
for /f "usebackq tokens=1,2 delims= " %%A in ("%HEAP%") do (set /a i+=1 & if !i! EQU !target! set "out=%%A")
endlocal & set "R=%out%"
goto :eof

:hp_cdr
setlocal enabledelayedexpansion
set "p=%~1" & set "idx=!p:P:=!" & set /a target=idx+1 & set "i=0" & set "out="
for /f "usebackq tokens=1,2 delims= " %%A in ("%HEAP%") do (set /a i+=1 & if !i! EQU !target! set "out=%%B")
endlocal & set "R=%out%"
goto :eof
