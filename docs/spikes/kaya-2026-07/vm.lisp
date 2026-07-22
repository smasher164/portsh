;; kaya's Windows-VM helper: every guest-side action deploy-win.sh
;; needs, as ONE portsh program with subcommands — replacing the
;; 60-file run_*.cmd zoo (the forgotten-clone class) and every inline
;; run_ssh command string (docs/traps.md: interior double quotes
;; re-pair through Windows sshd's own cmd /c wrapper; the structural
;; guard is to ship script FILES, and this is that file). Runs under
;; the vendored tools/guest/portsh.cmd (upstream pin in
;; deploy-win.sh); the sh half of portsh runs the same program on the
;; mac, which is what tools/check-winlegs.sh uses --dry for.
;;
;;   portsh.cmd vm.lisp leg NAME [--dry]
;;       One suite leg. NAME = [scene_]lang (milestone2 legs are the
;;       bare lang). Writes C:/kaya/out_NAME.txt with the guest's
;;       merged output and a trailing EXIT=n line — the retired cmd
;;       zoo's exact contract, except EXIT is portsh-observed (no
;;       %ERRORLEVEL% parse-time trap). --dry prints the plan.
;;   portsh.cmd vm.lisp prep
;;       Per-deploy directory resets (cs, bindings/python, java).
;;   portsh.cmd vm.lisp build-java
;;       Compile the shipped java sources in place (javac expands
;;       the wildcard itself; cmd never globs).
;;   portsh.cmd vm.lisp provision
;;       Idempotent toolchain: go127 (curl+tar — Windows ships both,
;;       and portsh strings cannot hold the quotes powershell
;;       -Command wants), and the ARM64 JDK (--architecture arm64 is
;;       LOAD-BEARING: winget under the emulated x64 shell defaults
;;       to x64, whose JVM cannot load the aarch64 kaya.dll).
;;   portsh.cmd vm.lisp provision-full
;;       provision + the Windows App Runtime installer (shipped by
;;       deploy-win under --provision).
;;   portsh.cmd vm.lisp legs-plan SCENE...
;;       Print the --dry plan for every SCENE x lang in ONE run —
;;       tools/check-winlegs.sh asserts this on the mac (one
;;       invocation on purpose: the sh half JIT-compiles per run,
;;       ~26s on bash, so per-leg invocation would cost half an
;;       hour; upstream note filed).
;;   portsh.cmd vm.lisp kill SCENE...
;;       taskkill the scene exes (passed in — SCENES stays
;;       single-registration in deploy-win.sh) + the guest runtimes.

(define args (argv))
(define sub (if (null? args) nil (car args)))
(define rest (if (null? args) nil (cdr args)))

(define kaya "C:\kaya")

(define die (lambda lines (begin (map print lines) (exit 1))))

;; One composed cmd line, run via cmd /c; returns the exit code. The
;; composition is local to this file and covered by the --dry gate —
;; no ssh layer ever sees these strings.
(define sh-run (lambda (line) (run-argv (list "cmd" "/c" line))))

;; ---- leg -------------------------------------------------------------

(define langs (list "rust" "python" "go" "csharp" "java"))

