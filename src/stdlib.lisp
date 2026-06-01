;;; portsh standard library — plain userspace Lisp on top of the kernel.
;;; Loaded at boot in the "full" distribution (portsh-full.cmd). Everything
;;; here is written with kernel primitives + the minimal prelude only.

(define not (lambda (x) (if x nil t)))

;; list accessors
(define cadr  (lambda (x) (car (cdr x))))
(define caddr (lambda (x) (car (cdr (cdr x)))))
(define cddr  (lambda (x) (cdr (cdr x))))

;; sequence
(define last (lambda (xs) (if (null? (cdr xs)) (car xs) (last (cdr xs)))))
(define begin (lambda args (last args)))            ; evaluate args left-to-right, return last
(define length (lambda (xs) (if (null? xs) 0 (+ 1 (length (cdr xs))))))
(define append (lambda (a b) (if (null? a) b (cons (car a) (append (cdr a) b)))))
(define reverse (lambda (xs) (if (null? xs) nil (append (reverse (cdr xs)) (cons (car xs) nil)))))

;; higher-order
(define map (lambda (f xs) (if (null? xs) nil (cons (f (car xs)) (map f (cdr xs))))))
(define filter (lambda (p xs)
  (if (null? xs) nil
    (if (p (car xs)) (cons (car xs) (filter p (cdr xs))) (filter p (cdr xs))))))
(define foldl (lambda (f acc xs) (if (null? xs) acc (foldl f (f acc (car xs)) (cdr xs)))))

;; comparison derivatives (kernel gives < and =)
(define <= (lambda (a b) (if (< a b) t (= a b))))
(define >  (lambda (a b) (< b a)))
(define >= (lambda (a b) (<= b a)))

;; control-flow operatives (need vau so operands stay unevaluated)
(define and (vau args env
  (if (null? args) t
    (if (null? (cdr args)) (eval (car args) env)
      (if (eval (car args) env) (eval (cons (quote and) (cdr args)) env) nil)))))
(define or (vau args env
  (if (null? args) nil
    ((lambda (v) (if v v (eval (cons (quote or) (cdr args)) env))) (eval (car args) env)))))
(define when   (vau args env (if (eval (car args) env) (eval (cons (quote begin) (cdr args)) env) nil)))
(define unless (vau args env (if (eval (car args) env) nil (eval (cons (quote begin) (cdr args)) env))))
(define cond (vau clauses env
  (if (null? clauses) nil
    (if (eval (car (car clauses)) env)
        (eval (cons (quote begin) (cdr (car clauses))) env)
        (eval (cons (quote cond) (cdr clauses)) env)))))

;; let: ((x a) (y b)) body...  ->  ((lambda (x y) body...) a b)
(define let (vau args env
  (eval (cons (cons (quote lambda) (cons (map car (car args)) (cdr args)))
              (map cadr (car args)))
        env)))
