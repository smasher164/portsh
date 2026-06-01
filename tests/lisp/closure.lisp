(define adder (lambda (n) (lambda (x) (+ x n))))
(print ((adder 10) 5))
