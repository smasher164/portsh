;;; src/compile-sh.lisp — the portsh Lisp->sh backend (sibling of compile.lisp's
;;; Lisp->batch backend). Emits NATIVE sh functions:
;;;   - an applicative -> an sh function; args arrive as POSITIONAL params ($1,$2,…);
;;;   - result returned in global $R; arithmetic is $(( )) on detagged values;
;;;   - values keep the interpreter's tags (I:5, P:3, T:foo, ...).
;;; ksh93-safe by construction (positional frames; no `local`/`typeset`).
;;;
;;; CALLER-SAVE: temps are global vars sht<k>. A recursive (or mutually-recursive)
;;; call re-runs the same compiled code -> reuses the same sht<k> names -> clobbers
;;; any temp LIVE across the call. So around each call to a compiled fn we save the
;;; live temps to a STK/SP stack (ksh93-safe via single-quote eval) and restore after.
;;; Positional PARAMS need no save (private per call). Calls to kernel hp_* don't use
;;; sht temps, so they need no save. The `live` set is threaded through cexpr-sh.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define rev (lambda (xs acc) (if (null? xs) acc (rev (cdr xs) (cons (car xs) acc)))))
(define lookup (lambda (k al) (if (null? al) nil (if (eq? (car (car al)) k) (cdr (car al)) (lookup k (cdr al))))))

;; refs: (lit . "n") | (val . "VAR") tagged value in an sh name/position | (cst . "TAGGED").
(define shval (lambda (r)
  (cond ((eq? (car r) (quote lit)) (str "I:" (cdr r)))
        ((eq? (car r) (quote cst)) (cdr r))
        (t (str "${" (cdr r) "}")))))
(define shdet (lambda (r)
  (cond ((eq? (car r) (quote lit)) (cdr r))
        ((eq? (car r) (quote cst)) (substring (cdr r) 2 (- (string-length (cdr r)) 2)))
        (t (str "${" (cdr r) "#??}")))))
