;; install-jq.lisp -- a cross-platform installer bootstrap: ONE file serving both the unix
;; `curl | sh` convention and the double-clickable Windows path. Downloads the right jq
;; binary for this OS/arch, verifies its sha256 against the release's published checksum
;; file, and installs it as DESTDIR/jq[.exe] (default: the current directory).
;;
;;   sh portsh.cmd examples/install-jq.lisp [DESTDIR]      # unix
;;   portsh.cmd examples\install-jq.lisp [DESTDIR]         # windows
;; or pack it once into a standalone installer:
;;   ./portsh.cmd pack examples/install-jq.lisp install-jq.cmd
;;
;; Everything it relies on ships with the OS: curl is in Windows 10+, and the hash tools
;; are sha256sum (Linux) / shasum (macOS) / certutil (Windows).

(define version "1.7.1")
(define base (str "https://github.com/jqlang/jq/releases/download/jq-" version "/"))

(define die (lambda lines (begin (map print lines) (exit 1))))

;; ---- the host decision, made ONCE; everything below consumes these -----------------------
(define windows? (eq? (host) (quote cmd)))
(define exe-suffix (if windows? ".exe" ""))
(define unix-os (if windows? nil (car (run-capture-argv (list "uname" "-s")))))

;; ---- helpers ---------------------------------------------------------------------------
(define non-empty (lambda (s) (not (eq? s ""))))
(define words (lambda (line) (filter non-empty (split line " "))))   ; split on runs of spaces
;; command EXECUTION on cmd needs backslashes ("./jq.exe" is not runnable); file PRIMITIVES
;; normalize forward slashes themselves, so only run paths need this.
(define run-path (lambda (p) (if windows? (join "\" (split p "/")) p)))

;; ---- platform detection ------------------------------------------------------------------
(define arch-of (lambda (m)
  (cond ((eq? m "x86_64") "amd64") ((eq? m "amd64") "amd64")
        ((eq? m "aarch64") "arm64") ((eq? m "arm64") "arm64")
        (t nil))))

(define platform
  (if windows?
      ;; windows-on-arm runs amd64 binaries via emulation, and jq ships no windows-arm64
      ;; asset -- so every windows machine gets windows-amd64.
      "windows-amd64"
      (let ((arch (arch-of (car (run-capture-argv (list "uname" "-m"))))))
        (cond ((null? arch) nil)
              ((eq? unix-os "Linux") (str "linux-" arch))
              ((eq? unix-os "Darwin") (str "macos-" arch))
              (t nil)))))

(when (null? platform)
  (die "install-jq: unsupported platform (need Linux/macOS on amd64/arm64, or Windows)."))

(define asset (str "jq-" platform exe-suffix))

;; ---- sha256 of a local file, normalized to lowercase bare hex ---------------------------
;; The hash tool is picked by platform (no blind fallback -- a missing tool would spray
;; "command not found" on stderr). certutil's digest is line 2; older windows prints it
;; spaced and uppercase -- strip the spaces and downcase, and the comparison is uniform.
(define hex64? (lambda (s) (= (string-length s) 64)))
(define first-word-hash (lambda (out)
  (if (null? out) nil
      (let ((w (words (car out))))
        (if (null? w) nil
            (let ((h (string-downcase (car w))))
              (if (hex64? h) h nil)))))))
(define local-sha256 (lambda (file)
  (if windows?
      (let ((lines (run-capture-argv (list "certutil" "-hashfile" file "SHA256"))))
        (if (null? lines) nil
            (if (null? (cdr lines)) nil
                (let ((h (string-downcase (join "" (words (car (cdr lines)))))))
                  (if (hex64? h) h nil)))))
      (if (eq? unix-os "Darwin")
          (first-word-hash (run-capture-argv (list "shasum" "-a" "256" file)))
          (first-word-hash (run-capture-argv (list "sha256sum" file)))))))

;; ---- expected sha256: the release's sha256sum.txt, one "<hash>  <file>" line per asset --
(define expected-sha256 (lambda (sums name)
  (if (null? sums) nil
      (let ((w (words (car sums))))
        (if (and (pair? w) (pair? (cdr w)) (eq? (car (cdr w)) name))
            (string-downcase (car w))
            (expected-sha256 (cdr sums) name))))))

;; ---- fetch ------------------------------------------------------------------------------
(define fetch (lambda (url out)
  (unless (= 0 (run-argv (list "curl" "-fsSL" "-o" out url)))
    (die (str "install-jq: download failed: " url)
         "Check your network connection (curl -fsSL was used)."))))

;; ---- main -------------------------------------------------------------------------------
(define main (lambda ()
  (let* ((dest-dir (if (null? (argv)) "." (car (argv))))
         (dest     (str dest-dir "/jq" exe-suffix))
         (tmp      (str dest ".download")))
    (begin
      (print (str "installing jq " version " (" platform ") -> " dest))
      (fetch (str base asset) tmp)
      (fetch (str base "sha256sum.txt") "jq-sums.txt")
      (let ((want (expected-sha256 (read-lines "jq-sums.txt") asset))
            (got  (local-sha256 tmp)))
        (begin
          (delete-file "jq-sums.txt")
          (when (null? want)
            (die (str "install-jq: " asset " not found in sha256sum.txt")))
          (when (null? got)
            (die "install-jq: could not compute a local sha256 (need sha256sum/shasum/certutil)."))
          (unless (eq? want got)
            (begin
              (delete-file tmp)
              (die "install-jq: sha256 MISMATCH -- refusing to install."
                   (str "  expected " want)
                   (str "  got      " got))))))
      (unless (copy-file tmp dest) (die (str "install-jq: cannot write " dest)))
      (delete-file tmp)
      (unless windows?
        (run-argv (list "chmod" "+x" dest)))
      (print (str "verified sha256 ok; installed " dest))
      (run-argv (list (run-path dest) "--version"))))))

(exit (main))
