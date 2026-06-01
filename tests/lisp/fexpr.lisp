(define unless (vau (c a b) e (if (eval c e) (eval b e) (eval a e))))
(unless nil (print 100) (print 200))
