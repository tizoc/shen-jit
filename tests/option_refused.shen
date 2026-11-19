(define option-test.two
  {A --> (option.t A)}
  X -> [X X])
\\ next
(define option-test.unchecked-list
  {(list A) --> (option.t A)}
  Xs -> Xs)
\\ next
(define option-test.wrong-item
  {(option.t number) --> string}
  [] -> ""
  [X] -> X)
