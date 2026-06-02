;;; src/compile.lisp — the portsh Lisp->batch compiler, written in portsh Lisp.
;;;
;;; See docs/compilation.md for the why (the interpretation ceiling on cmd) and
;;; the trajectory (Futamura projections / self-hosting). Developed on the fast
;;; sh kernel; emits quote-free batch (portsh has no string escape) as a LIST OF
;;; LINES, written with write-lines.
;;;
;;; VALUE MODEL: compiled code uses the interpreter's TAGGED values (I:5, P:3,
;;; T:foo, ...), so cons cells, strings, and the C: call boundary interoperate.
;;; A "ref" is lit (a literal int), raw (a var holding a raw int, from set /a), or
;;; val (a var holding a tagged value). Renderers convert at use sites: aref/iref
;;; give a raw number for set /a and `if` (stripping a val's 2-char tag); vref
;;; gives the tagged value for calls/cons/return (re-tagging a raw as I:..).
;;;
;;; Covers: + - *, < =, if, params, value return, tail self-recursion (loops ->
;;; goto), and inter-function calls. Next: cons/car/cdr, strings, then the
;;; control fexprs as compile-time macros, then self-hosting.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define op->batch  (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define cmp->batch (lambda (o) (cond ((eq? o (quote <)) "LSS") ((eq? o (quote =)) "EQU") (t "?"))))
(define arith? (lambda (o) (if (eq? o (quote +)) t (if (eq? o (quote -)) t (eq? o (quote *))))))
(define is? (lambda (f h) (if (pair? f) (eq? (car f) h) nil)))

;; ref kinds: lit (literal int) | raw (var, raw int) | val (var, tagged value) |
;; cst (a literal tagged value, e.g. NIL — carried verbatim).
(define aref (lambda (r) (cond ((eq? (car r) (quote lit)) (cdr r)) ((eq? (car r) (quote raw)) (cdr r)) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) ":~2!")))))
(define iref (lambda (r) (cond ((eq? (car r) (quote lit)) (cdr r)) ((eq? (car r) (quote raw)) (str "!" (cdr r) "!")) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) ":~2!")))))
(define vref (lambda (r) (cond ((eq? (car r) (quote lit)) (str "I:" (cdr r))) ((eq? (car r) (quote raw)) (str "I:!" (cdr r) "!")) ((eq? (car r) (quote cst)) (cdr r)) (t (str "!" (cdr r) "!")))))

;; --- caller-saves for general (non-tail) calls. Compiled fns have no setlocal
;; (so the shared heap survives across calls), which means a call clobbers the
;; caller's param/temp vars. Around every general call we push the caller's live
;; vars onto a global stack (STK/SP) and pop them back after. `live` is the set of
;; enclosing temp vars threaded through cexpr; params are added at the call site.
(define rev (lambda (xs acc) (if (null? xs) acc (rev (cdr xs) (cons (car xs) acc)))))
(define pvars (lambda (pm) (if (null? pm) nil (cons (cdr (car pm)) (pvars (cdr pm))))))
(define live-add (lambda (r live) (if (eq? (car r) (quote lit)) live (cons (cdr r) live))))
(define save-lines (lambda (vs)
  (if (null? vs) nil (cons (str "set STK!SP!=!" (car vs) "!") (cons "set /a SP+=1" (save-lines (cdr vs)))))))
(define restore-lines (lambda (vs)
  (if (null? vs) nil (cons "set /a SP-=1" (cons (str "call set " (car vs) "=%%STK!SP!%%") (restore-lines (cdr vs)))))))
(define call-wrap (lambda (sv callstr)
  (append (save-lines sv) (cons callstr (restore-lines (rev sv nil))))))

(define pmap-local  (lambda (fs)   (if (null? fs) nil (cons (cons (car fs) (symbol->string (car fs))) (pmap-local (cdr fs))))))
(define load-params (lambda (fs i) (if (null? fs) nil (cons (str "set " (symbol->string (car fs)) "=%~" (number->string i)) (load-params (cdr fs) (+ i 1))))))

