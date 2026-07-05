;;; src/compile.lisp — the portsh Lisp->batch compiler, written in portsh Lisp.
;;;
;;; See docs/compilation.md for the why (the interpretation ceiling on cmd) and
;;; the trajectory (Futamura projections / self-hosting). Developed on the fast
;;; sh kernel; emits quote-free batch (portsh has no string escape) as a LIST OF
;;; LINES, written with write-lines.
;;;
;;; VALUE MODEL: compiled code uses the interpreter's TAGGED values (I:5, P:3,
;;; T:foo, ...), so cons cells, strings, and the C: call boundary interoperate.
;;; A "ref" is lit (a literal int), raw (a var holding a raw int, from set /a), or
;;; val (a var holding a tagged value). Renderers convert at use sites: aref/iref
;;; give a raw number for set /a and `if` (stripping a val's 2-char tag); vref
;;; gives the tagged value for calls/cons/return (re-tagging a raw as I:..).
;;;
;;; Covers: + - *, < =, if, params, value return, tail self-recursion (loops ->
;;; goto), and inter-function calls. Next: cons/car/cdr, strings, then the
;;; control fexprs as compile-time macros, then self-hosting.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define op->batch  (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define cmp->batch (lambda (o) (cond ((eq? o (quote <)) "LSS") ((eq? o (quote <=)) "LEQ") ((eq? o (quote =)) "EQU") ((eq? o (quote >)) "GTR") ((eq? o (quote >=)) "GEQ") (t "?"))))
(define arith? (lambda (o) (if (eq? o (quote +)) t (if (eq? o (quote -)) t (eq? o (quote *))))))
;; predicates test-stmts can evaluate; in VALUE position we wrap them in an if so
;; the result becomes S:t / NIL (e.g. comp's is? returns (eq? (car f) h)).
(define tpred? (lambda (o) (cond ((eq? o (quote eq?)) t) ((eq? o (quote null?)) t) ((eq? o (quote pair?)) t)
  ((eq? o (quote number?)) t) ((eq? o (quote string?)) t) ((eq? o (quote symbol?)) t) ((eq? o (quote <)) t) ((eq? o (quote <=)) t) ((eq? o (quote =)) t) ((eq? o (quote >)) t) ((eq? o (quote >=)) t) (t nil))))
(define is? (lambda (f h) (if (pair? f) (eq? (car f) h) nil)))

;; ref kinds: lit (literal int) | raw (var, raw int) | val (var, tagged value) |
;; cst (a literal tagged value, e.g. NIL — carried verbatim).
(define aref (lambda (r) (cond ((eq? (car r) (quote lit)) (cdr r)) ((eq? (car r) (quote raw)) (cdr r)) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) ":~2!")))))
(define iref (lambda (r) (cond ((eq? (car r) (quote lit)) (cdr r)) ((eq? (car r) (quote raw)) (str "!" (cdr r) "!")) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) ":~2!")))))
(define vref (lambda (r) (cond ((eq? (car r) (quote lit)) (str "I:" (cdr r))) ((eq? (car r) (quote raw)) (str "I:!" (cdr r) "!")) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) "!")))))
;; cref: the CONTENT of a value (tag stripped) for string concat/retag. A cst
;; (T:lit) is stripped at compile time; a var (val) strips its 2-char tag at runtime.
;; cref: render an operand ref PAYLOAD (tag stripped). lit = raw compile-time number (no tag, verbatim --
;; without this arm a literal in (str "n=" 42) emits !42:~2!, a substring of an undefined var named 42).
(define cref (lambda (r) (if (eq? (car r) (quote lit)) (cdr r) (if (eq? (car r) (quote cst)) (substring (cdr r) 2 (- (string-length (cdr r)) 2)) (str "!" (cdr r) ":~2!")))))
;; enc-mc: rewrite the data metachars in a string LITERAL's content so they survive
;; into compiled.cmd. At runtime a value reaches `set zt=T:...`; there a bare 0x01('!')
;; is eaten by delayed expansion, 0x02('%') by percent-expansion, and 0x07('^') acts as
;; an escape. Emit each instead as !BANG!/!BANG2!/!BANG7! -- a runtime ref to the kernel's
;; 0x01/0x02/0x07 vars, which write-lines passes through verbatim and the dispatcher
;; re-expands back to the sentinel byte (decoded to the real char only at I/O).
;; The B1/B2/B7 keys ARE the sentinel bytes (the reader already encoded our "!"/"%"/"^").
(define B1 "!")
(define B2 "%")
(define B7 "^")
;; the cmd operators < > & |: a bare one in a literal would tokenize as redirection/
;; pipe, so emit each via its kernel var (!LT! etc.) -- inserted post-tokenization.
(define BLT "<")
(define BGT ">")
(define BAMP "&")
(define BPIPE "|")
(define mc-at (lambda (c) (cond ((eq? c B1) "!BANG!") ((eq? c B2) "!BANG2!") ((eq? c B7) "!BANG7!") ((eq? c BLT) "!LT!") ((eq? c BGT) "!GT!") ((eq? c BAMP) "!AMP!") ((eq? c BPIPE) "!PIPE!") (t c))))
(define enc-mc-go (lambda (s i n acc) (if (= i n) acc (enc-mc-go s (+ i 1) n (string-append acc (mc-at (substring s i 1)))))))
(define enc-mc (lambda (s) (enc-mc-go s 0 (string-length s) "")))
;; mangle: a function name becomes a batch LABEL, a `call <name>.cmd`, AND a FILENAME
;; <name>.cmd (multi-file codegen). So operator chars (> < & | *) would tokenize as
;; redirection/pipe/glob, and `?` (legal in a label) is ILLEGAL in a Windows filename.
;; Replace each with a safe code (zzG etc). Applied to every name->label/file/call site
;; (compile-fn label, the general-call target, make-compiled in the residual) so they
;; stay consistent. (- + = are fine in labels AND filenames, left alone.)
(define BST "*")
(define mangle-at (lambda (c) (cond ((eq? c BGT) "zzG") ((eq? c BLT) "zzL") ((eq? c BAMP) "zzA") ((eq? c BPIPE) "zzP") ((eq? c BST) "zzS") ((eq? c "?") "zzQ") (t c))))
(define mangle-go (lambda (s i n acc) (if (= i n) acc (mangle-go s (+ i 1) n (string-append acc (mangle-at (substring s i 1)))))))
(define mangle (lambda (s) (mangle-go s 0 (string-length s) "")))

;; --- caller-saves for general (non-tail) calls. Compiled fns have no setlocal
;; (so the shared heap survives across calls), which means a call clobbers the
;; caller's param/temp vars. Around every general call we push the caller's live
;; vars onto a global stack (STK/SP) and pop them back after. `live` is the set of
;; enclosing temp vars threaded through cexpr; params are added at the call site.
(define rev (lambda (xs acc) (if (null? xs) acc (rev (cdr xs) (cons (car xs) acc)))))
;; var names to caller-save. Skips the string-keyed "$ELIDE" marker (real param
;; keys are symbols), which carries the elide-set rather than a saveable var.

;; add a ref's VAR to the live set (caller-saved across calls). Only val/raw are
;; vars; lit and cst are literals (e.g. "S:if") -- saving them would emit bogus
;; `set STK..=!S:if!` / restore and corrupt state.

;; qset: a QUOTED `set "VAR=VAL"`. Required for any value that may carry an operator
;; (S:< etc): an unquoted `set X=!v!` lets the < / > redirect (the kernel quotes too).
(define qset (lambda (body) (str "set " (dq) body (dq))))



