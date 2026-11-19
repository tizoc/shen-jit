\\ (:ok V) and (:err E) inhabit (result.t (E * A)), where E is the error type and A the value type.
\\ Load under (tc -); result-typed.shen then checks the two union-returning constructors.

(shen.x.namespace result
  (import struct defstruct)
  (shadow bind)
  (export bind let-ok ok err ok.make err.make ok? err? empty t)

(defstruct (ok A) (_ : A))
(defstruct (err E) (_ : E))

\\ One type argument keeps a result distinct from a function arrow during unification.
\\ The struct signatures type construction. Widen once when the goal asks for a result.
\\ The left rules give a result pattern's fields their types.
(datatype t
  X : (ok A);
  ____________________
  X : (- (t (E * A)));

  Value : A >> Goal;
  __________________________
  (:ok Value) : (t (E * A)) >> Goal;

  X : (err E);
  ____________________
  X : (- (t (E * A)));

  Error : E >> Goal;
  __________________________
  (:err Error) : (t (E * A)) >> Goal;

  ___________
  [] : (- empty);)

\\ (result.let-ok X Result ... Body): Body with each X bound to the value of an ok Result, in
\\ order, or the first result that is not ok, as it is. _ ignores the payload, including [].
\\ Each step is a bind, so typed code chains results whose values differ in type.
(defmacro let-ok-macro
  [let-ok Body] -> Body
  [let-ok X _] -> (error "let-ok: no body after binding ~A" X)
  [let-ok X R | More] -> [bind R [/. (if (= (str X) "_") (gensym (protect U)) X) [let-ok | More]]])

)
