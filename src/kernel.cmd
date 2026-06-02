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
set "HN=0" & set "FID=0"
call :setup_global

rem Boot order: minimal prelude -> embedded Lisp after the marker (stdlib and/or
rem program) -> file-arg program. MK is built from fragments so the literal
rem never appears here (the self-scan would match the kernel, not the baked-in
rem final-line marker).
set "SRC="
set "SRC=!SRC! (define quote (vau (x) #ignore x))"
set "SRC=!SRC! (define list (wrap (vau args #ignore args)))"
set "SRC=!SRC! (define lambda (vau p env (wrap (eval (cons (quote vau) (cons (car p) (cons (quote #ignore) (cdr p)))) env))))"
set "MK=__PORTSH"
set "MK=!MK!_PAYLOAD__"
findstr /c:"!MK!" "%~f0" >nul 2>&1 || goto after_payload
for /f "delims=:" %%n in ('findstr /n /c:"!MK!" "%~f0"') do set "MLINE=%%n" & goto load_payload
:load_payload
for /f "usebackq skip=%MLINE% delims=" %%L in ("%~f0") do (set "ln=%%L" & call :addsrc)
:after_payload
if "%~1"=="" goto run_it
for /f "usebackq delims=" %%L in ("%~1") do (set "ln=%%L" & call :addsrc)
:run_it
set "SP=0" & set "DEPTH=0"
call :run_forms
exit /b 0

