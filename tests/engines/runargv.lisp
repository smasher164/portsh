; run-argv / run-capture-argv: ONE evaluated argument, a LIST of tokens; each element reaches the
; child as EXACTLY ONE argument (spaces survive -- no host re-splitting). mkdir/rmdir/sort exist on
; both hosts with byte-identical quiet behavior, so the observable is the filesystem, not stdout.
(print (run-argv (list "mkdir" "rav one.d")))
(print (file-exists? "rav one.d"))
(print (file-exists? "rav"))
(print (run-argv (list "rmdir" "rav one.d")))
(print (file-exists? "rav one.d"))
(write-lines "rav in.txt" (list "bb" "aa"))
(print (run-capture-argv (list "sort" "rav in.txt")))
(delete-file "rav in.txt")
