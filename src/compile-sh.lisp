;;; src/compile-sh.lisp — the portsh Lisp->sh backend (sibling of compile.lisp's
;;; Lisp->batch backend). Emits NATIVE sh functions:
;;;   - an applicative -> an sh function;
;;;   - args arrive as POSITIONAL params ($1,$2,...) -- private per call, so
;;;     recursion needs NO caller-save stack (the batch backend's big complication);
;;;   - the result is returned in global $R;
;;;   - arithmetic is $(( )) on detagged values; values keep the interpreter's tags.
;;; ksh93-safe by construction (positional frames; uniquely-numbered global temps).
;;; Output is a LIST OF LINES (write-lines), like the batch backend.
;;;
;;; CORE subset for now: + - *, < =, if, params, integer/symbol literals, tail
;;; self-recursion (-> while+set--), and calls (non-tail -> recurse, result in $R).
;;; TODO: cons/car/cdr (kernel heap), strings, let/cond via mexpand, general calls.

(define cadddr (lambda (x) (car (cdr (cdr (cdr x))))))
(define rev (lambda (xs acc) (if (null? xs) acc (rev (cdr xs) (cons (car xs) acc)))))
(define lookup (lambda (k al) (if (null? al) nil (if (eq? (car (car al)) k) (cdr (car al)) (lookup k (cdr al))))))

;; refs: (lit . "n") int literal | (val . "VAR") an sh name/position holding a TAGGED
;; value | (cst . "TAGGED") a literal tagged value carried verbatim.
;; shval: the tagged value (for calls / set-- / return).
(define shval (lambda (r)
  (cond ((eq? (car r) (quote lit)) (str "I:" (cdr r)))
        ((eq? (car r) (quote cst)) (cdr r))
        (t (str "${" (cdr r) "}")))))
;; shdet: detagged (strip the 2-char tag) for arithmetic / comparison.
(define shdet (lambda (r)
  (cond ((eq? (car r) (quote lit)) (cdr r))
        ((eq? (car r) (quote cst)) (substring (cdr r) 2 (- (string-length (cdr r)) 2)))
        (t (str "${" (cdr r) "#??}")))))
(define shop (lambda (o) (cond ((eq? o (quote +)) "+") ((eq? o (quote -)) "-") ((eq? o (quote *)) "*") (t "?"))))
(define arith? (lambda (o) (if (eq? o (quote +)) t (if (eq? o (quote -)) t (eq? o (quote *))))))
(define shcmp (lambda (o) (cond ((eq? o (quote <)) "-lt") ((eq? o (quote =)) "-eq") (t "?"))))

;; pmap: param symbol -> positional index string ("1","2",...).
(define pmap-pos (lambda (fs i) (if (null? fs) nil (cons (cons (car fs) (number->string i)) (pmap-pos (cdr fs) (+ i 1))))))

;; cexpr-sh: value-position expr -> (list acc ref k). acc = reversed lines so far.
(define cexpr-sh (lambda (f pmap k acc)
  (cond
    ((number? f) (list acc (cons (quote lit) (number->string f)) k))
    ((symbol? f) (list acc (cons (quote val) (lookup f pmap)) k))
    ((pair? f)
      (cond
        ((arith? (car f))
          (let ((ra (cexpr-sh (car (cdr f)) pmap k acc)))
            (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (car ra))))
              (let ((tmp (str "sht" (number->string (caddr rb)))))
                (list (cons (str tmp "=I:$(( " (shdet (cadr ra)) " " (shop (car f)) " " (shdet (cadr rb)) " ))") (car rb))
                      (cons (quote val) tmp) (+ (caddr rb) 1))))))
        (t ;; a call (fn args...) in value position: compute args -> temps, call, capture $R
          (let ((ca (cargs-sh (cdr f) pmap k acc)))
            (let ((tmp (str "sht" (number->string (caddr ca)))))
              (list (cons (str tmp "=${R}") (cons (str (symbol->string (car f)) (argstr (cadr ca))) (car ca)))
                    (cons (quote val) tmp) (+ (caddr ca) 1)))))))
    (t (list acc (cons (quote cst) "NIL") k)))))