;; param vars are FUNCTION-UNIQUE (prefixed with the fn's label) so a call to a
;; different function can never clobber the caller's params by name -- only a real
;; re-entry can, which the reachability elide-set detects. (temps zt<k> are already
;; globally-unique-numbered.)

;; params arrive in the global A1.. vars (space/special-char safe via delayed
;; expansion; positional `call` args split on spaces). Read them in immediately,
;; before any nested call overwrites A1...



;; cexpr: value-position expr -> (list lines ref next-k). arithmetic -> a raw
;; temp; a call -> compute args (tagged), call, take the tagged R into a val temp.
;; cquote: compile (quote DATUM). Atoms become a cst of the tagged literal
;; (symbol->S:, number->I:, nil->NIL, string->T:), metachars/operators in the
;; name run through enc-mc. A pair is built at runtime by desugaring to cons of
;; the quoted car and quoted cdr, reusing the cons codegen.
;; Codegen threads `acc` = all emitted lines so far, in REVERSE order (cons is O(1);
;; append re-copies). Each fn takes acc and returns it extended; compile-fn reverses
;; once. `(rev fwd acc)` appends a forward fragment; `(cons line acc)` appends one line.

;; cbegin: (begin e1..en) -> run each in order (discarding all but the last's
;; value); the last expr supplies the result ref.

(define lookup (lambda (k al) (if (null? al) nil (if (eq? (car (car al)) k) (cdr (car al)) (lookup k (cdr al))))))
(define lenl (lambda (xs) (if (null? xs) 0 (+ 1 (lenl (cdr xs))))))
(define maxi (lambda (a b) (if (< a b) b a)))
(define qset (lambda (body) (str "set " (dq) body (dq))))
(define b-blk (lambda (b) (car b)))
(define b-cur (lambda (b) (car (cdr b))))
(define b-pc  (lambda (b) (car (cdr (cdr b)))))
(define b-npc (lambda (b) (cadddr b)))
(define b-k   (lambda (b) (car (cdr (cdr (cdr (cdr b)))))))
(define b-smax (lambda (b) (car (cdr (cdr (cdr (cdr (cdr b))))))))
(define mkb (lambda (blk cur pc npc k sm) (cons blk (cons cur (cons pc (cons npc (cons k (cons sm nil))))))))
(define emit (lambda (b ln) (mkb (b-blk b) (cons ln (b-cur b)) (b-pc b) (b-npc b) (b-k b) (b-smax b))))
(define bk+ (lambda (b) (mkb (b-blk b) (b-cur b) (b-pc b) (b-npc b) (+ (b-k b) 1) (b-smax b))))
(define bsm (lambda (b n) (mkb (b-blk b) (b-cur b) (b-pc b) (b-npc b) (b-k b) (maxi (b-smax b) n))))
(define bnpc+ (lambda (b) (mkb (b-blk b) (b-cur b) (b-pc b) (+ (b-npc b) 1) (b-k b) (b-smax b))))
(define switch (lambda (b to) (mkb (cons (cons (b-pc b) (rev (b-cur b) nil)) (b-blk b)) nil to (b-npc b) (b-k b) (b-smax b))))
(define tmpn (lambda (b) (str "zt" (number->string (b-k b)))))
(define fval (lambda (r) (vref r)))
(define spill (lambda (b live j) (if (null? live) b (spill (emit b (str "set /a _i=!FP!+!NP!+" (number->string j) " & set " (dq) "F!_i!=!" (car live) "!" (dq))) (cdr live) (+ j 1)))))
(define unspill (lambda (b live j) (if (null? live) b (unspill (emit b (str "set /a _i=!FP!+!NP!+" (number->string j) " & call set " (dq) (car live) "=%%F!_i!%%" (dq))) (cdr live) (+ j 1)))))
(define stage (lambda (b refs i) (if (null? refs) (emit b (qset (str "ARGC=" (number->string i)))) (stage (emit b (str "set /a _i=!NFP!+" (number->string i) " & set " (dq) "F!_i!=" (fval (car refs)) (dq))) (cdr refs) (+ i 1)))))
(define setparams (lambda (b refs i) (if (null? refs) (emit b (qset (str "ARGC=" (number->string i)))) (setparams (emit b (str "set /a _i=!FP!+" (number->string i) " & set " (dq) "F!_i!=" (fval (car refs)) (dq))) (cdr refs) (+ i 1)))))
(define rvar (lambda (r) (if (eq? (car r) (quote val)) (cdr r) (if (eq? (car r) (quote raw)) (cdr r) nil))))
(define addlive (lambda (r live) (let ((v (rvar r))) (if (null? v) live (cons v live)))))
(define largs (lambda (es pmap b live)
  (if (null? es) (cons b nil)
    (let ((r1 (lval (car es) pmap b live)))
      (let ((rest (largs (cdr es) pmap (car r1) (addlive (cdr r1) live))))
        (cons (car rest) (cons (cdr r1) (cdr rest))))))))
(define bargs (lambda (refs) (if (null? refs) "" (str " " (vref (car refs)) (bargs (cdr refs))))))
(define lcell (lambda (f field pmap b live)
  ;; INLINE file-heap read -- `for %%v in (!zi!) do set /p tmp=<%HD%\<field>%%v` gives a
  ;; DYNAMIC-address redirect with no helper-file call (the redirect path takes the for-var;
  ;; set /p keeps & | < > ! raw). Measured 0.15ms vs 0.82ms for `call rdfield.cmd` -- car/cdr
  ;; is the hottest compiled op. The ~0,-1 substring drops the trailing guard byte (#).
  (let ((rx (lval (car (cdr f)) pmap b live)))
    (let ((zi (str "zi" (number->string (b-k (car rx))))) (tmp (tmpn (car rx))))
      (let ((b1 (emit (car rx) (qset (str zi "=!" (cdr (cdr rx)) ":~2!")))))
        (let ((b2 (emit b1 (str "if " (dq) "!" (cdr (cdr rx)) ":~0,2!" (dq) "==" (dq) "P:" (dq) " (for %%v in (!" zi "!) do set /p " tmp "=<%HD%\" field "%%v) else set " (dq) tmp "=NIL#" (dq)))))
          (cons (bk+ (emit b2 (qset (str tmp "=!" tmp ":~0,-1!")))) (cons (quote val) tmp))))))))
(define ltagtest (lambda (e ch pmap b live neg)
  (let ((rx (lval e pmap b live)))
    (let ((zp (str "zp" (number->string (b-k (car rx))))))
      (let ((b1 (emit (emit (car rx) (qset (str zp "=" (vref (cdr rx))))) (qset (str zp "=!" zp ":~0,1!")))))
        (cons (bk+ b1) (str (if neg "not " "") "!" zp "!==" ch)))))))
(define ctest (lambda (f pmap b live)
  (if (if (pair? f) (tpred? (car f)) nil)
    (cond
      ((eq? (car f) (quote null?)) (let ((ra (lval (car (cdr f)) pmap b live))) (cons (car ra) (str (dq) (vref (cdr ra)) (dq) "==" (dq) "NIL" (dq)))))
      ((eq? (car f) (quote eq?)) (let ((ra (lval (car (cdr f)) pmap b live))) (let ((rb (lval (car (cdr (cdr f))) pmap (car ra) live))) (cons (car rb) (str (dq) (vref (cdr ra)) (dq) "==" (dq) (vref (cdr rb)) (dq))))))
      ((eq? (car f) (quote pair?)) (ltagtest (car (cdr f)) "P" pmap b live nil))
      ((eq? (car f) (quote atom?)) (ltagtest (car (cdr f)) "P" pmap b live t))
      ((eq? (car f) (quote number?)) (ltagtest (car (cdr f)) "I" pmap b live nil))
      ((eq? (car f) (quote string?)) (ltagtest (car (cdr f)) "T" pmap b live nil))
      ((eq? (car f) (quote symbol?)) (ltagtest (car (cdr f)) "S" pmap b live nil))
      (t (let ((ra (lval (car (cdr f)) pmap b live))) (let ((rb (lval (car (cdr (cdr f))) pmap (car ra) live))) (cons (car rb) (str (iref (cdr ra)) " " (cmp->batch (car f)) " " (iref (cdr rb))))))))
    (let ((rx (lval f pmap b live))) (cons (car rx) (str "not " (dq) (vref (cdr rx)) (dq) "==" (dq) "NIL" (dq)))))))
(define jumpto (lambda (n) (str "set " (dq) "PC=" (number->string n) (dq) " & set " (dq) "ACTION=jump" (dq) " & goto :eof")))
(define ifjump (lambda (cond n) (str "if " cond " (set " (dq) "PC=" (number->string n) (dq) " & set " (dq) "ACTION=jump" (dq) " & goto :eof)")))
(define seg-files (lambda (preamble blk i n lbl) (if (= i n) nil (cons (cons (str lbl "_pc" (number->string i)) (append preamble (blkget blk i))) (seg-files preamble blk (+ i 1) n lbl)))))
(define write-segs (lambda (segs cmdpath) (if (null? segs) (quote done) (begin (write-lines (str cmdpath "/" (car (car segs)) ".cmd") (cdr (car segs))) (write-segs (cdr segs) cmdpath)))))
(define lif-val (lambda (c a bb pmap b live)
  (let ((ct (ctest c pmap b live)))
    (let ((aid (b-npc (car ct))) (bid (+ (b-npc (car ct)) 1)) (jid (+ (b-npc (car ct)) 2)) (tmp (tmpn (car ct))))
      (let ((b2 (emit (emit (bk+ (bnpc+ (bnpc+ (bnpc+ (car ct))))) (ifjump (cdr ct) aid)) (jumpto bid))))
        (let ((ra (lval a pmap (switch b2 aid) live)))
          (let ((ba (emit (emit (car ra) (qset (str tmp "=" (vref (cdr ra))))) (jumpto jid))))
            (let ((rb (lval bb pmap (switch ba bid) live)))
              (let ((bj (emit (emit (car rb) (qset (str tmp "=" (vref (cdr rb))))) (jumpto jid))))
                (cons (switch bj jid) (cons (quote val) tmp)))))))))))
(define lbinds (lambda (binds pmap b live) (if (null? binds) (cons b (cons pmap live)) (let ((r1 (lval (car (cdr (car binds))) pmap b live))) (let ((tmp (tmpn (car r1)))) (lbinds (cdr binds) (cons (cons (car (car binds)) tmp) pmap) (bk+ (emit (car r1) (qset (str tmp "=" (vref (cdr r1)))))) (cons tmp live)))))))
(define llet (lambda (binds body pmap b live) (let ((r (lbinds binds pmap b live))) (lval body (car (cdr r)) (car r) (cdr (cdr r))))))
(define lbegin (lambda (es pmap b live) (if (null? (cdr es)) (lval (car es) pmap b live) (let ((r1 (lval (car es) pmap b live))) (lbegin (cdr es) pmap (car r1) live)))))
(define lquote (lambda (d b)
  (cond ((null? d) (cons b (cons (quote cst) "NIL")))
        ((number? d) (cons b (cons (quote lit) (number->string d))))
        ((string? d) (cons b (cons (quote cst) (str "T:" (enc-mc d)))))
        ((symbol? d) (cons b (cons (quote cst) (str "S:" (enc-mc (symbol->string d))))))
        (t (lval (list (quote cons) (list (quote quote) (car d)) (list (quote quote) (cdr d))) nil b nil)))))
(define lretag (lambda (f tag pmap b live)
  (let ((rx (lval (car (cdr f)) pmap b live)))
    (let ((tmp (tmpn (car rx))))
      (cons (bk+ (emit (car rx) (qset (str tmp "=" tag (cref (cdr rx)))))) (cons (quote val) tmp))))))
(define lstrlen (lambda (f pmap b live)
  (let ((rx (lval (car (cdr f)) pmap b live)))
    (let ((j (number->string (b-k (car rx)))))
      (let ((zc (str "zc" j)) (zn (tmpn (car rx))) (lp (str "zSL" j)))
        (let ((b1 (emit (car rx) (qset (str zc "=" (cref (cdr rx)))))))
          (let ((b2 (emit b1 (str "set /a " zn "=0"))))
            (let ((b3 (emit b2 (str ":" lp))))
              (cons (bk+ (emit b3 (str "if defined " zc " (set " zc "=!" zc ":~1!& set /a " zn "+=1& goto " lp ")"))) (cons (quote raw) zn))))))))))
(define lsubstr (lambda (f pmap b live)
  (let ((rs (lval (car (cdr f)) pmap b live)))
    (let ((ro (lval (car (cdr (cdr f))) pmap (car rs) (addlive (cdr rs) live))))
      (let ((rl (lval (cadddr f) pmap (car ro) (addlive (cdr ro) (addlive (cdr rs) live)))))
        (let ((j (number->string (b-k (car rl)))))
          (let ((zc (str "zc" j)) (zsk (str "zsk" j)) (ztk (str "ztk" j)) (zr (str "zr" j)) (ztmp (tmpn (car rl))) (sk (str "zSK" j)) (tk (str "zTK" j)))
            (let ((b1 (emit (car rl) (qset (str zc "=" (cref (cdr rs)))))))
              (let ((b2 (emit b1 (str "set /a " zsk "=" (aref (cdr ro))))))
                (let ((b3 (emit b2 (str ":" sk))))
                  (let ((b4 (emit b3 (str "if defined " zc " if !" zsk "! gtr 0 (set " zc "=!" zc ":~1!& set /a " zsk "-=1& goto " sk ")"))))
                    (let ((b5 (emit b4 (qset (str zr "=")))))
                      (let ((b6 (emit b5 (str "set /a " ztk "=" (aref (cdr rl))))))
                        (let ((b7 (emit b6 (str ":" tk))))
                          (let ((b8 (emit b7 (str "if defined " zc " if !" ztk "! gtr 0 (set " zr "=!" zr "!!" zc ":~0,1!& set " zc "=!" zc ":~1!& set /a " ztk "-=1& goto " tk ")"))))
                            (cons (bk+ (emit b8 (qset (str ztmp "=T:!" zr "!")))) (cons (quote val) ztmp)))))))))))))))))
(define builtin? (lambda (o) (cond ((eq? o (quote write-lines)) t) ((eq? o (quote append-lines)) t) ((eq? o (quote gc)) t) ((eq? o (quote print)) t) ((eq? o (quote read-lines)) t) ((eq? o (quote file-exists?)) t) ((eq? o (quote read)) t) ((eq? o (quote type-of)) t) ((eq? o (quote split)) t) ((eq? o (quote argv)) t) ((eq? o (quote argv0)) t) ((eq? o (quote run-argv)) t) ((eq? o (quote run-capture-argv)) t) ((eq? o (quote getenv)) t) ((eq? o (quote setenv)) t) ((eq? o (quote exit)) t) ((eq? o (quote make-dir)) t) ((eq? o (quote delete-file)) t) ((eq? o (quote copy-file)) t) (t nil))))
;; run / run-capture are OPERATIVES: operands are unevaluated literal tokens joined into a host
;; command (matching prim_oper). fv/lift must SKIP their operands (like quote) -- runop? guards both.
;; The joined command is baked via enc-mc (the SAME sentinel encoding the reader applies to heap
;; tokens), so the prim's  cmd /c "!A1:~2!"  is byte-identical to the interpreter's  cmd /c "!rcCmd!".
(define runop? (lambda (o) (if (eq? o (quote run)) t (eq? o (quote run-capture)))))
(define tok-text (lambda (o) (cond ((symbol? o) (symbol->string o)) ((string? o) o) ((number? o) (number->string o)) (t ""))))
(define join-toks (lambda (os) (if (null? os) "" (str " " (tok-text (car os)) (join-toks (cdr os))))))
;; primitives inlined in CALL position have no fn value; in VALUE position (e.g. (foldr + 0 xs)) they
;; compile to a C:<label> wrapper -- a fixed-arity applicative fn (src/prims.lisp) named __p_<op>.
(define prim-wrap (lambda (s)
  (cond ((eq? s (quote +)) "__p_add") ((eq? s (quote -)) "__p_sub") ((eq? s (quote *)) "__p_mul")
        ((eq? s (quote <)) "__p_lt")  ((eq? s (quote <=)) "__p_le") ((eq? s (quote =)) "__p_neq")
        ((eq? s (quote >)) "__p_gt")  ((eq? s (quote >=)) "__p_ge")
        ((eq? s (quote cons)) "__p_cons") ((eq? s (quote car)) "__p_car") ((eq? s (quote cdr)) "__p_cdr")
        ((eq? s (quote null?)) "__p_null") ((eq? s (quote eq?)) "__p_eq") ((eq? s (quote pair?)) "__p_pair")
        ((eq? s (quote not)) "__p_not")
        ((eq? s (quote number?)) "__p_number") ((eq? s (quote string?)) "__p_string") ((eq? s (quote symbol?)) "__p_symbol")
        ((eq? s (quote print)) "__p_print")
        (t nil))))
(define aas (lambda (refs i) (if (null? refs) nil (cons (qset (str "A" (number->string i) "=" (vref (car refs)))) (aas (cdr refs) (+ i 1))))))
(define emit-list (lambda (b lns) (if (null? lns) b (emit-list (emit b (car lns)) (cdr lns)))))
(define lbuiltin (lambda (f pmap b live)
  (let ((ar (largs (cdr f) pmap b live)))
    (let ((tmp (tmpn (car ar))) (mn (mangle (symbol->string (car f)))))
      (let ((b1 (emit-list (car ar) (aas (cdr ar) 1))))
        (let ((b2 (emit b1 (str "call " mn ".cmd"))))
          (cons (bk+ (emit b2 (qset (str tmp "=!R!")))) (cons (quote val) tmp))))))))
(define lval (lambda (f pmap b live)
  (cond
    ((number? f) (cons b (cons (quote lit) (number->string f))))
    ((eq? f (quote nil)) (cons b (cons (quote cst) "NIL")))
    ((eq? f (quote t)) (cons b (cons (quote cst) "S:t")))
    ((string? f) (cons b (cons (quote cst) (str "T:" (enc-mc f)))))
    ((symbol? f) (let ((p (lookup f pmap)))
       (if (null? p)
         ;; pmap miss: a primitive used as a VALUE -> C:<wrapper>; a KNOWN top-level fn used as a
         ;; VALUE -> first-class C:<label> fn-value; else a global constant G_<name>.
         (if (prim-wrap f) (cons b (cons (quote cst) (str "C:" (prim-wrap f))))
           (if (mem? f (gfns-of pmap)) (cons b (cons (quote cst) (str "C:" (mangle (symbol->string f)))))
             (cons b (cons (quote val) (str "G_" (symbol->string f))))))
         (cons b (cons (quote val) p)))))
    ((arith? (car f))
      (let ((ra (lval (car (cdr f)) pmap b live)))
        (let ((rb (lval (car (cdr (cdr f))) pmap (car ra) (addlive (cdr ra) live))))
          (let ((tmp (tmpn (car rb))))
            (cons (bk+ (emit (car rb) (str "set /a " tmp "=" (aref (cdr ra)) (op->batch (car f)) (aref (cdr rb))))) (cons (quote raw) tmp))))))
    ((eq? (car f) (quote cons))
      (let ((ar (largs (cdr f) pmap b live)))
        (let ((tmp (tmpn (car ar))) (a0 (car (cdr ar))) (a1 (car (cdr (cdr ar)))))
          (let ((b1 (emit (car ar) "set /a HN+=1")))
            (let ((b2 (emit b1 (str ">%HD%\car%HN% echo(" (vref a0) "#"))))
              (let ((b3 (emit b2 (str ">%HD%\cdr%HN% echo(" (vref a1) "#"))))
                (cons (bk+ (emit b3 (qset (str tmp "=P:!HN!")))) (cons (quote val) tmp))))))))
    ((eq? (car f) (quote string-append))
      (let ((ra (lval (car (cdr f)) pmap b live)))
        (let ((rb (lval (car (cdr (cdr f))) pmap (car ra) (addlive (cdr ra) live))))
          (let ((tmp (tmpn (car rb))))
            (cons (bk+ (emit (car rb) (qset (str tmp "=T:" (cref (cdr ra)) (cref (cdr rb)))))) (cons (quote val) tmp))))))
    ((eq? (car f) (quote car)) (lcell f "car" pmap b live))
    ((eq? (car f) (quote cdr)) (lcell f "cdr" pmap b live))
    ((eq? (car f) (quote if)) (lif-val (car (cdr f)) (car (cdr (cdr f))) (cadddr f) pmap b live))
    ((eq? (car f) (quote cond)) (lval (cond->if (cdr f)) pmap b live))
    ((eq? (car f) (quote let)) (llet (car (cdr f)) (car (cdr (cdr f))) pmap b live))
    ((eq? (car f) (quote begin)) (lbegin (cdr f) pmap b live))
    ((eq? (car f) (quote quote)) (lquote (car (cdr f)) b))
    ((eq? (car f) (quote string-length)) (lstrlen f pmap b live))
    ((eq? (car f) (quote substring)) (lsubstr f pmap b live))
    ((eq? (car f) (quote symbol->string)) (lretag f "T:" pmap b live))
    ((eq? (car f) (quote number->string)) (lretag f "T:" pmap b live))
    ((eq? (car f) (quote string->symbol)) (lretag f "S:" pmap b live))
    ((eq? (car f) (quote string->number)) (lretag f "I:" pmap b live))
    ((eq? (car f) (quote dq)) (let ((tmp (tmpn b))) (cons (bk+ (emit b (qset (str tmp "=T:!BANG8!")))) (cons (quote val) tmp))))
    ((eq? (car f) (quote run))
      ;; operative: bake the joined literal command (enc-mc) into A1, then run_cmd.cmd -> R="I:errorlevel".
      (let ((tmp (tmpn b)))
        (let ((b1 (emit b (qset (str "A1=T:" (enc-mc (join-toks (cdr f))))))))
          (cons (bk+ (emit (emit b1 "call run_cmd.cmd") (qset (str tmp "=!R!")))) (cons (quote val) tmp)))))
    ((eq? (car f) (quote run-capture))
      ;; operative: bake command into A1, run_capture.cmd -> stdout+stderr as a line-list.
      (let ((tmp (tmpn b)))
        (let ((b1 (emit b (qset (str "A1=T:" (enc-mc (join-toks (cdr f))))))))
          (cons (bk+ (emit (emit b1 "call run_capture.cmd") (qset (str tmp "=!R!")))) (cons (quote val) tmp)))))
    ((builtin? (car f)) (lbuiltin f pmap b live))
    ((tpred? (car f)) (lif-val f (quote t) (quote nil) pmap b live))
    ((eq? (car f) (quote make-closure))
      ;; (make-closure (quote __lamN) cap...) -> heap record (S:__lamN cap...) tagged K:<idx>
      (let ((rr (lval (list (quote cons) (car (cdr f)) (mkclo-caps (cdr (cdr f)))) pmap b live)))
        (let ((tmp (tmpn (car rr))))
          (cons (bk+ (emit (car rr) (qset (str tmp "=K:!" (cdr (cdr rr)) ":~2!")))) (cons (quote val) tmp)))))
    ((eq? (car f) (quote apply))
      ;; (apply fn arglist): eval fn -> CALLEE, eval arglist -> APLIST; yield ACTION=apply. The driver's
      ;; apply arm spreads APLIST into the callee frame slots (runtime count) then dispatches like a call.
      (let ((rc (lval (car (cdr f)) pmap b live)))
        (let ((live2 (addlive (cdr rc) live)))
          (let ((rl (lval (car (cdr (cdr f))) pmap (car rc) live2)))
            (let ((live3 (addlive (cdr rl) live2)) (rpc (b-npc (car rl))))
              (let ((c1 (emit (spill (bnpc+ (car rl)) live3 0) "set /a NFP=!FT!")))
                (let ((c2 (emit c1 (str "set " (dq) "CALLEE=" (vref (cdr rc)) (dq)))))
                  (let ((c3 (emit c2 (str "set " (dq) "APLIST=" (vref (cdr rl)) (dq)))))
                    (let ((c4 (emit c3 (str "set " (dq) "RPC=" (number->string rpc) (dq)))))
                      (let ((c5 (emit c4 (str "set " (dq) "ACTION=apply" (dq) " & goto :eof"))))
                        (let ((br (switch c5 rpc)))
                          (let ((tmp (tmpn br)))
                            (cons (bk+ (bsm (emit (unspill br live3 0) (qset (str tmp "=!R!"))) (lenl live3)))
                                  (cons (quote val) tmp))))))))))))))
    (t ;; general non-tail call -> YIELD
      (if (if (symbol? (car f)) (null? (lookup (car f) pmap)) nil)
        ;; non-local symbol operator: a known global VAR holds a closure value in G_<name> -> load it
        ;; as the callee (driver K: applies); otherwise a global FN name -> direct named call. Compile-
        ;; time gvar test, so fn calls keep the bare static form (mirror of compile-sh.lisp).
        (let ((ar (largs (cdr f) pmap b live)))
          (let ((rpc (b-npc (car ar)))
                (cs (if (mem? (car f) (lookup "$GVARS" pmap))
                      (str "set " (dq) "CALLEE=!G_" (symbol->string (car f)) "!" (dq))
                      (str "set " (dq) "CALLEE=" (mangle (symbol->string (car f))) (dq)))))
            (let ((c1 (emit (spill (bnpc+ (car ar)) live 0) "set /a NFP=!FT!")))
              (let ((c2 (stage c1 (cdr ar) 0)))
                (let ((c3 (emit c2 cs)))
                  (let ((c4 (emit c3 (str "set " (dq) "RPC=" (number->string rpc) (dq)))))
                    (let ((c5 (emit c4 (str "set " (dq) "ACTION=call" (dq) " & goto :eof"))))
                      (let ((br (switch c5 rpc)))
                        (let ((tmp (tmpn br)))
                          (cons (bk+ (bsm (emit (unspill br live 0) (qset (str tmp "=!R!"))) (lenl live)))
                                (cons (quote val) tmp)))))))))))
        ;; computed call: eval the callee (a closure value) -> CALLEE=!cvar!; the driver's K: case
        ;; reads the record's label into CURFN and sets CLO for captured-var loads.
        (let ((rc (lval (car f) pmap b live)))
          (let ((cvar (cdr (cdr rc))) (live2 (addlive (cdr rc) live)))
            (let ((ar (largs (cdr f) pmap (car rc) live2)))
              (let ((rpc (b-npc (car ar))))
                (let ((c1 (emit (spill (bnpc+ (car ar)) live2 0) "set /a NFP=!FT!")))
                  (let ((c2 (stage c1 (cdr ar) 0)))
                    (let ((c3 (emit c2 (str "set " (dq) "CALLEE=!" cvar "!" (dq)))))
                      (let ((c4 (emit c3 (str "set " (dq) "RPC=" (number->string rpc) (dq)))))
                        (let ((c5 (emit c4 (str "set " (dq) "ACTION=call" (dq) " & goto :eof"))))
                          (let ((br (switch c5 rpc)))
                            (let ((tmp (tmpn br)))
                              (cons (bk+ (bsm (emit (unspill br live2 0) (qset (str tmp "=!R!"))) (lenl live2)))
                                    (cons (quote val) tmp))))))))))))))))))
(define ltbegin (lambda (es pmap fn np b live) (if (null? (cdr es)) (ltail (car es) pmap fn np b live) (let ((r1 (lval (car es) pmap b live))) (ltbegin (cdr es) pmap fn np (car r1) live)))))
(define ltail (lambda (f pmap fn np b live)
  (cond
    ((if (pair? f) (eq? (car f) (quote begin)) nil) (ltbegin (cdr f) pmap fn np b live))
    ((if (pair? f) (eq? (car f) fn) nil)   ;; self-tail-call: reset params, loop via ACTION=tail
      (let ((ar (largs (cdr f) pmap b live)))
        (emit (setparams (car ar) (cdr ar) 0) (str "set " (dq) "PC=0" (dq) " & set " (dq) "ACTION=tail" (dq) " & goto :eof"))))
    ((if (pair? f) (eq? (car f) (quote if)) nil)
      (let ((ct (ctest (car (cdr f)) pmap b live)))
        (let ((aid (b-npc (car ct))) (bid (+ (b-npc (car ct)) 1)))
          (let ((b2 (emit (emit (bnpc+ (bnpc+ (car ct))) (ifjump (cdr ct) aid)) (jumpto bid))))
            (let ((ba (ltail (car (cdr (cdr f))) pmap fn np (switch b2 aid) live)))
              (ltail (cadddr f) pmap fn np (switch ba bid) live))))))
    ((if (pair? f) (eq? (car f) (quote cond)) nil) (ltail (cond->if (cdr f)) pmap fn np b live))
    ((if (pair? f) (eq? (car f) (quote let)) nil)
      (let ((r (lbinds (car (cdr f)) pmap b live))) (ltail (car (cdr (cdr f))) (car (cdr r)) fn np (car r) (cdr (cdr r)))))
    (t (let ((r (lval f pmap b live)))
         (emit (car r) (str "set " (dq) "R=" (vref (cdr r)) (dq) " & set " (dq) "ACTION=ret" (dq) " & goto :eof")))))))
(define pmap-fr (lambda (fs i) (if (null? fs) nil (cons (cons (car fs) (str "p" (number->string i))) (pmap-fr (cdr fs) (+ i 1))))))
(define ploads (lambda (fs i) (if (null? fs) nil (if (= i 0)
  (cons (str "call set " (dq) "p0=%%F!FP!%%" (dq)) (ploads (cdr fs) 1))
  (cons (str "set /a _i=!FP!+" (number->string i) " & call set " (dq) "p" (number->string i) "=%%F!_i!%%" (dq)) (ploads (cdr fs) (+ i 1)))))))
(define blkget (lambda (al pc) (if (null? al) nil (if (eq? (car (car al)) pc) (cdr (car al)) (blkget (cdr al) pc)))))
(define caseblocks (lambda (al i n) (if (= i n) nil (append (cons (str ":_pc" (number->string i)) (blkget al i)) (caseblocks al (+ i 1) n)))))
;; variadic preamble (cmd): cons F[FP..FP+ARGC) into the rest list, ONLY on a fresh entry
;; (PC==0) -- on a resume the slot already holds the list and ARGC is stale. Labels are
;; file-local (one fn per per-PC file), so the backward goto scans a tiny file. Cons is the
;; standard inline pre-increment with the guard byte.
(define va-collect-cmd (lambda ()
  (list (str "if not " (dq) "!PC!" (dq) "==" (dq) "0" (dq) " goto _vrdy")
        (qset "vL=NIL")
        "set /a vI=ARGC"
        ":_vcl"
        "if !vI! LEQ 0 goto _vfin"
        "set /a vI-=1"
        "set /a _i=!FP!+!vI!"
        (str "call set " (dq) "vV=%%F!_i!%%" (dq))
        "set /a HN+=1"
        (str ">%HD%\car%HN% echo(!vV!#")
        (str ">%HD%\cdr%HN% echo(!vL!#")
        (qset "vL=P:%HN%")
        "goto _vcl"
        ":_vfin"
        (qset "F!FP!=!vL!")
        ":_vrdy")))
(define compile-fn (lambda (nm lbl fs body k0 elide gfns gvars)
  (let ((np (lenl (fs-list fs))) (pm (cons (cons "$GFNS" gfns) (cons (cons "$GVARS" gvars) (pmap-fr (fs-list fs) 0)))))
    (let ((bf (ltail body pm nm np (mkb nil nil 0 1 0 0) nil)))
      (let ((blk (cons (cons (b-pc bf) (rev (b-cur bf) nil)) (b-blk bf))) (fsz (+ np (b-smax bf))))
        (let ((preamble (append (if (varargs? fs) (append (va-collect-cmd) (ploads (fs-list fs) 0)) (ploads fs 0)) (cons (str "set /a FT=!FP!+" (number->string fsz)) (cons (qset (str "NP=" (number->string np))) nil)))))
          (cons (seg-files preamble blk 0 (b-npc bf) lbl) k0)))))))
;; a lifted closure sub: formals from frame slots (ploads), captured vars from the record (cap-loads via CLO).
(define compile-clambda (lambda (name lf cap body gfns gvars)
  (let ((np (lenl (fs-list lf))) (pm (cons (cons "$GFNS" gfns) (cons (cons "$GVARS" gvars) (pmap-fr (append (fs-list lf) cap) 0)))) (lbl (mangle (symbol->string name))))
    (let ((bf (ltail body pm name np (mkb nil nil 0 1 0 0) nil)))
      (let ((blk (cons (cons (b-pc bf) (rev (b-cur bf) nil)) (b-blk bf))) (fsz (+ np (b-smax bf))))
        ;; The cap-loads preamble (rdfield.cmd off the record) runs on EVERY entry, before the PC
        ;; dispatch -- including a resume after a non-tail call, where R holds that call's result.
        ;; rdfield.cmd sets R, so save/restore R around the preamble (mirror of compile-sh.lisp's _clrs).
        (let ((preamble (append (if (varargs? lf) (append (va-collect-cmd) (ploads (fs-list lf) 0)) (ploads lf 0)) (cons (qset "_clrs=!R!") (append (cap-loads cap np) (cons (qset "R=!_clrs!") (cons (str "set /a FT=!FP!+" (number->string fsz)) (cons (qset (str "NP=" (number->string np))) nil))))))))
          (seg-files preamble blk 0 (b-npc bf) lbl)))))))
(define tst (lambda (x) (let ((y (cdr x))) (cond ((null? y) (quote done)) ((pair? y) (write-lines "out" y)) (t (string-length y))))))

;; string-length: count chars by stripping one at a time (no batch strlen). The
;; content goes in via cref (delayed expansion, operator-safe); `if defined` ends
;; the loop when empty (avoids comparing content, which could hold operators/"").

;; substring: (substring s start len). Dynamic offsets can't use !v:~i,n! (i/n must
;; be literal) and the `call set %%v:~%i%,%n%%%` form would put an operator char into
;; command text. So walk char by char: skip `start`, then append `len` chars built
;; from !zc:~0,1! -- every char moves through delayed expansion, so operators survive.

;; cretag: symbol->string / number->string -- the content is unchanged, only the
;; 2-char tag becomes T:. set zt=T:<content of arg>.

;; car/cdr: strip P: from the (val) operand to an index, then read CAR_/CDR_<idx>.

;; cargs*: evaluate call args left-to-right -> (list lines (vref1 vref2 ...) k).
;; Each arg is evaluated with the earlier args' temps added to `live`, so a call
;; inside a later arg won't clobber an already-computed arg.

;; clet-binds: compile each (name value) binding -> materialise value into a temp,
;; extend pmap with name->temp. Returns (list lines extended-pmap nextk). Each later
;; binding's value sees the earlier bindings (sequential let, like let*).



;; test of an `if` -> lines ending in a `if ... goto TL`. Numeric (< =) compares
;; raw numbers; eq?/null? compare tagged values as strings (quote-free, so
;; space-free values only — symbols/NIL/numbers/pairs); pair? checks the P: tag.
;; tag-prefix predicate (pair?/number?/string?/symbol?): materialise the operand
;; into a temp (works for a var or a literal), then branch to TL if its first char
;; equals the tag letter (P/I/T/S).

;; test of an `if`. If it's a pair headed by a known predicate/comparison, emit the
;; specialised compare; OTHERWISE (a variable, or any other call -- e.g.
;; (if (def-lambda? f) ..), (if x ..)) it's a TRUTHINESS test: evaluate it and branch
;; to TL when the value is not NIL.

;; ctail: tail position. self-call -> args into zu temps, update params, goto top;
;; if -> goto-branch; else -> set R to the tagged value, return.



;; k0 is the program-wide monotonic label/temp counter: cexpr-level labels (zT/zE
;; value-if, zSL/zSK/zTK loops) are NOT function-prefixed, so `goto` would hit the
;; first match in the file. Threading one k across all fns keeps every label unique.
;; Returns (cons lines next-k).


;;; -------------------------------------------------- the driver (compile a program)
(define show-list (lambda (f)
  (if (null? (cdr f)) (show (car f))
    (if (pair? (cdr f)) (str (show (car f)) " " (show-list (cdr f)))
        (str (show (car f)) " . " (show (cdr f)))))))
(define show (lambda (f)
  (cond ((null? f) "()") ((number? f) (number->string f)) ((symbol? f) (symbol->string f))
        ;; re-quote strings (via dq) so the residual round-trips: a bare string
        ;; would read back as a symbol -> "unbound symbol" at load.
        ((string? f) (str (dq) f (dq))) (t (str "(" (show-list f) ")")))))
;; quote-free dispatcher: `call :<label>` (delayed expansion is inherited from the
;; kernel; R and the heap propagate since there's no setlocal).
(define def-lambda? (lambda (f)
  (if (pair? f) (if (eq? (car f) (quote define))
    (if (pair? (caddr f)) (eq? (car (caddr f)) (quote lambda)) nil) nil) nil)))
;; (define __lamN (clambda lf cap body)) -- a lifted closure sub; compiled like a fn but with
;; cap-loads. Never bound by name (called only via K:<idx>), so it emits NO residual binding.
(define def-clambda? (lambda (f)
  (if (pair? f) (if (eq? (car f) (quote define))
    (if (pair? (caddr f)) (eq? (car (caddr f)) (quote clambda)) nil) nil) nil)))
;; (define <nm> (make-compiled "<mangled>")) -- the residual binds the original symbol
;; to a C: combiner naming the MANGLED label, so calls dispatch to the right sub.
(define resid-bind (lambda (nm)
  (list (quote define) nm (list (quote make-compiled) (mangle (symbol->string nm))))))

;;; ------------------------------------------------ inlining (small non-recursive fns)
(define subst (lambda (s v tree)
  (cond ((eq? tree s) v) ((pair? tree) (cons (subst s v (car tree)) (subst s v (cdr tree)))) (t tree))))
(define subst* (lambda (ps as body)
  (if (null? ps) body (subst* (cdr ps) (cdr as) (subst (car ps) (car as) body)))))
(define refs? (lambda (s tree)
  (cond ((eq? tree s) t) ((pair? tree) (if (refs? s (car tree)) t (refs? s (cdr tree)))) (t nil))))
;; First-order map specialisations (the compiler has no closures; each is a named
;; recursive helper so comp itself stays compilable). One per call shape comp uses.
(define map-inline-expr (lambda (xs tbl) (if (null? xs) nil (cons (inline-expr (car xs) tbl) (map-inline-expr (cdr xs) tbl)))))
(define map-inline-form (lambda (xs tbl) (if (null? xs) nil (cons (inline-form (car xs) tbl) (map-inline-form (cdr xs) tbl)))))
;; map mexpand over a LIST of expressions (operands), preserving structural sharing (return xs
;; unchanged when nothing expanded). Used for call operands: this is what lets a special-form NAME
;; appear as a first-class argument ((app str 42)) without the operand list (str 42) being misread
;; as a (str ...) FORM -- each operand is mexpanded on its own, a bare `str` symbol stays itself.
(define map-mexpand (lambda (xs)
  (if (null? xs) nil
    (let ((a (mexpand (car xs))) (d (map-mexpand (cdr xs))))
      (if (if (eq? a (car xs)) (eq? d (cdr xs)) nil) xs (cons a d))))))
(define map-show (lambda (xs) (if (null? xs) nil (cons (show (car xs)) (map-show (cdr xs))))))
(define inline-expr (lambda (e tbl)
  (if (pair? e)
    (let ((ent (assoc (car e) tbl)))
      (if (null? ent)
        (cons (car e) (map-inline-expr (cdr e) tbl))
        (inline-expr (subst* (cadr ent) (map-inline-expr (cdr e) tbl) (caddr ent)) tbl)))
    e)))
(define mk-tbl (lambda (forms)
  (if (null? forms) nil
    (if (if (def-lambda? (car forms)) (not (refs? (cadr (car forms)) (caddr (caddr (car forms))))) nil)
      (cons (list (cadr (car forms)) (cadr (caddr (car forms))) (caddr (caddr (car forms)))) (mk-tbl (cdr forms)))
      (mk-tbl (cdr forms))))))
;; Inline ONLY inside compiled function bodies. Top-level (interpreted) forms are
;; left alone — inlining a body that uses a stdlib fn (e.g. pair?) into the
;; residual would reference something unbound there; as a compiled C: call it's fine.
(define inline-form (lambda (f tbl)
  (if (def-lambda? f)
    (list (quote define) (cadr f) (list (quote lambda) (cadr (caddr f)) (inline-expr (caddr (caddr f)) tbl)))
    f)))
(define inline-program (lambda (forms) (let ((tbl (mk-tbl forms))) (map-inline-form forms tbl))))

;; macro-expand: (cond (c1 e1)..(t en)) -> nested if. A source transform run before
;; compilation; cexpr/ctail then handle the resulting ifs. Skips `quote`d data so a
;; (cond ...) inside quoted data is left intact.
;; cond->if: a clause body is a SEQUENCE -> (begin body...), matching the stdlib cond
;; (a single-expr begin collapses in codegen, so single-body clauses are unchanged).
(define cond->if (lambda (cls)
  (if (null? cls) (quote nil)
    (if (eq? (car (car cls)) (quote t)) (cons (quote begin) (cdr (car cls)))
      (list (quote if) (car (car cls)) (cons (quote begin) (cdr (car cls))) (cond->if (cdr cls)))))))
;; str/list are variadic; the compiler is fixed-arity. comp only ever calls them
;; with a syntactically fixed arg count, so desugar to right-nested binary ops.
;; (str a b c)->(string-append a (string-append b c)); all comp's str args are
;; already strings (no ->string coercion needed). (list a b)->(cons a (cons b nil)).
(define str->app (lambda (as)
  (if (null? as) "" (if (null? (cdr as)) (car as) (list (quote string-append) (car as) (str->app (cdr as)))))))
(define list->cons (lambda (as)
  (if (null? as) (quote nil) (list (quote cons) (car as) (list->cons (cdr as))))))
;; builtin control forms (regular-Lisp derived forms; no vau, no macro system). Each
;; rewrites to core if/let/begin, then mexpand re-processes the result. (and)->t, (or)->nil.
;; or uses a temp so its test isn't double-evaluated; __or is reserved (nested ors shadow
;; safely -- the outer __or is consumed before the inner binding).
(define and->if (lambda (as)
  (if (null? as) (quote t)
    (if (null? (cdr as)) (car as)
      (list (quote if) (car as) (and->if (cdr as)) (quote nil))))))
(define or->if (lambda (as)
  (if (null? as) (quote nil)
    (if (null? (cdr as)) (car as)
      (list (quote let) (list (list (quote __or) (car as)))
        (list (quote if) (quote __or) (quote __or) (or->if (cdr as))))))))
(define when->if (lambda (c body) (list (quote if) c (cons (quote begin) body) (quote nil))))
(define unless->if (lambda (c body) (list (quote if) c (quote nil) (cons (quote begin) body))))
;; case: eval key ONCE (bound to __case), then a cond of eq? tests against quoted datum
;; literals; `else` -> the t clause. (__case reserved, like __or; nested cases shadow safely.)
(define case-clause (lambda (cl)
  (if (eq? (car cl) (quote else)) (cons (quote t) (cdr cl))
    (cons (list (quote eq?) (quote __case) (list (quote quote) (car cl))) (cdr cl)))))
(define case-clauses (lambda (cls) (if (null? cls) nil (cons (case-clause (car cls)) (case-clauses (cdr cls))))))
(define case->cond (lambda (key clauses)
  (list (quote let) (list (list (quote __case) key)) (cons (quote cond) (case-clauses clauses)))))
;; let*: sequential single-binding lets; (let* () body...) -> (begin body...).
(define let*->lets (lambda (binds body)
  (if (null? binds) (cons (quote begin) body)
    (list (quote let) (list (car binds)) (let*->lets (cdr binds) body)))))
;; n-ary arithmetic and chained comparisons, matching the bootstrap kernel's variadic prims
;; (the engines-suite migration caught (+ 1 2 (* 3 4)) silently compiling to (+ 1 2)).
;; Arithmetic left-folds onto the binary core ops: (+ a b c) -> (+ (+ a b) c); unary (+ a)/(* a)
;; are identity. Unary (- a) stays untouched (the kernel errors on it too). Comparisons bind
;; every operand ONCE in order (applicative, like the kernel prim), then AND adjacent tests:
;; (< a b c) -> (let ((__cmp0 a)) (let ((__cmp1 b)) (let ((__cmp2 c))
;;                (and (< __cmp0 __cmp1) (< __cmp1 __cmp2))))).
;; __cmpN is reserved like __or/__case: an inner chain's bindings are consumed before the
;; outer's next bind, so nesting shadows safely.
(define arith-op? (lambda (s) (if (eq? s (quote +)) t (if (eq? s (quote -)) t (eq? s (quote *))))))
(define cmp-op? (lambda (s) (if (eq? s (quote <)) t (if (eq? s (quote <=)) t (if (eq? s (quote =)) t (if (eq? s (quote >)) t (eq? s (quote >=))))))))
(define extra-args? (lambda (as) (if (null? as) nil (if (null? (cdr as)) nil (if (null? (cdr (cdr as))) nil t)))))
(define unary-args? (lambda (as) (if (null? as) nil (null? (cdr as)))))
(define nary->bin (lambda (op acc rest)
  (if (null? rest) acc (nary->bin op (list op acc (car rest)) (cdr rest)))))
(define cmp-names (lambda (as i)
  (if (null? as) nil
    (cons (string->symbol (string-append "__cmp" (number->string i))) (cmp-names (cdr as) (+ i 1))))))
(define cmp-pairs (lambda (op ns)
  (if (null? (cdr ns)) nil (cons (list op (car ns) (car (cdr ns))) (cmp-pairs op (cdr ns))))))
(define cmp-wrap (lambda (ns as body)
  (if (null? ns) body
    (list (quote let) (list (list (car ns) (car as))) (cmp-wrap (cdr ns) (cdr as) body)))))
(define chain->and (lambda (op as)
  (let ((ns (cmp-names as 0)))
    (cmp-wrap ns as (cons (quote and) (cmp-pairs op ns))))))
;; one small dispatcher pair so mexpand's if-chain grows by ONE level (comp compile time for a fn
;; grows steeply with chain depth).
(define nary-form? (lambda (f)
  (if (if (arith-op? (car f)) (extra-args? (cdr f)) nil) t
    (if (if (arith-op? (car f)) (unary-args? (cdr f)) nil) t
      (if (cmp-op? (car f)) (extra-args? (cdr f)) nil)))))
(define nary-rw (lambda (f)
  (if (if (arith-op? (car f)) (extra-args? (cdr f)) nil) (nary->bin (car f) (car (cdr f)) (cdr (cdr f)))
    (if (if (eq? (car f) (quote -)) (unary-args? (cdr f)) nil) (list (quote -) 0 (car (cdr f)))
      (if (arith-op? (car f)) (car (cdr f))
        (chain->and (car f) (cdr f)))))))
(define mexpand (lambda (f)
  (if (pair? f)
    (if (eq? (car f) (quote quote)) f
      ;; lambda: preserve the param list verbatim, mexpand only the body (a param named
      ;; cond/and/... is a BINDING, not that form -- else the param list gets rewritten and
      ;; the fn loses its params -> undefined G_<name> globals). cond/and/or/when/unless are
      ;; builtin DERIVED control forms: rewrite to core if/let/begin, then re-mexpand.
      (if (eq? (car f) (quote lambda)) (cons (quote lambda) (cons (car (cdr f)) (map-mexpand (cdr (cdr f)))))
      ;; define: preserve the NAME verbatim, mexpand only the value. The structural walk would
      ;; otherwise see (str (lambda ..)) inside (define str (lambda ..)) and desugar it as a (str ..)
      ;; FORM -- the define silently collapses (same for list/when/cond/...-named defines).
      (if (eq? (car f) (quote define)) (cons (quote define) (cons (car (cdr f)) (map-mexpand (cdr (cdr f)))))
      (if (eq? (car f) (quote cond)) (mexpand (cond->if (cdr f)))
      (if (eq? (car f) (quote and)) (mexpand (and->if (cdr f)))
      (if (eq? (car f) (quote or)) (mexpand (or->if (cdr f)))
      (if (eq? (car f) (quote when)) (mexpand (when->if (car (cdr f)) (cdr (cdr f))))
      (if (eq? (car f) (quote unless)) (mexpand (unless->if (car (cdr f)) (cdr (cdr f))))
      (if (eq? (car f) (quote case)) (mexpand (case->cond (car (cdr f)) (cdr (cdr f))))
      (if (eq? (car f) (quote let*)) (mexpand (let*->lets (car (cdr f)) (cdr (cdr f))))
      (if (nary-form? f)
        (mexpand (nary-rw f))
        (if (eq? (car f) (quote str)) (str->app (map-mexpand (cdr f)))
          (if (eq? (car f) (quote list)) (list->cons (map-mexpand (cdr f)))
            ;; function application: mexpand the OPERATOR, then map over the OPERANDS individually
            ;; (NOT recurse on (cdr f) as if it were a form -- that misreads an operand list whose
            ;; head is a special-form name, e.g. (g str 1), as a (str ...) call). Structural sharing:
            ;; if operator and every operand are unchanged, return f rather than re-consing.
            (let ((a (mexpand (car f))) (d (map-mexpand (cdr f))))
              (if (if (eq? a (car f)) (eq? d (cdr f)) nil) f (cons a d))))))))))))))))
    f)))
(define mexpand-program (lambda (forms) (map-mexpand forms)))

;; concat a list of line-lists into one (right-associated append -> O(total), vs
;; cp's old `(append subs newfn)` per fn which was O(n^2) in the line count).
(define concat (lambda (lol) (if (null? lol) nil (append (car lol) (concat (cdr lol))))))
;; cp compiles one fn at a time and APPENDS its output immediately (no accumulation),
;; then resets the heap bump pointer to `base` -- a fn's codegen garbage is dead once
;; its lines are emitted, so the slots get reused fn-to-fn (region reclamation). This
;; bounds the live heap to ONE function's worth instead of the whole program's.
;; `base` = heap mark taken AFTER the persistent setup (mexpanded source + elide-set +
;; header), so those survive every reset. nextk is read out BEFORE hreset (the cf pair
;; lives above base and is reclaimed; the k value it holds is an immediate, so it's safe
;; to carry across the reset).
(define cp (lambda (forms cmdpath lisppath k elide gfns gvars)
  (if (null? forms) (quote done)
    (begin
      ;; reclaim the PREVIOUS function's codegen garbage. At cp's entry the prior cf
      ;; is unreachable (dropped at the tail call); the roots (GLOBAL + this env ->
      ;; forms/k/elide -> the mexpanded source) are intact, so gc keeps them and
      ;; sweeps the dead intermediate cells. Bounds the heap to ~one function.
      (gc)
      (if (def-clambda? (car forms))
        ;; lifted closure sub -> its own <label>.cmd files; NO residual bind (called via K:).
        (let ((ce (caddr (car forms))))
          (begin
            (write-segs (compile-clambda (cadr (car forms)) (cadr ce) (caddr ce) (cadddr ce) gfns gvars) cmdpath)
            (cp (cdr forms) cmdpath lisppath k elide gfns gvars)))
      (if (def-lambda? (car forms))
        (let ((lbl (mangle (symbol->string (cadr (car forms))))))
          (let ((cf (compile-fn (cadr (car forms)) lbl (cadr (caddr (car forms))) (caddr (caddr (car forms))) k elide gfns gvars)))
            (let ((nextk (cdr cf)))
              (begin
                ;; multi-file: write THIS fn to its own <cmddir>/<label>.cmd (write-lines
                ;; truncates -> one file per fn). cmdpath is the output DIRECTORY now.
                (write-segs (car cf) cmdpath)
                (append-lines lisppath (cons (show (resid-bind (cadr (car forms)))) nil))
                (cp (cdr forms) cmdpath lisppath nextk elide gfns gvars)))))
        ;; atom constants are seeded into the header as G_<name>, so keep them OUT of
        ;; the residual (show can't re-quote a string literal -> unbound-symbol noise).
        (if (atom-const? (car forms))
          (cp (cdr forms) cmdpath lisppath k elide gfns gvars)
          (begin
            (append-lines lisppath (cons (show (car forms)) nil))
            (cp (cdr forms) cmdpath lisppath k elide gfns gvars)))))))))
;; a top-level (define X <atom>) -> a constant compiled fns read as G_X. (Only
;; atoms: a list-valued constant would rebuild itself on the heap every dispatch.)
(define atom-const? (lambda (f)
  (if (def-lambda? f) nil (if (pair? f) (if (eq? (car f) (quote define)) (not (pair? (caddr f))) nil) nil))))
(define const-inits (lambda (forms)
  (if (null? forms) nil
    (if (atom-const? (car forms))
      (cons (qset (str "G_" (symbol->string (cadr (car forms))) "=" (vref (cdr (lval (caddr (car forms)) nil (mkb nil nil 0 1 0 0) nil)))))
            (const-inits (cdr forms)))
      (const-inits (cdr forms))))))
;; The I/O runtime (:write-lines + :rdfield) is NOT emitted here -- it lives in a
;; hand-written, build-baked file (src/runtime.cmd) appended to every compiled.cmd.
;; It must reproduce its own decode patterns when comp compiles comp; a lossy decoder
;; can't, and if its placeholder (@B1@ etc) lived in comp's SOURCE it would land in
;; comp's compiled data and the link step would corrupt it. Keeping it a separate
;; file means comp's source/output never contains @B1@, so there's nothing to collide.
;; Compiled code just emits `call compiled.cmd write-lines` / `call :rdfield`.
;; inline-program is an OPTIMIZATION (inline small non-recursive helpers into call
;; sites). Skipped for now: on a big self-host input it inlines vref/aref/... into
;; cexpr's ~15 call sites, bloating generation time and output. Without it comp's
;; fns just `call` those helpers (correct, smaller, faster to generate). Re-enable
;; once self-host is proven and compiled-comp runtime speed matters.
;;; ---- call-graph reachability: which call targets need NO caller-saves.
;; A call F->G clobbers F's locals only if G can transitively RE-ENTER F, or shares
;; a var name (the latter is killed by per-function param naming below). G can
;; re-enter anyone only if G reaches a recursive fn (else F->G->...->F would itself
;; be a cycle, making F recursive). So: elide saves around a call to any G whose
;; reach-set contains no recursive fn. Computed once per program in compile-program.
(define mem? (lambda (x xs) (if (null? xs) nil (if (eq? x (car xs)) t (mem? x (cdr xs))))))
(define set-add (lambda (x xs) (if (mem? x xs) xs (cons x xs))))
;; free-variable analysis for flat closures: collect symbols referenced in a form that
;; are NOT bound by an enclosing lambda/let (over-collects globals/primitives; the caller
;; intersects with the enclosing pmap to get the real CAPTURE set -- globals aren't in it).
;; lambda/let extend `bound`; quote is opaque. Mirrors `callees` but visits every symbol.
(define lv-names (lambda (binds) (if (pair? binds) (cons (car (car binds)) (lv-names (cdr binds))) nil)))
(define fv-binds (lambda (binds bound acc) (if (pair? binds) (fv-binds (cdr binds) bound (fv (car (cdr (car binds))) bound acc)) acc)))
(define fv-list (lambda (fs bound acc) (if (pair? fs) (fv-list (cdr fs) bound (fv (car fs) bound acc)) acc)))
;; formals may be a SYMBOL (variadic rest-parameter: (lambda args body)) -- normalise to a
;; one-element list wherever a param LIST is expected; varargs? gates the codegen.
(define fs-list (lambda (fs) (if (symbol? fs) (cons fs nil) fs)))
(define varargs? (lambda (fs) (symbol? fs)))
(define fv (lambda (f bound acc)
  (if (pair? f)
    (if (eq? (car f) (quote quote)) acc
      (if (runop? (car f)) acc
        (if (eq? (car f) (quote lambda)) (fv (car (cdr (cdr f))) (append (fs-list (car (cdr f))) bound) acc)
          (if (eq? (car f) (quote let))
            (fv (car (cdr (cdr f))) (append (lv-names (car (cdr f))) bound) (fv-binds (car (cdr f)) bound acc))
            (fv-list f bound acc)))))
    (if (symbol? f) (if (mem? f bound) acc (set-add f acc)) acc))))
;; lambda-lift (flat closures): hoist each inline (lambda lf lb) to a top-level
;; (define __lamN (clambda lf cap lb)) and replace it with (make-closure (quote __lamN) cap...).
;; cap = free vars of the lambda bound in the ENCLOSING scope (fv ∩ bound). Returns
;; (form' lifted-defs next-ctr). Backend-independent -- byte-identical to compile-sh.lisp's lift.
(define keep-bound (lambda (fs bound) (if (null? fs) nil (if (mem? (car fs) bound) (cons (car fs) (keep-bound (cdr fs) bound)) (keep-bound (cdr fs) bound)))))
(define lift-list (lambda (fs bound ctr)
  (if (pair? fs)
    (let ((rh (lift (car fs) bound ctr)))
      (let ((rt (lift-list (cdr fs) bound (car (cdr (cdr rh))))))
        (list (cons (car rh) (car rt)) (append (car (cdr rh)) (car (cdr rt))) (car (cdr (cdr rt))))))
    (list fs nil ctr))))
(define lift (lambda (f bound ctr)
  (if (pair? f)
    (if (eq? (car f) (quote quote)) (list f nil ctr)
     (if (runop? (car f)) (list f nil ctr)
      (if (eq? (car f) (quote lambda))
        (let ((lf (car (cdr f))) (rb (lift (car (cdr (cdr f))) (append (fs-list (car (cdr f))) bound) ctr)))
          (let ((cap (keep-bound (fv (car rb) (fs-list lf) nil) bound)) (name (string->symbol (str "__lam" (number->string (car (cdr (cdr rb))))))))
            (list (cons (quote make-closure) (cons (list (quote quote) name) cap))
                  (append (car (cdr rb)) (list (list (quote define) name (list (quote clambda) lf cap (car rb)))))
                  (+ (car (cdr (cdr rb))) 1))))
        (lift-list f bound ctr))))
    (list f nil ctr))))
(define lift-program (lambda (forms ctr)
  (if (null? forms) nil
    (let ((d (car forms)))
      (if (if (pair? d) (if (eq? (car d) (quote define)) (if (pair? (car (cdr (cdr d)))) (eq? (car (car (cdr (cdr d)))) (quote lambda)) nil) nil) nil)
        (let ((nm (car (cdr d))) (lf (car (cdr (car (cdr (cdr d)))))) (bd (car (cdr (cdr (car (cdr (cdr d))))))))
          (let ((r (lift bd (fs-list lf) ctr)))
            (cons (list (quote define) nm (list (quote lambda) lf (car r)))
                  (append (car (cdr r)) (lift-program (cdr forms) (car (cdr (cdr r))))))))
        (cons d (lift-program (cdr forms) ctr)))))))
;; lift-program-c: like lift-program but RETURNS (lifted-forms . end-ctr), so the cmd interp REPL can
;; thread the lambda-lift counter across inputs (input N's __lamK must not overwrite N-1's live closures).
;; Backend-independent -- byte-identical to compile-sh.lisp's lift-program-c.
(define lift-program-c (lambda (forms ctr)
  (if (null? forms) (cons nil ctr)
    (let ((d (car forms)))
      (if (if (pair? d) (if (eq? (car d) (quote define)) (if (pair? (car (cdr (cdr d)))) (eq? (car (car (cdr (cdr d)))) (quote lambda)) nil) nil) nil)
        (let ((nm (car (cdr d))) (lf (car (cdr (car (cdr (cdr d)))))) (bd (car (cdr (cdr (car (cdr (cdr d))))))))
          (let ((r (lift bd (fs-list lf) ctr)))
            (let ((rest (lift-program-c (cdr forms) (car (cdr (cdr r))))))
              (cons (cons (list (quote define) nm (list (quote lambda) lf (car r)))
                          (append (car (cdr r)) (car rest)))
                    (cdr rest)))))
        (let ((rest (lift-program-c (cdr forms) ctr)))
          (cons (cons d (car rest)) (cdr rest))))))))
;; make-closure record builder + captured-var loads (cmd file-heap flavor: rdfield.cmd).
(define mkclo-caps (lambda (caps) (if (null? caps) (quote nil) (list (quote cons) (car caps) (mkclo-caps (cdr caps))))))
(define cap-loads-go (lambda (cap i)
  (if (null? cap) nil
    (append (list "for %%v in (!_cl!) do set /p R=<%HD%\car%%v" (qset (str "p" (number->string i) "=!R:~0,-1!")) "for %%v in (!_cl!) do set /p R=<%HD%\cdr%%v" (qset "_cl=!R:~2,-1!"))
            (cap-loads-go (cdr cap) (+ i 1))))))
(define cap-loads (lambda (cap np)
  (if (null? cap) nil (cons "for %%v in (!CLO!) do set /p R=<%HD%\cdr%%v" (cons (qset "_cl=!R:~2,-1!") (cap-loads-go cap np))))))
;; operator-position symbols in a body (over-collects; filtered to defined fns).
(define callees (lambda (f acc)
  (if (pair? f)
    (if (eq? (car f) (quote quote)) acc
      (let ((acc2 (if (symbol? (car f)) (set-add (car f) acc) acc)))
        (callees-list (cdr f) (callees (car f) acc2))))
    acc)))
(define callees-list (lambda (fs acc) (if (pair? fs) (callees-list (cdr fs) (callees (car fs) acc)) acc)))
(define defnames (lambda (forms) (if (null? forms) nil (if (def-lambda? (car forms)) (cons (cadr (car forms)) (defnames (cdr forms))) (defnames (cdr forms))))))
;; gvarnames: the known-global VARS (defines that are neither a lambda fn nor a lifted closure sub --
;; i.e. atom constants and computed defines, whose value lives in G_<name>). A reference to one of
;; these in OPERATOR position is a closure-bearing variable -> load !G_<name>! and apply (the named-
;; call path would `call` a label that doesn't exist). Mirror of compile-sh.lisp's gvar-names.
(define gvarnames (lambda (forms) (if (null? forms) nil (if (if (def-lambda? (car forms)) t (def-clambda? (car forms))) (gvarnames (cdr forms)) (if (eq? (car (car forms)) (quote define)) (cons (cadr (car forms)) (gvarnames (cdr forms))) (gvarnames (cdr forms)))))))
(define keep-defined (lambda (cs defs) (if (null? cs) nil (if (mem? (car cs) defs) (cons (car cs) (keep-defined (cdr cs) defs)) (keep-defined (cdr cs) defs)))))
(define fn-body (lambda (def) (caddr (caddr def))))
(define build-adj (lambda (forms defs)
  (if (null? forms) nil
    (if (def-lambda? (car forms))
      (cons (cons (cadr (car forms)) (keep-defined (callees (fn-body (car forms)) nil) defs)) (build-adj (cdr forms) defs))
      (build-adj (cdr forms) defs)))))
;; elide-set via peel-fixpoint: a fn is "clean" (calls to it need no caller-save)
;; iff ALL its defined-callees are clean -> it reaches no cycle. Leaves are clean;
;; a recursive fn's callees include itself, so it never becomes clean. This is the
;; same set as "reaches no recursive fn" but O(n*edges*depth), not O(n^4).
(define all-in? (lambda (xs set) (if (null? xs) t (if (mem? (car xs) set) (all-in? (cdr xs) set) nil))))
(define clean-pass (lambda (adj clean changed)
  (if (null? adj) (cons clean changed)
    (let ((nm (car (car adj))) (cs (cdr (car adj))))
      (if (mem? nm clean) (clean-pass (cdr adj) clean changed)
        (if (all-in? cs clean) (clean-pass (cdr adj) (cons nm clean) t) (clean-pass (cdr adj) clean changed)))))))
(define clean-fix (lambda (adj clean) (let ((r (clean-pass adj clean nil))) (if (cdr r) (clean-fix adj (car r)) (car r)))))
;; the elide-set is threaded to cexpr via a string-keyed marker in pmap (pvars skips it).
(define elide-of (lambda (pm) (let ((e (assoc "$ELIDE" pm))) (if (null? e) nil (cdr e)))))
;; the known-fns set rides in pmap under "$GFNS" (string key -> pvars skips it, like $ELIDE).
(define gfns-of (lambda (pm) (let ((e (assoc "$GFNS" pm))) (if (null? e) nil (cdr e)))))
(define compile-program (lambda (forms cmdpath lisppath)
  ;; mexpand derived forms first, THEN lambda-lift (hoist inline lambdas -> clambda subs +
  ;; make-closure sites). lift after mexpand so cond/let/etc are already core when fv runs.
  (let ((ms (lift-program (mexpand-program forms) 0)))
    (begin
      ;; multi-file: cmdpath is an output DIRECTORY. Each compiled fn -> <label>.cmd by cp.
      ;; Atom constants (G_<name>) -> _consts.cmd, called ONCE at startup. The TRAMPOLINE
      ;; codegen spills only the precise live set across each call, so the old reachability
      ;; elide analysis (defnames/build-adj/clean-fix -- O(n^2), the dominant comp(comp) cost)
      ;; is unnecessary; pass nil and skip it.
      (write-lines (str cmdpath "/_consts.cmd") (const-inits ms))
      (write-lines lisppath nil)
      (cp ms cmdpath lisppath 0 nil (defnames ms) (gvarnames ms))))))
