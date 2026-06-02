;;; src/compile.lisp — the portsh Lisp->batch compiler, written in portsh Lisp.
;;;
;;; WORK IN PROGRESS. See docs/compilation.md for the why (the ~interpretation
;;; gap on cmd) and the trajectory (the Futamura projections / self-hosting).
;;; Developed on the fast sh kernel; emits quote-free batch (portsh has no string
;;; escape, so codegen never needs a ") as a LIST OF LINES (written w/ write-lines).
;;;
;;; Covers: applicative functions over + - *, comparisons < =, `if`, params,
;;; value return, and TAIL SELF-RECURSION (loops -> goto, TCO for free). Control
;;; flow is goto-based with generated labels — NOT inline `if (...) else (...)`,
;;; because arithmetic parens like (n-1) inside an if-block break cmd's paren
;;; matcher. Verified: a compiled loop runs correctly and without the recursion
;;; crash on real cmd.exe.
;;;
;;; Next: calls to OTHER functions, cons/list/string via direct primitive calls,
;;; kernel integration (temp dir, C: dispatch, define-time compile), self-hosting.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define op->batch  (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define cmp->batch (lambda (o) (cond ((eq? o (quote <)) "LSS") ((eq? o (quote =)) "EQU") (t "?"))))

;; ca: compile an arithmetic subexpression to a `set /a` string. pmap maps each
;; param symbol to its batch reference (a mutable local name like "n", or "%~2").
(define ca (lambda (f pmap)
  (cond ((number? f) (number->string f))
        ((symbol? f) (cdr (assoc f pmap)))
        (t (str "(" (ca (cadr f) pmap) (op->batch (car f)) (ca (caddr f) pmap) ")")))))

(define pmap-local  (lambda (fs)   (if (null? fs) nil (cons (cons (car fs) (symbol->string (car fs))) (pmap-local (cdr fs))))))
(define load-params (lambda (fs i) (if (null? fs) nil (cons (str (symbol->string (car fs)) "=%~" (number->string i)) (load-params (cdr fs) (+ i 1))))))
(define arg-temps   (lambda (as pmap i) (if (null? as) nil (cons (str "_t" (number->string i) "=" (ca (car as) pmap)) (arg-temps (cdr as) pmap (+ i 1))))))
(define updates     (lambda (ps i)      (if (null? ps) nil (cons (str (symbol->string (car ps)) "=_t" (number->string i)) (updates (cdr ps) (+ i 1))))))
(define is? (lambda (f h) (if (pair? f) (eq? (car f) h) nil)))

;; A simple operand (number or param symbol) can go straight into an `if` —
;; `if !n! EQU 0` — no temp. Saves a command per branch (5 -> 4 cmds/iter on the
;; canonical loop). Complex (arithmetic) operands fall back to _a/_b temps.
(define simple? (lambda (x) (if (number? x) t (symbol? x))))
(define sref (lambda (x pmap) (if (number? x) (number->string x) (str "!" (cdr (assoc x pmap)) "!"))))
(define test-lines (lambda (test tl pmap)
  (if (if (simple? (cadr test)) (simple? (caddr test)) nil)
    (list (str "if " (sref (cadr test) pmap) " " (cmp->batch (car test)) " " (sref (caddr test) pmap) " goto " tl))
    (list (str "set /a _a=" (ca (cadr test) pmap) ",_b=" (ca (caddr test) pmap))
          (str "if !_a! " (cmp->batch (car test)) " !_b! goto " tl)))))

;; ctail: compile body `f` in TAIL position for a function named symbol `nm`
;; (label string `lbl`, params `ps`). Returns (lines . next-label-counter).
;;   - tail self-call -> new args into temps, update locals, goto <lbl>_top
;;   - if            -> goto-based branch (no nested parens)
;;   - value         -> set /a into _r, return I:!_r!
(define ctail (lambda (f nm lbl ps pmap k)
  (cond
    ((is? f nm)
       (cons (list (str "set /a " (join "," (arg-temps (cdr f) pmap 1)))
                   (str "set /a " (join "," (updates ps 1)))
                   (str "goto " lbl "_top")) k))
    ((is? f (quote if))
       (let ((tl (str lbl "_t" (number->string k))))
         (let ((er (ctail (cadddr f) nm lbl ps pmap (+ k 1))))
           (let ((tr (ctail (caddr f) nm lbl ps pmap (cdr er))))
             (cons (append (test-lines (cadr f) tl pmap)
                           (append (car er) (cons (str ":" tl) (car tr))))
                   (cdr tr))))))
    (t (cons (list (str "set /a _r=" (ca f pmap)) "set R=I:!_r!" "goto :eof") k)))))

;; compile a (possibly self-recursive) function -> a list of batch lines.
;; params arrive at %~1,%~2,... — the dispatcher does `call :<label> %2 %3 ...`,
;; so the sub's own args start at %~1.
(define compile-fn (lambda (nm lbl fs body)
  (append (list (str ":" lbl) (str "set /a " (join "," (load-params fs 1))) (str ":" lbl "_top"))
          (car (ctail body nm lbl fs (pmap-local fs) 0)))))

;;; -------------------------------------------------- the driver (compile a program)
;; A Lisp printer: form -> re-readable text. The residual it emits uses no string
;; literals (portsh has no string escape), so a compiled binding is written as
;; (make-compiled (symbol->string (quote name))) rather than (make-compiled "name").
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

;; The generated dispatcher header (quote-free): `call :<label>` then propagate R
;; back across endlocal.  All compiled subs are appended after it.
(define dispatch-header (list "@echo off" "setlocal enabledelayedexpansion"
                              "call :%1 %2 %3 %4 %5" "endlocal & set R=%R%" "goto :eof"))
(define def-lambda? (lambda (f)
  (if (pair? f) (if (eq? (car f) (quote define))
    (if (pair? (caddr f)) (eq? (car (caddr f)) (quote lambda)) nil) nil) nil)))
;; residual binding: (define NAME (make-compiled (symbol->string (quote NAME))))
(define resid-bind (lambda (nm)
  (list (quote define) nm (list (quote make-compiled) (list (quote symbol->string) (list (quote quote) nm))))))

;; compile-program: forms + the two output paths -> writes the batch subs to
;; cmdpath and the residual program to lisppath. Each compilable (define f
;; (lambda ...)) becomes a compiled sub + a make-compiled binding; everything
;; else passes through to be interpreted.
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
