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
(define cmp->batch (lambda (o) (cond ((eq? o (quote <)) "LSS") ((eq? o (quote =)) "EQU") (t "?"))))
(define arith? (lambda (o) (if (eq? o (quote +)) t (if (eq? o (quote -)) t (eq? o (quote *))))))
;; predicates test-stmts can evaluate; in VALUE position we wrap them in an if so
;; the result becomes S:t / NIL (e.g. comp's is? returns (eq? (car f) h)).
(define tpred? (lambda (o) (cond ((eq? o (quote eq?)) t) ((eq? o (quote null?)) t) ((eq? o (quote pair?)) t)
  ((eq? o (quote number?)) t) ((eq? o (quote string?)) t) ((eq? o (quote symbol?)) t) ((eq? o (quote <)) t) ((eq? o (quote =)) t) (t nil))))
(define is? (lambda (f h) (if (pair? f) (eq? (car f) h) nil)))

;; ref kinds: lit (literal int) | raw (var, raw int) | val (var, tagged value) |
;; cst (a literal tagged value, e.g. NIL — carried verbatim).
(define aref (lambda (r) (cond ((eq? (car r) (quote lit)) (cdr r)) ((eq? (car r) (quote raw)) (cdr r)) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) ":~2!")))))
(define iref (lambda (r) (cond ((eq? (car r) (quote lit)) (cdr r)) ((eq? (car r) (quote raw)) (str "!" (cdr r) "!")) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) ":~2!")))))
(define vref (lambda (r) (cond ((eq? (car r) (quote lit)) (str "I:" (cdr r))) ((eq? (car r) (quote raw)) (str "I:!" (cdr r) "!")) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) "!")))))
;; cref: the CONTENT of a value (tag stripped) for string concat/retag. A cst
;; (T:lit) is stripped at compile time; a var (val) strips its 2-char tag at runtime.
(define cref (lambda (r) (if (eq? (car r) (quote cst)) (substring (cdr r) 2 (- (string-length (cdr r)) 2)) (str "!" (cdr r) ":~2!"))))
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
(define pvars (lambda (pm) (if (null? pm) nil (if (string? (car (car pm))) (pvars (cdr pm)) (cons (cdr (car pm)) (pvars (cdr pm)))))))
;; add a ref's VAR to the live set (caller-saved across calls). Only val/raw are
;; vars; lit and cst are literals (e.g. "S:if") -- saving them would emit bogus
;; `set STK..=!S:if!` / restore and corrupt state.
(define live-add (lambda (r live) (if (eq? (car r) (quote lit)) live (if (eq? (car r) (quote cst)) live (cons (cdr r) live)))))
;; qset: a QUOTED `set "VAR=VAL"`. Required for any value that may carry an operator
;; (S:< etc): an unquoted `set X=!v!` lets the < / > redirect (the kernel quotes too).
(define qset (lambda (body) (str "set " (dq) body (dq))))
(define save-lines (lambda (vs)
  (if (null? vs) nil (cons (qset (str "STK!SP!=!" (car vs) "!")) (cons "set /a SP+=1" (save-lines (cdr vs)))))))
(define restore-lines (lambda (vs)
  (if (null? vs) nil (cons "set /a SP-=1" (cons (str "call set " (dq) (car vs) "=%%STK!SP!%%" (dq)) (restore-lines (cdr vs)))))))

