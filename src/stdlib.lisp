;;; portsh standard library — plain userspace Lisp on top of the kernel.
;;; Loaded at boot in the "full" distribution (portsh-full.cmd). Everything
;;; here is written with kernel primitives + the minimal prelude only.
;;;
;;; Primitives available (from the kernel + prelude):
;;;   operatives : vau define if quote lambda
;;;   applicative: cons car cdr eq? null? atom? + - * < = wrap unwrap eval
;;;                print run file-exists? list
;;;                string-append string-length substring
;;;                symbol->string string->symbol number->string string->number
;;;                read-lines write-lines        (run-capture is an operative)
;;; Notes / deliberate gaps in the kernel this stdlib must respect:
;;;   - binary - < =, no / and no mod, no >  (we derive > >= <= here)
;;;   - strings are single-line (host vars hold no newline); multi-line text is
;;;     a list of line-strings, so I/O is line-oriented (read-lines/write-lines)
;;;   - eq? compares the underlying tagged value, so it works for symbols,
;;;     integers, nil, t, and identity of pairs (same cell).
;;;
;;; Organization (top to bottom): booleans, list accessors, list construction
;;; & length, list query/access (nth/member/assoc/take/drop), higher-order
;;; (map/filter/fold/apply/compose/for-each), numeric (min/max/abs),
;;; comparison derivatives, and control-flow operatives (and/or/when/cond/
;;; let/let*/case).

;;; ------------------------------------------------------------------ booleans
(define not (lambda (x) (if x nil t)))

;;; ----------------------------------------------------------- list accessors
(define cadr   (lambda (x) (car (cdr x))))
(define caddr  (lambda (x) (car (cdr (cdr x)))))
(define cddr   (lambda (x) (cdr (cdr x))))
(define cdar   (lambda (x) (cdr (car x))))
(define caar   (lambda (x) (car (car x))))
(define cadar  (lambda (x) (car (cdr (car x)))))

;;; -------------------------------------------------- list construction/length
(define last (lambda (xs) (if (null? (cdr xs)) (car xs) (last (cdr xs)))))
(define begin (lambda args (last args)))             ; eval args L-to-R, return last
(define length (lambda (xs) (if (null? xs) 0 (+ 1 (length (cdr xs))))))
(define append (lambda (a b) (if (null? a) b (cons (car a) (append (cdr a) b)))))
(define reverse (lambda (xs) (if (null? xs) nil (append (reverse (cdr xs)) (cons (car xs) nil)))))

;;; ----------------------------------------------- list access / query helpers
;; list-tail: drop the first n cells, return the rest of the list.
(define list-tail (lambda (xs n) (if (= n 0) xs (list-tail (cdr xs) (- n 1)))))
;; nth: 0-indexed element.
(define nth (lambda (xs n) (car (list-tail xs n))))
;; take/drop: first n / all-but-first n.
(define take (lambda (xs n) (if (= n 0) nil (if (null? xs) nil (cons (car xs) (take (cdr xs) (- n 1)))))))
(define drop (lambda (xs n) (list-tail xs n)))
;; member?: t if x is in xs (uses eq?, i.e. symbol/int/nil identity).
(define member? (lambda (x xs)
  (if (null? xs) nil
    (if (eq? x (car xs)) t (member? x (cdr xs))))))
;; assoc: find (key . val) pair in an alist by eq? on the key; nil if absent.
(define assoc (lambda (k al)
  (if (null? al) nil
    (if (eq? k (caar al)) (car al) (assoc k (cdr al))))))

;;; ------------------------------------------------------------- higher-order
(define map (lambda (f xs) (if (null? xs) nil (cons (f (car xs)) (map f (cdr xs))))))
;; map2: map a binary fn over two equal-length lists (zipping fn).
(define map2 (lambda (f xs ys)
  (if (null? xs) nil
    (cons (f (car xs) (car ys)) (map2 f (cdr xs) (cdr ys))))))
;; zip: list of (x . y) pairs from two lists.
(define zip (lambda (xs ys) (map2 (lambda (a b) (cons a b)) xs ys)))
(define filter (lambda (p xs)
  (if (null? xs) nil
    (if (p (car xs)) (cons (car xs) (filter p (cdr xs))) (filter p (cdr xs))))))
