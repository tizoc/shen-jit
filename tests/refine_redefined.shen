\\ What a contract says once its function is defined again, or what was read was never checked. Each case is loaded in turn.
(define-checked at-1 {I : fixnum --> fixnum} {requires (fx= I 1)} I -> I)
(define-checked at-2 {I : fixnum --> fixnum} {requires (fx= I 2)} I -> I)
\\ loads
(define-checked promise {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
(define uses-promise {fixnum --> fixnum} X -> (at-1 (promise X)))
\\ loads
(define promise {fixnum --> fixnum} X -> 2)
\\ says type error in rule 1 of uses-promise: at-1 needs (fx= (promise X) 1), which may not be so, as if (promise X) is 0
(define uses-promise {fixnum --> fixnum} X -> (at-1 (promise X)))
\\ loads
(define-checked none {--> R : fixnum} {ensures (fx= R 1)} -> 1)
(define uses-none {--> fixnum} -> (at-1 (none)))
\\ loads
(define none {--> fixnum} -> 2)
\\ says type error in rule 1 of uses-none: at-1 needs (fx= (none) 1), which may not be so, as if (none) is 0
(define uses-none {--> fixnum} -> (at-1 (none)))
\\ loads
(define-checked recursive {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> 1)
\\ loads
(define recursive {fixnum --> fixnum} 0 -> 100 X -> (if (fx> X 0) (fx+ (recursive (fx- X 1)) 2) (recursive (recursive (fx+ X 1)))))
(define calls-recursive {--> fixnum} -> (recursive 3))
(if (= (calls-recursive) 106) true (simple-error (make-string "~A, not 106" (calls-recursive))))
\\ loads
(define-checked untyped-now {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> 1)
\\ loads untyped
(define untyped-now X -> 5)
\\ loads
(define calls-untyped {--> fixnum} -> (untyped-now 3))
(if (= (calls-untyped) 5) true (simple-error (make-string "~A, not 5" (calls-untyped))))
\\ loads untyped
(declare said [fixnum --> fixnum])
\\ loads untyped
(define-checked said {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
(define-checked untyped-both {X : fixnum --> R : fixnum} {requires (fx<= 0 X)} {ensures (fx= R 1)} X -> 1)
(declare untyped-both [fixnum --> fixnum])
\\ loads
(define uses-said {fixnum --> fixnum} X -> (at-1 (said X)))
(define uses-both {fixnum --> fixnum} X -> (at-1 (untyped-both X)) where (fx> X 0))
\\ loads untyped
(define said X -> 1)
\\ says type error in rule 1 of uses-said: at-1 needs (fx= (said X) 1), which may not be so, as if (said X) is 0
(define uses-said {fixnum --> fixnum} X -> (at-1 (said X)))
\\ says define-checked: unread-2 has ensurse in braces, where requires can be and then ensures
(define-checked unread-1 {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)
(define-checked unread-2 {X : fixnum --> R : fixnum} {ensurse (fx= R 2)} X -> 2)
\\ loads
(define unread-1 {fixnum --> fixnum} X -> 3)
\\ says type error in rule 1 of uses-unread: at-2 needs (fx= (unread-1 X) 2), which may not be so, as if (unread-1 X) is 0
(define uses-unread {fixnum --> fixnum} X -> (at-2 (unread-1 X)))
\\ loads
(define-checked old {X : fixnum --> R : fixnum} {requires (fx= X 1)} {ensures (fx= R 1)} X -> 1)
(define-checked old-promise {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
\\ says define-checked: unread-2 has ensurse in braces, where requires can be and then ensures
(define-checked old {X : fixnum --> R : fixnum} {requires (fx= X 0)} {ensures (fx= R 2)} X -> 2)
(define-checked old-promise {X : fixnum --> R : fixnum} {requires (fx= X 5)} {ensures (fx= R 2)} X -> 2)
(define-checked unread-2 {X : fixnum --> R : fixnum} {ensurse (fx= R 2)} X -> 2)
\\ loads
(define uses-old {--> fixnum} -> (at-1 (old 1)))
\\ says type error in rule 1 of uses-old: old needs (fx= 0 1), which may not be so
(define uses-old {--> fixnum} -> (at-1 (old 0)))
\\ says type error in rule 1 of uses-old: at-2 needs (fx= 1 2), which may not be so
(define uses-old {--> fixnum} -> (at-2 (old 1)))
\\ loads
(define uses-old {--> fixnum} -> (old-promise 5))
\\ says define-checked: unread-2 has ensurse in braces, where requires can be and then ensures
(define-checked old {X : fixnum --> R : fixnum} {requires (fx= X 3)} {ensures (fx= R 3)} X -> 3)
(define-checked unread-2 {X : fixnum --> R : fixnum} {ensurse (fx= R 2)} X -> 2)
\\ loads
(define uses-old {--> fixnum} -> (at-1 (old 1)))
\\ loads
(define-checked old {X : fixnum --> R : fixnum} {requires (fx= X 0)} {ensures (fx= R 2)} X -> 2)
(define uses-old {--> fixnum} -> (at-2 (old 0)))
\\ loads
(define-checked old {X : fixnum --> R : fixnum} {requires (fx= X 0)} {ensures (fx= R 2)} X -> 2)
(define uses-old {--> fixnum} -> (at-2 (old 0)))
\\ says type error in rule 1 of failing: failing promises (fx= 1 2), which may not be so
(define-checked failing {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 1)
\\ says type error
(at-2 (failing 1))
\\ loads
(define-checked failing {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)
(at-2 (failing 1))
\\ says type error in rule 1 of failing: failing promises (fx= 2 1), which may not be so
(define-checked failing {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 2)
\\ says type error
(at-1 (failing 1))
\\ loads
(define-checked unread {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
\\ says define-checked: unread-2 has ensurse in braces, where requires can be and then ensures
(define unread {fixnum --> fixnum} X -> 2)
(define-checked unread-2 {X : fixnum --> R : fixnum} {ensurse (fx= R 2)} X -> 2)
\\ loads
(define uses-unread {fixnum --> fixnum} X -> (at-1 (unread X)))
\\ loads
(define-checked condition {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> 1)
\\ says define-checked: unread-2 has ensurse in braces, where requires can be and then ensures
(define-checked condition {X : fixnum --> fixnum} {requires (fx<= 1 X)} X -> 1)
(define-checked unread-2 {X : fixnum --> R : fixnum} {ensurse (fx= R 2)} X -> 2)
\\ loads
(define before {--> fixnum} -> (condition 3))
(define condition {fixnum --> fixnum} X -> 7)
\\ loads
(define before {--> fixnum} -> (condition 3))
(define condition {fixnum --> fixnum} X -> 7)
(if (= (before) 7) true (simple-error (make-string "~A, not 7" (before))))
\\ loads
(define-checked condition {X : fixnum --> fixnum} {requires (fx<= 0 X)} X -> 1)
\\ loads
(define before {--> fixnum} -> (condition 3))
(define-checked condition {X : fixnum --> R : fixnum} {ensures (fx= R 7)} X -> 7)
\\ loads
(define before {--> fixnum} -> (at-1 (fx- (condition 3) 6)))
(define-checked condition {X : fixnum --> R : fixnum} {ensures (fx= R 7)} X -> 7)
(if (= (before) 1) true (simple-error (make-string "~A, not 1" (before))))
\\ loads
(define-checked even* {N : fixnum --> R : fixnum} {requires (fx<= 0 N)} {ensures (fx<= 0 R)} N -> (if (fx= N 0) 0 (odd* (fx- N 1))))
(define-checked odd* {N : fixnum --> R : fixnum} {requires (fx<= 0 N)} {ensures (fx<= 0 R)} N -> (if (fx= N 0) 1 (even* (fx- N 1))))
(if (= (even* 5) 1) true (simple-error "not 1"))
\\ loads
(defmacro within-macro [within I N] -> [and [fx<= 0 I] [fx< I N]])
\\ loads
(define-checked below-5 {X : fixnum --> fixnum} {requires (within X 5)} X -> X)
(define uses-below-5 {fixnum --> fixnum} X -> (below-5 X) where (within X 5))
\\ says type error in rule 1 of uses-below-5: below-5 needs (fx< 5 5), which may not be so
(define uses-below-5 {--> fixnum} -> (below-5 5))
\\ loads
(shen.x.namespace redefined (import refine define-checked)
  (define-checked f {X : fixnum --> R : fixnum} {requires (fx<= 0 X)} {ensures (fx= R 1)} X -> 1))
\\ loads
(shen.x.namespace redefined (define f {fixnum --> fixnum} 0 -> 9 X -> (f 0)))
(if (= (redefined.f 4) 9) true (simple-error "not 9"))
\\ says type error in rule 1 of uses-f: at-1 needs (fx= (redefined.f X) 1), which may not be so, as if (redefined.f X) is 0
(define uses-f {fixnum --> fixnum} X -> (at-1 (redefined.f X)))
\\ loads
(refine.type from-0 N where (fx<= 0 N))
(define-checked half {X : fixnum --> R : from-0} {requires (fx<= 0 X)} X -> (fxquotient X 2))
(define half-of-3 {--> from-0} -> (half 3))
\\ says type error in rule 1 of half
(define-checked half {X : number --> R : number} {requires (fx<= 0 X)} X -> (- 0 (/ X 2)))
\\ loads
(if (= (half-of-3) 1) true (simple-error (make-string "~A, not 1" (half-of-3))))
\\ loads
(define-checked late {X : fixnum --> R : fixnum} {ensures (fx= R 1)} X -> 1)
\\ untyped says no such host
(error "no such host")
(define-checked late {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)
\\ untyped says define-checked: unread-2 has ensurse in braces, where requires can be and then ensures
(define late X -> 2)
(define-checked unread-2 {X : fixnum --> R : fixnum} {ensurse (fx= R 2)} X -> 2)
\\ loads
(define uses-late {fixnum --> fixnum} X -> (at-1 (late X)))
\\ loads untyped
(define-checked late {X : fixnum --> R : fixnum} {ensures (fx= R 2)} X -> 2)
\\ loads
(define uses-late {fixnum --> fixnum} X -> (at-2 (late X)))
\\ loads
(track late)
(define uses-late {fixnum --> fixnum} X -> (at-2 (late X)))
(untrack late)
(define uses-late-2 {fixnum --> fixnum} X -> (at-2 (late X)))
\\ says type error in rule 1 of oops
(define oops {fixnum --> string} X -> X)
(defstruct never-made (value : fixnum))
\\ loads
(define never-made.make {fixnum --> fixnum} X -> (if (fx> X 100) 100 X))
(define never-made.value {fixnum --> fixnum} X -> X)
(define-checked over-100 {X : fixnum --> fixnum} {requires (fx> X 100)} X -> X)
\\ says type error in rule 1 of uses-made: over-100 needs (fx> (never-made.value (never-made.make 500)) 100), which may not be so, as if (never-made.value (never-made.make 500)) is 0
(define uses-made {--> fixnum} -> (over-100 (never-made.value (never-made.make 500))))
\\ loads
(define made-outside {fixnum --> fixnum} X -> X)
(refine.contract (made-outside X) requires (fx= X 1))
\\ loads
(refine.contract (made-outside X) requires (fx= X 2))
(define uses-outside {--> fixnum} -> (made-outside 2))
\\ says type error in rule 1 of uses-outside: made-outside needs (fx= 1 2), which may not be so
(define uses-outside {--> fixnum} -> (made-outside 1))
\\ An expression is evaluated before what is defined after it, so it calls no body of that.
\\ loads untyped
(define-checked later-again {X : fixnum --> R : fixnum} {requires (fx> X 5)} {ensures (fx= R 1)} X -> 1)
\\ loads
(if (fx= (later-again 6) 1) true (simple-error "not 1"))
(define-checked later-again {X : fixnum --> R : fixnum} {requires (fx> X 5)} {ensures (fx= R 1)} X -> 1)
(define calls-later {--> fixnum} -> (later-again 6))
(calls-later)
\\ What has a contract from elsewhere has no body, also where it is defined later.
\\ loads
(refine.contract (outside-later X) requires (fx= X 1))
(define calls-outside-later {--> fixnum} -> (outside-later 1))
(define outside-later {fixnum --> fixnum} X -> X)
(if (fx= 1 (calls-outside-later)) true (simple-error "not 1"))
