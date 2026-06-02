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
             (cons (append (list (str "set /a _a=" (ca (cadr (cadr f)) pmap) ",_b=" (ca (caddr (cadr f)) pmap))
                                 (str "if !_a! " (cmp->batch (car (cadr f))) " !_b! goto " tl))
                           (append (car er) (cons (str ":" tl) (car tr))))
                   (cdr tr))))))
    (t (cons (list (str "set /a _r=" (ca f pmap)) "set R=I:!_r!" "goto :eof") k)))))

;; compile a (possibly self-recursive) function -> a list of batch lines.
(define compile-fn (lambda (nm lbl fs body)
  (append (list (str ":" lbl) (str "set /a " (join "," (load-params fs 2))) (str ":" lbl "_top"))
          (car (ctail body nm lbl fs (pmap-local fs) 0)))))
