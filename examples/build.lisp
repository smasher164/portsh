;; A tiny "build script" in portsh. Same file runs on Unix and Windows:
;;   sh   portsh.cmd examples/build.lisp
;;   cmd /c portsh.cmd examples\build.lisp
;;
;; (run tok ...)        execute a command on the host shell (returns exit code)
;; (file-exists? "p")   t / () for build conditionals
;; (if c then else)     branch

(run echo building portsh demo)
(if (file-exists? "README.md")
    (run echo found README.md)
    (run echo no README.md))
(print "build done")
