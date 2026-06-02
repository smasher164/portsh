;;; interp — string interpolation in userspace, as a showcase of split + read.
;;;
;;; This is an EXAMPLE, not a stdlib function. It shows that the vau core plus
;;; `read` and the `split` primitive are enough to build interpolation in plain
;;; Lisp. Holes are (expr) regions evaluated in the CALLER's environment;
;;; everything else is literal.  (interp "x=(+ 1 2) y=(* 3 4)") => "x=3 y=12".
;;;
;;; It uses `split` so the scanning is native (a primitive call) rather than a
;;; per-character loop through the evaluator — far faster, especially on cmd.
;;; The tradeoff: split can't balance parens, so holes must NOT nest. (An earlier
;;; char-scan version handled nesting but was orders of magnitude slower; see the
;;; git history.) For real code prefer `str` from the stdlib, whose holes are
;;; ordinary pre-parsed arguments:  (str "x=" (+ 1 2) " y=" (* 3 4)).
;;;
;;; Run with the stdlib bundled (it uses let/foldl/->string/join/str):
;;;   cat portsh-full.cmd examples/interp.lisp > demo.cmd && sh demo.cmd

;; A hole-segment is "code) trailing-literal" — the text right after a '('.
;; Split once on ')': the first part is the code, the rest is the literal that
;; followed the close paren (rejoined in case it contained ')').
(define interp-seg (lambda (seg env)
  (let ((parts (split seg ")")))
    (string-append
      (->string (eval (read (str "(" (car parts) ")")) env))
      (join ")" (cdr parts))))))

;; Split on '(' -> [prefix, hole-seg, ...]: the prefix is literal, each later
;; segment opens a hole. `vau` hands us the caller's env, so (expr) is evaluated
;; where the call site lives.
(define interp (vau (s) env
  (let ((segs (split (eval s env) "(")))
    (foldl (lambda (acc seg) (string-append acc (interp-seg seg env)))
           (car segs) (cdr segs)))))

(define a 3)
(define b 4)
(print (interp "i have (+ 0 5) fingers"))         ; i have 5 fingers
(print (interp "a=(+ a b) b=(* a b) c=(- b a)"))   ; a=7 b=12 c=1
(print (interp "no holes here"))                   ; no holes here
