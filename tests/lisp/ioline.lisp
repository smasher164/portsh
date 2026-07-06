(write-lines "portsh_io_fixture.txt" (list "alpha" "" "beta"))
(define ls (read-lines "portsh_io_fixture.txt"))
(print (car ls))                              ; alpha
(print (string-length (car (cdr ls))))        ; 0  -> blank line preserved
(print (car (cdr (cdr ls))))                  ; beta
(print (car (run-capture echo cap-line)))     ; cap-line
(write-lines "portsh_io_fixture.txt" (list "=lead" "  sp-lead"))
(define l2 (read-lines "portsh_io_fixture.txt"))
(print (car l2))                              ; =lead   -> leading '=' round-trips (wl_enc)
(print (car (cdr l2)))                        ;   sp-lead -> leading spaces round-trip
