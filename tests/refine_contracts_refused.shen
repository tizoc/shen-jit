\\ Typed definitions that do not prove what buffer's contracts ask. Each is its own program.
(define refused {buffer.view --> fixnum --> fixnum} V I -> (buffer.u8 V I))
\\ next
(define-checked refused {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u8 V 8))
\\ next
(define-checked refused {buffer.view --> fixnum --> fixnum} V I -> (if (fx< I (buffer.length V)) (buffer.u8 V I) 0))
\\ next
(define-checked refused {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u16-be V 7))
\\ next
(define-checked refused {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u32-be V 5))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u8-> V 8 0))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u8-> V 7 256))
\\ next
(define-checked refused {V : buffer.view --> N : fixnum --> buffer.view} {requires (fx>= (buffer.length V) 8) (fx<= N 255)} V N -> (buffer.u8-> V 7 N))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u16-be-> V 7 0))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u16-be-> V 6 65536))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u32-be-> V 5 0))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u32-be-> V 4 4294967296))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.slice V 4 5))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.slice V 0 -1))
\\ next
(define-checked refused {V : buffer.view --> N : fixnum --> buffer.view} {requires (fx>= (buffer.length V) 8) (fx<= N 8)} V N -> (buffer.slice V 0 N))
\\ next
(define-checked refused {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 8)} V -> (buffer.offset-at V 4 5))
\\ next
(define-checked refused {fixnum --> buffer.view} N -> (buffer.new N))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.copy-into! V 0 (buffer.new 4) 0 5))
\\ next
(define-checked refused {V : buffer.view --> buffer.view} {requires (fx>= (buffer.length V) 8)} V -> (buffer.copy-into! (buffer.new 4) 0 V 0 5))
\\ next
\\ The inner of two calls, and the outer.
(define-checked refused {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 4)} V -> (buffer.u8 (buffer.slice (buffer.slice V 0 8) 4 4) 3))
\\ next
(define-checked refused {V : buffer.view --> fixnum} {requires (fx>= (buffer.length V) 8)} V -> (buffer.u8 (buffer.slice (buffer.slice V 0 8) 4 4) 4))
\\ next
\\ A call with what another function needs around its first argument is one that has not been asked about.
(define-checked at {V : buffer.view --> I : fixnum --> buffer.view} {requires (fx<= 0 I)} V _ -> V)
(define refused {buffer.view --> fixnum} V -> (buffer.u8 (at V 1) 0))
\\ next
\\ A contract from elsewhere, its second alternative, its promise one more than it is, and what it does not say.
(define plus {fixnum --> fixnum --> fixnum} A B -> (fx+ A B))
(refine.contract (plus A B) requires (fx<= 0 A) (or (fx= B 1) (fx= B 2) (fx= B 3)))
(define-checked refused {fixnum --> fixnum} X -> (plus (if (fx< X 0) 0 X) 4))
\\ next
(define plus {fixnum --> fixnum --> fixnum} A B -> (fx+ A B))
(refine.contract (plus A B) --> R requires (fx<= 0 B) trusts (fx<= A R))
(define-checked refused {X : fixnum --> R : fixnum} {ensures (fx< X R)} X -> (plus X 1))
\\ next
\\ What is trusted is known once the call has been made, and not where it was not.
(define plus {fixnum --> fixnum --> fixnum} A B -> (fx+ A B))
(refine.contract (plus A B) --> R requires (fx<= 0 B) trusts (fx<= 0 A))
(define-checked from-0 {I : fixnum --> fixnum} {requires (fx<= 0 I)} I -> I)
(define-checked refused {fixnum --> boolean --> fixnum} X Maybe -> (do (if Maybe (plus X 1) 0) (from-0 X)))
\\ next
\\ What is known of buffer's functions is not of a program's own in their place.
(define buffer.length {buffer.view --> fixnum} V -> (fx- 0 1))
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define refused {buffer.view --> fixnum} V -> (from-0 (buffer.length V)))
\\ next
(define-checked from-0 {N : fixnum --> fixnum} {requires (fx<= 0 N)} N -> N)
(define refused {buffer.view --> fixnum} V -> (from-0 (buffer.length V)))
(define buffer.length {buffer.view --> fixnum} V -> (fx- 0 1))