(define foldl (lambda (f acc xs) (if (null? xs) acc (foldl f (f acc (car xs)) (cdr xs)))))
;; foldr: right fold. (foldr f z (a b c)) = (f a (f b (f c z))).
(define foldr (lambda (f z xs) (if (null? xs) z (f (car xs) (foldr f z (cdr xs))))))
;; for-each: like map but for side effects (run/print); returns nil.
(define for-each (lambda (f xs) (if (null? xs) nil (begin (f (car xs)) (for-each f (cdr xs))))))
;; apply: call applicative f on a list of already-evaluated args.
;;   built by consing f onto the (quoted) arg list and evaluating it; the
;;   args are quoted so they pass through unchanged (they're already values).
(define apply (vau (f args) env
  (eval (cons (eval f env)
              (map (lambda (a) (list (quote quote) a)) (eval args env)))
        env)))
;; compose: (compose f g) is the fn x -> (f (g x)).
(define compose (lambda (f g) (lambda (x) (f (g x)))))

;;; --------------------------------------------- comparison derivatives (< =)
(define <= (lambda (a b) (if (< a b) t (= a b))))
(define >  (lambda (a b) (< b a)))
(define >= (lambda (a b) (<= b a)))

;;; ----------------------------------------------------------------- numeric
(define abs (lambda (n) (if (< n 0) (- 0 n) n)))
(define max (lambda (a b) (if (< a b) b a)))
(define min (lambda (a b) (if (< a b) a b)))
;; sum/product over a list (handy for counting build steps, etc.)
(define sum     (lambda (xs) (foldl (lambda (a x) (+ a x)) 0 xs)))
(define product (lambda (xs) (foldl (lambda (a x) (* a x)) 1 xs)))

;;; --------------------------------------------- control-flow operatives (vau)
;; and/or RETURN THE VALUE (not just t) and short-circuit.
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
;; let*: sequential binding — each binding sees the previous ones. Expands to
;; nested single-binding lets.
(define let* (vau args env
  (eval (if (null? (car args))
            (cons (quote begin) (cdr args))
            (cons (quote let)
                  (cons (cons (car (car args)) nil)
                        (cons (cons (quote let*)
                                    (cons (cdr (car args)) (cdr args)))
                              nil))))
        env)))

;; case: (case key (datum body...) ... (else body...)) — dispatch on eq? to a
;; literal datum. The key is evaluated once; clause data are unevaluated
;; literals (Scheme style: write `(case x (foo 1) (2 'two) (else ...))`, not
;; `(case x ('foo 1) ...)`). `else` matches anything.
(define case (vau args env
  ((lambda (k)
     (eval (cons (quote cond)
                 (map (lambda (cl)
                        (if (eq? (car cl) (quote else))
                            (cons (quote t) (cdr cl))
                            (cons (list (quote eq?) (list (quote quote) (car cl))
                                        (list (quote quote) k))
                                  (cdr cl))))
                      (cdr args)))
           env))
   (eval (car args) env))))

;;; -------------------------------------------- type reflection / string coercion
;; All derived from the single `type-of` primitive (returns a symbol).
(define number? (lambda (x) (eq? (type-of x) (quote number))))
(define string? (lambda (x) (eq? (type-of x) (quote string))))
(define symbol? (lambda (x) (eq? (type-of x) (quote symbol))))
(define pair?   (lambda (x) (eq? (type-of x) (quote pair))))
;; ->string: render any value as a string (the coercion `str`/interp build on).
(define ->string (lambda (x)
  (cond ((string? x) x)
        ((number? x) (number->string x))
        ((symbol? x) (symbol->string x))
        (t x))))
;; str: concatenate the string forms of all args.  (str "n=" (+ 1 2) "!") => "n=3!"
;; This is the "form-hole" answer to interpolation — needs no reader/`read`,
;; since each argument was already parsed and is evaluated normally before str
;; runs. (For the string-embedded `"... (expr) ..."` style, see examples/interp.lisp;
;; that one is a read+eval showcase, deliberately not shipped in the stdlib.)
(define str (lambda args (foldl (lambda (a x) (string-append a (->string x))) "" args)))
;; join: inverse of the `split` primitive — glue strings with a separator.
;; Pure userspace (a fold), no native help needed.  (join "," (split s ",")) = s.
(define join (lambda (sep xs)
  (if (null? xs) "" (foldl (lambda (a x) (str a sep x)) (car xs) (cdr xs)))))