(define shop (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define arith? (lambda (o) (if (eq? o (quote +)) t (if (eq? o (quote -)) t (eq? o (quote *))))))
(define shcmp (lambda (o) (cond ((eq? o (quote <)) "-lt") ((eq? o (quote =)) "-eq") (t "?"))))
(define pred? (lambda (o) (cond ((eq? o (quote null?)) t) ((eq? o (quote pair?)) t) ((eq? o (quote eq?)) t)
  ((eq? o (quote atom?)) t) ((eq? o (quote number?)) t) ((eq? o (quote string?)) t) ((eq? o (quote symbol?)) t) ((eq? o (quote <)) t) ((eq? o (quote =)) t) (t nil))))
(define tagtest   (lambda (r tag) (str "[ " (dq) "${" (cdr r) "#" tag "}" (dq) " != " (dq) (shval r) (dq) " ]")))
(define natagtest (lambda (r tag) (str "[ " (dq) "${" (cdr r) "#" tag "}" (dq) " = " (dq) (shval r) (dq) " ]")))

(define pmap-pos (lambda (fs i) (if (null? fs) nil (cons (cons (car fs) (number->string i)) (pmap-pos (cdr fs) (+ i 1))))))
;; a ref is a temp (saveable) iff it's a val whose name starts with "s" (sht<k>);
;; params map to numeric position strings, lit/cst are literals -- none saveable.
(define istemp? (lambda (s) (eq? (substring s 0 1) "s")))
(define live-add (lambda (r live) (if (eq? (car r) (quote val)) (if (istemp? (cdr r)) (cons (cdr r) live) live) live)))
;; caller-save: push live temps onto STK/SP, restore after. Single-quote eval keeps it
;; ksh93-safe and value-space-safe (each STK slot is a separate var).
(define sh-save (lambda (vs) (if (null? vs) nil (cons (str "eval STK$SP='${" (car vs) "}'") (cons "SP=$((SP+1))" (sh-save (cdr vs)))))))
(define sh-restore (lambda (vs) (if (null? vs) nil (cons "SP=$((SP-1))" (cons (str "eval " (car vs) "='${STK'$SP'}'") (sh-restore (cdr vs)))))))

(define setq (lambda (var val) (str var "=" (dq) val (dq))))
(define argstr (lambda (vs) (if (null? vs) "" (str " " (dq) (car vs) (dq) (argstr (cdr vs))))))

;; cretag-sh: (op x) strips x's tag and applies NEWTAG (symbol->string etc.).
(define cretag-sh (lambda (f newtag pmap k live acc)
  (let ((rx (cexpr-sh (car (cdr f)) pmap k live acc)))
    (let ((tmp (str "sht" (number->string (caddr rx)))))
      (list (cons (setq tmp (str newtag (shdet (cadr rx)))) (car rx)) (cons (quote val) tmp) (+ (caddr rx) 1))))))

;; cquote-sh: (quote DATUM). sh strings are literal -> no enc-mc.
(define cquote-sh (lambda (d pmap k live acc)
  (cond ((null? d) (list acc (cons (quote cst) "NIL") k))
        ((pair? d) (cexpr-sh (list (quote cons) (list (quote quote) (car d)) (list (quote quote) (cdr d))) pmap k live acc))
        ((number? d) (list acc (cons (quote lit) (number->string d)) k))
        ((string? d) (list acc (cons (quote cst) (str "T:" d)) k))
        (t (list acc (cons (quote cst) (str "S:" (symbol->string d))) k)))))

;; cargs-sh: compile arg exprs -> (list acc shval-list k), threading live so a later
;; arg's call saves an earlier arg's temp.
(define cargs-sh (lambda (es pmap k live acc)
  (if (null? es) (list acc nil k)
    (let ((r1 (cexpr-sh (car es) pmap k live acc)))
      (let ((rr (cargs-sh (cdr es) pmap (caddr r1) (live-add (cadr r1) live) (car r1))))
        (list (car rr) (cons (shval (cadr r1)) (cadr rr)) (caddr rr)))))))

;; ctest-sh: an `if` test -> (list acc condstr k).
(define ctest-sh (lambda (f pmap k live acc)
  (cond
    ((eq? (car f) (quote null?)) (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc))) (list (car ra) (str "[ " (dq) (shval (cadr ra)) (dq) " = NIL ]") (caddr ra))))
    ((eq? (car f) (quote eq?))
      (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc)))
        (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
          (list (car rb) (str "[ " (dq) (shval (cadr ra)) (dq) " = " (dq) (shval (cadr rb)) (dq) " ]") (caddr rb)))))
    ((eq? (car f) (quote pair?))   (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc))) (list (car ra) (tagtest   (cadr ra) "P:") (caddr ra))))
    ((eq? (car f) (quote atom?))   (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc))) (list (car ra) (natagtest (cadr ra) "P:") (caddr ra))))
    ((eq? (car f) (quote number?)) (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc))) (list (car ra) (tagtest   (cadr ra) "I:") (caddr ra))))
    ((eq? (car f) (quote string?)) (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc))) (list (car ra) (tagtest   (cadr ra) "T:") (caddr ra))))
    ((eq? (car f) (quote symbol?)) (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc))) (list (car ra) (tagtest   (cadr ra) "S:") (caddr ra))))
    (t ;; < or =
      (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc)))
        (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
          (list (car rb) (str "[ " (shdet (cadr ra)) " " (shcmp (car f)) " " (shdet (cadr rb)) " ]") (caddr rb))))))))