rem ============================ reader (iterative) ============================
:run_forms
:rf_loop
call :skipws
if "!SRC!"=="" goto :eof
set "ch=!SRC:~0,1!"
if "!ch!"=="(" goto rf_open
if "!ch!"==")" goto rf_close
if "!ch!"=="'" goto rf_quote
set "chq=!ch:"=!"
if "!chq!"=="" goto rf_string
goto rf_atom
:rf_quote
rem 'x -> (quote x): push a quote-marker; apply_quotes wraps the next datum
set "ST_!SP!=QM" & set /a SP+=1 & set "SRC=!SRC:~1!"
goto rf_loop
:rf_string
rem string literal "..." -> T:...  (quote detected by removing " and testing empty)
set "SRC=!SRC:~1!"
set "rfs="
:rfs_loop
if "!SRC!"=="" goto rfs_done
set "sc=!SRC:~0,1!"
set "scq=!sc:"=!"
if "!scq!"=="" set "SRC=!SRC:~1!" & goto rfs_done
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
for %%d in (0 1 2 3 4 5 6 7 8 9) do if "!c0!"=="%%d" set "isnum=1"
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
rem append a source line to SRC, stripping a ';' line comment. for/f delims=;
rem keeps the code before the first ';' and preserves string literals; only a
rem ';' INSIDE a string is mishandled (rare).
for /f "tokens=1 delims=;" %%C in ("!ln!") do set "SRC=!SRC! %%C"
goto :eof

rem ===================== heap (variables: CAR_i / CDR_i) =====================
:hp_cons
set "CAR_%HN%=%~1"
set "CDR_%HN%=%~2"
set "R=P:%HN%"
set /a HN+=1
goto :eof
:hp_car
set "hcp=%~1" & set "hcp=!hcp:P:=!"
set "R=!CAR_%hcp%!"
goto :eof
:hp_cdr
set "hdp=%~1" & set "hdp=!hdp:P:=!"
set "R=!CDR_%hdp%!"
goto :eof
:hp_setcar
set "scp=%~1" & set "scp=!scp:P:=!"
set "CAR_%scp%=%~2"
goto :eof
:hp_setcdr
set "sdp=%~1" & set "sdp=!sdp:P:=!"
set "CDR_%sdp%=%~2"
goto :eof

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
set "elkB=!CAR_%ei%!"
set "elkPrev="
:elk_b
if "!elkB!"=="NIL" goto elk_next
set "bi=!elkB:P:=!"
set "elkP=!CAR_%bi%!"
set "pi=!elkP:P:=!"
if "!CAR_%pi%!"=="!elkSym!" goto elk_found
set "elkPrev=!elkB!"
set "elkB=!CDR_%bi%!"
goto elk_b
:elk_next
set "elkEnv=!CDR_%ei%!"
goto elk_env
:elk_found
if "!elkPrev!"=="" goto elk_val
set "elkNext=!CDR_%bi%!"
call :hp_setcdr "!elkPrev!" "!elkNext!"
set "elkHead=!CAR_%ei%!"
call :hp_setcdr "!elkB!" "!elkHead!"
call :hp_setcar "!elkEnv!" "!elkB!"
:elk_val
set "R=!CDR_%pi%!"
goto :eof
:elk_unbound
set "elkU=!elkSym:S:=!"
1>&2 echo portsh: unbound symbol: !elkU!
set "R=NIL"
goto :eof

rem =============================== evaluator ===============================
:ev
set "evX=%~2"
if "!evX!"=="NIL" set "R=NIL" & goto :eof
set "evPre=!evX:~0,2!"
if "!evPre!"=="I:" set "R=!evX!" & goto :eof
if "!evPre!"=="F:" set "R=!evX!" & goto :eof
if "!evPre!"=="R:" set "R=!evX!" & goto :eof
if "!evPre!"=="O:" set "R=!evX!" & goto :eof
if "!evPre!"=="A:" set "R=!evX!" & goto :eof
if "!evPre!"=="S:" call :env_lookup "%~3" "!evX!" & goto :eof
if "!evPre!"=="P:" goto ev_comb
set "R=!evX!" & goto :eof
:ev_comb
set "eci=%~2" & set "eci=!eci:P:=!"
set /a ND=%1+1 & call :ev !ND! "!CAR_%eci%!" "%~3"
set "_%1_c=!R!"
set "eci=%~2" & set "eci=!eci:P:=!"
set /a ND=%1+1 & call :combine !ND! "!_%1_c!" "!CDR_%eci%!" "%~3"
goto :eof

:combine
set "cmbC=%~2" & set "cmbPre=!cmbC:~0,2!"
if "!cmbPre!"=="F:" goto cmb_oper
if "!cmbPre!"=="R:" goto cmb_app
if "!cmbPre!"=="A:" goto cmb_appl
if "!cmbPre!"=="O:" goto cmb_compound
set "R=NIL" & goto :eof
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
set /a ND=%1+1 & call :ev !ND! "!CAR_%eli%!" "%~3"
set "_%1_e=!R!"
set "eli=%~2" & set "eli=!eli:P:=!"
set /a ND=%1+1 & call :eval_list !ND! "!CDR_%eli%!" "%~3"
set "CAR_%HN%=!_%1_e!" & set "CDR_%HN%=!R!" & set "R=P:%HN%" & set /a HN+=1
goto :eof

:prim_oper
set "poN=%~2"
if "!poN!"=="vau" goto po_vau
if "!poN!"=="define" goto po_define
if "!poN!"=="if" goto po_if
if "!poN!"=="run" goto po_run
set "R=NIL" & goto :eof
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
set "_%1_f=!CAR_%ci%!"
set "cr1=!CDR_%ci%!" & set "cr1=!cr1:P:=!"
set "_%1_ef=!CAR_%cr1%!"
set "cr2=!CDR_%cr1%!" & set "cr2=!cr2:P:=!"
set "_%1_body=!CAR_%cr2%!"
set "_%1_senv=!CDR_%cr2%!"
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

rem =========================== primitives (applicative) ===========================
:prim_app
set "paN=%~2"
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
set "R=NIL" & goto :eof
:pa_fex
call :hp_car "%~3"
set "fexP=!R:~2!"
if exist "!fexP!" (set "R=S:t") else (set "R=NIL")
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
<nul set /p "=!R!"
echo(
set "R=NIL"
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
if "!_%1_lst!"=="NIL" set "R=!_%1_acc!" & goto :eof
call :hp_car "!_%1_lst!"
set /a ND=%1+1 & call :lisp_write !ND! "!R!"
set "_%1_piece=!R!"
if "!_%1_first!"=="1" (set "_%1_acc=!_%1_piece!") else (set "_%1_acc=!_%1_acc! !_%1_piece!")
set "_%1_first=0"
call :hp_cdr "!_%1_lst!"
set "_%1_lst=!R!"
goto rl2

rem ================================ bootstrap ================================
:setup_global
call :env_new "NIL"
set "GLOBAL=!R!"
call :env_define "!GLOBAL!" "S:vau" "F:vau"
call :env_define "!GLOBAL!" "S:define" "F:define"
call :env_define "!GLOBAL!" "S:if" "F:if"
call :env_define "!GLOBAL!" "S:cons" "R:cons"
call :env_define "!GLOBAL!" "S:car" "R:car"
call :env_define "!GLOBAL!" "S:cdr" "R:cdr"
call :env_define "!GLOBAL!" "S:eq?" "R:eq?"
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
call :env_define "!GLOBAL!" "S:run" "F:run"
call :env_define "!GLOBAL!" "S:t" "S:t"
call :env_define "!GLOBAL!" "S:nil" "NIL"
goto :eof
