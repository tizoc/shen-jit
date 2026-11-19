\\ An optional A is [] for no value or [X] for one value, including when X itself is [].
(shen.x.namespace option
  (export t some none)

  (datatype t
    ___________
    [] : (- (t A));

    X : A;
    ____________
    [X] : (- (t A));

    X : A >> Goal;
    ____________
    [X] : (t A) >> Goal;))