;; cexpr-sh: value-position expr -> (list acc ref k). acc = reversed lines.
(define cexpr-sh (lambda (f pmap k live acc)
  (cond
    ((null? f) (list acc (cons (quote cst) "NIL") k))
    ((string? f) (list acc (cons (quote cst) (str "T:" f)) k))   ; self-evaluating string literal
    ((number? f) (list acc (cons (quote lit) (number->string f)) k))
    ((symbol? f)
      (cond ((eq? f (quote nil)) (list acc (cons (quote cst) "NIL") k))
            ((eq? f (quote t))   (list acc (cons (quote cst) "S:t") k))
            (t (list acc (cons (quote val) (lookup f pmap)) k))))
    ((pair? f)
      (cond
        ((eq? (car f) (quote quote)) (cquote-sh (car (cdr f)) pmap k live acc))
        ((arith? (car f))
          (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
              (let ((tmp (str "sht" (number->string (caddr rb)))))
                (list (cons (setq tmp (str "I:$(( " (shdet (cadr ra)) " " (shop (car f)) " " (shdet (cadr rb)) " ))")) (car rb))
                      (cons (quote val) tmp) (+ (caddr rb) 1))))))
        ((eq? (car f) (quote cons))
          (let ((ca (cargs-sh (cdr f) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr ca)))))
              (list (cons (setq tmp "${R}") (cons (str "hp_cons" (argstr (cadr ca))) (car ca))) (cons (quote val) tmp) (+ (caddr ca) 1)))))
        ((eq? (car f) (quote car))
          (let ((rx (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr rx)))))
              (list (cons (setq tmp "${R}") (cons (str "hp_car " (dq) (shval (cadr rx)) (dq)) (car rx))) (cons (quote val) tmp) (+ (caddr rx) 1)))))
        ((eq? (car f) (quote cdr))
          (let ((rx (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr rx)))))
              (list (cons (setq tmp "${R}") (cons (str "hp_cdr " (dq) (shval (cadr rx)) (dq)) (car rx))) (cons (quote val) tmp) (+ (caddr rx) 1)))))
        ((eq? (car f) (quote string-append))
          (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
              (let ((tmp (str "sht" (number->string (caddr rb)))))
                (list (cons (setq tmp (str "T:" (shdet (cadr ra)) (shdet (cadr rb)))) (car rb)) (cons (quote val) tmp) (+ (caddr rb) 1))))))
        ((eq? (car f) (quote symbol->string)) (cretag-sh f "T:" pmap k live acc))
        ((eq? (car f) (quote number->string)) (cretag-sh f "T:" pmap k live acc))
        ((eq? (car f) (quote string->symbol)) (cretag-sh f "S:" pmap k live acc))
        ((eq? (car f) (quote string->number)) (cretag-sh f "I:" pmap k live acc))
        ((eq? (car f) (quote string-length))
          (let ((rx (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr rx)))))
              (list (cons (setq tmp (str "I:$(( ${#" (cdr (cadr rx)) "} - 2 ))")) (car rx)) (cons (quote val) tmp) (+ (caddr rx) 1)))))
        ((pred? (car f))
          (let ((rt (ctest-sh f pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr rt)))))
              (list (cons "fi" (cons (setq tmp "NIL") (cons "else" (cons (setq tmp "S:t") (cons (str "if " (cadr rt) "; then") (car rt))))))
                    (cons (quote val) tmp) (+ (caddr rt) 1)))))
        ((eq? (car f) (quote if))
          (let ((rt (ctest-sh (car (cdr f)) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr rt)))))
              (let ((at (cexpr-sh (car (cdr (cdr f))) pmap (+ (caddr rt) 1) live (cons (str "if " (cadr rt) "; then") (car rt)))))
                (let ((ae (cexpr-sh (cadddr f) pmap (caddr at) live (cons "else" (cons (setq tmp (shval (cadr at))) (car at))))))
                  (list (cons "fi" (cons (setq tmp (shval (cadr ae))) (car ae))) (cons (quote val) tmp) (caddr ae)))))))
        (t ;; user-function call: compute args (live threaded), save live temps, call, capture $R, restore
          (let ((ca (cargs-sh (cdr f) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr ca)))))
              (list (rev (sh-restore (rev live nil))
                      (cons (setq tmp "${R}")
                        (cons (str (symbol->string (car f)) (argstr (cadr ca)))
                          (rev (sh-save live) (car ca)))))
                    (cons (quote val) tmp) (+ (caddr ca) 1)))))))
    (t (list acc (cons (quote cst) "NIL") k)))))

;; ctail-sh: tail position -> (list acc k). Only `if` (tail branches) and the self-tail
;; loop are special; everything else routes through cexpr-sh then `R=…; return`.
(define ctail-sh (lambda (f pmap fname k live acc)
  (cond
    ((and (pair? f) (eq? (car f) (quote if)))
      (let ((rt (ctest-sh (car (cdr f)) pmap k live acc)))
        (let ((a1 (cons (str "if " (cadr rt) "; then") (car rt))))
          (let ((at (ctail-sh (car (cdr (cdr f))) pmap fname (caddr rt) live a1)))
            (let ((ae (ctail-sh (cadddr f) pmap fname (cadr at) live (cons "else" (car at)))))
              (list (cons "fi" (car ae)) (cadr ae)))))))
    ((and (pair? f) (eq? (car f) fname))  ;; tail self-call -> set -- (loop); no temp lives past it
      (let ((ca (cargs-sh (cdr f) pmap k live acc)))
        (list (cons (str "set --" (argstr (cadr ca))) (car ca)) (caddr ca))))
    (t
      (let ((r (cexpr-sh f pmap k live acc)))
        (list (cons "return" (cons (setq "R" (shval (cadr r))) (car r))) (caddr r)))))))

(define compile-fn-sh (lambda (name params body)
  (let ((pm (pmap-pos params 1)))
    (let ((a0 (cons "while :; do" (cons (str (symbol->string name) "() {") nil))))
      (let ((r (ctail-sh body pm name 0 nil a0)))
        (rev (cons "}" (cons "done" (car r))) nil))))))

(define compile-def-sh (lambda (d)
  (compile-fn-sh (car (cdr d)) (car (cdr (car (cdr (cdr d))))) (car (cdr (cdr (car (cdr (cdr d)))))))))
