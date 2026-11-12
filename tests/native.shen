\\ Native code written by hand (lib/native.shen): code the builder and the
\\ checker accept runs as written, and code they should refuse never reaches the
\\ JIT. Run by make test-native, from the repository's root, after loading
\\ lib/native.shen: a macro applies only to files read after it is defined.

(set native-test.*passed* 0)
(set native-test.*failed* 0)

(define native-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define native-test.check
  Name Expected F -> (native-test.compare Name Expected (native-test.result F)))

(define native-test.compare
  _ X X -> (set native-test.*passed* (+ 1 (value native-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set native-test.*failed* (+ 1 (value native-test.*failed*)))))

\\ Code that must be refused, as hand-written code objects and through the builder.
\\ What matters is that the JIT never sees it: running it could crash. Code objects
\\ are data, so brackets write them; the macro takes forms.
(define native-test.refused
  Name F -> (native-test.compare Name refused
              (trap-error (do (thaw F) accepted) (/. E refused))))

(define native-test.raw
  Name Code -> (native-test.refused Name (freeze (shen-jit.install-code Code))))

\\ ---------------------------------------------------------------------------
\\ Code that runs.

\\ A loop: parameters overwritten in place, and a tail call with its arguments
\\ already in their slots, which the JIT compiles to a jump.
(define-native native-test.sum (Xs Acc)
  (prim T cons? Xs)
  (jump-if-false T done)
  (prim H hd Xs)
  (prim Acc + Acc H)
  (prim Xs tl Xs)
  (tail-call native-test.sum Xs Acc)
  (label done)
  (return Acc))
(native-test.check "a loop" 10 (freeze (native-test.sum [1 2 3 4] 0)))
(native-test.check "through fn" 3 (freeze ((fn native-test.sum) [1 2] 0)))
(native-test.check "a type error raises" error (freeze (hd (native-test.result (freeze (native-test.sum [a] 0))))))

(define native-test.numbers
  0 Acc -> Acc
  N Acc -> (native-test.numbers (- N 1) [N | Acc]))
(native-test.check "a long loop" 5000050000 (freeze (native-test.sum (native-test.numbers 100000 []) 0)))

\\ A tail call whose arguments swap, and ones that rotate or reach past the
\\ parameters, over a slot in use.
(define-native native-test.swap (A B N)
  (prim T = N 0)
  (jump-if-false T more)
  (prim R cons A B)
  (return R)
  (label more)
  (prim N1 - N 1)
  (tail-call native-test.swap B A N1))
(native-test.check "swapped arguments" [1 | 2] (freeze (native-test.swap 1 2 4)))
(native-test.check "swapped, odd" [2 | 1] (freeze (native-test.swap 1 2 3)))

(define-native native-test.three (A B C)
  (prim R cons B C)
  (prim R cons A R)
  (return R))
(define-native native-test.rotate (A B C)
  (tail-call native-test.three B C A))
(native-test.check "rotated arguments" [2 3 | 1] (freeze (native-test.rotate 1 2 3)))
(define-native native-test.widen (A)
  (prim X + A 1)
  (tail-call native-test.three X A X))
(native-test.check "more arguments than parameters" [2 1 | 2] (freeze (native-test.widen 1)))

\\ Constants: a string, a real, a Boolean, a symbol, a list, and with const the
\\ value of an expression, here one that is no literal.
(set native-test.*vector* (vector 2))
(define-native native-test.constants ()
  (prim A cons "s" [])
  (prim A cons 1.5 A)
  (prim A cons true A)
  (prim B cons foo A)
  (move C [1 2])
  (prim D cons C B)
  (prim E cons (const (value native-test.*vector*)) D)
  (return E))
(native-test.check "constants" [[1 2] foo true 1.5 "s"] (freeze (tl (native-test.constants))))
(native-test.check "a heap value as a constant" true
  (freeze (= (hd (native-test.constants)) (value native-test.*vector*))))

\\ Calls: an open one, a sealed one and one of a variable.
(define native-test.double X -> (* 2 X))
(define-native native-test.calls (X F)
  (call A native-test.double X)
  (call B reverse [1 2 3])
  (call C F A)
  (prim R cons C B)
  (return R))
(native-test.check "calls" [7 3 2 1] (freeze (native-test.calls 3 (/. X (+ X 1)))))
(define-native native-test.tail-of-variable (F X)
  (tail-call F X))
(native-test.check "a tail call of a variable" 4 (freeze (native-test.tail-of-variable (/. X (+ X 1)) 3)))

\\ Calls clobber the window, not the slots below it.
(define-native native-test.survive (X)
  (move A 10)
  (move B 20)
  (call C native-test.double X)
  (prim R + A B)
  (prim R + R C)
  (return R))
(native-test.check "slots survive a call" 36 (freeze (native-test.survive 3)))

\\ An open call sees a redefinition.
(define-native native-test.answer () (return 1))
(define-native native-test.ask () (call X native-test.answer) (return X))
(native-test.check "first definition" 1 (freeze (native-test.ask)))
(define-native native-test.answer () (return 2))
(native-test.check "redefined" 2 (freeze (native-test.ask)))

\\ Closures: a captured value and a freeze.
(define-native native-test.adder (N)
  (closure F (X) (N)
    (prim R + X N)
    (return R))
  (return F))
(native-test.check "a closure" 5 (freeze ((native-test.adder 2) 3)))
(define-native native-test.later (A B)
  (closure F () (A B)
    (prim R cons A B)
    (return R))
  (return F))
(native-test.check "a freeze" [1 | 2] (freeze (thaw (native-test.later 1 2))))

\\ Handlers: reading the exception, quietly, nested, and around a call.
(define-native native-test.safe-hd (X)
  (push-handler caught)
  (prim R hd X)
  (pop-handler)
  (return R)
  (label caught)
  (exception E)
  (prim S error-to-string E)
  (return S))
(native-test.check "no error" 1 (freeze (native-test.safe-hd [1])))
(native-test.check "an error caught" "hd: 2 is not a pair" (freeze (native-test.safe-hd 2)))
(define-native native-test.quiet (X)
  (push-handler caught)
  (prim R hd X)
  (pop-handler)
  (return R)
  (label caught)
  (return none))
(native-test.check "caught quietly" none (freeze (native-test.quiet 2)))
(define-native native-test.nested (X)
  (push-handler outer)
  (push-handler inner)
  (prim R hd X)
  (pop-handler)
  (jump after)
  (label inner)
  (prim R simple-error "again")
  (label after)
  (prim R tl X)
  (pop-handler)
  (return R)
  (label outer)
  (exception E)
  (prim S error-to-string E)
  (return S))
(native-test.check "nested handlers" "again" (freeze (native-test.nested 2)))
(native-test.check "nested, no error" [2] (freeze (native-test.nested [1 2])))
(define-native native-test.call-in-handler (X)
  (push-handler caught)
  (call R native-test.double X)
  (pop-handler)
  (return R)
  (label caught)
  (return X))
(native-test.check "a call under a handler" 4 (freeze (native-test.call-in-handler 2)))
(native-test.check "an error in the call" a (freeze (native-test.call-in-handler a)))

\\ Allocation, which moves values under GC stress.
(define-native native-test.build (N Acc)
  (prim T = N 0)
  (jump-if-false T more)
  (return Acc)
  (label more)
  (prim V absvector 2)
  (prim V address-> V 0 N)
  (prim S str N)
  (prim V address-> V 1 S)
  (prim Acc cons V Acc)
  (prim N - N 1)
  (tail-call native-test.build N Acc))
(native-test.check "allocation" "3" (freeze (<-address (hd (tl (tl (native-test.build 3 [])))) 1)))

\\ Code generated at run time: the macro inside a definition, where const reads the
\\ definition's own variable, and instructions as data for shen-jit.assemble, where
\\ brackets build the lists and protect makes a variable a symbol.
(define native-test.make-adder
  Name N -> (define-native Name (X)
              (prim R + X (const N))
              (return R)))
(native-test.make-adder native-test.add5 5)
(native-test.check "defined at run time" 8 (freeze (native-test.add5 3)))
(define native-test.generate
  N -> (shen-jit.install-code
         (shen-jit.assemble native-test.generated [(protect X)]
           [[prim (protect R) * (protect X) N]
            [return (protect R)]])))
(native-test.check "assembled at run time" 21 (freeze ((native-test.generate 7) 3)))
(native-test.check "assemble gives the code object"
  [code f 1 4 [1] [[prim 3 + 2 [const 0]] [return 3]] []]
  (freeze (shen-jit.assemble f [(protect X)] [[prim (protect R) + (protect X) 1] [return (protect R)]])))

\\ Byte buffers and bit operations, as primitives of a call-free loop, whose slots live
\\ in registers. The buffer comes first, and collections move it under GC stress.
(define-native native-test.sum-bytes (B I N Acc)
  (prim T = I N)
  (jump-if-false T more)
  (return Acc)
  (label more)
  (prim X shen-jit.u8 B I)
  (prim Acc + Acc X)
  (prim I + I 1)
  (tail-call native-test.sum-bytes B I N Acc))
(define-native native-test.fill (B I N)
  (prim T = I N)
  (jump-if-false T more)
  (return B)
  (label more)
  (prim X shen-jit.bit-and I 255)
  (prim B shen-jit.u8! B I X)
  (prim I + I 1)
  (tail-call native-test.fill B I N))
(native-test.check "filling and reading a buffer" 124716
  (freeze (native-test.sum-bytes (native-test.fill (shen-jit.bytes 3000) 0 1000) 0 1000 0)))
(native-test.check "a large buffer" 38246416
  (freeze (native-test.sum-bytes (native-test.fill (shen-jit.bytes 300000) 0 300000) 0 300000 0)))
(native-test.check "past the end of a buffer" [error "bytes: 3 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.sum-bytes (shen-jit.bytes 3) 0 4 0)))))

\\ Buffers that live across collections keep their contents.
(define native-test.buffers
  0 Acc -> Acc
  N Acc -> (native-test.buffers (- N 1) [(shen-jit.u32! (shen-jit.bytes 16) 4 N) | Acc]))
(define native-test.read-buffers
  [] Acc -> Acc
  [B | Bs] Acc -> (native-test.read-buffers Bs (+ Acc (shen-jit.u32 B 4))))
(native-test.check "buffers across collections" 500500
  (freeze (native-test.read-buffers (native-test.buffers 1000 []) 0)))

\\ FNV-1a, in plain Shen, with its published value for "a".
(define native-test.fnv
  _ I N H -> H where (= I N)
  B I N H -> (native-test.fnv B (+ I 1) N
               (shen-jit.bit-and (* (shen-jit.bit-xor H (shen-jit.u8 B I)) 16777619) 4294967295)))
(native-test.check "a hash" 3826002220 (freeze (native-test.fnv (shen-jit.string->bytes "a") 0 1 2166136261)))

\\ A code object written by hand, with what the builder does not write: an entry
\\ for two arguments at once, which also takes a jump from code that knows slot 2
\\ holds a pair. The label must not assume that when entered with two arguments.
(set native-test.*entry*
  (shen-jit.install-code
    [code native-test.entry 1 6 [1]
      [[entry 2 0]
       [prim 4 cons? 2]
       [jump-if-false 4 1]
       [const 3 0]
       [jump 0]
       [label 1]
       [return 2]
       [label 0]
       [prim 5 hd 2]
       [return 5]]
      []]))
(native-test.check "one argument" 7 (freeze ((value native-test.*entry*) 7)))
(native-test.check "one, a pair" 1 (freeze ((value native-test.*entry*) [1])))
(native-test.check "two arguments, checked" [error "hd: 7 is not a pair"]
  (freeze (native-test.result (freeze (let F (value native-test.*entry*) (F 7 8))))))
(native-test.check "two arguments, a pair" 1
  (freeze (let F (value native-test.*entry*) (F [1] 8))))

\\ ---------------------------------------------------------------------------
\\ Code to refuse. Each would misbehave or crash if it reached the JIT.

\\ What could overwrite the frame's own slots or read them as values.
(native-test.raw "writes the return address" [code f 0 4 [1] [[const 2 0] [const 0 0] [return 2]] []])
(native-test.raw "writes the procedure" [code f 0 4 [1] [[const 2 0] [move 1 2] [return 2]] []])
(native-test.raw "reads the return address" [code f 0 4 [] [[move 2 0] [return 2]] []])
(native-test.raw "reads the procedure" [code f 0 4 [] [[move 2 1] [return 2]] []])
(native-test.raw "returns the procedure" [code f 0 4 [] [[return 1]] []])
(native-test.raw "a slot past the frame" [code f 0 4 [1] [[const 9 0] [return 9]] []])
(native-test.raw "a window over the frame's start" [code f 0 6 [] [[call 3 0 native-test.double 0] [return 3]] []])
(native-test.raw "a window over a parameter" [code f 1 6 [] [[call 3 2 native-test.double 0] [return 3]] []])
(native-test.raw "a window past the frame" [code f 0 4 [] [[call 2 2 native-test.double 3] [return 2]] []])
(native-test.raw "a value tail call in window 0" [code f 0 4 [] [[tail-call-value 0 0]] []])

\\ Reading what was never written, or what a call has clobbered.
(native-test.raw "reads an unset slot" [code f 0 4 [] [[return 3]] []])
(native-test.raw "an unset argument" [code f 0 6 [] [[call 2 2 native-test.double 1] [return 2]] []])
(native-test.raw "reads above a window" [code f 0 6 [1] [[const 3 0] [call 2 2 native-test.ask 0] [return 3]] []])
(native-test.raw "set on one path only"
  [code f 1 5 [1] [[prim 3 cons? 2] [jump-if-false 3 0] [const 4 0] [label 0] [return 4]] []])

\\ Control flow the JIT cannot compile: it is one pass, and jumps only go forward.
(native-test.raw "a backward jump" [code f 0 4 [1] [[label 0] [const 2 0] [jump 0]] []])
(native-test.raw "falls off the end" [code f 0 4 [1] [[const 2 0]] []])
(native-test.raw "no code" [code f 0 4 [] [] []])
(native-test.raw "unreachable code" [code f 0 4 [1] [[const 2 0] [return 2] [const 2 0] [return 2]] []])
(native-test.raw "a label twice" [code f 0 4 [1] [[const 2 0] [jump 0] [label 0] [label 0] [return 2]] []])
(native-test.raw "an undefined label" [code f 0 4 [] [[jump 3]] []])

\\ Handlers: the JIT tracks them by the order of the code.
(native-test.raw "returns under a handler"
  [code f 0 4 [1] [[push-handler 0] [const 2 0] [return 2] [label 0] [return 2]] []])
(native-test.raw "tail calls under a handler"
  [code f 0 6 [1] [[push-handler 0] [tail-call 0 native-test.ask 0] [label 0] [const 2 0] [return 2]] []])
(native-test.raw "pops with no handler" [code f 0 4 [1] [[const 2 0] [pop-handler] [return 2]] []])
(native-test.raw "one push, a pop on each branch"
  [code f 1 5 [] [[push-handler 0] [prim 3 cons? 2] [jump-if-false 3 1] [pop-handler] [return 2]
                  [label 1] [pop-handler] [return 2] [label 0] [return 2]] []])
(native-test.raw "handlers differ at a join"
  [code f 1 5 [] [[push-handler 0] [prim 3 cons? 2] [jump-if-false 3 1] [pop-handler]
                  [label 1] [return 2] [label 0] [return 2]] []])
(native-test.raw "a handler out of the code's order"
  [code f 1 5 [] [[push-handler 0] [prim 3 cons? 2] [jump-if-false 3 2] [pop-handler] [push-handler 1]
                  [jump 3] [label 2] [pop-handler] [push-handler 1] [label 3] [prim 4 hd 2] [pop-handler] [return 4]
                  [label 0] [return 2] [label 1] [return 2]] []])
(native-test.raw "exception outside a handler" [code f 0 4 [1] [[const 2 0] [exception 3] [return 2]] []])
(native-test.raw "a handler reads a slot written under it"
  [code f 1 6 [1] [[const 3 0] [push-handler 0] [prim 3 cons? 2] [jump-if-false 3 1] [prim 4 hd 2]
                   [label 1] [pop-handler] [return 2] [label 0] [return 3]] []])

\\ Captures and nested code.
(native-test.raw "a capture at the top" [code f 0 4 [] [[capture 2 0] [return 2]] []])
(native-test.raw "a capture out of range"
  [code f 1 5 [] [[closure 3 0 2] [return 3]] [[code lambda 1 5 [] [[capture 3 1] [return 3]] []]]])
(native-test.raw "nested code not used"
  [code f 0 4 [1] [[const 2 0] [return 2]] [[code lambda 1 4 [] [[return 2]] []]]])
(native-test.raw "nested code used twice"
  [code f 0 5 [] [[closure 2 0] [closure 3 0] [return 3]] [[code lambda 1 4 [] [[return 2]] []]]])
(native-test.raw "a closure of no code" [code f 0 4 [] [[closure 2 0] [return 2]] []])
(native-test.raw "a nested lambda of two" 
  [code f 0 4 [] [[closure 2 0] [return 2]] [[code lambda 2 5 [] [[return 2]] []]]])

\\ Operands and names.
(native-test.raw "a constant out of range" [code f 0 4 [] [[const 2 5] [return 2]] []])
(native-test.raw "an operand constant out of range" [code f 0 4 [] [[return [const 0]]] []])
(native-test.raw "an unknown primitive" [code f 0 4 [] [[prim 2 frob] [return 2]] []])
(native-test.raw "a primitive's wrong arity" [code f 0 4 [1] [[prim 2 hd [const 0] [const 0]] [return 2]] []])
(native-test.raw "a call of a primitive" [code f 0 6 [1] [[const 4 0] [call 2 2 hd 1] [return 2]] []])
(native-test.raw "a sealed call of an open name" [code f 0 6 [] [[call-sealed 2 2 native-test.ask 0] [return 2]] []])
(native-test.raw "a primitive's arity, with five" [code f 0 4 [1] [[prim 2 shen-jit.copy-bytes [const 0]] [return 2]] []])
(native-test.raw "an unknown instruction" [code f 0 4 [] [[frob 1 2] [return 2]] []])
(native-test.raw "an instruction not a list" [code f 0 4 [] [5] []])
(native-test.raw "a slot not a number" [code f 0 4 [1] [[const a 0] [return a]] []])

\\ Code objects.
(native-test.raw "too short" [code f])
(native-test.raw "not code" [frob f 0 4 [] [] []])
(native-test.raw "a frame too small" [code f 1 2 [1] [[return [const 0]]] []])
(native-test.raw "an arity not a number" [code f a 4 [1] [[return [const 0]]] []])
(native-test.raw "named as nested code" [code lambda 1 4 [1] [[return [const 0]]] []])
(native-test.raw "an inline body" [code f 0 4 [1] [[return [const 0]]] [] [[x] y]])
(native-test.raw "an entry not above the arity" [code f 1 5 [] [[entry 1 0] [return 2] [label 0] [return 2]] []])
(native-test.raw "an entry not first" [code f 1 5 [] [[move 3 2] [entry 2 0] [return 3] [label 0] [return 2]] []])
(native-test.raw "an entry past the frame" [code f 1 3 [] [[entry 5 0] [return 2] [label 0] [return 2]] []])
(native-test.refused "redefines a sealed function" (freeze (shen-jit.install-code [defun reverse [code reverse 0 3 [1] [[return [const 0]]] []]])))

\\ Through the builder.
(native-test.refused "an unset name" (freeze (define-native native-test.bad (X) (return Y))))
(native-test.refused "an unset name on one path"
  (freeze (define-native native-test.bad (X)
            (prim T cons? X) (jump-if-false T l) (move Y 1) (label l) (return Y))))
(native-test.refused "no such label" (freeze (define-native native-test.bad () (jump nowhere))))
(native-test.refused "a label twice"
  (freeze (define-native native-test.bad () (jump l) (label l) (label l) (return 1))))
(native-test.refused "a name twice" (freeze (define-native native-test.bad (X X) (return X))))
(native-test.refused "a call of a variable with two arguments"
  (freeze (define-native native-test.bad (F) (call R F 1 2) (return R))))
(native-test.refused "a call of a primitive" (freeze (define-native native-test.bad (X) (call R hd X) (return R))))
(native-test.refused "an unknown instruction" (freeze (define-native native-test.bad () (add A B))))
(native-test.refused "a form as an operand" (freeze (define-native native-test.bad () (return (hd X)))))
(native-test.refused "a symbol as a destination" (freeze (define-native native-test.bad () (move r 1) (return 1))))
(native-test.refused "no return" (freeze (define-native native-test.bad () (move X 1))))
(native-test.refused "a capture unset" (freeze (define-native native-test.bad () (closure F () (A) (return A)) (return F))))
(native-test.refused "a closure of two" (freeze (define-native native-test.bad () (closure F (A B) () (return A)) (return F))))
(native-test.refused "a closure's variable not captured"
  (freeze (define-native native-test.bad (X) (closure F () () (return X)) (return F))))
(native-test.refused "a handler's code outside the handler around it"
  (freeze (define-native native-test.bad (X)
            (push-handler outer) (push-handler inner) (prim R hd X) (pop-handler) (pop-handler) (return R)
            (label inner) (pop-handler) (return X)
            (label outer) (return X))))
(native-test.refused "a backward jump" (freeze (define-native native-test.bad () (label l) (jump l))))
(native-test.refused "none of those was installed" (freeze ((fn native-test.bad))))
(native-test.refused "redefines a sealed function, built" (freeze (define-native reverse () (return 1))))

\\ ---------------------------------------------------------------------------
\\ Real registers.

\\ A loop: what comes before its head runs once, a register keeps its value round the loop, and a
\\ slot read for a number takes an integer as well as a real.
(define-native native-test.real-sum (B I End Start)
  (real Acc Start)
  (loop top)
  (prim T >= I End)
  (jump-if-false T more)
  (return-real Acc)
  (label more)
  (real Acc (+ Acc (f64 B I)))
  (prim I + I 8)
  (again top))

(set native-test.reals (shen-jit.bytes 24))
(shen-jit.f64! (value native-test.reals) 0 1.5)
(shen-jit.f64! (value native-test.reals) 8 2.5)
(shen-jit.f64! (value native-test.reals) 16 0.25)
(native-test.check "a loop on a buffer" 4.25 (freeze (native-test.real-sum (value native-test.reals) 0 24 0)))
(native-test.check "from a real" 4.75 (freeze (native-test.real-sum (value native-test.reals) 0 24 0.5)))
(native-test.check "no times round gives what it started with, boxed" 2.5 (freeze (native-test.real-sum (value native-test.reals) 0 0 2.5)))
(native-test.check "it is a real" true (freeze (number? (native-test.real-sum (value native-test.reals) 0 0 2))))
(native-test.check "not a number" [error "a is not a number"]
  (freeze (native-test.result (freeze (native-test.real-sum (value native-test.reals) 0 24 a)))))
(native-test.check "past the end" [error "bytes: 32 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.real-sum (value native-test.reals) 32 40 0)))))
(native-test.check "not memory" error
  (freeze (hd (native-test.result (freeze (native-test.real-sum "abc" 0 8 0))))))

\\ Each operation, nested, with literals and slots among them.
(define-native native-test.real-ops (A B)
  (real X A)
  (real Y B)
  (real R (- (/ (* (+ X Y) 2) Y) (sqrt (abs (neg X)))))
  (return-real R))
(native-test.check "arithmetic" 4 (freeze (native-test.real-ops 4 2)))

\\ What is on both sides, written after it is read.
(define-native native-test.real-same (A)
  (real X A)
  (real X (+ (* X X) X))
  (real X (- X (* X 0.5)))
  (return-real X))
(native-test.check "a register read in what writes it" 6 (freeze (native-test.real-same 3)))

(define-native native-test.real-many (A B)
  (real X (+ A B 1 2.5))
  (real Y (* A B 2))
  (return-real (+ X Y)))
(native-test.check "several operands, from slots" 25.5 (freeze (native-test.real-many 2 4)))

(define-native native-test.real-divide (A B)
  (real X A)
  (real Y B)
  (return-real (/ X Y)))
(native-test.check "division by zero gives infinity" true (freeze (> (native-test.real-divide 1 0) 1e300)))

\\ An index in arithmetic, and a store.
(define-native native-test.real-store (B I X)
  (real V X)
  (f64! B (* (+ I 1) 8) (+ V 1))
  (return-real (f64 B (* (+ I 1) 8))))
(native-test.check "a store, and an index worked out" 3.5 (freeze (native-test.real-store (shen-jit.bytes 16) 0 2.5)))
(native-test.check "a store past the end" [error "bytes: 16 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.real-store (shen-jit.bytes 16) 1 2.5)))))

\\ Each comparison, NaN making each one false.
(define-native native-test.real-lt (A B) (jump-unless (< A B) no) (return yes) (label no) (return no))
(define-native native-test.real-gt (A B) (jump-unless (> A B) no) (return yes) (label no) (return no))
(define-native native-test.real-le (A B) (jump-unless (<= A B) no) (return yes) (label no) (return no))
(define-native native-test.real-ge (A B) (jump-unless (>= A B) no) (return yes) (label no) (return no))
(define-native native-test.real-eq (A B) (jump-unless (= A B) no) (return yes) (label no) (return no))

(define native-test.compare-all
  A B -> [(native-test.real-lt A B) (native-test.real-gt A B) (native-test.real-le A B)
          (native-test.real-ge A B) (native-test.real-eq A B)])

(set native-test.nan (let I (* 1e300 1e300) (- I I)))
(native-test.check "below" [yes no yes no no] (freeze (native-test.compare-all 1.5 2)))
(native-test.check "above" [no yes no yes no] (freeze (native-test.compare-all 2 1.5)))
(native-test.check "equal" [no no yes yes yes] (freeze (native-test.compare-all 2 2)))
(native-test.check "NaN" [no no no no no] (freeze (native-test.compare-all (value native-test.nan) 1)))
(native-test.check "a comparison raises on what is no number" [error "a is not a number"]
  (freeze (native-test.result (freeze (native-test.real-lt a 1)))))

\\ What calls C or collects keeps them: boxes that allocate, a primitive that calls C and
\\ allocates, and an = that calls C and does not.
(define-native native-test.real-keep (N Acc)
  (real X 0)
  (real Y 100)
  (loop top)
  (prim T = N 0)
  (jump-if-false T more)
  (return Acc)
  (label more)
  (real X (+ X 1))
  (real Y (- Y 1))
  (real-box A X)
  (real-box B Y)
  (prim S str N)
  (prim S2 str N)
  (prim E = S S2)
  (jump-if-false E fail)
  (prim P + A B)
  (prim Acc + Acc P)
  (prim N - N 1)
  (again top)
  (label fail)
  (return fail))
(native-test.check "kept across C and collections" 20000 (freeze (native-test.real-keep 200 0)))

\\ All twelve, for a square root whose registers an instruction encodes in extra bits.
(define-native native-test.real-twelve (A)
  (real R0 A)
  (real R1 (+ R0 1))
  (real R2 (+ R1 1))
  (real R3 (+ R2 1))
  (real R4 (+ R3 1))
  (real R5 (+ R4 1))
  (real R6 (+ R5 1))
  (real R7 (+ R6 1))
  (real R8 (+ R7 1))
  (real R9 (+ R8 1))
  (real R10 (sqrt (* R9 R9)))
  (real R0 (sqrt R10))
  (real R10 (sqrt R1))
  (real R0 (+ R0 R10 R2 R3 R4 R5 R6 R7 R8))
  (return-real R0))
(native-test.check "every register, and a root in each" true
  (freeze (let V (native-test.real-twelve 3)
            (and (> V 61.46) (< V 61.47)))))

(native-test.refused "an unknown instruction among them"
  (freeze (define-native native-test.bad (A) (real X A) (call-result R F) (return-real X))))

\\ What must be refused.
(native-test.refused "a call" (freeze (define-native native-test.bad (A) (real X A) (call R reverse A) (return-real X))))
(native-test.refused "a call of a value" (freeze (define-native native-test.bad (F) (real X 1) (call R F 1) (return-real X))))
(native-test.refused "a handler"
  (freeze (define-native native-test.bad (A) (push-handler h) (real X A) (pop-handler) (return-real X) (label h) (return A))))
(native-test.refused "a register unset" (freeze (define-native native-test.bad (A) (real X (+ Y 1)) (real Y 1) (return-real X))))
(native-test.refused "a register set on one path"
  (freeze (define-native native-test.bad (A) (jump-if-false A l) (real X 1) (label l) (return-real X))))
(native-test.refused "a register as a slot" (freeze (define-native native-test.bad (A) (real X A) (prim Y + X 1) (return Y))))
(native-test.refused "a register as memory" (freeze (define-native native-test.bad (A) (real X A) (real Y (f64 X 0)) (return-real Y))))
(native-test.refused "going back to nothing" (freeze (define-native native-test.bad () (again l))))
(native-test.refused "going back to a label"
  (freeze (define-native native-test.bad (A) (label l) (again l))))
(native-test.refused "going back before the loop is there"
  (freeze (define-native native-test.bad (A) (jump-if-false A l) (again m) (label l) (loop m) (again m))))
(native-test.refused "a loop with no name" (freeze (define-native native-test.bad (A) (loop) (return A))))
(native-test.refused "two loops of one name" (freeze (define-native native-test.bad (A) (loop l) (loop l) (again l))))
(native-test.refused "a loop named as a label" (freeze (define-native native-test.bad (A) (label l) (loop l) (again l))))
(native-test.refused "a jump to a loop's head from before it"
  (freeze (define-native native-test.bad (A) (jump-if-false A l) (loop l) (again l))))
(native-test.refused "a jump back to a loop's head, not again"
  (freeze (define-native native-test.bad (A) (loop l) (jump l))))
(native-test.refused "a test jumping back to a loop's head"
  (freeze (define-native native-test.bad (A) (loop l) (jump-if-false A l) (return A))))
(native-test.refused "a loop with a call" (freeze (define-native native-test.bad (A) (loop l) (call R reverse A) (again l))))
(native-test.refused "a register the loop's head has, and going back without it"
  (freeze (define-native native-test.bad (A)
            (jump-if-false A inside)
            (real X 1)
            (loop l)
            (real Y X)
            (label inside)
            (again l))))
(native-test.refused "a slot read at the head, set only later"
  (freeze (define-native native-test.bad (A)
            (loop l)
            (prim T = K 0)
            (prim K + A 1)
            (jump-if-false T l2)
            (again l)
            (label l2)
            (return A))))
(native-test.refused "after going back, nothing"
  (freeze (define-native native-test.bad (A) (loop l) (again l) (return A))))
(native-test.refused "not a real expression" (freeze (define-native native-test.bad (A) (real X (foo A)) (return-real X))))
(native-test.refused "not a comparison" (freeze (define-native native-test.bad (A) (jump-unless (foo A A) l) (label l) (return A))))
(native-test.refused "more registers than there are"
  (freeze (define-native native-test.bad (A)
            (real R0 A) (real R1 A) (real R2 A) (real R3 A) (real R4 A) (real R5 A) (real R6 A) (real R7 A)
            (real R8 A) (real R9 A) (real R10 A) (real R11 A) (real R12 A) (real R13 A) (real R14 A) (real R15 A)
            (real R16 A) (real R17 A) (real R18 A) (real R19 A) (real R20 A) (real R21 A) (real R22 A) (real R23 A)
            (real R24 A) (real R25 A) (real R26 A) (real R27 A) (real R28 A) (real R29 A) (real R30 A) (real R31 A)
            (real R32 A) (real R33 A) (real R34 A) (real R35 A) (real R36 A) (real R37 A) (real R38 A) (real R39 A)
            (real R40 A) (real R41 A) (real R42 A) (real R43 A) (real R44 A) (real R45 A) (real R46 A) (real R47 A)
            (real R48 A) (return-real R48))))
(native-test.raw "a register out of range" [code native-test.bad 0 3 [0] [[real-number 48 [const 0]] [return [const 0]]] []])
(native-test.raw "a negative register" [code native-test.bad 0 3 [0] [[real-number -1 [const 0]] [return [const 0]]] []])
(native-test.raw "a slot for a register" [code native-test.bad 0 3 [0] [[real-box 2 2] [return 2]] []])
(native-test.raw "a label that is not there" [code native-test.bad 0 3 [0] [[real-number 0 [const 0]] [real-unless< 0 0 9] [return [const 0]]] []])
(native-test.raw "a load into nothing" [code native-test.bad 1 4 [0] [[real-load 48 2 [const 0]] [return 2]] []])
(native-test.raw "a store of nothing" [code native-test.bad 1 4 [0] [[real-store 2 [const 0] 0] [return 2]] []])
(native-test.refused "none of those was installed, again" (freeze ((fn native-test.bad))))

\\ More real registers than the machine gives: those live in the native frame, and work the same.
(define-native native-test.real-many-more (A)
  (real R0 A) (real R1 (+ R0 1)) (real R2 (+ R1 1)) (real R3 (+ R2 1)) (real R4 (+ R3 1))
  (real R5 (+ R4 1)) (real R6 (+ R5 1)) (real R7 (+ R6 1)) (real R8 (+ R7 1)) (real R9 (+ R8 1))
  (real R10 (+ R9 1)) (real R11 (+ R10 1)) (real R12 (+ R11 1)) (real R13 (+ R12 1)) (real R14 (+ R13 1))
  (real R15 (sqrt (* R14 R14)))
  (real R16 (/ (neg R15) 2))
  (jump-unless (< R16 R0) wrong)
  (real-box A1 R15)
  (prim S str A1)
  (return-real (+ R0 R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15 R16))
  (label wrong)
  (return wrong))
(native-test.check "more registers than the machine's" 127.5 (freeze (native-test.real-many-more 1)))

\\ ---------------------------------------------------------------------------
\\ Word registers.

\\ Each operation, on what fits a fixnum so that it can come back.
(define-native native-test.word-ops (A B)
  (word X A)
  (word Y B)
  (word S (+ X Y))
  (word D (- X Y))
  (word M (* X Y))
  (word N (neg X))
  (return-word (+ (* S 1000000) (* D 10000) (* M 100) N)))
(native-test.check "arithmetic" 15093588 (freeze (native-test.word-ops 12 3)))

(define-native native-test.word-bits (A B)
  (word X A)
  (word Y B)
  (word Result (bit-xor (bit-or (bit-and X Y) (shift-left Y 8)) (shift-right X 2)))
  (return-word Result))
(native-test.check "and, or, xor, shifts" 3843 (freeze (native-test.word-bits 60 15)))

(define-native native-test.word-not (A)
  (word X A)
  (return-word (bit-not X)))
(native-test.check "not" -1 (freeze (native-test.word-not 0)))
(native-test.check "not of one" -2 (freeze (native-test.word-not 1)))

(define-native native-test.word-rotate (A N)
  (word X A)
  (word R (rotate-right (rotate-left X N) N))
  (return-word R))
(native-test.check "rotate there and back" 1234 (freeze (native-test.word-rotate 1234 13)))

(define-native native-test.word-signed (A N)
  (word X A)
  (return-word (shift-right-signed X N)))
(native-test.check "a signed shift" -2 (freeze (native-test.word-signed -8 2)))

\\ Wraparound: past 64 bits nothing raises. 2^63 + 2^63 is 0.
(define-native native-test.word-wrap (A)
  (word X (shift-left 1 63))
  (word Y (+ X X A))
  (return-word Y))
(native-test.check "addition wraps" 5 (freeze (native-test.word-wrap 5)))

\\ What does not fit a fixnum raises when it comes back, and only then.
(define-native native-test.word-big (N)
  (word X (shift-left 1 N))
  (return-word X))
(native-test.check "2^60 fits" 1152921504606846976 (freeze (native-test.word-big 60)))
(native-test.check "2^61 does not" error (freeze (hd (native-test.result (freeze (native-test.word-big 61))))))
(native-test.check "nor does 2^63" error (freeze (hd (native-test.result (freeze (native-test.word-big 63))))))
(native-test.check "and it says what" [error "the word 2305843009213693952 does not fit in an integer"]
  (freeze (native-test.result (freeze (native-test.word-big 61)))))
(define-native native-test.word-small (N)
  (word X (neg (shift-left 1 N)))
  (return-word X))
(native-test.check "-2^61 fits" -2305843009213693952 (freeze (native-test.word-small 61)))
(native-test.check "-2^62 does not" error (freeze (hd (native-test.result (freeze (native-test.word-small 62))))))

\\ A slot read as a word must be an integer.
(define-native native-test.word-of (A)
  (word X A)
  (return-word X))
(native-test.check "from a slot" -7 (freeze (native-test.word-of -7)))
(native-test.check "not an integer" [error "1.5 is not an integer"] (freeze (native-test.result (freeze (native-test.word-of 1.5)))))
(native-test.check "nor is a symbol" [error "a is not an integer"] (freeze (native-test.result (freeze (native-test.word-of a)))))

\\ Between words and reals.
(define-native native-test.word-real (A)
  (word X A)
  (real R (* X 0.5))
  (return-real R))
(native-test.check "a word in a real expression" 1.5 (freeze (native-test.word-real 3)))

(define-native native-test.real-word (A)
  (real R A)
  (word X (truncate (* R 2)))
  (return-word X))
(native-test.check "truncate" 3 (freeze (native-test.real-word 1.75)))
(native-test.check "truncate, toward zero" -3 (freeze (native-test.real-word -1.75)))

\\ Each comparison, and that unsigned sees -1 as the largest.
(define-native native-test.word-lt (A B) (word X A) (word Y B) (jump-unless-word (< X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-gt (A B) (word X A) (word Y B) (jump-unless-word (> X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-le (A B) (word X A) (word Y B) (jump-unless-word (<= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ge (A B) (word X A) (word Y B) (jump-unless-word (>= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-eq (A B) (word X A) (word Y B) (jump-unless-word (= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ult (A B) (word X A) (word Y B) (jump-unless-word (u< X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ugt (A B) (word X A) (word Y B) (jump-unless-word (u> X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-ule (A B) (word X A) (word Y B) (jump-unless-word (u<= X Y) no) (return yes) (label no) (return no))
(define-native native-test.word-uge (A B) (word X A) (word Y B) (jump-unless-word (u>= X Y) no) (return yes) (label no) (return no))

(define native-test.word-compare
  A B -> [(native-test.word-lt A B) (native-test.word-gt A B) (native-test.word-le A B) (native-test.word-ge A B)
          (native-test.word-eq A B)])
(define native-test.word-unsigned
  A B -> [(native-test.word-ult A B) (native-test.word-ugt A B) (native-test.word-ule A B) (native-test.word-uge A B)])
(native-test.check "below" [yes no yes no no] (freeze (native-test.word-compare -1 2)))
(native-test.check "above" [no yes no yes no] (freeze (native-test.word-compare 2 -1)))
(native-test.check "equal" [no no yes yes yes] (freeze (native-test.word-compare 2 2)))
(native-test.check "unsigned, -1 is the largest" [no yes no yes] (freeze (native-test.word-unsigned -1 2)))
(native-test.check "unsigned, equal" [no no yes yes] (freeze (native-test.word-unsigned 2 2)))

\\ A constant on either side, and in a loop, whose register keeps its value round it.
(define-native native-test.word-loop (N Start)
  (word Acc Start)
  (word I 0)
  (loop top)
  (jump-unless-word (< I N) done)
  (word Acc (+ Acc (* I 2)))
  (word I (+ I 1))
  (again top)
  (label done)
  (return-word Acc))
(native-test.check "a loop" 90 (freeze (native-test.word-loop 10 0)))
(native-test.check "from a start" 95 (freeze (native-test.word-loop 10 5)))
(native-test.check "no times round" 5 (freeze (native-test.word-loop 0 5)))

\\ FNV-1a on bytes, whose value is known: 64 bits that wrap on each multiplication. Neither the
\\ offset basis nor the result is a fixnum, so the result goes to memory, read back in halves.
(define-native native-test.word-fnv (B Out End)
  (word Prime 1099511628211)
  (word Hash (+ (* 3421674724 4294967296) 2216829733))
  (word I 0)
  (loop top)
  (jump-unless-word (u< I End) done)
  (word Hash (* (bit-xor Hash (u8 B I)) Prime))
  (word I (+ I 1))
  (again top)
  (label done)
  (u64! Out 0 Hash)
  (return Out))

(define native-test.word-fnv-of
  S -> (let B (shen-jit.string->bytes S)
            Out (native-test.word-fnv B (shen-jit.bytes 8) (shen-jit.bytes-length B))
         [(shen-jit.u32 Out 4) (shen-jit.u32 Out 0)]))
(native-test.check "FNV-1a of nothing" [3421674724 2216829733] (freeze (native-test.word-fnv-of "")))
(native-test.check "FNV-1a of a" [2942557260 2248273036] (freeze (native-test.word-fnv-of "a")))
(native-test.check "FNV-1a of foobar" [2241085809 4147734504] (freeze (native-test.word-fnv-of "foobar")))

\\ Every width, at a word index, each checked against the length.
(define-native native-test.word-widths (M)
  (word I 8)
  (u64! M I 513)
  (word A (u8 M I))
  (word B (u16 M I))
  (word C (u32 M I))
  (word D (u64 M I))
  (u8! M 0 255)
  (u16! M 2 65535)
  (u32! M 4 -1)
  (word E (s32 M 4))
  (word F (u32 M 4))
  (word G (u16 M 2))
  (word H (u8 M 0))
  (return-word (+ A (* B 1000) (* C 10000000) (* D 100000000000) E (* F 10) (* G 100) (* H 3))))
(native-test.check "each width" 51348086740215 (freeze (native-test.word-widths (shen-jit.bytes 16))))

\\ Bounds: a word index has no tag to fail on, so each way round must be caught here.
(define-native native-test.word-at (M I)
  (word X I)
  (return-word (u64 M X)))
(define-native native-test.byte-at (M I)
  (word X I)
  (return-word (u8 M X)))
(define-native native-test.store-at (M I)
  (word X I)
  (u64! M X 1)
  (return M))
(define-native native-test.real-at (M I)
  (word X I)
  (return-real (f64 M X)))
(define-native native-test.real-store-at (M I)
  (word X I)
  (f64! M X 1.5)
  (return M))

(define native-test.bytes8
  -> (shen-jit.u32! (shen-jit.bytes 16) 8 7))
(native-test.check "the last place for 8 bytes" 7 (freeze (native-test.word-at (native-test.bytes8) 8)))
(native-test.check "past it" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.word-at (native-test.bytes8) 9)))))
(native-test.check "the last byte" 0 (freeze (native-test.byte-at (native-test.bytes8) 15)))
(native-test.check "past it, by bytes" [error "bytes: 16 is not a valid index"] (freeze (native-test.result (freeze (native-test.byte-at (native-test.bytes8) 16)))))
(native-test.check "a negative index" [error "bytes: -1 is not a valid index"] (freeze (native-test.result (freeze (native-test.word-at (native-test.bytes8) -1)))))
(native-test.check "one that adds up small" [error "bytes: -7 is not a valid index"] (freeze (native-test.result (freeze (native-test.word-at (native-test.bytes8) -7)))))
(native-test.check "a negative index, by bytes" [error "bytes: -1 is not a valid index"] (freeze (native-test.result (freeze (native-test.byte-at (native-test.bytes8) -1)))))
(native-test.check "a store past the end" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.store-at (native-test.bytes8) 9)))))
(native-test.check "a store before the start" [error "bytes: -8 is not a valid index"] (freeze (native-test.result (freeze (native-test.store-at (native-test.bytes8) -8)))))
(native-test.check "a real past the end" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.real-at (native-test.bytes8) 9)))))
(native-test.check "a real before the start" [error "bytes: -1 is not a valid index"] (freeze (native-test.result (freeze (native-test.real-at (native-test.bytes8) -1)))))
(native-test.check "a real store past the end" [error "bytes: 9 is not a valid index"] (freeze (native-test.result (freeze (native-test.real-store-at (native-test.bytes8) 9)))))
(native-test.check "a real read" 1.5 (freeze (native-test.real-at (native-test.real-store-at (shen-jit.bytes 16) 8) 8)))
(native-test.check "not memory" error (freeze (hd (native-test.result (freeze (native-test.word-at "abc" 0))))))
(native-test.check "not a pointer with a length" error (freeze (hd (native-test.result (freeze (native-test.word-at a 0))))))

\\ What the word index works out in words, when it mentions one, and in prim otherwise.
(define-native native-test.index-kinds (M I)
  (word X I)
  (real A (f64 M (+ X 8)))
  (real B (f64 M (+ I 8)))
  (return-real (+ A B)))
(native-test.check "either way of working out an index" 3 (freeze (native-test.index-kinds (shen-jit.f64! (shen-jit.bytes 16) 8 1.5) 0)))

\\ What calls C or collects keeps word registers, in the registers and out of them.
(define-native native-test.word-keep (N Acc)
  (word A 1) (word B 2) (word C 3) (word D 4) (word E 5) (word F 6) (word G 7) (word H 8)
  (word I 9) (word J 10) (word K 11) (word L 12) (word M 13)
  (loop top)
  (prim T = N 0)
  (jump-if-false T more)
  (return-word (+ A B C D E F G H I J K L M))
  (label more)
  (word A (+ A 1))
  (word M (+ M 1))
  (word-box S A)
  (real-box R A)
  (prim Text str N)
  (prim N - N 1)
  (again top))
(native-test.check "kept across C and collections" 491 (freeze (native-test.word-keep 200 0)))

\\ ---------------------------------------------------------------------------
\\ Loops within loops.

(define native-test.ramp
  N -> (native-test.ramp-from (shen-jit.bytes N) 0 N))

(define native-test.ramp-from
  B I N -> B where (>= I N)
  B I N -> (native-test.ramp-from (shen-jit.u8! B I (* 12 I)) (+ I 1) N))

\\ Slots and registers each keep what the rounds of each loop leave, with exits by forward jumps.
(define-native native-test.loops (Rows Cols)
  (word Acc 0)
  (word R 0)
  (real Sum 0)
  (prim Count + 0 0)
  (loop rows)
  (jump-unless-word (< R Rows) done)
  (word C 0)
  (loop cols)
  (jump-unless-word (< C Cols) next-row)
  (word Acc (+ Acc (* R C)))
  (real Sum (+ Sum 0.5))
  (prim Count + Count 1)
  (word C (+ C 1))
  (again cols)
  (label next-row)
  (word R (+ R 1))
  (again rows)
  (label done)
  (word-box A Acc)
  (real-box S Sum)
  (prim P cons A S)
  (prim P cons Count P)
  (return P))
(native-test.check "two loops, one in the other" [12 | [18 | 6]] (freeze (native-test.loops 3 4)))
(native-test.check "the inner one not at all" [0 | [0 | 0]] (freeze (native-test.loops 3 0)))
(native-test.check "the outer one not at all" [0 | [0 | 0]] (freeze (native-test.loops 0 3)))

\\ Three deep, one after another inside another, and leaving from the middle.
(define-native native-test.three-deep (N Stop)
  (word Acc 0)
  (word I 0)
  (loop one)
  (jump-unless-word (< I N) done)
  (word J 0)
  (loop two)
  (jump-unless-word (< J N) next-one)
  (word K 0)
  (loop three)
  (jump-unless-word (< K N) next-two)
  (word Acc (+ Acc 1))
  (jump-unless-word (= Acc Stop) go-on)
  (jump done)
  (label go-on)
  (word K (+ K 1))
  (again three)
  (label next-two)
  (word K 0)
  (loop after)
  (jump-unless-word (< K 2) finished)
  (word Acc (+ Acc 100))
  (word K (+ K 1))
  (again after)
  (label finished)
  (word J (+ J 1))
  (again two)
  (label next-one)
  (word I (+ I 1))
  (again one)
  (label done)
  (return-word Acc))
(native-test.check "three deep, and one after" 1827 (freeze (native-test.three-deep 3 -1)))
(native-test.check "left from the inside" 2 (freeze (native-test.three-deep 3 2)))

\\ Going back reads what the last round wrote: a slot from before the loop, a test on it, and a
\\ parameter. The JIT drops a store it finds dead, and has to look round the loop.
(define-native native-test.slot-round (A N)
  (prim K + A 1)
  (prim Acc + 0 0)
  (loop top)
  (prim T >= K N)
  (jump-if-false T more)
  (prim P cons K Acc)
  (return P)
  (label more)
  (prim Acc + Acc K)
  (prim K + K 2)
  (prim A + A 1)
  (again top))
(native-test.check "a slot and its test, round a loop" [7 | 9] (freeze (native-test.slot-round 0 6)))

(define-native native-test.parameter-round (X N)
  (loop top)
  (prim T = N 0)
  (jump-if-false T more)
  (return X)
  (label more)
  (prim X cons N X)
  (prim N - N 1)
  (again top))
(native-test.check "parameters, round a loop" [1 2 3] (freeze (native-test.parameter-round [] 3)))

\\ Pairs known in a round are not known in the next: a test before the head says nothing after it.
(define-native native-test.pairs-round (X N)
  (prim T cons? X)
  (jump-if-false T out)
  (loop top)
  (prim H hd X)
  (prim N - N 1)
  (prim D = N 0)
  (jump-if-false D more)
  (return H)
  (label more)
  (prim X tl X)
  (again top)
  (label out)
  (return X))
(native-test.check "hd round a loop" 3 (freeze (native-test.pairs-round [1 2 3] 3)))
(native-test.check "and raises when it runs out" error (freeze (hd (native-test.result (freeze (native-test.pairs-round [1 2] 5))))))

\\ Collections and calls into C within the inner loop keep all of it, the outer loop's too.
(define-native native-test.loops-keep (Rows Cols Bytes)
  (word Acc 0)
  (real Sum 0)
  (word R 0)
  (loop rows)
  (jump-unless-word (< R Rows) done)
  (word C 0)
  (loop cols)
  (jump-unless-word (< C Cols) next-row)
  (word Acc (+ Acc (u8 Bytes C)))
  (real Sum (+ Sum 1))
  (word-box Boxed Acc)
  (prim Text str Boxed)
  (real-box B Sum)
  (prim Pair cons B Text)
  (word C (+ C 1))
  (again cols)
  (label next-row)
  (word R (+ R 1))
  (again rows)
  (label done)
  (word-box A Acc)
  (real-box S Sum)
  (prim P cons A S)
  (return P))
(native-test.check "kept across C, in loops within loops, as a buffer moves" [6840 | 60]
  (freeze (native-test.loops-keep 3 20 (native-test.ramp 20))))

\\ ---------------------------------------------------------------------------
\\ Memory in a loop, whose base and length are worked out on the way in: ordinary code gets this
\\ as code with registers does, and it must never read what has gone stale.

\\ A buffer moves when the loop's own allocation collects, which GC stress makes often.
(define native-test.cached-sum
  B I N Acc Junk -> [Acc | (length Junk)] where (>= I N)
  B I N Acc Junk -> (native-test.cached-sum B (+ I 1) N (+ Acc (shen-jit.u8 B I)) [I | Junk]))

(define native-test.counting-bytes
  N -> (native-test.fill-counting (shen-jit.bytes N) 0 N))

(define native-test.fill-counting
  B I N -> B where (>= I N)
  B I N -> (native-test.fill-counting (shen-jit.u8! B I (shen-jit.bit-and I 255)) (+ I 1) N))

(native-test.check "a buffer read as it moves" [31872 | 256]
  (freeze (native-test.cached-sum (native-test.counting-bytes 256) 0 256 -768 [])))

(define-native native-test.cached-registers (B N Junk)
  (word I 0)
  (word Acc 0)
  (loop top)
  (jump-unless-word (< I N) done)
  (word Acc (+ Acc (u8 B I)))
  (word-box Boxed I)
  (prim Junk cons Boxed Junk)
  (word I (+ I 1))
  (again top)
  (label done)
  (return-word Acc))
(native-test.check "and in registers" 32640 (freeze (native-test.cached-registers (native-test.counting-bytes 256) 256 [])))

\\ Stores to a buffer that moves land in it.
(define native-test.cached-store
  B I N Junk -> B where (>= I N)
  B I N Junk -> (native-test.cached-store (shen-jit.u8! B I 7) (+ I 1) N [I | Junk]))
(native-test.check "a store as it moves" 7 (freeze (shen-jit.u8 (native-test.cached-store (shen-jit.bytes 64) 0 64 []) 63)))

\\ A parameter the loop changes is not the same memory each time round.
(define native-test.swapping
  A B 0 Acc -> Acc
  A B N Acc -> (native-test.swapping B A (- N 1) (+ (* Acc 10) (shen-jit.u8 A 0))))
(native-test.check "parameters that swap"
  1212
  (freeze (native-test.swapping (shen-jit.u8! (shen-jit.bytes 1) 0 1) (shen-jit.u8! (shen-jit.bytes 1) 0 2) 4 0)))

(define native-test.replacing
  M 0 Acc -> Acc
  M N Acc -> (native-test.replacing (shen-jit.u8! (shen-jit.bytes 1) 0 N) (- N 1) (+ Acc (shen-jit.u8 M 0))))
(native-test.check "a parameter replaced" 14 (freeze (native-test.replacing (shen-jit.u8! (shen-jit.bytes 1) 0 9) 3 0)))

\\ What is no memory is no error until it is used, and then says so.
(define native-test.maybe-read
  M I N Acc -> Acc where (>= I N)
  M I N Acc -> (native-test.maybe-read M (+ I 1) N (+ Acc (shen-jit.u8 M I))))
(native-test.check "not memory, and not read" 0 (freeze (native-test.maybe-read a 0 0 0)))
(native-test.check "not memory, and read" error (freeze (hd (native-test.result (freeze (native-test.maybe-read a 0 1 0))))))
(native-test.check "a string, which is read only memory, and read" 97 (freeze (native-test.maybe-read "abc" 0 1 0)))
(native-test.check "past the end, in a loop" [error "bytes: 2 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.maybe-read (shen-jit.bytes 2) 0 3 0)))))

\\ Each width and store through the same memory.
(define native-test.widths-loop
  M I N Acc -> Acc where (>= I N)
  M I N Acc -> (do (shen-jit.u32! M 0 I)
                   (shen-jit.u16! M 4 I)
                   (shen-jit.u8! M 6 I)
                   (shen-jit.f64! M 8 1.5)
                   (native-test.widths-loop M (+ I 1) N
                     (+ Acc (shen-jit.u32 M 0) (shen-jit.u16 M 4) (shen-jit.u8 M 6) (shen-jit.s32 M 0) (shen-jit.f64 M 8)))))
(native-test.check "every width, round a loop" 16.5 (freeze (native-test.widths-loop (shen-jit.bytes 16) 0 3 0)))

\\ C that does not collect needs nothing worked out again, but keeps no register, and = on long
\\ lists or vectors and cn on long strings all use plenty of them.
(define native-test.kept-text
  0 Acc -> Acc
  N Acc -> (native-test.kept-text (- N 1) (cn Acc "x")))

(define native-test.kept-list
  0 End -> [End]
  N End -> [(* 1.5 N) "text" (native-test.kept-text 40 "") | (native-test.kept-list (- N 1) End)])

(define native-test.kept-vector
  V 0 End -> (address-> V 1 End)
  V I End -> (native-test.kept-vector (address-> V I (* 0.5 I)) (- I 1) End))

(define native-test.kept-equal
  B1 B2 B3 B4 I N X Y Acc -> Acc where (>= I N)
  B1 B2 B3 B4 I N X Y Acc
  -> (native-test.kept-equal B1 B2 B3 B4 (+ I 1) N X Y
       (if (= X Y)
           -1000000
           (+ Acc (+ (shen-jit.u8 B1 I) (+ (shen-jit.u8 B2 I) (+ (shen-jit.u8 B3 I) (shen-jit.u8 B4 I))))))))

(define native-test.kept-four
  F -> (F (native-test.counting-bytes 64) (native-test.counting-bytes 64)
          (native-test.counting-bytes 64) (native-test.counting-bytes 64)))

(native-test.check "kept across = on lists" 8064
  (freeze (native-test.kept-four
            (/. A B C D (native-test.kept-equal A B C D 0 64 (native-test.kept-list 200 1) (native-test.kept-list 200 2) 0)))))
(native-test.check "kept across = on vectors" 8064
  (freeze (native-test.kept-four
            (/. A B C D (native-test.kept-equal A B C D 0 64 (native-test.kept-vector (vector 200) 200 1.25)
                                                (native-test.kept-vector (vector 200) 200 1.75) 0)))))

(define native-test.kept-cn
  B1 B2 B3 B4 I N X Acc -> Acc where (>= I N)
  B1 B2 B3 B4 I N X Acc
  -> (let Joined (cn X X)
       (native-test.kept-cn B1 B2 B3 B4 (+ I 1) N X
         (+ Acc (+ (shen-jit.u8 B1 I) (+ (shen-jit.u8 B2 I) (+ (shen-jit.u8 B3 I) (shen-jit.u8 B4 I))))))))
(native-test.check "kept across cn" 8064
  (freeze (native-test.kept-four (/. A B C D (native-test.kept-cn A B C D 0 64 (native-test.kept-text 2000 "") 0)))))

(define-native native-test.kept-equal-registers (B1 B2 B3 B4 X Y N)
  (word I 0)
  (word Acc 0)
  (loop top)
  (jump-unless-word (< I N) done)
  (prim T = X Y)
  (word Acc (+ Acc (+ (u8 B1 I) (+ (u8 B2 I) (+ (u8 B3 I) (u8 B4 I))))))
  (word I (+ I 1))
  (again top)
  (label done)
  (return-word Acc))
(native-test.check "and in registers" 8064
  (freeze (native-test.kept-four
            (/. A B C D (native-test.kept-equal-registers A B C D (native-test.kept-list 200 1) (native-test.kept-list 200 2) 64)))))

\\ One width through memory makes its length a limit on the index: every width, reading and storing,
\\ up to the last index with room and not one past it, at lengths down to less than the width.
(define-native native-test.limit-u8 (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (word X (u8 M I)) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u16 (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (word X (u16 M I)) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u32 (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (word X (u32 M I)) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-s32 (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (word X (s32 M I)) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u64 (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (word X (u64 M I)) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-f64 (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (real X (f64 M I)) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u8! (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (u8! M I 7) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u16! (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (u16! M I 7) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u32! (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (u32! M I 7) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-u64! (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (u64! M I N) (word N (- N 1)) (again top) (label done) (return-word N))
(define-native native-test.limit-f64! (M I0 N0) (word I I0) (word N N0) (loop top) (jump-unless-word (> N 0) done) (f64! M I 1.5) (word N (- N 1)) (again top) (label done) (return-word N))

(define native-test.limit-wrong
  F Width Length I -> (let Fits (and (>= I 0) (<= (+ I Width) Length))
                           Did (trap-error (do (F (shen-jit.bytes Length) I 2) true) (/. E false))
                        (if (= Fits Did) [] [[Width Length I Fits]])))

(define native-test.limit-indices
  Width Length -> [0 1 (- Length Width) (+ 1 (- Length Width)) (- Length 1) Length (+ Length 1) -1 -8 1152921504606846975])

(define native-test.limit-all
  [F Width] -> (mapcan (/. Length (mapcan (/. I (native-test.limit-wrong F Width Length I))
                                          (native-test.limit-indices Width Length)))
                       [0 1 2 3 4 7 8 9 15 16 17 1024]))

(native-test.check "one width: what fits, and nothing else" []
  (freeze (mapcan (function native-test.limit-all)
                  [[(fn native-test.limit-u8) 1] [(fn native-test.limit-u16) 2] [(fn native-test.limit-u32) 4]
                   [(fn native-test.limit-s32) 4] [(fn native-test.limit-u64) 8] [(fn native-test.limit-f64) 8]
                   [(fn native-test.limit-u8!) 1] [(fn native-test.limit-u16!) 2] [(fn native-test.limit-u32!) 4]
                   [(fn native-test.limit-u64!) 8] [(fn native-test.limit-f64!) 8]])))
(native-test.check "one width, not memory, and not reached" 0 (freeze (native-test.limit-f64 a 0 0)))
(native-test.check "one width, not memory, and reached" error (freeze (hd (native-test.result (freeze (native-test.limit-f64 a 0 1))))))
(native-test.check "one width, what it says past the end" [error "bytes: 9 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.limit-f64 (shen-jit.bytes 16) 9 1)))))

\\ An integer as an index is one more word index, and keeps memory at one width.
(define-native native-test.literal-index (M N0)
  (word N N0)
  (real Acc 0)
  (loop top)
  (jump-unless-word (> N 0) done)
  (f64! M 8 (+ Acc (f64 M 0)))
  (real Acc (+ Acc (f64 M 8)))
  (word N (- N 1))
  (again top)
  (label done)
  (return-real Acc))
(native-test.check "an integer as an index" 10.5 (freeze (native-test.literal-index (shen-jit.f64! (shen-jit.bytes 16) 0 1.5) 3)))
(native-test.check "and past the end" [error "bytes: 8 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.literal-index (shen-jit.f64! (shen-jit.bytes 8) 0 1.5) 3)))))
(define-native native-test.literal-below (M) (real X (f64 M -1)) (return-real X))
(native-test.check "and before the start" [error "bytes: -1 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.literal-below (shen-jit.bytes 8))))))

\\ More than one width, or an index in a slot, leaves the length a length.
(define-native native-test.mixed-widths (M I0 N0)
  (word I I0)
  (word N N0)
  (word Acc 0)
  (loop top)
  (jump-unless-word (> N 0) done)
  (word Acc (+ Acc (u8 M I)))
  (real X (f64 M 0))
  (word N (- N 1))
  (again top)
  (label done)
  (return-word Acc))
(native-test.check "a byte past where 8 would fit" 30 (freeze (native-test.mixed-widths (native-test.counting-bytes 16) 15 2)))
(native-test.check "and past the end" [error "bytes: 16 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.mixed-widths (native-test.counting-bytes 16) 16 2)))))

(define-native native-test.slot-and-word (M S I0 N0)
  (word I I0)
  (word N N0)
  (loop top)
  (jump-unless-word (> N 0) done)
  (real X (f64 M S))
  (real Y (f64 M I))
  (word N (- N 1))
  (again top)
  (label done)
  (return-word N))
(native-test.check "a slot and a word as indices" 0 (freeze (native-test.slot-and-word (shen-jit.bytes 16) 8 8 2)))
(native-test.check "the slot past the end" error (freeze (hd (native-test.result (freeze (native-test.slot-and-word (shen-jit.bytes 16) 9 8 2))))))
(native-test.check "the word past the end" [error "bytes: 9 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.slot-and-word (shen-jit.bytes 16) 8 9 2)))))

\\ A loop runs to its last jump back, and an inner loop can jump back to an outer one.
(define-native native-test.back-jumps (M N0)
  (word N N0)
  (word I 0)
  (word Acc 0)
  (loop outer)
  (jump-unless-word (< I N) done)
  (word I (+ I 1))
  (word J 0)
  (loop inner)
  (jump-unless-word (< J 4) next)
  (word Acc (+ Acc (u8 M J)))
  (word J (+ J 1))
  (jump-unless-word (< Acc 10) skip)
  (again outer)
  (label skip)
  (again inner)
  (label next)
  (again outer)
  (label done)
  (return-word Acc))
(native-test.check "jumps back, several and from within" 63
  (freeze (native-test.back-jumps (native-test.cached-store (shen-jit.bytes 64) 0 64 []) 3)))

\\ More than fits in registers: the deepest loop's names get them, with kept memory among them, and
\\ what is used least stays in the native frame, where a narrow load must still replace all of a
\\ word. Calls to C, collecting or not, leave it all as it was, and a buffer can move. The numbers
\\ were worked out apart from this.
(define-native native-test.places (M1 M2 M3 M4 N0 X Y Junk)
  (word Low1 -1)
  (word Low1 (u8 M1 15))
  (word Low2 0)
  (word Low2 (s32 M3 0))
  (word N N0)
  (word A 1)
  (word B 2)
  (word C 3)
  (word D 4)
  (word E 5)
  (word F 6)
  (word H 7)
  (word K 8)
  (word I 0)
  (loop outer)
  (jump-unless-word (< I N) finished)
  (word Z (* 4 (bit-and I 3)))
  (word B (+ B (s32 M3 Z)))
  (word-box Boxed I)
  (prim Junk cons Boxed Junk)
  (prim T = X Y)
  (word J 0)
  (loop inner)
  (jump-unless-word (< J 8) next)
  (word A (+ A (u8 M1 J)))
  (word C (bit-xor C (+ A B)))
  (word D (+ D (u64 M4 (* J 8))))
  (u64! M4 (* J 8) (+ D C))
  (word E (+ E (bit-and C 255)))
  (word F (bit-xor F (shift-left E 3)))
  (word H (bit-xor H (shift-right F 5)))
  (word K (+ K (bit-and H 15)))
  (f64! M2 (* J 8) (+ (f64 M2 (* J 8)) K))
  (word J (+ J 1))
  (again inner)
  (label next)
  (word I (+ I 1))
  (again outer)
  (label finished)
  (word A (+ A B))
  (word A (+ A C))
  (word A (+ A D))
  (word A (bit-xor A E))
  (word A (+ A F))
  (word A (+ A H))
  (word A (+ A K))
  (word A (+ A Low1))
  (word A (+ A Low2))
  (word-box Count (bit-and A 1048575))
  (prim R cons Count Junk)
  (return R))

(define native-test.run-places
  M1Length M4Length N
  -> (let M1 (native-test.counting-bytes M1Length)
          M2 (shen-jit.bytes 64)
          M3 (shen-jit.u32! (shen-jit.u32! (shen-jit.u32! (shen-jit.u32! (shen-jit.bytes 16) 0 4294967295) 4 5) 8 6) 12 7)
          M4 (shen-jit.bytes M4Length)
          R (native-test.places M1 M2 M3 M4 N (native-test.kept-list 20 1) (native-test.kept-list 20 2) [])
       [R (shen-jit.f64 M2 0) (shen-jit.f64 M2 56) (shen-jit.u32 M4 0)]))

(native-test.check "more than fits in registers" [[33461 4 3 2 1 0] 685 976 6092] (freeze (native-test.run-places 16 64 5)))
(native-test.check "what it says of memory used least" [error "bytes: 15 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.run-places 8 64 5)))))
(native-test.check "and of memory used most" [error "bytes: 8 is not a valid index"]
  (freeze (native-test.result (freeze (native-test.run-places 16 8 5)))))

\\ And reals: two used once, outside the loop, and more in it than there are float registers.
(define-native native-test.real-places (A N0)
  (real Low 16)
  (real Root (sqrt Low))
  (real R0 A) (real R1 A) (real R2 A) (real R3 A) (real R4 A) (real R5 A) (real R6 A) (real R7 A)
  (real R8 A) (real R9 A) (real R10 A) (real R11 A) (real R12 A) (real R13 A) (real R14 A) (real R15 A)
  (real R16 A) (real R17 A) (real R18 A) (real R19 A) (real R20 A) (real R21 A) (real R22 A) (real R23 A)
  (real R24 A) (real R25 A) (real R26 A) (real R27 A) (real R28 A) (real R29 A) (real R30 A) (real R31 A)
  (word N N0)
  (loop top)
  (jump-unless-word (> N 0) done)
  (real R0 (+ R0 R1)) (real R1 (+ R1 R2)) (real R2 (+ R2 R3)) (real R3 (+ R3 R4)) (real R4 (+ R4 R5))
  (real R5 (+ R5 R6)) (real R6 (+ R6 R7)) (real R7 (+ R7 R8)) (real R8 (+ R8 R9)) (real R9 (+ R9 R10))
  (real R10 (+ R10 R11)) (real R11 (+ R11 R12)) (real R12 (+ R12 R13)) (real R13 (+ R13 R14)) (real R14 (+ R14 R15))
  (real R15 (+ R15 R16)) (real R16 (+ R16 R17)) (real R17 (+ R17 R18)) (real R18 (+ R18 R19)) (real R19 (+ R19 R20))
  (real R20 (+ R20 R21)) (real R21 (+ R21 R22)) (real R22 (+ R22 R23)) (real R23 (+ R23 R24)) (real R24 (+ R24 R25))
  (real R25 (+ R25 R26)) (real R26 (+ R26 R27)) (real R27 (+ R27 R28)) (real R28 (+ R28 R29)) (real R29 (+ R29 R30))
  (real R30 (+ R30 R31))
  (word N (- N 1))
  (again top)
  (label done)
  (return-real (+ Root (+ R0 R31))))
(native-test.check "more reals than fit" 13 (freeze (native-test.real-places 1.0 3)))

\\ What must be refused.
(native-test.refused "a word unset" (freeze (define-native native-test.bad (A) (word X (+ Y 1)) (word Y 1) (return-word X))))
(native-test.refused "a word as a slot" (freeze (define-native native-test.bad (A) (word X A) (prim Y + X 1) (return Y))))
(native-test.refused "a real in a word expression" (freeze (define-native native-test.bad (A) (real R A) (word X (+ R 1)) (return-word X))))
(native-test.refused "both kinds under one name" (freeze (define-native native-test.bad (A) (real X A) (word X A) (return-word X))))
(native-test.refused "a fraction as a word" (freeze (define-native native-test.bad (A) (word X 1.5) (return-word X))))
(native-test.refused "not a word expression" (freeze (define-native native-test.bad (A) (word X (foo A)) (return-word X))))
(native-test.refused "not a comparison of words" (freeze (define-native native-test.bad (A) (word X A) (jump-unless-word (foo X X) l) (label l) (return A))))
(native-test.refused "a word with a call" (freeze (define-native native-test.bad (A) (word X A) (call R reverse A) (return-word X))))
(native-test.refused "more word registers than there are"
  (freeze (define-native native-test.bad (A)
            (word R0 A) (word R1 A) (word R2 A) (word R3 A) (word R4 A) (word R5 A) (word R6 A) (word R7 A)
            (word R8 A) (word R9 A) (word R10 A) (word R11 A) (word R12 A) (word R13 A) (word R14 A) (word R15 A)
            (word R16 A) (return-word R16))))
(native-test.raw "a word out of range" [code native-test.bad 0 3 [0] [[word-number 16 [const 0]] [return [const 0]]] []])
(native-test.raw "a word unset, by number" [code native-test.bad 0 3 [0] [[word-box 2 0] [return 2]] []])
(native-test.raw "a word store past the registers" [code native-test.bad 1 4 [0] [[word-store8 2 [const 0] 16] [return 2]] []])
(native-test.raw "back to no loop" [code native-test.bad 0 3 [] [[again 0]] []])
(native-test.raw "back to a label" [code native-test.bad 0 3 [] [[label 0] [again 0]] []])
(native-test.raw "back to a loop after it" [code native-test.bad 0 3 [] [[again 0] [loop 0] [again 0]] []])
(native-test.raw "a word test to nowhere" [code native-test.bad 0 3 [0] [[word-number 0 [const 0]] [word-unless< 0 0 9] [return [const 0]]] []])
(native-test.refused "none of those was installed, a third time" (freeze ((fn native-test.bad))))

\\ ---------------------------------------------------------------------------
\\ Structured control, made into the same labels, loops and jumps.

(define-native native-test.count-byte (Data Start End Byte)
  (word Count 0)
  (for I Start End
    (when (= (u8 Data I) Byte)
      (word Count (+ Count 1))))
  (return-word Count))

(native-test.check "for and when" 3
  (freeze (native-test.count-byte (shen-jit.string->bytes "abcabca") 0 7 97)))
(native-test.check "for over nothing" 0
  (freeze (native-test.count-byte (shen-jit.string->bytes "abc") 2 2 99)))

\* Even numbers below N, skipped past with next, until the sum passes Limit. *\
(define-native native-test.evens (N Limit)
  (word Sum 0)
  (word I 0)
  (while (< I N)
    (word I (+ I 1))
    (unless (= (bit-and I 1) 0) (next))
    (word Sum (+ Sum I))
    (when (> Sum Limit) (exit)))
  (return-word Sum))

(native-test.check "while, next and exit" 2550 (freeze (native-test.evens 100 100000)))
(native-test.check "while, left early" 110 (freeze (native-test.evens 100 100)))

\* if and else, comparing reals because a side is a real register. *\
(define-native native-test.clamp (X)
  (real V X)
  (if (< V 0) (real V 0) (if (> V 1) (real V 1)))
  (return-real V))

(native-test.check "if on reals, below" 0.0 (freeze (native-test.clamp -2.5)))
(native-test.check "if on reals, between" 0.25 (freeze (native-test.clamp 0.25)))
(native-test.check "if on reals, above" 1.0 (freeze (native-test.clamp 7.5)))

\* and, or and not, and != *\
(define-native native-test.in-range (X Lo Hi)
  (word V X)
  (when (and (>= V Lo) (< V Hi) (not (= V 5)) (or (= V 1) (!= (bit-and V 1) 1)))
    (return-word 1))
  (return-word 0))

(native-test.check "and, or and not"
  [0 1 1 0 1 0 0 0 0]
  (freeze (map (/. X (native-test.in-range X 1 8)) [0 1 2 3 4 5 7 8 9])))

\* Leaving an outer loop by its name, and a block. *\
(define-native native-test.factors (Target)
  (word Found 0)
  (for outer I 1 20
    (for J 1 20
      (when (= (* I J) Target)
        (word Found (+ (* I 100) J))
        (exit outer))))
  (block checked
    (when (= Found 0) (exit checked))
    (word Found (+ Found 10000)))
  (return-word Found))

(native-test.check "exit by name" 10118 (freeze (native-test.factors 18)))
(native-test.check "exit from a block" 0 (freeze (native-test.factors 401)))

\* next by name goes round the outer loop *\
(define-native native-test.rows (N)
  (word Count 0)
  (for row I 0 N
    (for J 0 N
      (when (> J I) (next row))
      (word Count (+ Count 1))))
  (return-word Count))

(native-test.check "next by name" 15 (freeze (native-test.rows 5)))

\* A slot holding a boolean is a test too, with tagged instructions around it. *\
(define-native native-test.pick (Flag)
  (if Flag (return yes) (return no)))

(native-test.check "a boolean as a test" [yes no] (freeze [(native-test.pick true) (native-test.pick false)]))

\* A loop whose body always leaves it has no way round, and arms that both end nothing after them. *\
(define-native native-test.first-even (N)
  (for I 0 N
    (when (= (bit-and I 1) 0) (return-word I))
    (return-word -1))
  (return-word -2))

(define native-test.first-even-from-one
  -> (let F (shen-jit.install-code (shen-jit.assemble native-test.odd [(protect N)]
              [[for (protect I) 1 (protect N)
                 [when [= [bit-and (protect I) 1] 0] [return-word (protect I)]]
                 [return-word -1]]
               [return-word -2]]))
       (F 3)))

(native-test.check "a loop that never goes round" [-1 0 -2]
  (freeze [(native-test.first-even-from-one) (native-test.first-even 5) (native-test.first-even 0)]))

\* The same code object as the loop written out, the labels aside, which number the same. *\
(native-test.check "the same instructions as written by hand"
  true
  (freeze (= (shen-jit.assemble native-test.s [(protect N)]
               [[word (protect I) 0]
                [while [< (protect I) (protect N)] [word (protect I) [+ (protect I) 1]]]
                [return-word (protect I)]])
             (shen-jit.assemble native-test.s [(protect N)]
               [[word (protect I) 0]
                [loop head]
                [jump-unless-word [< (protect I) (protect N)] out]
                [word (protect I) [+ (protect I) 1]]
                [label next]
                [again head]
                [label out]
                [return-word (protect I)]]))))

\* expand-native shows what a generator's statements become. *\
(native-test.check "expand-native gives instructions"
  [[jump-unless-test [< x 1] structure.end.1] [return-word 0] [label structure.end.1]]
  (freeze (do (set shen-jit.structure.*count* 0)
              (shen-jit.expand-native [[when [< x 1] [return-word 0]]]))))

(native-test.check "exit outside a loop"
  [error "native code: exit or next outside a loop"]
  (freeze (shen-jit.assemble native-test.bad [] [[exit] [return-word 0]])))
(native-test.check "next of a block"
  [error "native code: next of b, which is a block and not a loop"]
  (freeze (shen-jit.assemble native-test.bad [] [[block b [next b]] [return-word 0]])))
(native-test.check "exit by a name not around"
  [error "native code: no loop or block named nowhere around here"]
  (freeze (shen-jit.assemble native-test.bad [] [[while true [exit nowhere]] [return-word 0]])))
(native-test.check "not a test"
  [error "native code: not a test: (+ 1 2)"]
  (freeze (shen-jit.assemble native-test.bad [] [[when [+ 1 2] [return-word 0]] [return-word 1]])))
(native-test.check "a malformed for"
  [error "native code: malformed for: (for 1 2)"]
  (freeze (shen-jit.assemble native-test.bad [] [[for 1 2] [return-word 1]])))
(native-test.refused "falls off the end after if"
  (freeze (shen-jit.install-code (shen-jit.assemble native-test.bad [(protect X)]
            [[word (protect V) (protect X)] [if [< (protect V) 1] [return-word 0]]]))))

(shen-jit.install-code
  [defun native-test.entry-loop
    [code native-test.entry-loop 1 4 [0]
      [[entry 2 0]
       [prim 3 = 2 [const 0]]
       [jump-if-false 3 1]
       [return 2]
       [label 1]
       [const 2 0]
       [tail-call 0 native-test.entry-loop 1]
       [label 0]
       [return 3]]
      []]])
(native-test.check "an entry beside a self tail call loads its arguments" true
  (freeze (eval-kl [= [native-test.entry-loop 10 20] 20])))

(define-native native-test.mixed-store (M)
  (word I 8)
  (f64! M (truncate (+ I 0.5)) (+ 1.5 2.5))
  (return M))
(native-test.check "a store index keeps the real value it stores" 4
  (freeze (shen-jit.f64 (native-test.mixed-store (shen-jit.bytes 16)) 8)))
(define-native native-test.mixed-load (M A)
  (word I 7)
  (return-word (+ (+ A 1) (truncate (f64 M (+ I 1))))))
(native-test.check "a load index keeps the word operand around it" 43
  (freeze (native-test.mixed-load (shen-jit.f64! (shen-jit.bytes 16) 8 2.5) 40)))

(native-test.refused "a register may not take a temporary's name"
  (freeze
    (define-native native-test.temp-collision (A)
      (word Word.0 10)
      (return-word (+ (+ A 1) Word.0)))))

(native-test.refused "a word constant is an integer"
  (freeze
    (define-native native-test.bad-word-constant ()
      (word X (const "bad"))
      (return-word X))))

(native-test.check "a constant test keeps only the branch that runs" 2
  (freeze
    (do
      (define-native native-test.constant-false ()
        (if false (return 1) (return 2)))
      (native-test.constant-false))))

(native-test.refused "a raw instruction with extra operands"
  (freeze
    (define-native native-test.extra-word-operand ()
      (word X 7)
      (word-move X 9 10)
      (return-word X))))

(native-test.check "a misplaced exception is the one named"
  [error "native code, native-test.bad-exception: exception not at a handler label: (exception 3)"]
  (freeze
    (shen-jit.install-code
      [defun native-test.bad-exception
        [code native-test.bad-exception 0 4 [7]
          [[const 2 0] [exception 3] [return 2]]
          []]])))

(output "~A passed, ~A failed~%" (value native-test.*passed*) (value native-test.*failed*))