;; The go toolchain's mingw dir is versioned (llvm-mingw-*): discover
;; it at run time; under --dry (mac side) it does not exist, so a
;; stable placeholder keeps the plan printable.
(define mingw-bin (lambda (dry?)
  (if dry?
      (str kaya "\llvm-mingw-VERSION\bin")
      (let ((found (run-capture-argv
                     (list "cmd" "/c" (str "dir /b /ad " kaya "\llvm-mingw-*")))))
        (if (null? found)
            (die "vm.lisp leg: no llvm-mingw-* under C:\kaya")
            (str kaya "\" (car found) "\bin"))))))

;; Env for the leg (setenv: inherited by the child) + the guest
;; command line — one table instead of sixty files.
(define leg-cmdline (lambda (scene lang dry?)
  (cond
    ((eq? lang "rust")
     (str "cd /d " kaya " & " kaya "\" scene ".exe"))
    ((eq? lang "python")
     (begin
       (setenv "PATH" (str kaya ";" (getenv "PATH")))
       (setenv "PYTHONPATH" (str kaya "\bindings\python"))
       (str "cd /d " kaya " & python " kaya "\" scene ".py")))
    ((eq? lang "go")
     (begin
       (setenv "PATH" (str kaya ";" (mingw-bin dry?) ";"
                          kaya "\go127\go\bin;" (getenv "PATH")))
       (setenv "CGO_ENABLED" "1")
       (setenv "CC" "aarch64-w64-mingw32-clang")
       (str "cd /d " kaya " & go run dev.kaya/guests/go/" scene)))
    ((eq? lang "csharp")
     (begin
       (setenv "PATH" (str kaya ";" (getenv "PATH")))
       (setenv "DOTNET_CLI_TELEMETRY_OPTOUT" "1")
       (str "cd /d " kaya "\cs & dotnet run")))
    ((eq? lang "java")
     (begin
       (setenv "PATH" (str kaya ";" (getenv "PATH")))
       (str "cd /d " kaya
            " & java -cp " kaya "\java\classes dev.kaya.milestone2kt.Main")))
    (t (die (str "vm.lisp leg: unknown lang " lang))))))

(define leg (lambda (name dry?)
  (let* ((parts (split name "_"))
         (lang (car (reverse parts)))
         (scene (if (null? (cdr parts)) "milestone2" (car parts)))
         (selftest (if (eq? scene "milestone2") "1" scene))
         (out (str kaya "\out_" name ".txt")))
    (unless (member? lang langs)
      (die (str "vm.lisp leg: unknown lang in " name)))
    (setenv "KAYA_SELFTEST" selftest)
    (let ((line (str (leg-cmdline scene lang dry?) " > " out " 2>&1")))
      (if dry?
          (begin
            (print (str "LEG " name " scene=" scene " lang=" lang
                        " selftest=" selftest))
            (print (str "CMD " line)))
          (let ((code (sh-run line)))
            (append-lines out (list (str "EXIT=" (number->string code))))))))))

;; ---- prep ------------------------------------------------------------

;; portsh has no recursive delete (upstream note) — cmd's rmdir /s /q
;; is the host tool for the job; mkdir creates parents.
(define reset-dir (lambda (p)
  (begin
    (sh-run (str "if exist " p " rmdir /s /q " p))
    (sh-run (str "mkdir " p)))))

(define prep (lambda ()
  (begin
    (reset-dir (str kaya "\cs"))
    (reset-dir (str kaya "\bindings\python"))
    (reset-dir (str kaya "\java\src")))))

;; ---- build-java ------------------------------------------------------

(define build-java (lambda ()
  (let ((code (sh-run (str "javac -d " kaya "\java\classes "
                           kaya "\java\src\*.java"))))
    (when (not (= code 0))
      (die "vm.lisp build-java: javac failed")))))

;; ---- provision -------------------------------------------------------

(define provision (lambda (full?)
  (begin
    (if (file-exists? "C:/kaya/go127/go/bin/go.exe")
        (print "go127 present")
        (begin
          (sh-run (str "curl -fsSL -o " kaya "\go127.zip "
                       "https://go.dev/dl/go1.27rc2.windows-arm64.zip"))
          (sh-run (str "mkdir " kaya "\go127"))
          (sh-run (str "tar -C " kaya "\go127 -xf " kaya "\go127.zip"))
          (sh-run (str "del " kaya "\go127.zip"))))
    (if (= 0 (sh-run "java -version >nul 2>&1"))
        (print "jdk present")
        (sh-run (str "winget install --id Microsoft.OpenJDK.17 "
                     "--architecture arm64 --silent "
                     "--accept-package-agreements "
                     "--accept-source-agreements --scope machine")))
    (when full?
      (sh-run (str kaya "\WindowsAppRuntimeInstall-arm64.exe --quiet --force"))))))

;; ---- kill ------------------------------------------------------------

(define kill-guests (lambda (scenes)
  (begin
    (map (lambda (s) (sh-run (str "taskkill /f /im " s ".exe 2>nul")))
         scenes)
    (map (lambda (p) (sh-run (str "taskkill /f /im " p " 2>nul")))
         (list "python.exe" "go.exe" "dotnet.exe" "java.exe" "cdb.exe"))
    0)))

;; ---- legs-plan -------------------------------------------------------

(define leg-name (lambda (scene lang)
  (if (eq? scene "milestone2") lang (str scene "_" lang))))

(define legs-plan (lambda (scenes)
  (map (lambda (scene)
         (map (lambda (lang) (leg (leg-name scene lang) t)) langs))
       scenes)))

;; ---- dispatch --------------------------------------------------------

(cond
  ((eq? sub "leg")
   (if (null? rest)
       (die "vm.lisp leg: missing NAME")
       (leg (car rest) (member? "--dry" rest))))
  ((eq? sub "prep") (prep))
  ((eq? sub "build-java") (build-java))
  ((eq? sub "provision") (provision nil))
  ((eq? sub "provision-full") (provision t))
  ((eq? sub "legs-plan")
   (if (null? rest) (die "vm.lisp legs-plan: pass the scene list") (legs-plan rest)))
  ((eq? sub "kill") (kill-guests rest))
  (t (die "vm.lisp: unknown subcommand (leg|prep|build-java|provision|provision-full|kill)")))
