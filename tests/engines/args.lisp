(print (argv))
(print (getenv "PORTSH_TEST_VAR"))
(print (getenv "PORTSH_SURELY_UNSET_XYZ"))
; argv0 differs per leg (fixture path when run directly, the app itself when packed) -- the STEM
; is byte-stable across all of them: args.lisp / args.cmd -> args
(print (car (split (car (reverse (split (argv0) "/"))) ".")))
