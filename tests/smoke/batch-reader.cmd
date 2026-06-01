@echo off
rem portsh batch reader — increment 2.
rem Iterative stack parser (NOT recursive: it mutates SRC + allocates, which
rem setlocal/endlocal would revert). Printer BUILDS a string and returns it,
rem because (a) `set /p` strips leading spaces so piecewise space-printing
rem fails, and (b) values contain parens, so we use goto-dispatch instead of
rem parenthesized if-blocks (a ')' in a value would close the block).
rem NOTE: batch files must be CRLF or call/goto label lookup flakes.
setlocal enabledelayedexpansion
set "HEAP=%TEMP%\portsh_heap.dat"

call :read_one "(+ 1 (* 2 3))"
call :read_one "(a (b c) d)"
call :read_one "foo"
exit /b 0

:read_one
type nul > "%HEAP%"
set "SRC=%~1" & set "SP=0" & set "DEPTH=0"
<nul set /p "=in : %~1"& echo(
<nul set /p "=out: "
:rt_loop
call :skipws
if "!SRC!"=="" echo(& goto :eof
set "ch=!SRC:~0,1!"
if "!ch!"=="(" goto :rt_open
if "!ch!"==")" goto :rt_close
goto :rt_atom
:rt_open
set "ST_!SP!=LP" & set /a SP+=1 & set /a DEPTH+=1 & set "SRC=!SRC:~1!"
goto :rt_loop
:rt_close
set "SRC=!SRC:~1!"
call :reduce_list
call :emit_or_push "!R!"
goto :rt_loop
:rt_atom
call :read_atom
call :emit_or_push "!R!"
goto :rt_loop

:skipws
if "!SRC!"=="" goto :eof
if "!SRC:~0,1!"==" " set "SRC=!SRC:~1!" & goto :skipws
goto :eof

:read_atom
set "tok="
:ra_loop
if "!SRC!"=="" goto :ra_done
set "ch=!SRC:~0,1!"
if "!ch!"==" " goto :ra_done
if "!ch!"=="(" goto :ra_done
if "!ch!"==")" goto :ra_done
set "tok=!tok!!ch!" & set "SRC=!SRC:~1!"
goto :ra_loop
:ra_done
set "t=!tok!"
if "!t!"=="" set "R=S:" & goto :eof
if "!t!"=="-" set "R=S:-" & goto :eof
set "scan=!t!"
for %%d in (0 1 2 3 4 5 6 7 8 9) do set "scan=!scan:%%d=!"
set "scan=!scan:-=!"
if "!scan!"=="" (set "R=I:!t!") else (set "R=S:!t!")
goto :eof

:reduce_list
set "acc=NIL"
:rl_loop
set /a SP-=1
call set "top=%%ST_!SP!%%"
if "!top!"=="LP" set /a DEPTH-=1 & set "R=!acc!" & goto :eof
call :hp_cons "!top!" "!acc!"
set "acc=!R!"
goto :rl_loop

:emit_or_push
set "val=%~1"
if !DEPTH! GTR 0 goto eop_push
call :lisp_write "!val!"
<nul set /p "=!R!"
goto :eof
:eop_push
set "ST_!SP!=!val!" & set /a SP+=1
goto :eof

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

:lisp_write
setlocal enabledelayedexpansion
set "v=%~1" & set "pre=!v:~0,2!"
if "!v!"=="NIL" goto lw_nil
if "!pre!"=="I:" goto lw_strip
if "!pre!"=="S:" goto lw_strip
if "!pre!"=="P:" goto lw_pair
set "res=?" & goto lw_done
:lw_nil
set "res=()" & goto lw_done
:lw_strip
set "res=!v:~2!" & goto lw_done
:lw_pair
call :render_list "!v!"
set "res=(!R!)"
:lw_done
endlocal & set "R=%res%"
goto :eof

:render_list
setlocal enabledelayedexpansion
set "lst=%~1" & set "acc=" & set "first=1"
:rl2
if "!lst!"=="NIL" goto rl2_done
call :hp_car "!lst!"
set "cv=!R!"
call :lisp_write "!cv!"
set "piece=!R!"
if "!first!"=="1" goto rl2_first
set "acc=!acc! !piece!" & goto rl2_next
:rl2_first
set "acc=!piece!"
:rl2_next
set "first=0"
call :hp_cdr "!lst!"
set "lst=!R!"
goto rl2
:rl2_done
endlocal & set "R=%acc%"
goto :eof
