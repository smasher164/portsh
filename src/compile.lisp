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

;; --- caller-saves for general (non-tail) calls. Compiled fns have no setlocal
;; (so the shared heap survives across calls), which means a call clobbers the
;; caller's param/temp vars. Around every general call we push the caller's live
;; vars onto a global stack (STK/SP) and pop them back after. `live` is the set of
;; enclosing temp vars threaded through cexpr; params are added at the call site.
(define rev (lambda (xs acc) (if (null? xs) acc (rev (cdr xs) (cons (car xs) acc)))))
(define pvars (lambda (pm) (if (null? pm) nil (cons (cdr (car pm)) (pvars (cdr pm))))))
(define live-add (lambda (r live) (if (eq? (car r) (quote lit)) live (cons (cdr r) live))))
(define save-lines (lambda (vs)
  (if (null? vs) nil (cons (str "set STK!SP!=!" (car vs) "!") (cons "set /a SP+=1" (save-lines (cdr vs)))))))
(define restore-lines (lambda (vs)
  (if (null? vs) nil (cons "set /a SP-=1" (cons (str "call set " (car vs) "=%%STK!SP!%%") (restore-lines (cdr vs)))))))

(define pmap-local  (lambda (fs)   (if (null? fs) nil (cons (cons (car fs) (symbol->string (car fs))) (pmap-local (cdr fs))))))
;; params arrive in the global A1.. vars (space/special-char safe via delayed
;; expansion; positional `call` args split on spaces). Read them in immediately,
;; before any nested call overwrites A1...
(define load-params (lambda (fs i) (if (null? fs) nil (cons (str "set " (symbol->string (car fs)) "=!A" (number->string i) "!") (load-params (cdr fs) (+ i 1))))))
(define aassign (lambda (vs i) (if (null? vs) nil (cons (str "set A" (number->string i) "=" (car vs)) (aassign (cdr vs) (+ i 1))))))

;; cexpr: value-position expr -> (list lines ref next-k). arithmetic -> a raw
;; temp; a call -> compute args (tagged), call, take the tagged R into a val temp.
;; cquote: compile (quote DATUM). Atoms become a cst of the tagged literal
;; (symbol->S:, number->I:, nil->NIL, string->T:), metachars/operators in the
;; name run through enc-mc. A pair is built at runtime by desugaring to cons of
;; the quoted car and quoted cdr, reusing the cons codegen.
(define cquote (lambda (d pmap k live)
  (cond ((null? d) (list nil (cons (quote cst) "NIL") k))
        ((pair? d) (cexpr (list (quote cons) (list (quote quote) (car d)) (list (quote quote) (cdr d))) pmap k live))
        ((number? d) (list nil (cons (quote lit) (number->string d)) k))
        ((string? d) (list nil (cons (quote cst) (str "T:" (enc-mc d))) k))
        (t (list nil (cons (quote cst) (str "S:" (enc-mc (symbol->string d)))) k)))))
;; cbegin: (begin e1..en) -> run each in order (discarding all but the last's
;; value); the last expr supplies the result ref.
(define cbegin (lambda (es pmap k live)
  (if (null? (cdr es)) (cexpr (car es) pmap k live)
    (let ((r1 (cexpr (car es) pmap k live)))
      (let ((rr (cbegin (cdr es) pmap (caddr r1) live)))
        (list (append (car r1) (car rr)) (cadr rr) (caddr rr)))))))