;; cexpr: value-position expr -> (list lines ref next-k). arithmetic -> a raw
;; temp; a call -> compute args (tagged), call, take the tagged R into a val temp.
(define cexpr (lambda (f pmap k live)
  (cond
    ((number? f) (list nil (cons (quote lit) (number->string f)) k))
    ((eq? f (quote nil)) (list nil (cons (quote cst) "NIL") k))
    ((symbol? f) (list nil (cons (quote val) (cdr (assoc f pmap))) k))
    ((arith? (car f))
       (let ((ra (cexpr (cadr f) pmap k live)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (append (car ra) (append (car rb) (list (str "set /a " tmp "=" (aref (cadr ra)) (op->batch (car f)) (aref (cadr rb))))))
                   (cons (quote raw) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote cons))
       (let ((ra (cexpr (cadr f) pmap k live)))
         (let ((rb (cexpr (caddr f) pmap (caddr ra) (live-add (cadr ra) live))))
           (let ((tmp (str "zt" (number->string (caddr rb)))))
             (list (append (car ra) (append (car rb)
                     (list (str "set CAR_!HN!=" (vref (cadr ra))) (str "set CDR_!HN!=" (vref (cadr rb)))
                           (str "set " tmp "=P:!HN!") "set /a HN+=1")))
                   (cons (quote val) tmp) (+ (caddr rb) 1))))))
    ((eq? (car f) (quote car)) (ccell f "CAR_" pmap k live))
    ((eq? (car f) (quote cdr)) (ccell f "CDR_" pmap k live))
    (t (let ((ar (cargs (cdr f) pmap k live)))
         (let ((tmp (str "zt" (number->string (caddr ar)))))
           (list (append (car ar)
                   (append (call-wrap (append (pvars pmap) live) (str "call compiled.cmd " (symbol->string (car f)) (cadr ar)))
                           (list (str "set " tmp "=!R!"))))
                 (cons (quote val) tmp) (+ (caddr ar) 1))))))))
;; car/cdr: strip P: from the (val) operand to an index, then read CAR_/CDR_<idx>.
(define ccell (lambda (f field pmap k live)
  (let ((rx (cexpr (cadr f) pmap k live)))
    (let ((zi (str "zi" (number->string (caddr rx)))) (tmp (str "zt" (number->string (+ (caddr rx) 1)))))
      (list (append (car rx) (list (str "set " zi "=!" (cdr (cadr rx)) ":~2!")
                                   (str "call set " tmp "=%%" field "!" zi "!%%")))
            (cons (quote val) tmp) (+ (caddr rx) 2))))))
;; cargs: call args rendered as TAGGED values -> (list lines " v v ..." k). Each
;; arg is evaluated with the earlier args' temps added to `live` (a call inside a
;; later arg must not clobber an already-computed arg).
(define cargs (lambda (as pmap k live)
  (if (null? as) (list nil "" k)
    (let ((r (cexpr (car as) pmap k live)))
      (let ((rest (cargs (cdr as) pmap (caddr r) (live-add (cadr r) live))))
        (list (append (car r) (car rest)) (str " " (vref (cadr r)) (cadr rest)) (caddr rest)))))))
(define cargs* (lambda (as pmap k live)
  (if (null? as) (list nil nil k)
    (let ((r (cexpr (car as) pmap k live)))
      (let ((rest (cargs* (cdr as) pmap (caddr r) (live-add (cadr r) live))))
        (list (append (car r) (car rest)) (cons (vref (cadr r)) (cadr rest)) (caddr rest)))))))
(define uassign (lambda (vs i) (if (null? vs) nil (cons (str "set zu" (number->string i) "=" (car vs)) (uassign (cdr vs) (+ i 1))))))
(define pupd (lambda (ps i) (if (null? ps) nil (cons (str "set " (symbol->string (car ps)) "=!zu" (number->string i) "!") (pupd (cdr ps) (+ i 1))))))
;; test of an `if` -> lines ending in a `if ... goto TL`. Numeric (< =) compares
;; raw numbers; eq?/null? compare tagged values as strings (quote-free, so
;; space-free values only — symbols/NIL/numbers/pairs); pair? checks the P: tag.
(define test-stmts (lambda (test tl pmap k live)
  (let ((op (car test)))
    (cond
      ((eq? op (quote null?))
        (let ((rx (cexpr (cadr test) pmap k live)))
          (cons (append (car rx) (list (str "if " (vref (cadr rx)) "==NIL goto " tl))) (caddr rx))))
      ((eq? op (quote pair?))
        (let ((rx (cexpr (cadr test) pmap k live)))
          (cons (append (car rx)
                  (list (str "set zp" k "=!" (cdr (cadr rx)) ":~0,1!")
                        (str "if !zp" k "!==P goto " tl))) (caddr rx))))
      ((eq? op (quote eq?))
        (let ((ra (cexpr (cadr test) pmap k live)))
          (let ((rb (cexpr (caddr test) pmap (caddr ra) (live-add (cadr ra) live))))
            (cons (append (car ra) (append (car rb) (list (str "if " (vref (cadr ra)) "==" (vref (cadr rb)) " goto " tl)))) (caddr rb)))))
      (t
        (let ((ra (cexpr (cadr test) pmap k live)))
          (let ((rb (cexpr (caddr test) pmap (caddr ra) (live-add (cadr ra) live))))
            (cons (append (car ra) (append (car rb) (list (str "if " (iref (cadr ra)) " " (cmp->batch op) " " (iref (cadr rb)) " goto " tl)))) (caddr rb)))))))))
;; ctail: tail position. self-call -> args into zu temps, update params, goto top;
;; if -> goto-branch; else -> set R to the tagged value, return.
(define ctail (lambda (f nm lbl ps pmap k)
  (cond
    ((is? f nm)
       (let ((ar (cargs* (cdr f) pmap k nil)))
         (cons (append (car ar) (append (uassign (cadr ar) 1) (append (pupd ps 1) (list (str "goto " lbl "_top"))))) (caddr ar))))
    ((is? f (quote if))
       (let ((tl (str lbl "_L" (number->string k))))
         (let ((tr (test-stmts (cadr f) tl pmap (+ k 1) nil)))
           (let ((er (ctail (cadddr f) nm lbl ps pmap (cdr tr))))
             (let ((th (ctail (caddr f) nm lbl ps pmap (cdr er))))
               (cons (append (car tr) (append (car er) (cons (str ":" tl) (car th)))) (cdr th)))))))
    (t (let ((r (cexpr f pmap k nil))) (cons (append (car r) (list (str "set R=" (vref (cadr r))) "goto :eof")) (caddr r)))))))

(define compile-fn (lambda (nm lbl fs body)
  (append (cons (str ":" lbl) (load-params fs 1)) (cons (str ":" lbl "_top") (car (ctail body nm lbl fs (pmap-local fs) 0))))))

;;; -------------------------------------------------- the driver (compile a program)
(define show-list (lambda (f)
  (if (null? (cdr f)) (show (car f))
    (if (pair? (cdr f)) (str (show (car f)) " " (show-list (cdr f)))
        (str (show (car f)) " . " (show (cdr f)))))))
(define show (lambda (f)
  (cond ((null? f) "()") ((number? f) (number->string f)) ((symbol? f) (symbol->string f))
        ((string? f) f) (t (str "(" (show-list f) ")")))))
;; quote-free dispatcher: `call :<label>` (delayed expansion is inherited from the
;; kernel; R and the heap propagate since there's no setlocal).
(define dispatch-header (list "@echo off" "call :%1 %2 %3 %4 %5 %6 %7 %8 %9" "goto :eof"))
(define def-lambda? (lambda (f)
  (if (pair? f) (if (eq? (car f) (quote define))
    (if (pair? (caddr f)) (eq? (car (caddr f)) (quote lambda)) nil) nil) nil)))
(define resid-bind (lambda (nm)
  (list (quote define) nm (list (quote make-compiled) (list (quote symbol->string) (list (quote quote) nm))))))

;;; ------------------------------------------------ inlining (small non-recursive fns)
(define subst (lambda (s v tree)
  (cond ((eq? tree s) v) ((pair? tree) (cons (subst s v (car tree)) (subst s v (cdr tree)))) (t tree))))
(define subst* (lambda (ps as body)
  (if (null? ps) body (subst* (cdr ps) (cdr as) (subst (car ps) (car as) body)))))
(define refs? (lambda (s tree)
  (cond ((eq? tree s) t) ((pair? tree) (if (refs? s (car tree)) t (refs? s (cdr tree)))) (t nil))))
(define inline-expr (lambda (e tbl)
  (if (pair? e)
    (let ((ent (assoc (car e) tbl)))
      (if (null? ent)
        (cons (car e) (map (lambda (a) (inline-expr a tbl)) (cdr e)))
        (inline-expr (subst* (cadr ent) (map (lambda (a) (inline-expr a tbl)) (cdr e)) (caddr ent)) tbl)))
    e)))
(define mk-tbl (lambda (forms)
  (if (null? forms) nil
    (if (if (def-lambda? (car forms)) (not (refs? (cadr (car forms)) (caddr (caddr (car forms))))) nil)
      (cons (list (cadr (car forms)) (cadr (caddr (car forms))) (caddr (caddr (car forms)))) (mk-tbl (cdr forms)))
      (mk-tbl (cdr forms))))))
;; Inline ONLY inside compiled function bodies. Top-level (interpreted) forms are
;; left alone — inlining a body that uses a stdlib fn (e.g. pair?) into the
;; residual would reference something unbound there; as a compiled C: call it's fine.
(define inline-form (lambda (f tbl)
  (if (def-lambda? f)
    (list (quote define) (cadr f) (list (quote lambda) (cadr (caddr f)) (inline-expr (caddr (caddr f)) tbl)))
    f)))
(define inline-program (lambda (forms) (let ((tbl (mk-tbl forms))) (map (lambda (f) (inline-form f tbl)) forms))))

(define cp (lambda (forms subs resid cmdpath lisppath)
  (if (null? forms)
    (begin (write-lines cmdpath subs) (write-lines lisppath (map show (reverse resid))))
    (if (def-lambda? (car forms))
      (cp (cdr forms)
          (append subs (compile-fn (cadr (car forms)) (symbol->string (cadr (car forms))) (cadr (caddr (car forms))) (caddr (caddr (car forms)))))
          (cons (resid-bind (cadr (car forms))) resid) cmdpath lisppath)
      (cp (cdr forms) subs (cons (car forms) resid) cmdpath lisppath)))))
(define compile-program (lambda (forms cmdpath lisppath)
  (cp (inline-program forms) dispatch-header nil cmdpath lisppath)))
