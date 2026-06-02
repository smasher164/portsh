;;; src/compile.lisp — the portsh Lisp->batch compiler, written in portsh Lisp.
;;;
;;; WORK IN PROGRESS. See docs/compilation.md for the why (the ~1000x
;;; interpretation gap on cmd) and the trajectory (the Futamura projections /
;;; self-hosting). This file is developed on the fast sh kernel and emits
;;; quote-free batch (portsh has no string escape, so the codegen never needs a
;;; ").  Output is a LIST OF LINES, written with write-lines.
;;;
;;; Covered so far: applicative functions over + - *, comparisons < =, one-level
;;; `if`, params, value return. Result lands in _r, then `set R=I:!_r!`.
;;; Next: calls, tail self-recursion (loops -> goto), then kernel integration.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define op->batch  (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define cmp->batch (lambda (o) (cond ((eq? o (quote <)) "LSS") ((eq? o (quote =)) "EQU") (t "?"))))

;; ca: compile an arithmetic subexpression to a `set /a`-compatible string.
;; pmap is an alist of param-symbol -> batch arg ref ("%~2", "%~3", ...).
(define ca (lambda (f pmap)
  (cond ((number? f) (number->string f))
        ((symbol? f) (cdr (assoc f pmap)))
        (t (str "(" (ca (cadr f) pmap) (op->batch (car f)) (ca (caddr f) pmap) ")")))))

;; map a formals list to arg refs starting at %~2 (%~1 is the dispatch label).
(define pmap-build (lambda (formals i)
  (if (null? formals) nil
    (cons (cons (car formals) (str "%~" (number->string i)))
          (pmap-build (cdr formals) (+ i 1))))))

;; cbody: compile a body (arith, or one-level `(if (cmp a b) then else)`) into a
;; list of batch lines that compute the result into _r, then return I:!_r!.
(define cbody (lambda (f pmap)
  (if (if (pair? f) (eq? (car f) (quote if)) nil)
    (append
      (list (str "set /a _a=" (ca (cadr (cadr f)) pmap) ",_b=" (ca (caddr (cadr f)) pmap))
            (str "if !_a! " (cmp->batch (car (cadr f))) " !_b! (set /a _r="
                 (ca (caddr f) pmap) ") else (set /a _r=" (ca (cadddr f) pmap) ")"))
      (list "set R=I:!_r!" "goto :eof"))
    (cons (str "set /a _r=" (ca f pmap)) (list "set R=I:!_r!" "goto :eof")))))

;; compile-fn: name + formals + body -> a list of batch lines (a :label sub).
(define compile-fn (lambda (label formals body)
  (cons (str ":" label) (cbody body (pmap-build formals 2)))))