(define cexpr (lambda (f pmap k live)
  (cond
    ((number? f) (list nil (cons (quote lit) (number->string f)) k))
    ((eq? f (quote nil)) (list nil (cons (quote cst) "NIL") k))
    ((string? f) (list nil (cons (quote cst) (str "T:" (enc-mc f))) k))
    ((symbol? f) (let ((e (assoc f pmap)))
                   ;; param/local -> its temp var; otherwise a top-level constant,
                   ;; held in a G_<name> cmd var seeded by the dispatch header.
                   (list nil (cons (quote val) (if (null? e) (str "G_" (symbol->string f)) (cdr e))) k)))
    ((eq? (car f) (quote quote)) (cquote (cadr f) pmap k live))
    ((eq? (car f) (quote begin)) (cbegin (cdr f) pmap k live))
    ((arith? (car f))
       (let ((ra (cexpr (cadr f) pmap k live)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (append (car ra) (append (car rb) (list (str "set /a " tmp "=" (aref (cadr ra)) (op->batch (car f)) (aref (cadr rb))))))
                   (cons (quote raw) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote cons))
       (let ((ra (cexpr (cadr f) pmap k live)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (append (car ra) (append (car rb)
                     (list (str "set CAR_!HN!=" (vref (cadr ra))) (str "set CDR_!HN!=" (vref (cadr rb)))
                           (str "set " tmp "=P:!HN!") "set /a HN+=1")))
                   (cons (quote val) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote car)) (ccell f "CAR_" pmap k live))
    ((eq? (car f) (quote cdr)) (ccell f "CDR_" pmap k live))
    ((eq? (car f) (quote symbol->string)) (cretag f pmap k live))
    ((eq? (car f) (quote number->string)) (cretag f pmap k live))
    ((eq? (car f) (quote string-append))
       ;; (string-append a b) -> T:<content-a><content-b>
       (let ((ra (cexpr (cadr f) pmap k live)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (append (car ra) (append (car rb) (list (str "set " tmp "=T:" (cref (cadr ra)) (cref (cadr rb))))))
                   (cons (quote val) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote string-length)) (cstrlen f pmap k live))
    ((eq? (car f) (quote substring)) (csubstr f pmap k live))
    ((eq? (car f) (quote dq)) (let ((tmp (str "zt" (number->string k)))) (list (list (str "set " tmp "=T:!BANG8!")) (cons (quote val) tmp) (+ k 1))))
    ((tpred? (car f)) (cexpr (list (quote if) f (list (quote quote) (quote t)) (quote nil)) pmap k live))
    ((eq? (car f) (quote let))
       ;; (let ((x v) ...) body): materialise each value into a temp, bind name->temp
       ;; in pmap, compile body. clet-binds threads k and grows pmap.
       (let ((bs (clet-binds (cadr f) pmap k live)))
         (let ((rb (cexpr (caddr f) (cadr bs) (caddr bs) live)))
           (list (append (car bs) (car rb)) (cadr rb) (caddr rb)))))
    ((eq? (car f) (quote if))
       ;; value-position if: test branches to the then-label; both arms set the
       ;; same result temp; fall-through is the else arm. Labels keyed on the
       ;; entry k (monotonic, so unique even when ifs nest).
       (let ((tl (str "zT" (number->string k))) (dl (str "zE" (number->string k))))
         (let ((tr (test-stmts (cadr f) tl pmap (+ k 1) live)))
           (let ((rb (cexpr (cadddr f) pmap (cdr tr) live)))
             (let ((ra (cexpr (caddr f) pmap (caddr rb) live)))
               (let ((rt (str "zt" (number->string (caddr ra)))))
                 (list (append (car tr)
                         (append (car rb)
                           (append (list (str "set " rt "=" (vref (cadr rb))) (str "goto " dl) (str ":" tl))
                             (append (car ra)
                               (list (str "set " rt "=" (vref (cadr ra))) (str ":" dl))))))
                       (cons (quote val) rt) (+ (caddr ra) 1))))))))
    (t (let ((ar (cargs* (cdr f) pmap k live)))
         (let ((tmp (str "zt" (number->string (caddr ar)))) (sv (append (pvars pmap) live)))
           (list (append (car ar)
                   (append (save-lines sv)
                     (append (aassign (cadr ar) 1)
                       (cons (str "call compiled.cmd " (symbol->string (car f)))
                         (append (restore-lines (rev sv nil)) (list (str "set " tmp "=!R!")))))))
                 (cons (quote val) tmp) (+ (caddr ar) 1))))))))
;; string-length: count chars by stripping one at a time (no batch strlen). The
;; content goes in via cref (delayed expansion, operator-safe); `if defined` ends
;; the loop when empty (avoids comparing content, which could hold operators/"").
(define cstrlen (lambda (f pmap k live)
  (let ((rx (cexpr (cadr f) pmap k live)))
    (let ((j (number->string (caddr rx))))
      (let ((zc (str "zc" j)) (zn (str "zt" (number->string (+ (caddr rx) 1)))) (lp (str "zSL" j)))
        (list (append (car rx)
                (list (str "set " zc "=" (cref (cadr rx)))
                      (str "set /a " zn "=0")
                      (str ":" lp)
                      (str "if defined " zc " (set " zc "=!" zc ":~1!& set /a " zn "+=1& goto " lp ")")))
              (cons (quote raw) zn) (+ (caddr rx) 2)))))))
;; substring: (substring s start len). Dynamic offsets can't use !v:~i,n! (i/n must
;; be literal) and the `call set %%v:~%i%,%n%%%` form would put an operator char into
;; command text. So walk char by char: skip `start`, then append `len` chars built
;; from !zc:~0,1! -- every char moves through delayed expansion, so operators survive.
(define csubstr (lambda (f pmap k live)
  (let ((rs (cexpr (cadr f) pmap k live)))
    (let ((rb (cexpr (caddr f) pmap (caddr rs) (live-add (cadr rs) live))))
      (let ((rl (cexpr (cadddr f) pmap (caddr rb) (live-add (cadr rb) (live-add (cadr rs) live)))))
        (let ((j (number->string (caddr rl))))
          (let ((zc (str "zc" j)) (zsk (str "zsk" j)) (ztk (str "ztk" j)) (zr (str "zr" j))
                (ztmp (str "zt" (number->string (+ (caddr rl) 1)))) (sk (str "zSK" j)) (tk (str "zTK" j)))
            (list (append (car rs) (append (car rb) (append (car rl)
                    (list (str "set " zc "=" (cref (cadr rs)))
                          (str "set /a " zsk "=" (aref (cadr rb)))
                          (str ":" sk)
                          (str "if defined " zc " if !" zsk "! gtr 0 (set " zc "=!" zc ":~1!& set /a " zsk "-=1& goto " sk ")")
                          (str "set " zr "=")
                          (str "set /a " ztk "=" (aref (cadr rl)))
                          (str ":" tk)
                          (str "if defined " zc " if !" ztk "! gtr 0 (set " zr "=!" zr "!!" zc ":~0,1!& set " zc "=!" zc ":~1!& set /a " ztk "-=1& goto " tk ")")
                          (str "set " ztmp "=T:!" zr "!")))))
                  (cons (quote val) ztmp) (+ (caddr rl) 2)))))))))
;; cretag: symbol->string / number->string -- the content is unchanged, only the
;; 2-char tag becomes T:. set zt=T:<content of arg>.
(define cretag (lambda (f pmap k live)
  (let ((rx (cexpr (cadr f) pmap k live)))
    (let ((tmp (str "zt" (number->string (caddr rx)))))
      (list (append (car rx) (list (str "set " tmp "=T:" (cref (cadr rx))))) (cons (quote val) tmp) (+ (caddr rx) 1))))))
;; car/cdr: strip P: from the (val) operand to an index, then read CAR_/CDR_<idx>.
(define ccell (lambda (f field pmap k live)
  (let ((rx (cexpr (cadr f) pmap k live)))
    (let ((zi (str "zi" (number->string (caddr rx)))) (tmp (str "zt" (number->string (+ (caddr rx) 1)))))
      ;; read CAR_/CDR_<idx> via :rdfield (set R=!FIELD<idx>!, delayed -> operator-safe);
      ;; `call set tmp=%%FIELD!zi!%%` would re-parse the value unquoted and a & | < >
      ;; in it would split the line.
      (list (append (car rx) (list (str "set " zi "=!" (cdr (cadr rx)) ":~2!")
                                   (str "call :rdfield " field " !" zi "!")
                                   (str "set " tmp "=!R!")))
            (cons (quote val) tmp) (+ (caddr rx) 2))))))
;; cargs*: evaluate call args left-to-right -> (list lines (vref1 vref2 ...) k).
;; Each arg is evaluated with the earlier args' temps added to `live`, so a call
;; inside a later arg won't clobber an already-computed arg.
(define cargs* (lambda (as pmap k live)
  (if (null? as) (list nil nil k)
    (let ((r (cexpr (car as) pmap k live)))
      (let ((rest (cargs* (cdr as) pmap (caddr r) (live-add (cadr r) live))))
        (list (append (car r) (car rest)) (cons (vref (cadr r)) (cadr rest)) (caddr rest)))))))
;; clet-binds: compile each (name value) binding -> materialise value into a temp,
;; extend pmap with name->temp. Returns (list lines extended-pmap nextk). Each later
;; binding's value sees the earlier bindings (sequential let, like let*).
(define clet-binds (lambda (binds pmap k live)
  (if (null? binds) (list nil pmap k)
    (let ((b (car binds)))
      (let ((rv (cexpr (cadr b) pmap k live)))
        (let ((tmp (str "zt" (number->string (caddr rv)))))
          (let ((rest (clet-binds (cdr binds) (cons (cons (car b) tmp) pmap) (+ (caddr rv) 1) (cons tmp live))))
            (list (append (car rv) (cons (str "set " tmp "=" (vref (cadr rv))) (car rest)))
                  (cadr rest) (caddr rest)))))))))
(define uassign (lambda (vs i) (if (null? vs) nil (cons (str "set zu" (number->string i) "=" (car vs)) (uassign (cdr vs) (+ i 1))))))
(define pupd (lambda (ps i) (if (null? ps) nil (cons (str "set " (symbol->string (car ps)) "=!zu" (number->string i) "!") (pupd (cdr ps) (+ i 1))))))
;; test of an `if` -> lines ending in a `if ... goto TL`. Numeric (< =) compares
;; raw numbers; eq?/null? compare tagged values as strings (quote-free, so
;; space-free values only — symbols/NIL/numbers/pairs); pair? checks the P: tag.
;; tag-prefix predicate (pair?/number?/string?/symbol?): materialise the operand
;; into a temp (works for a var or a literal), then branch to TL if its first char
;; equals the tag letter (P/I/T/S).
(define ctag-test (lambda (test tl pmap k ch live)
  (let ((rx (cexpr (cadr test) pmap k live)))
    (let ((zt (str "zp" (number->string (caddr rx)))))
      ;; substring must be done in a `set` -- a `:~0,1` inside `if` breaks (the
      ;; comma is a token delimiter there). Materialise the value, slice to its
      ;; first char in place, then compare the whole short var.
      (cons (append (car rx)
              (list (str "set " zt "=" (vref (cadr rx)))
                    (str "set " zt "=!" zt ":~0,1!")
                    (str "if !" zt "!==" ch " goto " tl))) (+ (caddr rx) 1))))))
(define test-stmts (lambda (test tl pmap k live)
  (let ((op (car test)))
    (cond
      ((eq? op (quote null?))
        (let ((rx (cexpr (cadr test) pmap k live)))
          ;; unquoted is operator-safe: !v! expands AFTER tokenization, so a & | < >
          ;; in the value lands as data, not a separator. Tagged values are never
          ;; empty (>=2-char tag or NIL), so `if ==..` can't arise. Keeps codegen "-free.
          (cons (append (car rx) (list (str "if " (vref (cadr rx)) "==NIL goto " tl))) (caddr rx))))
      ((eq? op (quote pair?)) (ctag-test test tl pmap k "P" live))
      ((eq? op (quote number?)) (ctag-test test tl pmap k "I" live))
      ((eq? op (quote string?)) (ctag-test test tl pmap k "T" live))
      ((eq? op (quote symbol?)) (ctag-test test tl pmap k "S" live))
      ((eq? op (quote eq?))
        (let ((ra (cexpr (cadr test) pmap k live)))
          (let ((rb (cexpr (caddr test) pmap (caddr ra) (live-add (cadr ra) live))))
            (cons (append (car ra) (append (car rb) (list (str "if " (vref (cadr ra)) "==" (vref (cadr rb)) " goto " tl)))) (caddr rb)))))
      (t
        (let ((ra (cexpr (cadr test) pmap k live)))
          (let ((rb (cexpr (caddr test) pmap (caddr ra) (live-add (cadr ra) live))))
            (cons (append (car ra) (append (car rb) (list (str "if " (iref (cadr ra)) " " (cmp->batch op) " " (iref (cadr rb)) " goto " tl)))) (caddr rb)))))))))
;; ctail: tail position. self-call -> args into zu temps, update params, goto top;
;; if -> goto-branch; else -> set R to the tagged value, return.
(define ctail-begin (lambda (es nm lbl ps pmap k)
  (if (null? (cdr es)) (ctail (car es) nm lbl ps pmap k)
    (let ((r1 (cexpr (car es) pmap k nil)))
      (let ((rr (ctail-begin (cdr es) nm lbl ps pmap (caddr r1))))
        (cons (append (car r1) (car rr)) (cdr rr)))))))
(define ctail (lambda (f nm lbl ps pmap k)
  (cond
    ((is? f (quote begin)) (ctail-begin (cdr f) nm lbl ps pmap k))
    ((is? f nm)
       (let ((ar (cargs* (cdr f) pmap k nil)))
         (cons (append (car ar) (append (uassign (cadr ar) 1) (append (pupd ps 1) (list (str "goto " lbl "_top"))))) (caddr ar))))
    ((is? f (quote if))
       (let ((tl (str lbl "_L" (number->string k))))
         (let ((tr (test-stmts (cadr f) tl pmap (+ k 1) nil)))
           (let ((er (ctail (cadddr f) nm lbl ps pmap (cdr tr))))
             (let ((th (ctail (caddr f) nm lbl ps pmap (cdr er))))
               (cons (append (car tr) (append (car er) (cons (str ":" tl) (car th)))) (cdr th)))))))
    ((is? f (quote let))
       (let ((bs (clet-binds (cadr f) pmap k nil)))
         (let ((tb (ctail (caddr f) nm lbl ps (cadr bs) (caddr bs))))
           (cons (append (car bs) (car tb)) (cdr tb)))))
    (t (let ((r (cexpr f pmap k nil))) (cons (append (car r) (list (str "set R=" (vref (cadr r))) "goto :eof")) (caddr r)))))))

;; k0 is the program-wide monotonic label/temp counter: cexpr-level labels (zT/zE
;; value-if, zSL/zSK/zTK loops) are NOT function-prefixed, so `goto` would hit the
;; first match in the file. Threading one k across all fns keeps every label unique.
;; Returns (cons lines next-k).
(define compile-fn (lambda (nm lbl fs body k0)
  (let ((tb (ctail body nm lbl fs (pmap-local fs) k0)))
    (cons (append (cons (str ":" lbl) (load-params fs 1)) (cons (str ":" lbl "_top") (car tb))) (cdr tb)))))

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
(define dispatch-header (list "@echo off" "call :%1 %2 %3 %4 %5 %6 %7 %8 %9" "goto :eof"))
(define def-lambda? (lambda (f)
  (if (pair? f) (if (eq? (car f) (quote define))
    (if (pair? (caddr f)) (eq? (car (caddr f)) (quote lambda)) nil) nil) nil)))
(define resid-bind (lambda (nm)
  (list (quote define) nm (list (quote make-compiled) (list (quote symbol->string) (list (quote quote) nm))))))

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
            (cons (mexpand (car f)) (mexpand (cdr f)))))))
    f)))
