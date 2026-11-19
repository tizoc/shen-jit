\\ A field read at a type its parameter does not have.
(defstruct (refused.box A) (mutable value : A))
(define refused.read {(refused.box number) --> string} B -> (refused.box.value B))
\\ next
(defstruct (refused.box A) (mutable value : A))
(define refused.set {(refused.box number) --> (refused.box number)} B -> (refused.box.value-> B "a"))
\\ next
\\ A union member's field has the type the union gives it.
(defstruct (refused.ok A) (value : A))
(defstruct (refused.err E) (error : E))
(struct.union (refused.result (E * A)) (refused.ok A) (refused.err E))
(define refused.error {(refused.result (string * number)) --> number}
  (:refused.err error <- E) -> E
  (:refused.ok value <- V) -> V)
\\ next
(defstruct (refused.anonymous A) (_ : A))
(define refused.anonymous-read {(refused.anonymous number) --> string}
  (:refused.anonymous X) -> X)
\\ next
(defstruct refused.anonymous (_ : number))
(define refused.anonymous-build {--> refused.anonymous}
  -> (:refused.anonymous "wrong"))
\\ next
\\ The token guard sees T before the next row binds it to number.
(datatype refused.sensitive if (= T number) ____ refused.token : (list T);)
(define refused.same {(list (A * A)) --> number} X -> (length X))
(define refused.order {--> number}
  -> (refused.same [(@p [] refused.token) (@p [1] [2])]))

\\ next
\\ A product-parameter union cannot be passed a lambda.
(defstruct (refused.left A) (value : A))
(defstruct (refused.right B) (value : B))
(struct.union (refused.either (A * B)) (refused.left A) (refused.right B))
(define refused.consume {(refused.either (A * B)) --> number} _ -> 0)
(define refused.lambda {--> number} -> (refused.consume (/. X 42)))

\\ next
\\ A struct type cannot be supplied by a lambda either.
(defstruct (refused.pair (A * B)) (left : A) (right : B))
(define refused.pick-right {(refused.pair (A * B)) --> B}
  Pair -> (refused.pair.right Pair))
(define refused.pair-lambda {number --> number} N -> (+ N (refused.pick-right (/. X 1))))
