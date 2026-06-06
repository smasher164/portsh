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
;; sh function names must be POSIX identifiers ([A-Za-z_][A-Za-z0-9_]*): dash/ksh93
;; reject `mangle-at`, `cargs*`, `all-in?`, etc. Map the non-id chars to safe codes
;; (- -> _, operators/? -> zz-codes). comp's names use - not _, so - -> _ is collision-free.
(define sh-mangle-at (lambda (c) (cond ((eq? c "-") "_") ((eq? c ">") "zzG") ((eq? c "<") "zzL")
  ((eq? c "*") "zzS") ((eq? c "?") "zzQ") ((eq? c "!") "zzB") ((eq? c "=") "zzE") ((eq? c "+") "zzP") (t c))))
(define sh-mangle-go (lambda (s i n acc) (if (= i n) acc (sh-mangle-go s (+ i 1) n (string-append acc (sh-mangle-at (substring s i 1)))))))
(define sh-mangle (lambda (s) (sh-mangle-go s 0 (string-length s) "")))
;; sh-esc: a tagged value's content is emitted INSIDE double quotes (setq/argstr), so a
;; bare $ in a string/symbol literal (comp's "$ELIDE" marker) would shell-expand. Escape
;; $ -> \$ via split/join (one ${%%} op per part; no per-char fork). The shell strips the
;; backslash at runtime, restoring the literal value. (\ stays before a letter, " is the
;; (dq) primitive -- comp's literals carry neither, so $ is the only metacharacter here.)
(define sh-esc-join (lambda (ps) (if (null? (cdr ps)) (car ps) (string-append (car ps) (string-append "\$" (sh-esc-join (cdr ps)))))))
(define sh-esc (lambda (s) (sh-esc-join (split s "$"))))

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
;; iota-str i n -> ("i" "i+1" ... "n"). Used as the positional list ($1..$np) to MIRROR a frame's
;; params into STK for gc. Params are positional (private per call) -> invisible to gc unless mirrored;
;; the mirror is written only at frame entry / self-tail-call (O(arity)), so fast positional access
;; is unchanged. The frame's base index into STK rides in positional $(np+1).
(define iota-str (lambda (i n) (if (< n i) nil (cons (number->string i) (iota-str (+ i 1) n)))))
(define lenl (lambda (xs) (if (null? xs) 0 (+ 1 (lenl (cdr xs))))))

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
        ((string? d) (list acc (cons (quote cst) (str "T:" (sh-esc d))) k))
        (t (list acc (cons (quote cst) (str "S:" (sh-esc (symbol->string d)))) k)))))

;; variadic / boolean source rewrites (what comp's mexpand does): str->string-append,
;; list->cons, and/or->if.
(define dsg-str  (lambda (es) (if (null? es) "" (if (null? (cdr es)) (car es) (list (quote string-append) (car es) (dsg-str (cdr es)))))))
(define dsg-list (lambda (es) (if (null? es) (quote nil) (list (quote cons) (car es) (dsg-list (cdr es))))))
(define dsg-and  (lambda (es) (if (null? es) (quote t)   (if (null? (cdr es)) (car es) (list (quote if) (car es) (dsg-and (cdr es)) (quote nil))))))
(define dsg-or   (lambda (es) (if (null? es) (quote nil) (if (null? (cdr es)) (car es) (list (quote if) (car es) (car es) (dsg-or (cdr es)))))))
;; cond -> nested if (source rewrite). (t e) is the default arm; no clause -> nil.
(define cond->if (lambda (clauses)
  (if (null? clauses) (quote nil)
    (let ((c (car clauses)))
      (if (eq? (car c) (quote t)) (car (cdr c))
        (list (quote if) (car c) (car (cdr c)) (cond->if (cdr clauses))))))))
;; let bindings: each value -> a temp; extend pmap name->temp; temp is live for the rest.
;; Sequential (let*-like). -> (list acc pmap' k live').
(define clet-binds-sh (lambda (binds pmap k live acc)
  (if (null? binds) (list acc pmap k live)
    (let ((rv (cexpr-sh (car (cdr (car binds))) pmap k live acc)))
      (let ((tmp (str "sht" (number->string (caddr rv)))))
        (clet-binds-sh (cdr binds) (cons (cons (car (car binds)) tmp) pmap) (+ (caddr rv) 1)
                       (cons tmp live) (cons (setq tmp (shval (cadr rv))) (car rv))))))))
;; begin in value position: run all but last (discard), value = last.
(define cbegin-sh (lambda (es pmap k live acc)
  (if (null? (cdr es)) (cexpr-sh (car es) pmap k live acc)
    (let ((r1 (cexpr-sh (car es) pmap k live acc))) (cbegin-sh (cdr es) pmap (caddr r1) live (car r1))))))
;; begin in tail position: run all but last (value), tail-compile the last.
(define ctbegin-sh (lambda (es pmap fname np k live acc)
  (if (null? (cdr es)) (ctail-sh (car es) pmap fname np k live acc)
    (let ((r1 (cexpr-sh (car es) pmap k live acc))) (ctbegin-sh (cdr es) pmap fname np (caddr r1) live (car r1))))))

;; cargs-sh: compile arg exprs -> (list acc shval-list k), threading live so a later
;; arg's call saves an earlier arg's temp.
(define cargs-sh (lambda (es pmap k live acc)
  (if (null? es) (list acc nil k)
    (let ((r1 (cexpr-sh (car es) pmap k live acc)))
      (let ((rr (cargs-sh (cdr es) pmap (caddr r1) (live-add (cadr r1) live) (car r1))))
        (list (car rr) (cons (shval (cadr r1)) (cadr rr)) (caddr rr)))))))

;; ctest-sh: an `if` test -> (list acc condstr k).
(define ctest-sh (lambda (f pmap k live acc)
  (if (if (pair? f) (pred? (car f)) nil)
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
            (list (car rb) (str "[ " (shdet (cadr ra)) " " (shcmp (car f)) " " (shdet (cadr rb)) " ]") (caddr rb))))))
    ;; general expression test (a call, a variable, an inlined if, ...): eval -> truthiness
    (let ((rx (cexpr-sh f pmap k live acc)))
      (list (car rx) (str "[ " (dq) (shval (cadr rx)) (dq) " != NIL ]") (caddr rx))))))

