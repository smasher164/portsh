;;; interp — string interpolation in userspace, as a showcase of fexpr + read.
;;;
;;; This is an EXAMPLE, not a stdlib function. It demonstrates that the vau core
;;; plus `read` is expressive enough to build string interpolation entirely in
;;; Lisp — but it scans the string a character at a time through the evaluator,
;;; which is fine on sh and very slow on cmd. For real code, prefer `str` from
;;; the stdlib: (str "i have " (+ 0 5) " fingers") — the holes are ordinary
;;; pre-parsed arguments, so there's no per-char scan and no `read` at all.
;;;
;;; Run it with the stdlib bundled (it uses cond/let/foldl/->string):
;;;   cat portsh-full.cmd examples/interp.lisp > demo.cmd && sh demo.cmd
;;;
;;; How it works: `interp` is a vau, so it receives the CALLER's environment.
;;; For each parenthesized region in the string it uses `read` to turn that text
;;; into a form and `eval` to run it where the call site lives; everything else
;;; is copied literally.  (interp "i have (+ 0 5) fingers") => "i have 5 fingers".

;; Single chars via substring (we have no string-ref); compare by eq?, since
;; equal strings share a tag.
(define char-at (lambda (s i) (substring s i 1)))
(define idx-from (lambda (s c i n)
  (if (= i n) -1 (if (eq? (char-at s i) c) i (idx-from s c (+ i 1) n)))))
(define index-of (lambda (s c) (idx-from s c 0 (string-length s))))

;; match-paren: given a '(' at index op, return the index of the matching ')'.
(define match-go (lambda (s i n depth)
  (if (= i n) -1
    (cond ((eq? (char-at s i) "(") (match-go s (+ i 1) n (+ depth 1)))
          ((eq? (char-at s i) ")") (if (= depth 1) i (match-go s (+ i 1) n (- depth 1))))
          (t (match-go s (+ i 1) n depth))))))
(define match-paren (lambda (s op) (match-go s (+ op 1) (string-length s) 1)))

(define interp-go (lambda (s env)
  (let ((op (index-of s "(")))
    (if (< op 0) s
      (let ((close (match-paren s op)))
        (string-append
          (substring s 0 op)
          (->string (eval (read (substring s op (+ 1 (- close op)))) env))
          (interp-go (substring s (+ close 1) (- (string-length s) (+ close 1))) env)))))))
(define interp (vau (s) env (interp-go (eval s env) env)))

(define a 3)
(define b 4)
(print (interp "i have (+ 0 5) fingers"))            ; i have 5 fingers
(print (interp "a=(+ a b), nested=(+ (* a 2) b)"))   ; a=7, nested=10
(print (interp "no holes here"))                     ; no holes here
