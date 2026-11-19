\\ Loaded twice by tests/typed.shen under (tc +), sealed the first time, so that the second
\\ definition typechecks and then raises as it is installed.
(define typed-sealed {fixnum --> fixnum} N -> (fx+ N 1))
