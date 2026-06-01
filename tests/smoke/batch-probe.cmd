@echo off
setlocal enabledelayedexpansion
set "HEAP=%TEMP%\portsh_probe.dat"
type nul > "%HEAP%"

rem (1) recursion with locals + value-return past endlocal (the `endlocal & set` trick)
call :fact 6
echo fact(6)=!R!

rem (2) does a file append from INSIDE a setlocal/endlocal scope survive endlocal?
rem     (a variable-based heap would NOT survive; a file must.)
call :alloc tag-A
call :alloc tag-B
call :alloc tag-C
for /f %%c in ('type "%HEAP%" ^| find /c /v ""') do echo heap_cells=%%c
call :readline 2
echo cell[2]=!R!
exit /b 0

:fact
setlocal
set "n=%~1"
if %n% LSS 2 ( endlocal & set "R=1" & goto :eof )
set /a m=n-1
call :fact %m%
set /a r=n*R
endlocal & set "R=%r%"
goto :eof

:alloc
setlocal
set "v=%~1"
>> "%HEAP%" echo(%v%
endlocal
goto :eof

:readline
setlocal enabledelayedexpansion
set "target=%~1" & set "i=0" & set "out="
for /f "usebackq delims=" %%L in ("%HEAP%") do (
  set /a i+=1
  if !i! EQU %target% set "out=%%L"
)
endlocal & set "R=%out%"
goto :eof
