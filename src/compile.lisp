;;; src/compile.lisp — the portsh Lisp->batch compiler, written in portsh Lisp.
;;;
;;; See docs/compilation.md for the why (the interpretation ceiling on cmd) and
;;; the trajectory (Futamura projections / self-hosting). Developed on the fast
;;; sh kernel; emits quote-free batch (portsh has no string escape, so codegen
;;; never needs a ") as a LIST OF LINES, written with write-lines.
;;;
;;; Covers: applicative functions over + - *, comparisons < =, `if`, params,
;;; value return, TAIL self-recursion (loops -> goto, TCO for free), and CALLS to
;;; other compiled functions. `cexpr` linearizes any value-position expression
;;; into statements + a result ref (a literal or a temp), which is what makes
;;; calls — and, later, cons/string primitives — compilable.
;;;
;;; Not yet: cons/list/string primitives, general (non-tail) recursion depth
;;; beyond batch's ~300-frame call limit. Next steps toward self-hosting.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define op->batch  (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define cmp->batch (lambda (o) (cond ((eq? o (quote <)) "LSS") ((eq? o (quote =)) "EQU") (t "?"))))
(define arith? (lambda (o) (if (eq? o (quote +)) t (if (eq? o (quote -)) t (eq? o (quote *))))))
(define is? (lambda (f h) (if (pair? f) (eq? (car f) h) nil)))

;; A "ref" to a computed value: (n . str) a literal, or (v . str) a variable.
;; sref is how it reads in a `set /a` expression; cref is how it reads in a
;; `call`/`if` (a literal as-is, a variable as !name! for delayed expansion).
(define sref (lambda (r) (cdr r)))
(define cref (lambda (r) (if (eq? (car r) (quote n)) (cdr r) (str "!" (cdr r) "!"))))

(define pmap-local  (lambda (fs)   (if (null? fs) nil (cons (cons (car fs) (symbol->string (car fs))) (pmap-local (cdr fs))))))
(define load-params (lambda (fs i) (if (null? fs) nil (cons (str (symbol->string (car fs)) "=%~" (number->string i)) (load-params (cdr fs) (+ i 1))))))

;; cexpr: compile a value-position expression -> (list lines ref next-k).
;;   literal/param -> no lines; arithmetic -> a `set /a` into a fresh temp;
;;   a call (g a..) -> compute args, `call compiled.cmd g <args>`, take R (strip
;;   the I: tag) into a temp. Sub-results thread the temp counter k.
(define cexpr (lambda (f pmap k)
  (cond
    ((number? f) (list nil (cons (quote n) (number->string f)) k))
    ((symbol? f) (list nil (cons (quote v) (cdr (assoc f pmap))) k))
    ((arith? (car f))
       (let ((ra (cexpr (cadr f) pmap k)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra))))
           (let ((tmp (str "_t" (number->string (caddr rb)))))
             (list (append (car ra) (append (car rb)
                     (list (str "set /a " tmp "=" (sref (cadr ra)) (op->batch (car f)) (sref (cadr rb))))))
                   (cons (quote v) tmp) (+ (caddr rb) 1))))))
    (t (let ((ar (cargs (cdr f) pmap k)))
         (let ((tmp (str "_t" (number->string (caddr ar)))))
           (list (append (car ar)
                   (list (str "call compiled.cmd " (symbol->string (car f)) (cadr ar))
                         (str "set " tmp "=!R:~2!")))
                 (cons (quote v) tmp) (+ (caddr ar) 1))))))))

;; cargs: compile a call's args -> (list lines " !a! !b! ..." k)  (call/if refs)
(define cargs (lambda (as pmap k)
  (if (null? as) (list nil "" k)
    (let ((r (cexpr (car as) pmap k)))
      (let ((rest (cargs (cdr as) pmap (caddr r))))
        (list (append (car r) (car rest)) (str " " (cref (cadr r)) (cadr rest)) (caddr rest)))))))
;; cargs*: like cargs but yields a list of set/a refs (for the tail-call update)
(define cargs* (lambda (as pmap k)
  (if (null? as) (list nil nil k)
    (let ((r (cexpr (car as) pmap k)))
      (let ((rest (cargs* (cdr as) pmap (caddr r))))
        (list (append (car r) (car rest)) (cons (sref (cadr r)) (cadr rest)) (caddr rest)))))))
