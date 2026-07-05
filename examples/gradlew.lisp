;; gradlew.lisp -- the Gradle wrapper as one portable program.
;; Pack it once:      ./portsh.cmd pack gradlew.lisp gradlew.cmd
;; and gradlew.cmd is a single file replacing gradlew + gradlew.bat.

(define die (lambda lines (begin (map print lines) (exit 1))))

;; APP_HOME = the directory containing this wrapper (argv0 is absolute, forward slashes,
;; and for a packed app it is the app itself) -- works from any cwd, like real gradlew.
(define app-home
  (join "/" (reverse (cdr (reverse (split (argv0) "/"))))))

(define wrapper-jar (str app-home "/gradle/wrapper/gradle-wrapper.jar"))

;; the java binary's name is HOST DATA, decided once -- the only host-sensitive line
(define java-bin (if (eq? (host) (quote cmd)) "bin/java.exe" "bin/java"))

(define main (lambda ()
  (let* ((java-home (getenv "JAVA_HOME"))
         (java-cmd  (if (null? java-home)
                        "java"                          ; trust PATH
                        (str java-home "/" java-bin)))) ; spaces fine: run-argv quotes per host
    (begin
      (when java-home
        (unless (file-exists? java-cmd)
          (die "ERROR: JAVA_HOME is set but no java executable was found at:"
               (str "  " java-cmd)
               "Fix JAVA_HOME, or unset it to use java from PATH.")))
      (unless (file-exists? wrapper-jar)
        (die (str "ERROR: " wrapper-jar " not found.")
             "This wrapper must sit in the root of a Gradle project."))
      ;; each list element reaches java as EXACTLY ONE argument -- args and paths with
      ;; spaces survive, no env-var bridge, no per-host branching.
      (run-argv (append (list java-cmd "-Xmx64m" "-Xms64m"
                              "-classpath" wrapper-jar
                              "org.gradle.wrapper.GradleWrapperMain")
                        (argv)))))))

(exit (main))