;; cexpr-sh: value-position expr -> (list acc ref k). acc = reversed lines.
(define cexpr-sh (lambda (f pmap k live acc)
  (cond
    ((null? f) (list acc (cons (quote cst) "NIL") k))
    ((string? f) (list acc (cons (quote cst) (str "T:" (sh-esc f))) k))   ; self-evaluating string literal
    ((number? f) (list acc (cons (quote lit) (number->string f)) k))
    ((symbol? f)
      (cond ((eq? f (quote nil)) (list acc (cons (quote cst) "NIL") k))
            ((eq? f (quote t))   (list acc (cons (quote cst) "S:t") k))
            (t (let ((p (lookup f pmap)))
                 (if (null? p)
                   (list acc (cons (quote val) (str "G_" (symbol->string f))) k)   ; a global constant (G_<name>)
                   (list acc (cons (quote val) p) k))))))
    ((pair? f)
      (cond
        ((eq? (car f) (quote quote)) (cquote-sh (car (cdr f)) pmap k live acc))
        ((eq? (car f) (quote dq)) (list acc (cons (quote val) "G_DQ") k))  ; runtime: G_DQ='T:"' (literal " would break source)
        ((eq? (car f) (quote str))  (cexpr-sh (dsg-str (cdr f)) pmap k live acc))
        ((eq? (car f) (quote list)) (cexpr-sh (dsg-list (cdr f)) pmap k live acc))
        ((eq? (car f) (quote and))  (cexpr-sh (dsg-and (cdr f)) pmap k live acc))
        ((eq? (car f) (quote or))   (cexpr-sh (dsg-or (cdr f)) pmap k live acc))
        ((eq? (car f) (quote cond)) (cexpr-sh (cond->if (cdr f)) pmap k live acc))
        ((eq? (car f) (quote begin)) (cbegin-sh (cdr f) pmap k live acc))
        ((eq? (car f) (quote let))
          (let ((b (clet-binds-sh (car (cdr f)) pmap k live acc)))
            (cexpr-sh (car (cdr (cdr f))) (car (cdr b)) (car (cdr (cdr b))) (cadddr b) (car b))))
        ((arith? (car f))
          (let ((ra (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((rb (cexpr-sh (car (cdr (cdr f))) pmap (caddr ra) (live-add (cadr ra) live) (car ra))))
              (let ((tmp (str "sht" (number->string (caddr rb)))))
                (list (cons (setq tmp (str "I:$(( " (shdet (cadr ra)) " " (shop (car f)) " " (shdet (cadr rb)) " ))")) (car rb))
                      (cons (quote val) tmp) (+ (caddr rb) 1))))))
        ((eq? (car f) (quote cons))
          ;; hp_cons is the ONLY allocator in compiled code, so it's the only gc trigger.
          ;; The cons ARGS are gc-rooted by gc_run "$@"; the ENCLOSING live temps are not, so
          ;; save them to STK around hp_cons (sh-save/restore; no-op when live is empty) -- gc
          ;; scans STK0..SP-1. car/cdr/string-ops/arith don't allocate; calls already caller-save.
          (let ((ca (cargs-sh (cdr f) pmap k live acc)))
            (let ((tmp (str "sht" (number->string (caddr ca)))))
              (list (rev (sh-restore (rev live nil))
                      (cons (setq tmp "${R}")
                        (cons (str "hp_cons" (argstr (cadr ca)))
                          (rev (sh-save live) (car ca)))))
                    (cons (quote val) tmp) (+ (caddr ca) 1)))))
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
        ((eq? (car f) (quote substring))   ;; (substring s off len) via cut (portable; forks)
          (let ((rs (cexpr-sh (car (cdr f)) pmap k live acc)))
            (let ((ro (cexpr-sh (car (cdr (cdr f))) pmap (caddr rs) (live-add (cadr rs) live) (car rs))))
              (let ((rn (cexpr-sh (cadddr f) pmap (caddr ro) (live-add (cadr ro) (live-add (cadr rs) live)) (car ro))))
                (let ((tmp (str "sht" (number->string (caddr rn)))))
                  (list (cons (setq tmp (str "T:$(printf '%s' " (dq) (shdet (cadr rs)) (dq) " | cut -c$(( " (shdet (cadr ro)) " + 1 ))-$(( " (shdet (cadr ro)) " + " (shdet (cadr rn)) " )))")) (car rn))
                        (cons (quote val) tmp) (+ (caddr rn) 1)))))))
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
                        (cons (str (sh-mangle (symbol->string (car f))) (argstr (cadr ca)))
                          (rev (sh-save live) (car ca)))))
                    (cons (quote val) tmp) (+ (caddr ca) 1)))))))
    (t (list acc (cons (quote cst) "NIL") k)))))