(define uassign (lambda (rs i) (if (null? rs) nil (cons (str "_u" (number->string i) "=" (car rs)) (uassign (cdr rs) (+ i 1))))))
(define pupdate (lambda (ps i) (if (null? ps) nil (cons (str (symbol->string (car ps)) "=_u" (number->string i)) (pupdate (cdr ps) (+ i 1))))))
;; test of an `if` -> lines ending in `if <a> CMP <b> goto TL` (operands via cexpr)
(define test-stmts (lambda (test tl pmap k)
  (let ((ra (cexpr (cadr test) pmap k)))
    (let ((rb (cexpr (caddr test) pmap (caddr ra))))
      (cons (append (car ra) (append (car rb)
              (list (str "if " (cref (cadr ra)) " " (cmp->batch (car test)) " " (cref (cadr rb)) " goto " tl))))
            (caddr rb))))))

;; ctail: compile body `f` in TAIL position. Returns (lines . next-k).
;;   tail self-call -> args into temps, update mutable locals, goto <lbl>_top;
;;   if            -> goto-based branch (no nested parens);
;;   anything else -> cexpr it, then `set R=I:<ref>` and return.
(define ctail (lambda (f nm lbl ps pmap k)
  (cond
    ((is? f nm)
       (let ((ar (cargs* (cdr f) pmap k)))
         (cons (append (car ar) (list (str "set /a " (join "," (uassign (cadr ar) 1)))
                                      (str "set /a " (join "," (pupdate ps 1)))
                                      (str "goto " lbl "_top"))) (caddr ar))))
    ((is? f (quote if))
       (let ((tl (str lbl "_L" (number->string k))))
         (let ((tr (test-stmts (cadr f) tl pmap (+ k 1))))
           (let ((er (ctail (cadddr f) nm lbl ps pmap (cdr tr))))
             (let ((th (ctail (caddr f) nm lbl ps pmap (cdr er))))
               (cons (append (car tr) (append (car er) (cons (str ":" tl) (car th)))) (cdr th)))))))
    (t (let ((r (cexpr f pmap k)))
         (cons (append (car r) (list (str "set R=I:" (cref (cadr r))) "goto :eof")) (caddr r)))))))

(define compile-fn (lambda (nm lbl fs body)
  (append (list (str ":" lbl) (str "set /a " (join "," (load-params fs 1))) (str ":" lbl "_top"))
          (car (ctail body nm lbl fs (pmap-local fs) 0)))))

;;; -------------------------------------------------- the driver (compile a program)
;; A Lisp printer: form -> re-readable text. The residual uses no string literals
;; (portsh has no string escape), so a compiled binding is emitted as
;; (make-compiled (symbol->string (quote name))), not (make-compiled "name").
(define show-list (lambda (f)
  (if (null? (cdr f)) (show (car f))
    (if (pair? (cdr f)) (str (show (car f)) " " (show-list (cdr f)))
        (str (show (car f)) " . " (show (cdr f)))))))
(define show (lambda (f)
  (cond ((null? f) "()")
        ((number? f) (number->string f))
        ((symbol? f) (symbol->string f))
        ((string? f) f)
        (t (str "(" (show-list f) ")")))))

(define dispatch-header (list "@echo off" "setlocal enabledelayedexpansion"
                              "call :%1 %2 %3 %4 %5" "endlocal & set R=%R%" "goto :eof"))
(define def-lambda? (lambda (f)
  (if (pair? f) (if (eq? (car f) (quote define))
    (if (pair? (caddr f)) (eq? (car (caddr f)) (quote lambda)) nil) nil) nil)))
(define resid-bind (lambda (nm)
  (list (quote define) nm (list (quote make-compiled) (list (quote symbol->string) (list (quote quote) nm))))))

;; compile-program: forms + two output paths -> writes the batch subs to cmdpath
;; and the residual program to lisppath. Each compilable (define f (lambda ...))
;; becomes a compiled sub + a make-compiled binding; everything else passes
;; through to be interpreted.
(define cp (lambda (forms subs resid cmdpath lisppath)
  (if (null? forms)
    (begin (write-lines cmdpath subs) (write-lines lisppath (map show (reverse resid))))
    (if (def-lambda? (car forms))
      (cp (cdr forms)
          (append subs (compile-fn (cadr (car forms)) (symbol->string (cadr (car forms)))
                                   (cadr (caddr (car forms))) (caddr (caddr (car forms)))))
          (cons (resid-bind (cadr (car forms))) resid) cmdpath lisppath)
      (cp (cdr forms) subs (cons (car forms) resid) cmdpath lisppath)))))
(define compile-program (lambda (forms cmdpath lisppath)
  (cp forms dispatch-header nil cmdpath lisppath)))
