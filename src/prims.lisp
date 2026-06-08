; Fixed-arity applicative wrappers for the primitives that comp inlines in CALL position. When a
; primitive appears in VALUE position (e.g. (foldr + 0 xs), (map car pairs)), lval (compile*.lisp,
; prim-wrap) compiles it to C:__p_<op>, which dispatches to one of these. Compiled into the eval/load
; runtimes alongside the AOT stdlib. The bodies use the primitives in call position, so comp inlines
; them -- these are just the first-class fn-values the primitives otherwise lack.
(define __p_add (lambda (a b) (+ a b)))
(define __p_sub (lambda (a b) (- a b)))
(define __p_mul (lambda (a b) (* a b)))
(define __p_lt  (lambda (a b) (< a b)))
(define __p_neq (lambda (a b) (= a b)))
(define __p_cons (lambda (a b) (cons a b)))
(define __p_car (lambda (x) (car x)))
(define __p_cdr (lambda (x) (cdr x)))
(define __p_null (lambda (x) (null? x)))
(define __p_eq (lambda (a b) (eq? a b)))
(define __p_pair (lambda (x) (pair? x)))
(define __p_not (lambda (x) (not x)))