;; ctail-sh: tail position -> (list acc k). Only `if` (tail branches) and the self-tail
;; loop are special; everything else routes through cexpr-sh then `R=…; return`.
(define ctail-sh (lambda (f pmap fname np k live acc)
  (cond
    ((and (pair? f) (eq? (car f) (quote if)))
      (let ((rt (ctest-sh (car (cdr f)) pmap k live acc)))
        (let ((a1 (cons (str "if " (cadr rt) "; then") (car rt))))
          (let ((at (ctail-sh (car (cdr (cdr f))) pmap fname np (caddr rt) live a1)))
            (let ((ae (ctail-sh (cadddr f) pmap fname np (cadr at) live (cons "else" (car at)))))
              (list (cons "fi" (car ae)) (cadr ae)))))))
    ((and (pair? f) (eq? (car f) (quote str)))  (ctail-sh (dsg-str (cdr f)) pmap fname np k live acc))
    ((and (pair? f) (eq? (car f) (quote list))) (ctail-sh (dsg-list (cdr f)) pmap fname np k live acc))
    ((and (pair? f) (eq? (car f) (quote and)))  (ctail-sh (dsg-and (cdr f)) pmap fname np k live acc))
    ((and (pair? f) (eq? (car f) (quote or)))   (ctail-sh (dsg-or (cdr f)) pmap fname np k live acc))
    ((and (pair? f) (eq? (car f) (quote cond))) (ctail-sh (cond->if (cdr f)) pmap fname np k live acc))
    ((and (pair? f) (eq? (car f) (quote begin))) (ctbegin-sh (cdr f) pmap fname np k live acc))
    ((and (pair? f) (eq? (car f) (quote let)))
      (let ((b (clet-binds-sh (car (cdr f)) pmap k live acc)))
        (ctail-sh (car (cdr (cdr f))) (car (cdr b)) fname np (car (cdr (cdr b))) (cadddr b) (car b))))
    ((and (pair? f) (eq? (car f) fname))  ;; tail self-call: set new args + re-append base; reset SP; re-mirror params
      (let ((ca (cargs-sh (cdr f) pmap k live acc)))
        (list (rev (cons (str "set --" (argstr (cadr ca)) " " (dq) "${" (number->string (+ np 1)) "}" (dq))
                     (cons (str "SP=${" (number->string (+ np 1)) "}")
                       (sh-save (iota-str 1 np))))
                   (car ca))
              (caddr ca))))
    (t  ;; return: pop this frame off STK (SP=base, the mirror) before returning
      (let ((r (cexpr-sh f pmap k live acc)))
        (list (cons "return" (cons (str "SP=${" (number->string (+ np 1)) "}") (cons (setq "R" (shval (cadr r))) (car r)))) (caddr r)))))))

(define compile-fn-sh (lambda (name params body)
  (let ((pm (pmap-pos params 1)) (np (lenl params)))
    ;; entry: stash this frame's STK base in positional $(np+1) (survives nested calls), then mirror
    ;; $1..$np into STK so gc can see the params. Then the existing tail loop.
    (let ((a0 (cons "while :; do"
                (rev (sh-save (iota-str 1 np))
                  (cons (str "set -- " (dq) "$@" (dq) " " (dq) "$SP" (dq))
                    (cons (str (sh-mangle (symbol->string name)) "() {") nil))))))
      (let ((r (ctail-sh body pm name np 0 nil a0)))
        (rev (cons "}" (cons "done" (car r))) nil))))))

(define compile-def-sh (lambda (d)
  (compile-fn-sh (car (cdr d)) (car (cdr (car (cdr (cdr d))))) (car (cdr (cdr (car (cdr (cdr d)))))))))
