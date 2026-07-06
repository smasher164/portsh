;; collect-diagnostics.lisp -- "run this and send support the file": gather system facts
;; into one report, identically shaped on both hosts. The double-clickable-.cmd story:
;;   ./portsh.cmd pack examples/collect-diagnostics.lisp diagnose.cmd
;; and a Windows user double-clicks diagnose.cmd; a unix user runs ./diagnose.cmd.
;;
;;   sh portsh.cmd examples/collect-diagnostics.lisp [OUT.txt]    (default: diagnostics.txt)
;;
;; Command-form guide, demonstrated throughout: the `run`/`run-capture` OPERATIVES take literal
;; tokens -- required for cmd INTERNAL commands with switches (ver, dir /b), which parse their
;; raw command line and reject quoted switches. `run-capture-argv` takes computed tokens --
;; right for external tools (they parse quoted argv fine) and anything built at runtime.

(define windows? (eq? (host) (quote cmd)))

;; one section = a title line, the captured lines, a blank line
(define section (lambda (title lines)
  (append (list (str "== " title " ==")) (append lines (list "")))))

(define os-info
  (if windows?
      (run-capture ver)                          ; ver is a cmd INTERNAL -> literal run-capture
      (run-capture uname -a)))

(define env-line (lambda (name)
  (let ((v (getenv name)))
    (str name "=" (if (null? v) "(unset)" v)))))

(define env-info
  (map env-line
       (if windows?
           (list "USERPROFILE" "TEMP" "PROCESSOR_ARCHITECTURE" "OS")
           (list "HOME" "TMPDIR" "SHELL" "LANG"))))

;; a real hit is a path; misses are "" (which) or an INFO: complaint on stderr (where)
(define found-line? (lambda (s)
  (if (eq? s "") nil
      (if (< (string-length s) 5) t
          (not (eq? (substring s 0 5) "INFO:"))))))
(define tool-check (lambda (name)
  ;; where/which are EXTERNAL tools, and `name` is computed -> run-capture-argv
  (let ((out (run-capture-argv (list (if windows? "where" "which") name))))
    (if (null? out) (str name ": not found")
        (if (found-line? (car out))
            (str name ": " (car out))
            (str name ": not found"))))))

(define tools-info (map tool-check (list "curl" "tar" "git" "jq")))

(define report
  (append (section "portsh" (list (str "program: " (argv0))
                                  (str "host layer: " (if windows? "cmd" "sh"))))
  (append (section "os" os-info)
  (append (section "environment" env-info)
          (section "tools" tools-info)))))

(define out-file (if (null? (argv)) "diagnostics.txt" (car (argv))))
(write-lines out-file report)
(print (str "wrote " out-file " (" (->string (length report)) " lines) -- attach it to your report"))
(exit 0)
