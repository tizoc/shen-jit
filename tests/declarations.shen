\\ This left rule can prove any goal when its hypothesis is present.
(datatype decl.need
  ____
  decl.key : decl.type >> P;)

(define decl.nested-cost
  -> (let Start (inferences)
          _ (prolog? (decl.need#type anything []))
       (- (inferences) Start)))

(set decl.ordinary (decl.nested-cost))
(set decl.nested 0)
(define decl.target X -> X)
(datatype decl.fact
  if (do (set decl.nested (decl.nested-cost)) true)
  ____
  (fn decl.target) : (number --> number);)

(declare decl.target [string --> string])
(if (and (> (value decl.ordinary) 0) (= (value decl.ordinary) (value decl.nested)))
    true (error "a declaration changed the cost of its guard's independent proof"))
(if (prolog? (decl.need#type anything [[decl.key : decl.type]]))
    true (error "a left rule lost its hypothesis"))

\\ A wildcard can supply the old type even for a fresh function. Visibility
\\ and the first successful rule still determine whether declare warns.
(define decl.hidden X -> X)
(define decl.visible X -> X)
(define decl.same X -> X)
(define decl.also-visible X -> X)
(datatype decl.wild ____ _ : (number --> number);)
(preclude [decl.wild])
(declare decl.hidden [string --> string])
(include [decl.wild])
(declare decl.visible [string --> string])
(declare decl.also-visible [string --> string])
(datatype decl.specific ____ (fn decl.same) : (string --> string);)
(declare decl.same [string --> string])
(preclude [decl.wild decl.specific])

\\ An installed clause calls its current helper even when the old helper
\\ required a nonempty list. Locate the kernel-generated helper by its name.
(define decl.member-name?
  (@s "shen.member" _) -> true
  _ -> false)
(define decl.find-member
  [X | Xs] -> (let F (decl.find-member X) (if (= F false) (decl.find-member Xs) F))
  F -> F where (and (symbol? F) (decl.member-name? (str F)))
  _ -> false)

(set decl.helper (decl.find-member (ps decl.need#type)))
(eval [defprolog (value decl.helper) (protect H) <--
       [when [simple-error "replacement hypothesis helper ran"]] (intern ";")])
(if (= "replacement hypothesis helper ran"
       (trap-error (declare decl.replaced [A --> A]) (/. E (error-to-string E))))
    true (error "declaration bypassed the redefined helper"))
(output "declaration checks passed~%")
