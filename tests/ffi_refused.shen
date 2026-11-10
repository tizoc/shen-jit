\\ A function defined again with a result that gets no type keeps none from before.
(shen-jit.library ffi-refused ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign ffi-refused.f ffi-refused "abs" (int32) --> int32)
(define-foreign ffi-refused.f ffi-refused "strerror" (int32) --> string)
(define ffi-refused.result {--> number} -> (ffi-refused.f 0))
\\ next
(shen-jit.library ffi-refused ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign ffi-refused.g ffi-refused "abs" (int32) --> int32)
(define-foreign-procedure ffi-refused.g ffi-refused "abs" 1)
(define ffi-refused.result {--> number} -> (ffi-refused.g 0))
