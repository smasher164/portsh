(define sumr (lambda (n) (if (eq? n 0) 0 (+ n (sumr (- n 1))))))
(print (sumr 10))
(define fact (lambda (n) (if (eq? n 0) 1 (* n (fact (- n 1))))))
(print (fact 6))