;; cargs-sh: compile a list of arg exprs -> (list acc shval-list k).
(define cargs-sh (lambda (es pmap k acc)
  (if (null? es) (list acc nil k)
    (let ((r1 (cexpr-sh (car es) pmap k acc)))
      (let ((rr (cargs-sh (cdr es) pmap (caddr r1) (car r1))))
        (list (car rr) (cons (shval (cadr r1)) (cadr rr)) (caddr rr)))))))
;; argstr: " v1 v2 ..." (leading space each), already shval strings.
(define argstr (lambda (vs) (if (null? vs) "" (str " " (car vs) (argstr (cdr vs))))))

;; ctest-sh: an `if` test -> (list acc condstr k). Handles < = (arith) and null?/eq?.
(define ctest-sh (lambda (f pmap k acc)
  (cond
    ((eq? (car f) (quote null?))
      (let ((ra (cexpr-sh (car (cdr f)) pmap k acc)))
        (list (car ra) (str "[ " (shval (cadr ra)) " = NIL ]") (caddr ra))))
    ((eq? (car f) (quote eq?))
      (let ((ra (cexpr-sh (car (cdr f)) pmap k acc)))
        (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (car ra))))
          (list (car rb) (str "[ " (shval (cadr ra)) " = " (shval (cadr rb)) " ]") (caddr rb)))))
    (t ;; < or =
      (let ((ra (cexpr-sh (car (cdr f)) pmap k acc)))
        (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (car ra))))
          (list (car rb) (str "[ " (shdet (cadr ra)) " " (shcmp (car f)) " " (shdet (cadr rb)) " ]") (caddr rb))))))))

;; ctail-sh: tail-position expr -> (list acc k). Emits R=...; return | set -- (loop) |
;; if/then/else/fi with tail branches.
(define ctail-sh (lambda (f pmap fname k acc)
  (cond
    ((number? f) (list (cons "return" (cons (str "R=I:" (number->string f)) acc)) k))
    ((symbol? f) (list (cons "return" (cons (str "R=${" (lookup f pmap) "}") acc)) k))
    ((pair? f)
      (cond
        ((eq? (car f) (quote if))
          (let ((rt (ctest-sh (car (cdr f)) pmap k acc)))
            (let ((a1 (cons (str "if " (cadr rt) "; then") (car rt))))
              (let ((at (ctail-sh (car (cdr (cdr f))) pmap fname (caddr rt) a1)))
                (let ((a2 (cons "else" (car at))))
                  (let ((ae (ctail-sh (cadddr f) pmap fname (cadr at) a2)))
                    (list (cons "fi" (car ae)) (cadr ae))))))))
        ((arith? (car f))
          (let ((r (cexpr-sh f pmap k acc)))
            (list (cons "return" (cons (str "R=" (shval (cadr r))) (car r))) (caddr r))))
        ((eq? (car f) fname) ;; tail self-call -> compute args to temps, set -- (loop)
          (let ((ca (cargs-sh (cdr f) pmap k acc)))
            (list (cons (str "set --" (argstr (cadr ca))) (car ca)) (caddr ca))))
        (t ;; tail non-self call -> call (sets R), return
          (let ((ca (cargs-sh (cdr f) pmap k acc)))
            (list (cons "return" (cons (str (symbol->string (car f)) (argstr (cadr ca))) (car ca))) (caddr ca))))))
    (t (list (cons "return" (cons "R=NIL" acc)) k)))))

;; compile-fn-sh: (name params body) -> list of sh lines for the function.
(define compile-fn-sh (lambda (name params body)
  (let ((pm (pmap-pos params 1)))
    (let ((a0 (cons "while :; do" (cons (str (symbol->string name) "() {") nil))))
      (let ((r (ctail-sh body pm name 0 a0)))
        (rev (cons "}" (cons "done" (car r))) nil))))))

;; compile-def-sh: take a (define name (lambda params body)) form -> sh lines.
(define compile-def-sh (lambda (d)
  (compile-fn-sh (car (cdr d)) (car (cdr (car (cdr (cdr d))))) (car (cdr (cdr (car (cdr (cdr d)))))))))
