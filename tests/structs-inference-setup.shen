\\ Each definition must typecheck under the image's default inference limit.
(defstruct proof-test.red (_ : number))
(defstruct proof-test.blue (_ : number))
(struct.union proof-test.color proof-test.red proof-test.blue)

\\ An active context-sensitive rule is visible to the ordinary checker.
(datatype proof-test.context
  ctxt H if (cons? H) ____ proof-test.token : number;)

(datatype proof-test.unbound if (shen.pvar? T) ____ proof-test.unbound-token : (list T);)

\\ Red belongs to either union. The second row needs a user rule to get
\\ from raw to blue. Both routes look possible before the guard is checked.
(struct.union proof-test.pigment proof-test.red)
(defstruct proof-test.pale (_ : number))
(struct.union proof-test.pigment proof-test.pale)

(datatype proof-test.paint ctxt H if (cons? H)
  X : proof-test.raw;
  _______________
  X : proof-test.blue;)

(datatype proof-test.pale-paint
  ctxt H if (not (cons? H))
  X : proof-test.raw;
  _______________
  X : proof-test.pale;)
