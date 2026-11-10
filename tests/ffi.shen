\\ C functions called from Shen (lib/ffi.shen), against tests/ffi_lib.c. Run by make test-ffi,
\\ from build/, where that library is, after loading lib/ffi.shen: a macro applies only to
\\ files read after it is defined.

(set ffi-test.*passed* 0)
(set ffi-test.*failed* 0)

(define ffi-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define ffi-test.check
  Name Expected F -> (ffi-test.compare Name Expected (ffi-test.result F)))

(define ffi-test.compare
  _ X X -> (set ffi-test.*passed* (+ 1 (value ffi-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set ffi-test.*failed* (+ 1 (value ffi-test.*failed*)))))

(define ffi-test.report
  -> (output "~A passed, ~A failed~%" (value ffi-test.*passed*) (value ffi-test.*failed*)))

(define ffi-test.prefix
  0 _ -> ""
  N S -> (cn (pos S 0) (ffi-test.prefix (- N 1) (tlstr S))))

\\ ---------------------------------------------------------------------------
\\ What a build without loading can do, which is to say so.

(shen-jit.library libm ["libm.so.6" "libm.dylib" "ucrtbase.dll"])
(define-foreign c-cos libm "cos" (double) --> double)

(if (= (ffi-test.result (freeze (c-cos 0))) [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(ffi-test.check "a function from a system library" 1 (freeze (c-cos 0)))

(shen-jit.library libc ["libc.so.6" "libSystem.dylib" "ucrtbase.dll"])
(define-foreign c-strlen libc "strlen" (string) --> int64)
(ffi-test.check "another" 6 (freeze (c-strlen "sqlite")))

\\ ---------------------------------------------------------------------------
\\ Each type, as a result.

(shen-jit.library t ["./ffi_test.so" "ffi_test.dll"])

(define-foreign add64 t "add64" (int64 int64) --> int64)
(define-foreign too-big t "too_big" () --> int64)
(define-foreign biggest t "biggest" () --> int64)
(define-foreign smallest t "smallest" () --> int64)
(define-foreign neg32 t "neg32" () --> int32)
(define-foreign big32 t "big32" () --> uint32)
(define-foreign dirty32 t "dirty32" () --> int32)
(define-foreign half t "half" (double) --> double)
(define-foreign yes t "yes" () --> bool)
(define-foreign no t "no" () --> bool)
(define-foreign low-byte-clear t "low_byte_clear" () --> bool)
(define-foreign low-byte-set t "low_byte_set" () --> bool)
(define-foreign hello t "hello" () --> string)
(define-foreign no-string t "no_string" () --> string)
(define-foreign no-pointer t "no_pointer" () --> pointer)
(define-foreign nothing t "nothing" () --> void)
(define-foreign times-nothing-ran t "times_nothing_ran" () --> int32)

(ffi-test.check "int64" 5 (freeze (add64 2 3)))
(ffi-test.check "negative int64" -1 (freeze (add64 2 -3)))
(ffi-test.check "the largest fixnum" 2305843009213693951 (freeze (biggest)))
(ffi-test.check "the smallest fixnum" (- -2305843009213693951 1) (freeze (smallest)))
(ffi-test.check "too big for a fixnum"
                [error "foreign: the result 2305843009213693952 is too big for an integer"]
                (freeze (too-big)))
(ffi-test.check "int32 sign-extends" -5 (freeze (neg32)))
(ffi-test.check "uint32 does not" 4000000000 (freeze (big32)))
(ffi-test.check "int32 ignores the upper half" 7 (freeze (dirty32)))
(ffi-test.check "double" 1.25 (freeze (half 2.5)))
(ffi-test.check "a double from an integer" 1.5 (freeze (half 3)))
(ffi-test.check "bool true" true (freeze (yes)))
(ffi-test.check "bool false" false (freeze (no)))
(ffi-test.check "bool is the low byte, clear" false (freeze (low-byte-clear)))
(ffi-test.check "bool is the low byte, set" true (freeze (low-byte-set)))
(ffi-test.check "string" "hello" (freeze (hello)))
(ffi-test.check "a NULL string" [] (freeze (no-string)))
(ffi-test.check "a NULL pointer" [] (freeze (no-pointer)))
(ffi-test.check "void" [] (freeze (nothing)))
(ffi-test.check "and it ran" 1 (freeze (times-nothing-ran)))

\\ ---------------------------------------------------------------------------
\\ Each type, as an argument.

(define-foreign add32 t "add32" (int32 int32) --> int32)
(define-foreign echo-u32 t "echo_u32" (uint32) --> uint32)
(define-foreign negate-bool t "negate_bool" (bool) --> int32)
(define-foreign length-of t "length" (string) --> int64)
(define-foreign rest t "rest" (string) --> string)
(define-foreign is-null t "is_null" (pointer) --> int32)

(ffi-test.check "int32" -2 (freeze (add32 -7 5)))
(ffi-test.check "the largest int32" 2147483647 (freeze (add32 2147483647 0)))
(ffi-test.check "the smallest int32" -2147483648 (freeze (add32 -2147483648 0)))
(ffi-test.check "past int32" [error "foreign: 2147483648 is not an int32"] (freeze (add32 2147483648 0)))
(ffi-test.check "below int32" [error "foreign: -2147483649 is not an int32"] (freeze (add32 -2147483649 0)))
(ffi-test.check "the largest uint32" 4294967295 (freeze (echo-u32 4294967295)))
(ffi-test.check "past uint32" [error "foreign: 4294967296 is not a uint32"] (freeze (echo-u32 4294967296)))
(ffi-test.check "below uint32" [error "foreign: -1 is not a uint32"] (freeze (echo-u32 -1)))
(ffi-test.check "not an integer" [error "foreign: c#34;ac#34; is not an integer"] (freeze (add64 "a" 1)))
(ffi-test.check "a real is not an integer" [error "foreign: 1.5 is not an integer"] (freeze (add64 1.5 1)))
(ffi-test.check "not a number" [error "foreign: a is not a number"] (freeze (half a)))
(ffi-test.check "bool true, as an argument" 0 (freeze (negate-bool true)))
(ffi-test.check "bool false, as an argument" 1 (freeze (negate-bool false)))
(ffi-test.check "not a boolean" [error "foreign: 1 is not a boolean"] (freeze (negate-bool 1)))
(ffi-test.check "not a string" [error "foreign: 1 is not a string"] (freeze (length-of 1)))

\\ Strings: with no NUL in the heap at a multiple of 8, longer than the call's own space,
\\ with a NUL inside, and with the result pointing into the copy.
(define ffi-test.repeat
  0 _ -> ""
  N S -> (cn S (ffi-test.repeat (- N 1) S)))

(ffi-test.check "an empty string" 0 (freeze (length-of "")))
(ffi-test.check "8 bytes" 8 (freeze (length-of "12345678")))
(ffi-test.check "16 bytes" 16 (freeze (length-of "1234567812345678")))
(ffi-test.check "a long string" 5000 (freeze (length-of (ffi-test.repeat 500 "0123456789"))))
(ffi-test.check "a NUL in a string" "foreign:"
                (freeze (ffi-test.prefix 8 (hd (tl (ffi-test.result (freeze (length-of (cn "a" (n->string 0))))))))))
(ffi-test.check "a result pointing into a string" "ello" (freeze (rest "hello")))
(ffi-test.check "and into a long one" 4999 (freeze (length-of (rest (ffi-test.repeat 500 "0123456789")))))

\\ ---------------------------------------------------------------------------
\\ Byte buffers.

(define-foreign fill-bytes t "fill" (bytes int64 int32) --> void)
(define-foreign sum-bytes t "sum_bytes" (bytes int64) --> int64)
(define-foreign write-text t "write_text" (bytes) --> string)

(define ffi-test.filled
  N Byte -> (let B (shen-jit.bytes N)
              (do (fill-bytes B N Byte) B)))

(ffi-test.check "written by C" 9 (freeze (shen-jit.u8 (ffi-test.filled 4 9) 3)))
(ffi-test.check "read by C" 36 (freeze (sum-bytes (ffi-test.filled 4 9) 4)))
(ffi-test.check "a big buffer, apart from the heap" 3000000
                (freeze (sum-bytes (ffi-test.filled 1000000 3) 1000000)))
(ffi-test.check "not a buffer" [error "foreign: c#34;ac#34; is not a byte buffer"] (freeze (sum-bytes "a" 1)))
(ffi-test.check "a result pointing into a buffer" "written" (freeze (write-text (shen-jit.bytes 8))))

\\ ---------------------------------------------------------------------------
\\ Pointers.

(define-foreign a-thing t "a_thing" () --> pointer)
(define-foreign is-thing t "is_thing" (pointer) --> int32)
(define-foreign thing-out t "thing_out" (bytes) --> void)
(define-foreign null-out t "null_out" (bytes) --> void)
(define-foreign pointer-id t "pointer_id" (pointer) --> pointer)

(define ffi-test.out
  F -> (let B (shen-jit.bytes 8)
         (do (F B) (shen-jit.bytes->pointer B 0 thing))))

(ffi-test.check "a pointer" true (freeze (shen-jit.pointer? (a-thing))))
(ffi-test.check "something else" false (freeze (shen-jit.pointer? 1)))
(ffi-test.check "its kind" pointer (freeze (shen-jit.pointer-kind (a-thing))))
(ffi-test.check "given back" 1 (freeze (is-thing (a-thing))))
(ffi-test.check "[] is NULL" 1 (freeze (is-null [])))
(ffi-test.check "not a pointer" [error "foreign: 1 is not a pointer"] (freeze (is-null 1)))
(ffi-test.check "an out-parameter" 1 (freeze (is-thing (ffi-test.out (fn thing-out)))))
(ffi-test.check "its kind, as asked" thing (freeze (shen-jit.pointer-kind (ffi-test.out (fn thing-out)))))
(ffi-test.check "NULL out" [] (freeze (ffi-test.out (fn null-out))))
(ffi-test.check "a kind is a symbol" [error "shen-jit.bytes->pointer: 1 is not a symbol"]
                (freeze (shen-jit.bytes->pointer (shen-jit.bytes 8) 0 1)))
(ffi-test.check "an offset past the end" [error "shen-jit.bytes->pointer: 1 is not a valid offset"]
                (freeze (shen-jit.bytes->pointer (shen-jit.bytes 8) 1 thing)))
(ffi-test.check "= compares both" true (freeze (= (a-thing) (a-thing))))
(ffi-test.check "and the kind counts" false (freeze (= (a-thing) (ffi-test.out (fn thing-out)))))
(ffi-test.check "hash agrees" true (freeze (= (hash (a-thing) 1000000) (hash (a-thing) 1000000))))
(ffi-test.check "an address" true (freeze (> (shen-jit.pointer-address (a-thing)) 0)))
(ffi-test.check "the same one through C" true
                (freeze (= (shen-jit.pointer-address (a-thing)) (shen-jit.pointer-address (pointer-id (a-thing))))))
(ffi-test.check "to a string" "a thing in C" (freeze (shen-jit.pointer->string (a-thing))))
(ffi-test.check "to bytes" 116 (freeze (shen-jit.u8 (shen-jit.pointer->bytes (a-thing) 2 5) 0)))
(ffi-test.check "bytes past a NUL" 13 (freeze (shen-jit.bytes-length (shen-jit.pointer->bytes (a-thing) 0 13))))
(ffi-test.check "[] to a string" [error "shen-jit.pointer->string: [] is not a live pointer"]
                (freeze (shen-jit.pointer->string [])))
(set ffi-test.killed (shen-jit.pointer-kill (ffi-test.out (fn thing-out))))
(ffi-test.check "killed" 0 (freeze (shen-jit.pointer-address (value ffi-test.killed))))
(ffi-test.check "killed, and given to C" "foreign:"
                (freeze (ffi-test.prefix 8 (hd (tl (ffi-test.result (freeze (is-thing (value ffi-test.killed)))))))))
(ffi-test.check "only pointers" [error "shen-jit.pointer-kill: 1 is not a pointer"] (freeze (shen-jit.pointer-kill 1)))
(ffi-test.check "it prints" "#<pointer thing 0x" (freeze (ffi-test.prefix 18 (str (ffi-test.out (fn thing-out))))))
(ffi-test.check "and shows" "#<pointer pointer 0x" (freeze (ffi-test.prefix 20 (make-string "~S" (a-thing)))))

\\ ---------------------------------------------------------------------------
\\ The error codes.

(define-foreign set-c-error t "set_c_error" (int32) --> void)
(define-foreign set-system-error t "set_system_error" (int32) --> void)

(set-c-error 42)
(ffi-test.check "the C library's" 42 (freeze (shen-jit.c-errno)))
(set-system-error 43)
(ffi-test.check "the system's" 43 (freeze (shen-jit.errno)))

\\ ---------------------------------------------------------------------------
\\ Every position of doubles among the first four arguments, for each kind of result. The
\\ functions are defined from data, so that the 32 are not written out.

(define ffi-test.types
  _ 4 -> []
  Mask I -> [(if (= 1 (shen-jit.bit-and (shen-jit.shift-right Mask I) 1)) double int64)
             | (ffi-test.types Mask (+ I 1))])

(define ffi-test.mask
  Mask Suffix Result
  -> (let CName (cn "mask" (cn (str Mask) Suffix))
          Name (intern (cn "t." CName))
       (do (shen-jit.ffi.define Name t CName (ffi-test.types Mask 0) Result false 0)
           (ffi-test.check CName 1234 (freeze ((fn Name) 1 2 3 4))))))

(define ffi-test.masks
  16 -> done
  Mask -> (do (ffi-test.mask Mask "_word" int64)
              (ffi-test.mask Mask "_real" double)
              (ffi-test.masks (+ Mask 1))))
(ffi-test.masks 0)

\\ The most a function can take.
(define-foreign six-words t "six_words" (int64 int64 int64 int64 int64 int64) --> int64)
(define-foreign eight-doubles t "eight_doubles" (double double double double double double double double) --> double)
(define-foreign all-fourteen t "all_fourteen"
  (int64 double int64 double int64 double int64 double int64 double int64 double double double) --> double)

(ffi-test.check "six words" 123456 (freeze (six-words 1 2 3 4 5 6)))
(ffi-test.check "eight doubles" 12345678 (freeze (eight-doubles 1 2 3 4 5 6 7 8)))
(ffi-test.check "all fourteen" 12345678912345 (freeze (all-fourteen 1 2 3 4 5 6 7 8 9 1 2 3 4 5)))

\\ What the macro and the runtime refuse.
(ffi-test.check "too many words" [error "foreign: too-many has too many arguments: at most 6, and 8 doubles"]
                (freeze (shen-jit.ffi.define too-many t "six_words" [int64 int64 int64 int64 int64 int64 int64] int64 false 0)))
(ffi-test.check "void as an argument" [error "foreign: void is not an argument type"]
                (freeze (shen-jit.ffi.define refused t "six_words" [void] int64 false 0)))
(ffi-test.check "bytes as a result" [error "foreign: bytes is not a result type"]
                (freeze (shen-jit.ffi.define refused t "six_words" [] bytes false 0)))
(ffi-test.check "not a type" [error "foreign: float is not a type"]
                (freeze (shen-jit.ffi.define refused t "six_words" [float] int64 false 0)))
(ffi-test.check "no such library" [error "foreign: nowhere is not a library: see shen-jit.library"]
                (freeze (shen-jit.ffi.define refused nowhere "six_words" [] int64 false 0)))
(ffi-test.check "a description checked" [error "shen-jit.foreign: 1 is not a description"]
                (freeze (shen-jit.foreign refused 1)))
(ffi-test.check "a system function" [error "foreign: hd is a system function"]
                (freeze (shen-jit.ffi.define hd t "six_words" [] int64 false 0)))
(ffi-test.check "which still works" 1 (freeze (hd [1])))
(ffi-test.check "and a sealed name" [error "shen.app is sealed and cannot be redefined"]
                (freeze (shen-jit.foreign shen.app (shen-jit.ffi.fill (absvector 7) 0 [a a [] "a" 0 0 a]))))
(ffi-test.check "a variadic with doubles" [error "foreign: refused is variadic, so it cannot use doubles"]
                (freeze (shen-jit.ffi.define refused t "var_one" [int32 double] int64 false 1)))
(ffi-test.check "more fixed than it has"
                [error "foreign: refused takes 1 to 3 fixed arguments, and no more than it has"]
                (freeze (shen-jit.ffi.define refused t "var_one" [int32] int64 false 2)))

\\ ---------------------------------------------------------------------------
\\ Finding functions, on the first call and again.

(shen-jit.library missing ["./no-such-library.so" "no-such-library.dll"])
(define-foreign in-no-library missing "something" () --> void)
(define-foreign no-such-function t "no_such_function" () --> void)
(ffi-test.check "no library" [error "foreign: cannot find something in missing"] (freeze (in-no-library)))
(ffi-test.check "no function" [error "foreign: cannot find no_such_function in t"] (freeze (no-such-function)))
(ffi-test.check "and again" [error "foreign: cannot find no_such_function in t"] (freeze (no-such-function)))

\\ [] is the executable and what it links, which on Windows is nothing. Only libc is sure to be
\\ linked: a linker may drop libm, if the runtime happens to use nothing from it.
(shen-jit.library self [])
(define-foreign self-strlen self "strlen" (string) --> int64)
(if (= (value *os*) "Windows")
    (ffi-test.check "nothing in the executable" [error "foreign: cannot find strlen in self"] (freeze (self-strlen "abc")))
    (ffi-test.check "what the executable links" 3 (freeze (self-strlen "abc"))))

\\ ---------------------------------------------------------------------------
\\ As a function like any other: passed around, curried, redefined, in a tail call, and
\\ with too many arguments, which only code written in KLambda can pass.

(ffi-test.check "by fn" 5 (freeze ((fn add64) 2 3)))
(ffi-test.check "curried" 5 (freeze ((add64 2) 3)))
(ffi-test.check "mapped" [-2 -1] (freeze (map (add32 -3) [1 2])))
(ffi-test.check "arity" 2 (freeze (arity add64)))
(define ffi-test.tail X -> (add64 X 1))
(ffi-test.check "in a tail call" 2 (freeze (ffi-test.tail 1)))
(ffi-test.check "too many arguments" [error "add64: expected 2 arguments, got 3"]
                (freeze (eval-kl [add64 1 2 3])))
(ffi-test.check "and one more" [error "half: expected 1 argument, got 2"]
                (freeze (eval-kl [half 1 2])))

(define ffi-test.calls-redefined X -> (redefined X))
(define-foreign redefined t "half" (double) --> double)
(ffi-test.check "a call compiled first" 2 (freeze (ffi-test.calls-redefined 4)))
(define-foreign redefined t "echo_u32" (uint32) --> uint32)
(ffi-test.check "after redefining" 4 (freeze (ffi-test.calls-redefined 4)))
(define redefined X -> (+ X 1))
(ffi-test.check "and as Shen" 5 (freeze (ffi-test.calls-redefined 4)))

\\ An error raised in a conversion, from deep in other code, unwinds as any other does.
(define ffi-test.down
  0 X -> (half X)
  N X -> (+ 1 (ffi-test.down (- N 1) X)))
(ffi-test.check "caught" [error "foreign: a is not a number"] (freeze (ffi-test.down 100 a)))
(ffi-test.check "by a handler that ignores it" 1 (freeze (trap-error (ffi-test.down 2 a) (/. E 1))))

\\ A value that outlives collections in the slots of the call: each of these allocates.
(define ffi-test.churn
  0 Acc -> Acc
  N Acc -> (ffi-test.churn (- N 1) (cn (rest "abcdefgh") (rest "ijklmnop"))))
(ffi-test.check "strings and collections" "bcdefghjklmnop" (freeze (ffi-test.churn 3000 "")))
(define ffi-test.reals
  0 X -> X
  N X -> (ffi-test.reals (- N 1) (half (* X 2))))
(ffi-test.check "reals and collections" 1.5 (freeze (ffi-test.reals 3000 1.5)))

\\ ---------------------------------------------------------------------------
\\ Variadic functions.

(define-foreign var-one t "var_one" (int32 int32 int32 int32) --> int64 (varargs 1))
(define-foreign var-two t "var_two" (int32 int32 int32) --> int32 (varargs 2))
(define-foreign var-three t "var_three" (int32 int32 int32 int32 int32) --> int32 (varargs 3))
(ffi-test.check "one fixed" 123 (freeze (var-one 3 1 2 3)))
(ffi-test.check "two fixed" 123 (freeze (var-two 1 2 3)))
(ffi-test.check "three fixed" 12345 (freeze (var-three 1 2 3 4 5)))

\\ ---------------------------------------------------------------------------
\\ Calls that wait. With no other thread, an ordinary call.

(define-foreign slow-fill t "slow_fill" (bytes int64 int32 int32) --> int64 blocking)
(ffi-test.check "blocking, alone" 8
                (freeze (let B (ffi-test.filled 4 2)
                             Before (slow-fill B 4 5 1)
                          (if (= (shen-jit.u8 B 0) 5) Before wrong))))

\\ With another thread, which collects while C waits, so that the buffer moves: C works on a
\\ copy, which comes back to wherever the buffer now is. And the error codes are per thread.
(define ffi-test.wait
  Name -> (if (= (value Name) waiting) (ffi-test.wait-more Name) (value Name)))
(define ffi-test.wait-more
  Name -> (do (ffi-test.churn 50 "") (ffi-test.wait Name)))

(set ffi-test.moved waiting)
(thread (freeze (let B (ffi-test.filled 64 2)
                     Before (slow-fill B 64 7 100)
                  (set ffi-test.moved [Before (shen-jit.u8 B 0) (shen-jit.u8 B 63)]))))
(ffi-test.check "a buffer moved during the wait" [128 7 7] (freeze (ffi-test.wait ffi-test.moved)))

(set ffi-test.other-error waiting)
(set-c-error 5)
(thread (freeze (do (set-c-error 6)
                    (ffi-test.churn 2000 "")
                    (set ffi-test.other-error (shen-jit.c-errno)))))
(ffi-test.check "another thread's code" 6 (freeze (ffi-test.wait ffi-test.other-error)))
(ffi-test.check "this thread's code" 5 (freeze (shen-jit.c-errno)))

\\ With threads, one buffer given twice is one copy, so what C writes through one it reads through the other.
(define-foreign alias-bytes t "alias_bytes" (bytes bytes) --> int32 blocking)
(ffi-test.check "one buffer given twice" [42 42]
                (freeze (let B (shen-jit.bytes 1)
                             R (alias-bytes B B)
                          [R (shen-jit.u8 B 0)])))

(ffi-test.report)
