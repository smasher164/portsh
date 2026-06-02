;;; stdlib-tour.lisp — exercises the richer stdlib (nth/assoc/take/drop,
;;; map2/zip/foldr, apply/compose/for-each, min/max/abs/sum, let*/case).
;;; Run on the sh kernel with the stdlib concatenated in front:
;;;   cat src/stdlib.lisp examples/stdlib-tour.lisp > /tmp/t.lisp
;;;   dash src/kernel.sh /tmp/t.lisp

;; A tiny "build config" as an alist, looked up with assoc.
(define config (list (cons 'name "myapp")
                     (cons 'opt  2)
                     (cons 'jobs 4)))
(print (cdr (assoc 'jobs config)))           ; 4
(print (cdr (assoc 'opt  config)))           ; 2

;; Pick the higher of two optimization levels, clamp with min/max.
(print (min 9 (max 0 (cdr (assoc 'opt config)))))  ; 2

;; Sum the squares of a list of step weights (map + sum).
(print (sum (map (lambda (w) (* w w)) (list 1 2 3))))  ; 14

;; Pair up source files with object files (zip / map2).
(define srcs (list 'a 'b 'c))
(define objs (list 'a.o 'b.o 'c.o))
(print (zip srcs objs))                      ; ((a . a.o) (b . b.o) (c . c.o))

;; First two and the rest of a task list (take / drop).
(define tasks (list 'fetch 'configure 'compile 'link 'install))
(print (take tasks 2))                       ; (fetch configure)
(print (drop tasks 2))                       ; (compile link install)
(print (nth tasks 3))                        ; link

;; compose + apply.
(define inc (lambda (x) (+ x 1)))
(define dbl (lambda (x) (* x 2)))
(print ((compose inc dbl) 10))               ; 21
(print (apply + (list 10 20 30)))            ; 60

;; foldr to rebuild a list, abs for a delta.
(print (foldr cons nil tasks))               ; (fetch configure compile link install)
(print (abs (- 3 8)))                        ; 5

;; let* with dependent bindings.
(print (let* ((base 4) (sq (* base base))) (+ base sq)))  ; 20

;; case dispatch on a symbol target.
(define describe (lambda (target)
  (case target
    (compile "compiling sources")
    (link    "linking objects")
    (else    "unknown step"))))
(print (describe 'compile))                  ; compiling sources
(print (describe 'package))                  ; unknown step

;; for-each for side effects over a list.
(for-each print (list 'done-a 'done-b 'done-c))