(define mexpand-program (lambda (forms) (map-mexpand forms)))

(define cp (lambda (forms subs resid cmdpath lisppath k)
  (if (null? forms)
    (begin (write-lines cmdpath subs) (write-lines lisppath (map-show (reverse resid))))
    (if (def-lambda? (car forms))
      (let ((cf (compile-fn (cadr (car forms)) (symbol->string (cadr (car forms))) (cadr (caddr (car forms))) (caddr (caddr (car forms))) k)))
        (cp (cdr forms) (append subs (car cf)) (cons (resid-bind (cadr (car forms))) resid) cmdpath lisppath (cdr cf)))
      ;; atom constants are seeded into the header as G_<name>, so keep them OUT of
      ;; the residual (show can't re-quote a string literal -> unbound-symbol noise).
      (if (atom-const? (car forms))
        (cp (cdr forms) subs resid cmdpath lisppath k)
        (cp (cdr forms) subs (cons (car forms) resid) cmdpath lisppath k))))))
;; a top-level (define X <atom>) -> a constant compiled fns read as G_X. (Only
;; atoms: a list-valued constant would rebuild itself on the heap every dispatch.)
(define atom-const? (lambda (f)
  (if (def-lambda? f) nil (if (pair? f) (if (eq? (car f) (quote define)) (not (pair? (caddr f))) nil) nil))))
(define const-inits (lambda (forms)
  (if (null? forms) nil
    (if (atom-const? (car forms))
      (cons (str "set G_" (symbol->string (cadr (car forms))) "=" (vref (cadr (cexpr (caddr (car forms)) nil 0 nil))))
            (const-inits (cdr forms)))
      (const-inits (cdr forms))))))
;; the compiled :write-lines sub, prepended to every output. Mirrors the kernel's
;; pa_wrlines/wl_emit: truncate the file, then per line decode the sentinels and
;; append. The decode needs the sentinel BYTES as search patterns; we can't bake
;; literal 0x01/0x07 (write-lines would decode them), so route through ascii
;; placeholders -- byte->@P@ under ENABLED expansion (byte search via %BANGx%),
;; then @P@->char under DISABLED (literal placeholder search, char repl safe). The
;; only " needed are this sub's own set/p prompt etc., built with dq (0x08 -> ").
(define wl-sub (lambda ()
  (let ((Q (dq)))
    (append
      (list ":rdfield"
            "set R=!%1%2!"
            "goto :eof"
            ":write-lines"
            "set wlf=!A1:~2!"
            "set wll=!A2!"
            (str "break > " Q "!wlf!" Q)
            ":wl_loop_c"
            "if !wll!==NIL (set R=S:t & goto :eof)"
            "set wli=!wll:~2!"
            "call :rdfield CAR_ !wli!"
            "set wlline=!R:~2!"
            (str "call :wl_emit_c " Q "!wlf!" Q)
            "call :rdfield CDR_ !wli!"
            "set wll=!R!"
            "goto wl_loop_c"
            ":wl_emit_c"
            "if defined wlline goto wl_enc_c"
            (str ">>" Q "%~1" Q " echo(")
            "goto :eof"
            ":wl_enc_c"
            "setlocal enableDelayedExpansion")
      (list (str "set " Q "w=!wlline:%BANG2%=%%!" Q)
            (str "set " Q "w=!w:%BANG%=@P1@!" Q)
            (str "set " Q "w=!w:%BANG7%=@P7@!" Q)
            (str "endlocal & set " Q "wcar=%w%" Q)
            "setlocal disableDelayedExpansion"
            (str "set " Q "wd=%wcar:@P1@=!%" Q)
            (str "set " Q "wd=%wd:@P7@=^%" Q)
            (str ">>" Q "%~1" Q " <nul set /p " Q "=%wd%" Q)
            (str ">>" Q "%~1" Q " echo(")
            "endlocal"
            "goto :eof")))))
(define compile-program (lambda (forms cmdpath lisppath)
  (let ((ms (inline-program (mexpand-program forms))))
    (cp ms (append (list "@echo off") (append (const-inits ms) (append (cdr dispatch-header) (wl-sub)))) nil cmdpath lisppath 0))))
