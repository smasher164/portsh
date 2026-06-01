;; A tiny "build script" in portsh — runs real commands via (run ...).
;; (run tok ...) renders its unevaluated operands into a command line and
;; executes it on the host shell (sh on Unix, cmd on Windows), returning the
;; exit code. Same script works on both:
;;
;;   sh   portsh.cmd examples/build.lisp
;;   cmd /c portsh.cmd examples\build.lisp

(run echo building portsh demo)
(run echo step 1 of 2)
(run echo step 2 of 2)
(print done)