;; param vars are FUNCTION-UNIQUE (prefixed with the fn's label) so a call to a
;; different function can never clobber the caller's params by name -- only a real
;; re-entry can, which the reachability elide-set detects. (temps zt<k> are already
;; globally-unique-numbered.)
(define pmap-local  (lambda (fs lbl)   (if (null? fs) nil (cons (cons (car fs) (str lbl "_" (symbol->string (car fs)))) (pmap-local (cdr fs) lbl)))))
;; params arrive in the global A1.. vars (space/special-char safe via delayed
;; expansion; positional `call` args split on spaces). Read them in immediately,
;; before any nested call overwrites A1...
(define load-params (lambda (fs i lbl) (if (null? fs) nil (cons (qset (str lbl "_" (symbol->string (car fs)) "=!A" (number->string i) "!")) (load-params (cdr fs) (+ i 1) lbl)))))
(define aassign (lambda (vs i) (if (null? vs) nil (cons (qset (str "A" (number->string i) "=" (car vs))) (aassign (cdr vs) (+ i 1))))))

;; cexpr: value-position expr -> (list lines ref next-k). arithmetic -> a raw
;; temp; a call -> compute args (tagged), call, take the tagged R into a val temp.
;; cquote: compile (quote DATUM). Atoms become a cst of the tagged literal
;; (symbol->S:, number->I:, nil->NIL, string->T:), metachars/operators in the
;; name run through enc-mc. A pair is built at runtime by desugaring to cons of
;; the quoted car and quoted cdr, reusing the cons codegen.
;; Codegen threads `acc` = all emitted lines so far, in REVERSE order (cons is O(1);
;; append re-copies). Each fn takes acc and returns it extended; compile-fn reverses
;; once. `(rev fwd acc)` appends a forward fragment; `(cons line acc)` appends one line.
(define cquote (lambda (d pmap k live acc)
  (cond ((null? d) (list acc (cons (quote cst) "NIL") k))
        ((pair? d) (cexpr (list (quote cons) (list (quote quote) (car d)) (list (quote quote) (cdr d))) pmap k live acc))
        ((number? d) (list acc (cons (quote lit) (number->string d)) k))
        ((string? d) (list acc (cons (quote cst) (str "T:" (enc-mc d))) k))
        (t (list acc (cons (quote cst) (str "S:" (enc-mc (symbol->string d)))) k)))))
;; cbegin: (begin e1..en) -> run each in order (discarding all but the last's
;; value); the last expr supplies the result ref.
(define cbegin (lambda (es pmap k live acc)
  (if (null? (cdr es)) (cexpr (car es) pmap k live acc)
    (let ((r1 (cexpr (car es) pmap k live acc)))
      (cbegin (cdr es) pmap (caddr r1) live (car r1))))))
(define cexpr (lambda (f pmap k live acc)
  (cond
    ((number? f) (list acc (cons (quote lit) (number->string f)) k))
    ((eq? f (quote nil)) (list acc (cons (quote cst) "NIL") k))
    ((eq? f (quote t)) (list acc (cons (quote cst) "S:t") k))
    ((string? f) (list acc (cons (quote cst) (str "T:" (enc-mc f))) k))
    ((symbol? f) (let ((e (assoc f pmap)))
                   ;; param/local -> its temp var; otherwise a top-level constant,
                   ;; held in a G_<name> cmd var seeded by the dispatch header.
                   (list acc (cons (quote val) (if (null? e) (str "G_" (symbol->string f)) (cdr e))) k)))
    ((eq? (car f) (quote quote)) (cquote (cadr f) pmap k live acc))
    ((eq? (car f) (quote begin)) (cbegin (cdr f) pmap k live acc))
    ((arith? (car f))
       (let ((ra (cexpr (cadr f) pmap k live acc)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (cons (str "set /a " tmp "=" (aref (cadr ra)) (op->batch (car f)) (aref (cadr rb))) (car rb))
                   (cons (quote raw) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote cons))
       ;; file-backed heap: cell HN = files %HD%\car<HN>/cdr<HN>. Redirect PATH uses
       ;; %HN% (immediate; re-expands per line execution, incl goto-loops); the value
       ;; is delayed content of `echo(` so operators/parens in it never re-tokenize.
       ;; Trailing GUARD byte (#): set /p (rdfield) strips trailing control bytes
       ;; (0x01=! 0x08="); the guard absorbs that strip so values ending in !/" survive.
       (let ((ra (cexpr (cadr f) pmap k live acc)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (rev (list (str ">%HD%\car%HN% echo(" (vref (cadr ra)) "#") (str ">%HD%\cdr%HN% echo(" (vref (cadr rb)) "#"))
                              (qset (str "" tmp "=P:!HN!")) "set /a HN+=1") (car rb))
                   (cons (quote val) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote car)) (ccell f "car" pmap k live acc))
    ((eq? (car f) (quote cdr)) (ccell f "cdr" pmap k live acc))
    ((eq? (car f) (quote symbol->string)) (cretag f pmap k live acc))
    ((eq? (car f) (quote number->string)) (cretag f pmap k live acc))
    ((eq? (car f) (quote string-append))
       ;; (string-append a b) -> T:<content-a><content-b>
       (let ((ra (cexpr (cadr f) pmap k live acc)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (cons (qset (str "" tmp "=T:" (cref (cadr ra)) (cref (cadr rb)))) (car rb))
                   (cons (quote val) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote string-length)) (cstrlen f pmap k live acc))
    ((eq? (car f) (quote substring)) (csubstr f pmap k live acc))
    ((eq? (car f) (quote dq)) (let ((tmp (str "zt" (number->string k)))) (list (cons (qset (str "" tmp "=T:!BANG8!")) acc) (cons (quote val) tmp) (+ k 1))))
    ((tpred? (car f)) (cexpr (list (quote if) f (list (quote quote) (quote t)) (quote nil)) pmap k live acc))
    ((eq? (car f) (quote let))
       ;; (let ((x v) ...) body): materialise each value into a temp, bind name->temp
       ;; in pmap, compile body. clet-binds threads k, pmap, AND acc.
       (let ((bs (clet-binds (cadr f) pmap k live acc)))
         (cexpr (caddr f) (cadr bs) (caddr bs) live (car bs))))
    ((eq? (car f) (quote if))
       ;; value-position if: test branches to the then-label; both arms set the
       ;; same result temp; fall-through is the else arm. The else arm (the deep
       ;; cond-chain) is THREADED (no copy); the then arm (small) is compiled with a
       ;; fresh acc and appended once -- keeps rt's numbering and order byte-identical.
       (let ((tl (str "zT" (number->string k))) (dl (str "zE" (number->string k))))
         (let ((tr (test-stmts (cadr f) tl pmap (+ k 1) live acc)))
           (let ((rb (cexpr (cadddr f) pmap (cdr tr) live (car tr))))
             (let ((ra (cexpr (caddr f) pmap (caddr rb) live nil)))
               (let ((rt (str "zt" (number->string (caddr ra)))))
                 (list (rev (list (qset (str "" rt "=" (vref (cadr ra)))) (str ":" dl))
                         (append (car ra)
                           (rev (list (qset (str "" rt "=" (vref (cadr rb)))) (str "goto " dl) (str ":" tl)) (car rb))))
                       (cons (quote val) rt) (+ (caddr ra) 1))))))))
    (t (let ((ar (cargs* (cdr f) pmap k live acc)))
         ;; elide caller-saves entirely when the callee can't re-enter us (reachability).
         (let ((tmp (str "zt" (number->string (caddr ar)))) (sv (if (mem? (car f) (elide-of pmap)) nil (append (pvars pmap) live))))
           (list (rev (append (save-lines sv)
                        (append (aassign (cadr ar) 1)
                          ;; multi-file: each compiled fn is its own <label>.cmd, so a
                          ;; call is `call <label>.cmd` (cwd-relative). cmd's label scan is
                          ;; O(file-position), so one-fn-per-file keeps every entry at the
                          ;; top -> ~1ms flat, vs ~30-59ms in a single 8900-line file.
                          (cons (str "call " (mangle (symbol->string (car f))) ".cmd")
                            (append (restore-lines (rev sv nil)) (list (qset (str "" tmp "=!R!")))))))
                      (car ar))
                 (cons (quote val) tmp) (+ (caddr ar) 1))))))))
;; string-length: count chars by stripping one at a time (no batch strlen). The
;; content goes in via cref (delayed expansion, operator-safe); `if defined` ends
;; the loop when empty (avoids comparing content, which could hold operators/"").
(define cstrlen (lambda (f pmap k live acc)
  (let ((rx (cexpr (cadr f) pmap k live acc)))
    (let ((j (number->string (caddr rx))))
      (let ((zc (str "zc" j)) (zn (str "zt" (number->string (+ (caddr rx) 1)))) (lp (str "zSL" j)))
        (list (rev (list (qset (str "" zc "=" (cref (cadr rx))))
                         (str "set /a " zn "=0")
                         (str ":" lp)
                         (str "if defined " zc " (set " zc "=!" zc ":~1!& set /a " zn "+=1& goto " lp ")")) (car rx))
              (cons (quote raw) zn) (+ (caddr rx) 2)))))))
;; substring: (substring s start len). Dynamic offsets can't use !v:~i,n! (i/n must
;; be literal) and the `call set %%v:~%i%,%n%%%` form would put an operator char into
;; command text. So walk char by char: skip `start`, then append `len` chars built
;; from !zc:~0,1! -- every char moves through delayed expansion, so operators survive.
(define csubstr (lambda (f pmap k live acc)
  (let ((rs (cexpr (cadr f) pmap k live acc)))
    (let ((rb (cexpr (caddr f) pmap (caddr rs) (live-add (cadr rs) live) (car rs))))
      (let ((rl (cexpr (cadddr f) pmap (caddr rb) (live-add (cadr rb) (live-add (cadr rs) live)) (car rb))))
        (let ((j (number->string (caddr rl))))
          (let ((zc (str "zc" j)) (zsk (str "zsk" j)) (ztk (str "ztk" j)) (zr (str "zr" j))
                (ztmp (str "zt" (number->string (+ (caddr rl) 1)))) (sk (str "zSK" j)) (tk (str "zTK" j)))
            (list (rev (list (qset (str "" zc "=" (cref (cadr rs))))
                             (str "set /a " zsk "=" (aref (cadr rb)))
                             (str ":" sk)
                             (str "if defined " zc " if !" zsk "! gtr 0 (set " zc "=!" zc ":~1!& set /a " zsk "-=1& goto " sk ")")
                             (qset (str "" zr "="))
                             (str "set /a " ztk "=" (aref (cadr rl)))
                             (str ":" tk)
                             (str "if defined " zc " if !" ztk "! gtr 0 (set " zr "=!" zr "!!" zc ":~0,1!& set " zc "=!" zc ":~1!& set /a " ztk "-=1& goto " tk ")")
                             (qset (str "" ztmp "=T:!" zr "!"))) (car rl))
                  (cons (quote val) ztmp) (+ (caddr rl) 2)))))))))
;; cretag: symbol->string / number->string -- the content is unchanged, only the
;; 2-char tag becomes T:. set zt=T:<content of arg>.
(define cretag (lambda (f pmap k live acc)
  (let ((rx (cexpr (cadr f) pmap k live acc)))
    (let ((tmp (str "zt" (number->string (caddr rx)))))
      (list (cons (qset (str "" tmp "=T:" (cref (cadr rx)))) (car rx)) (cons (quote val) tmp) (+ (caddr rx) 1))))))
;; car/cdr: strip P: from the (val) operand to an index, then read CAR_/CDR_<idx>.
(define ccell (lambda (f field pmap k live acc)
  (let ((rx (cexpr (cadr f) pmap k live acc)))
    (let ((zi (str "zi" (number->string (caddr rx)))) (tmp (str "zt" (number->string (+ (caddr rx) 1)))))
      ;; read CAR_/CDR_<idx> via :rdfield (set R=!FIELD<idx>!, delayed -> operator-safe);
      ;; `call set tmp=%%FIELD!zi!%%` would re-parse the value unquoted and a & | < >
      ;; in it would split the line.
      (list (rev (list (qset (str "" zi "=!" (cdr (cadr rx)) ":~2!"))
                       (str "call rdfield.cmd " field " !" zi "!")
                       (qset (str "" tmp "=!R!"))) (car rx))
            (cons (quote val) tmp) (+ (caddr rx) 2))))))
;; cargs*: evaluate call args left-to-right -> (list lines (vref1 vref2 ...) k).
;; Each arg is evaluated with the earlier args' temps added to `live`, so a call
;; inside a later arg won't clobber an already-computed arg.
(define cargs* (lambda (as pmap k live acc)
  (if (null? as) (list acc nil k)
    (let ((r (cexpr (car as) pmap k live acc)))
      (let ((rest (cargs* (cdr as) pmap (caddr r) (live-add (cadr r) live) (car r))))
        (list (car rest) (cons (vref (cadr r)) (cadr rest)) (caddr rest)))))))
;; clet-binds: compile each (name value) binding -> materialise value into a temp,
;; extend pmap with name->temp. Returns (list lines extended-pmap nextk). Each later
;; binding's value sees the earlier bindings (sequential let, like let*).
(define clet-binds (lambda (binds pmap k live acc)
  (if (null? binds) (list acc pmap k)
    (let ((b (car binds)))
      (let ((rv (cexpr (cadr b) pmap k live acc)))
        (let ((tmp (str "zt" (number->string (caddr rv)))))
          (clet-binds (cdr binds) (cons (cons (car b) tmp) pmap) (+ (caddr rv) 1) (cons tmp live)
            (cons (qset (str "" tmp "=" (vref (cadr rv)))) (car rv)))))))))
(define uassign (lambda (vs i) (if (null? vs) nil (cons (qset (str "zu" (number->string i) "=" (car vs))) (uassign (cdr vs) (+ i 1))))))
(define pupd (lambda (ps i lbl) (if (null? ps) nil (cons (qset (str lbl "_" (symbol->string (car ps)) "=!zu" (number->string i) "!")) (pupd (cdr ps) (+ i 1) lbl)))))
;; test of an `if` -> lines ending in a `if ... goto TL`. Numeric (< =) compares
;; raw numbers; eq?/null? compare tagged values as strings (quote-free, so
;; space-free values only — symbols/NIL/numbers/pairs); pair? checks the P: tag.
;; tag-prefix predicate (pair?/number?/string?/symbol?): materialise the operand
;; into a temp (works for a var or a literal), then branch to TL if its first char
;; equals the tag letter (P/I/T/S).
(define ctag-test (lambda (test tl pmap k ch live acc)
  (let ((rx (cexpr (cadr test) pmap k live acc)))
    (let ((zt (str "zp" (number->string (caddr rx)))))
      ;; substring must be done in a `set` -- a `:~0,1` inside `if` breaks (the
      ;; comma is a token delimiter there). Materialise the value, slice to its
      ;; first char in place, then compare the whole short var.
      (cons (rev (list (qset (str "" zt "=" (vref (cadr rx))))
                       (qset (str "" zt "=!" zt ":~0,1!"))
                       (str "if !" zt "!==" ch " goto " tl)) (car rx)) (+ (caddr rx) 1))))))
;; test of an `if`. If it's a pair headed by a known predicate/comparison, emit the
;; specialised compare; OTHERWISE (a variable, or any other call -- e.g.
;; (if (def-lambda? f) ..), (if x ..)) it's a TRUTHINESS test: evaluate it and branch
;; to TL when the value is not NIL.
(define test-stmts (lambda (test tl pmap k live acc)
  (if (if (pair? test) (tpred? (car test)) nil)
    (let ((op (car test)))
    (cond
      ((eq? op (quote null?))
        (let ((rx (cexpr (cadr test) pmap k live acc)))
          ;; MUST quote: an unquoted `if !v!==NIL` with a < or > in the value triggers
          ;; a redirection (< is not just a separator like &). The " come from dq;
          ;; write-lines handles " in the generated code.
          (let ((q (dq)))
            (cons (cons (str "if " q (vref (cadr rx)) q "==" q "NIL" q " goto " tl) (car rx)) (caddr rx)))))
      ((eq? op (quote pair?)) (ctag-test test tl pmap k "P" live acc))
      ((eq? op (quote number?)) (ctag-test test tl pmap k "I" live acc))
      ((eq? op (quote string?)) (ctag-test test tl pmap k "T" live acc))
      ((eq? op (quote symbol?)) (ctag-test test tl pmap k "S" live acc))
      ((eq? op (quote eq?))
        (let ((ra (cexpr (cadr test) pmap k live acc)))
          (let ((rb (cexpr (caddr test) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
            (let ((q (dq)))
              (cons (cons (str "if " q (vref (cadr ra)) q "==" q (vref (cadr rb)) q " goto " tl) (car rb)) (caddr rb))))))
      (t
        (let ((ra (cexpr (cadr test) pmap k live acc)))
          (let ((rb (cexpr (caddr test) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
            (cons (cons (str "if " (iref (cadr ra)) " " (cmp->batch op) " " (iref (cadr rb)) " goto " tl) (car rb)) (caddr rb)))))))
    (let ((rx (cexpr test pmap k live acc)))
      (let ((q (dq)))
        (cons (cons (str "if not " q (vref (cadr rx)) q "==" q "NIL" q " goto " tl) (car rx)) (caddr rx)))))))
;; ctail: tail position. self-call -> args into zu temps, update params, goto top;
;; if -> goto-branch; else -> set R to the tagged value, return.
(define ctail-begin (lambda (es nm lbl ps pmap k acc)
  (if (null? (cdr es)) (ctail (car es) nm lbl ps pmap k acc)
    (let ((r1 (cexpr (car es) pmap k nil acc)))
      (ctail-begin (cdr es) nm lbl ps pmap (caddr r1) (car r1))))))
(define ctail (lambda (f nm lbl ps pmap k acc)
  (cond
    ((is? f (quote begin)) (ctail-begin (cdr f) nm lbl ps pmap k acc))
    ((is? f nm)
       (let ((ar (cargs* (cdr f) pmap k nil acc)))
         (cons (rev (append (uassign (cadr ar) 1) (append (pupd ps 1 lbl) (list (str "goto " lbl "_top")))) (car ar)) (caddr ar))))
    ((is? f (quote if))
       ;; else arm threaded (deep cond-chain), then arm compiled fresh + appended (small).
       (let ((tl (str lbl "_L" (number->string k))))
         (let ((tr (test-stmts (cadr f) tl pmap (+ k 1) nil acc)))
           (let ((er (ctail (cadddr f) nm lbl ps pmap (cdr tr) (car tr))))
             (let ((th (ctail (caddr f) nm lbl ps pmap (cdr er) nil)))
               (cons (append (car th) (cons (str ":" tl) (car er))) (cdr th)))))))
    ((is? f (quote let))
       (let ((bs (clet-binds (cadr f) pmap k nil acc)))
         (ctail (caddr f) nm lbl ps (cadr bs) (caddr bs) (car bs))))
    (t (let ((r (cexpr f pmap k nil acc))) (cons (rev (list (qset (str "R=" (vref (cadr r)))) "goto :eof") (car r)) (caddr r)))))))

;; k0 is the program-wide monotonic label/temp counter: cexpr-level labels (zT/zE
;; value-if, zSL/zSK/zTK loops) are NOT function-prefixed, so `goto` would hit the
;; first match in the file. Threading one k across all fns keeps every label unique.
;; Returns (cons lines next-k).
(define compile-fn (lambda (nm lbl fs body k0 elide)
  ;; ctail accumulates body lines in REVERSE; reverse once here, then prepend the header.
  (let ((tb (ctail body nm lbl fs (cons (cons "$ELIDE" elide) (pmap-local fs lbl)) k0 nil)))
    (cons (append (cons (str ":" lbl) (load-params fs 1 lbl)) (cons (str ":" lbl "_top") (rev (car tb) nil))) (cdr tb)))))

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
(define map-mexpand (lambda (xs) (if (null? xs) nil (cons (mexpand (car xs)) (map-mexpand (cdr xs))))))
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
(define cond->if (lambda (cls)
  (if (null? cls) (quote nil)
    (if (eq? (car (car cls)) (quote t)) (cadr (car cls))
      (list (quote if) (car (car cls)) (cadr (car cls)) (cond->if (cdr cls)))))))
;; str/list are variadic; the compiler is fixed-arity. comp only ever calls them
;; with a syntactically fixed arg count, so desugar to right-nested binary ops.
;; (str a b c)->(string-append a (string-append b c)); all comp's str args are
;; already strings (no ->string coercion needed). (list a b)->(cons a (cons b nil)).
(define str->app (lambda (as)
  (if (null? as) "" (if (null? (cdr as)) (car as) (list (quote string-append) (car as) (str->app (cdr as)))))))
(define list->cons (lambda (as)
  (if (null? as) (quote nil) (list (quote cons) (car as) (list->cons (cdr as))))))
(define mexpand (lambda (f)
  (if (pair? f)
    (if (eq? (car f) (quote quote)) f
      (if (eq? (car f) (quote cond)) (mexpand (cond->if (cdr f)))
        (if (eq? (car f) (quote str)) (str->app (map-mexpand (cdr f)))
          (if (eq? (car f) (quote list)) (list->cons (map-mexpand (cdr f)))
            ;; structural sharing: if neither sub-tree changed, return f rather than
            ;; re-consing. comp's source is mostly untouched by mexpand (only
            ;; cond/str/list rewrite), so this avoids copying nearly the whole tree.
            (let ((a (mexpand (car f))) (d (mexpand (cdr f))))
              (if (if (eq? a (car f)) (eq? d (cdr f)) nil) f (cons a d)))))))
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
(define cp (lambda (forms cmdpath lisppath k elide)
  (if (null? forms) (quote done)
    (begin
      ;; reclaim the PREVIOUS function's codegen garbage. At cp's entry the prior cf
      ;; is unreachable (dropped at the tail call); the roots (GLOBAL + this env ->
      ;; forms/k/elide -> the mexpanded source) are intact, so gc keeps them and
      ;; sweeps the dead intermediate cells. Bounds the heap to ~one function.
      (gc)
      (if (def-lambda? (car forms))
        (let ((lbl (mangle (symbol->string (cadr (car forms))))))
          (let ((cf (compile-fn (cadr (car forms)) lbl (cadr (caddr (car forms))) (caddr (caddr (car forms))) k elide)))
            (let ((nextk (cdr cf)))
              (begin
                ;; multi-file: write THIS fn to its own <cmddir>/<label>.cmd (write-lines
                ;; truncates -> one file per fn). cmdpath is the output DIRECTORY now.
                (write-lines (str cmdpath "/" lbl ".cmd") (car cf))
                (append-lines lisppath (cons (show (resid-bind (cadr (car forms)))) nil))
                (cp (cdr forms) cmdpath lisppath nextk elide)))))
        ;; atom constants are seeded into the header as G_<name>, so keep them OUT of
        ;; the residual (show can't re-quote a string literal -> unbound-symbol noise).
        (if (atom-const? (car forms))
          (cp (cdr forms) cmdpath lisppath k elide)
          (begin
            (append-lines lisppath (cons (show (car forms)) nil))
            (cp (cdr forms) cmdpath lisppath k elide))))))))
;; a top-level (define X <atom>) -> a constant compiled fns read as G_X. (Only
;; atoms: a list-valued constant would rebuild itself on the heap every dispatch.)
(define atom-const? (lambda (f)
  (if (def-lambda? f) nil (if (pair? f) (if (eq? (car f) (quote define)) (not (pair? (caddr f))) nil) nil))))
(define const-inits (lambda (forms)
  (if (null? forms) nil
    (if (atom-const? (car forms))
      (cons (qset (str "G_" (symbol->string (cadr (car forms))) "=" (vref (cadr (cexpr (caddr (car forms)) nil 0 nil nil)))))
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
;; operator-position symbols in a body (over-collects; filtered to defined fns).
(define callees (lambda (f acc)
  (if (pair? f)
    (if (eq? (car f) (quote quote)) acc
      (let ((acc2 (if (symbol? (car f)) (set-add (car f) acc) acc)))
        (callees-list (cdr f) (callees (car f) acc2))))
    acc)))
(define callees-list (lambda (fs acc) (if (pair? fs) (callees-list (cdr fs) (callees (car fs) acc)) acc)))
(define defnames (lambda (forms) (if (null? forms) nil (if (def-lambda? (car forms)) (cons (cadr (car forms)) (defnames (cdr forms))) (defnames (cdr forms))))))
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
(define compile-program (lambda (forms cmdpath lisppath)
  (let ((ms (mexpand-program forms)))
    (let ((defs (defnames ms)))
      (let ((elide (clean-fix (build-adj ms defs) nil)))
        (begin
          ;; multi-file: cmdpath is an output DIRECTORY (must exist). Each compiled fn is
          ;; written there as <label>.cmd by cp. The top-level atom constants (G_<name>),
          ;; which used to live in the single file's header, go in _consts.cmd -- `call`ed
          ;; ONCE at startup to seed the G_ env vars (inherited by every fn file in-process).
          (write-lines (str cmdpath "/_consts.cmd") (const-inits ms))
          (write-lines lisppath nil)
          (cp ms cmdpath lisppath 0 elide)))))))
