\\ C functions for foreign.shen: two of doubles, and one that is not.
(shen-jit.library foreign-libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
(define-foreign foreign-cos foreign-libm "cos" (double) --> double)
(define-foreign foreign-pow foreign-libm "pow" (double double) --> double)
(define-foreign foreign-labs foreign-libm "llabs" (int64) --> int64)
