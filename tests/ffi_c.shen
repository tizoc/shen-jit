\\ C written for Shen (include/shen.h), against tests/ffi_lib.c. Run by make test-ffi, from build/,
\\ where that library is, after loading lib/ffi.shen, and by make test-kernel-stress with a
\\ collection at every allocation: so a C local that should be in a root shows at once.

(set c-test.*passed* 0)
(set c-test.*failed* 0)

(define c-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define c-test.check
  Name Expected F -> (c-test.compare Name Expected (c-test.result F)))

(define c-test.compare
  _ X X -> (set c-test.*passed* (+ 1 (value c-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set c-test.*failed* (+ 1 (value c-test.*failed*)))))

(shen-jit.library t ["./ffi_test.so" "ffi_test.dll"])

(define-foreign-procedure sum-list t "sum_list" 1)
(define-foreign-procedure on-each t "on_each" 2)
(define-foreign-procedure call-in-c t "call_in_c" 2)
(define-foreign-procedure forty-two t "forty_two" 0)
(define-foreign-procedure eight-arguments t "eight_arguments" 8)
(define-foreign-procedure kind-of t "kind_of" 1)
(define-foreign-procedure reads-right t "reads_right" 6)
(define-foreign-procedure pointer-of-kind t "pointer_of_kind" 2)
(define-foreign-procedure make-all t "make_all" 0)
(define-foreign-procedure copy-string t "copy_string" 1)
(define-foreign-procedure vector-set-out-of-range t "vector_set_out_of_range" 1)
(define-foreign-procedure huge-vector t "huge_vector" 0)
(define-foreign-procedure huge-bytes t "huge_bytes" 0)
(define-foreign-procedure heap-text t "heap_text" 1)
(define-foreign-procedure global-named t "global_named" 1)
(define-foreign-procedure call-named t "call_named" 2)
(define-foreign-procedure raises t "raises" 0)
(define-foreign-procedure raises-value t "raises_value" 1)
(define-foreign-procedure caught-message t "caught_message" 2)
(define-foreign-procedure caught-exception t "caught_exception" 2)
(define-foreign-procedure early-return t "early_return" 1)
(define-foreign-procedure root-and-unroot t "root_and_unroot" 1)
(define-foreign-procedure keep t "keep" 1)
(define-foreign-procedure kept-value t "kept_value" 0)
(define-foreign-procedure kept-set t "kept_set" 1)
(define-foreign-procedure kept-delete t "kept_delete" 0)
(define-foreign-procedure many-roots t "many_roots" 0)
(define-foreign-procedure released-wait t "released_wait" 2)
(define-foreign-procedure delete-when-released t "delete_when_released" 1)
(define-foreign-procedure delete-on-another-thread t "delete_on_another_thread" 1)
(define-foreign-procedure walk t "walk" 2)

(if (= (c-test.result (freeze (forty-two))) [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

\\ ---------------------------------------------------------------------------
\\ Procedures, called like anything else.

(c-test.check "no arguments" 42 (freeze (forty-two)))
(c-test.check "a list" 6 (freeze (sum-list [1 2 3])))
(c-test.check "an empty list" 0 (freeze (sum-list [])))
(c-test.check "the most arguments" 12345678 (freeze (eight-arguments 1 2 3 4 5 6 7 8)))
(c-test.check "by fn" 3 (freeze ((fn sum-list) [1 2])))
(c-test.check "curried" [1 | 2] (freeze ((call-in-c (/. X (+ X 1))) 1)))
(c-test.check "arity" 2 (freeze (arity call-in-c)))
(c-test.check "too many arguments" [error "forty-two: expected 0 arguments, got 1"]
              (freeze (eval-kl [forty-two 1])))
(c-test.check "refused: too many" [error "foreign: too-many has too many arguments: at most 8"]
              (freeze (shen-jit.ffi.define-procedure too-many t "forty_two" 9)))
(c-test.check "refused: a system function" [error "foreign: hd is a system function"]
              (freeze (shen-jit.ffi.define-procedure hd t "forty_two" 1)))
(define c-test.tail X -> (sum-list X))
(c-test.check "in a tail call" 3 (freeze (c-test.tail [1 2])))

(define c-test.kinds
  [] -> []
  [X | Xs] -> [(kind-of X) | (c-test.kinds Xs)])

(c-test.check "what C sees" [fixnum nil boolean string pair vector symbol real bytes procedure]
              (freeze (c-test.kinds [1 [] true "s" [1] (absvector 1) a-symbol 1.5 (shen-jit.bytes 1) (/. X X)])))

\\ ---------------------------------------------------------------------------
\\ Reading and making.

(define c-test.vector567
  -> (let V (absvector 3)
       (do (address-> V 0 5) (address-> V 1 6) (address-> V 2 7) V)))

(c-test.check "every read, right and wrong" 0
              (freeze (reads-right [1 2] (c-test.vector567) "abcdefgh" (shen-jit.bytes 3) foo 1.5)))
(c-test.check "and C can write to a buffer" 77
              (freeze (let B (shen-jit.bytes 3)
                           R (reads-right [1 2] (c-test.vector567) "abcdefgh" B foo 1.5)
                        (shen-jit.u8 B 2))))

(set made (make-all))
(c-test.check "a real" 1.5 (freeze (nth 1 (value made))))
(c-test.check "a string" "abc" (freeze (nth 2 (value made))))
(c-test.check "bytes given" 2 (freeze (shen-jit.u8 (nth 3 (value made)) 1)))
(c-test.check "bytes of zeros" [0 9 0]
              (freeze (let B (nth 4 (value made)) [(shen-jit.u8 B 0) (shen-jit.u8 B 1) (shen-jit.u8 B 2)])))
(c-test.check "interned, as intern does" true (freeze (nth 5 (value made))))
(c-test.check "a symbol" a-symbol (freeze (nth 6 (value made))))
(c-test.check "a vector" 7 (freeze (<-address (nth 7 (value made)) 0)))
(c-test.check "written from C, with a pointer a collection must follow" true
              (freeze (shen-jit.pointer? (nth 2 (<-address (nth 7 (value made)) 1)))))
(c-test.check "and NULL is []" [] (freeze (nth 8 (value made))))
(c-test.check "a pointer" thing (freeze (shen-jit.pointer-kind (nth 9 (value made)))))
(c-test.check "of its kind" true (freeze (pointer-of-kind (nth 9 (value made)) "thing")))
(c-test.check "not of another" false (freeze (pointer-of-kind (nth 9 (value made)) "other")))
(define c-test.eight
  -> (shen-jit.u8! (shen-jit.bytes 8) 0 1))
(c-test.check "not when dead" false
              (freeze (pointer-of-kind (shen-jit.pointer-kill (shen-jit.bytes->pointer (c-test.eight) 0 thing)) "thing")))

(c-test.check "a string made from one in the heap" "abcdefgh" (freeze (copy-string (cn "abcd" "efgh"))))
(c-test.check "a store out of range" false (freeze (vector-set-out-of-range (c-test.vector567))))
(c-test.check "a vector longer than a header holds" [error "out of memory"] (freeze (huge-vector)))
(c-test.check "and bytes" [error "out of memory"] (freeze (huge-bytes)))
(c-test.check "interned from bytes in the heap" "ffi-heap-intern-93817" (freeze (str (heap-text 0))))
(c-test.check "a pointer's kind from bytes in the heap" "ffi-heap-kind-93817"
              (freeze (str (shen-jit.pointer-kind (heap-text 1)))))
(c-test.check "an error from bytes in the heap" [error "ffi-heap-message-93817"] (freeze (heap-text 2)))

\\ ---------------------------------------------------------------------------
\\ Globals and functions, by name.

(set c-test.global 11)
(define c-test.double X -> (* 2 X))
(c-test.check "a global" 11 (freeze (global-named "c-test.global")))
(c-test.check "no such global" none (freeze (global-named "c-test.no-such-global")))
(c-test.check "a symbol with no value" none (freeze (global-named "c-test.double")))
(c-test.check "a function" 42 (freeze (call-named "c-test.double" 21)))
(c-test.check "no such function" none (freeze (call-named "c-test.no-such-function" 1)))
(c-test.check "a C function by name" 3 (freeze (call-named "sum-list" [1 2])))

\\ ---------------------------------------------------------------------------
\\ Calling Shen, and errors at the boundary: caught inside the nested call, by a handler outside
\\ it, by a quiet one, and by nothing. The handlers balance after each, so later ones work.

(define c-test.churn
  0 A -> A
  N A -> (c-test.churn (- N 1) (cn "x" "y")))

(c-test.check "nested" [1 | 2] (freeze (call-in-c (/. X (+ X 1)) 1)))
(c-test.check "twice nested" [1 1 | 2] (freeze (call-in-c (/. X (call-in-c (/. Y (+ Y 1)) X)) 1)))
(c-test.check "held across collections" ["abcd" | "xy"] (freeze (call-in-c (/. X (c-test.churn 50 "")) (cn "ab" "cd"))))
(c-test.check "an error caught inside" [1 | "hd: 1 is not a pair"]
              (freeze (call-in-c (/. X (trap-error (hd X) (/. E (error-to-string E)))) 1)))
(c-test.check "caught outside" [error "hd: 1 is not a pair"] (freeze (call-in-c (/. X (hd X)) 1)))
(c-test.check "caught by a quiet handler" 8 (freeze (+ 1 (trap-error (call-in-c (/. X (hd X)) 1) (/. E 7)))))
(c-test.check "from two levels down" [error "hd: 2 is not a pair"]
              (freeze (call-in-c (/. X (call-in-c (/. Y (hd Y)) 2)) 1)))
(c-test.check "not a function" [error "1 is not a function"] (freeze (call-in-c 1 2)))
(c-test.check "and handlers still work" 3 (freeze (trap-error (+ 1 2) (/. E 0))))

(set seen [])
(c-test.check "a list walked with a callback" true
              (freeze (on-each [1 2 3] (/. X (set seen [X | (value seen)])))))
(c-test.check "in order" [3 2 1] (freeze (value seen)))
(c-test.check "an error in it" [error "boom"] (freeze (on-each [1 2] (/. X (simple-error "boom")))))

(c-test.check "raised in C" [error "from C"] (freeze (raises)))
(c-test.check "with a value" [error "C refuses [1 2] here"] (freeze (raises-value [1 2])))
(c-test.check "a quiet handler" 1 (freeze (trap-error (raises) (/. E 1))))
(c-test.check "raised, by a type" [error "sum_list: a is not an integer"] (freeze (sum-list [1 a])))

(c-test.check "caught in C, which goes on" "hd: 1 is not a pair"
              (freeze (caught-message (/. X (hd X)) 1)))
(c-test.check "the error itself" "hd: 1 is not a pair"
              (freeze (error-to-string (caught-exception (/. X (hd X)) 1))))
(c-test.check "no error to catch" no-error (freeze (caught-exception (/. X X) 1)))

\\ ---------------------------------------------------------------------------
\\ Roots.

(c-test.check "an early return, with roots left" "a" (freeze (early-return 1)))
(c-test.check "and a raise" [error "and with an error"] (freeze (early-return [1])))
(c-test.check "the frame gone at the next collection" "xy" (freeze (c-test.churn 50 "")))
(c-test.check "unrooted by hand" ["kept" | 1] (freeze (root-and-unroot 1)))

(c-test.check "a root that outlives the call" true (freeze (keep (cn "kept" " value"))))
(c-test.churn 50 "")
(c-test.check "and it is there" "kept value" (freeze (kept-value)))
(c-test.check "set" true (freeze (kept-set (cn "another" " value"))))
(c-test.churn 50 "")
(c-test.check "and there too" "another value" (freeze (kept-value)))
(c-test.check "deleted" true (freeze (kept-delete)))
(c-test.churn 50 "")
(c-test.check "more than a chunk of them" 0 (freeze (many-roots)))
(c-test.check "deleted between release and acquire" true (freeze (delete-when-released 1)))
(c-test.check "and on a thread of C's own" 0 (freeze (delete-on-another-thread (cn "a" "b"))))

\\ ---------------------------------------------------------------------------
\\ A callback from a library, with userdata.

(set seen [])
(c-test.check "every call" 3 (freeze (walk 3 (/. I (set seen [I | (value seen)])))))
(c-test.check "with what it was given" [2 1 0] (freeze (value seen)))
(c-test.check "stopped by the callback" 1 (freeze (walk 5 (/. I (< I 1)))))
(c-test.check "an error in it, through the library" [error "boom"] (freeze (walk 5 (/. I (simple-error "boom")))))
(c-test.check "with collections" 3 (freeze (walk 3 (/. I (c-test.churn 20 "")))))

\\ ---------------------------------------------------------------------------
\\ shen_release and shen_acquire around a wait, which change nothing now.
(c-test.check "a release around a wait" "alone" (freeze (released-wait "alone" 1)))

(output "~A passed, ~A failed~%" (value c-test.*passed*) (value c-test.*failed*))
