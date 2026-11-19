(define typing-test.empty
  {number --> (list (option.t number))}
  X -> (let A (option.none) B (option.none) C (option.none)
            D (option.none) E (option.none) F (option.none)
          [A B C D E F]))

(define typing-test.present
  {number --> (list (option.t number))}
  X -> (let A (option.some X) B (option.some X) C (option.some X)
            D (option.some X) E (option.some X) F (option.some X)
          [A B C D E F]))

(define typing-test.json
  {string --> number --> json.value}
  Text Number ->
    (let S (json.from-string Text)
         N (json.from-number Number)
      (json.from-array [S N])))

(if (and (= (typing-test.empty 0) [[] [] [] [] [] []])
         (= (typing-test.present 7) [[7] [7] [7] [7] [7] [7]])
         (= (typing-test.json "count" 7) ["count" 7]))
    (output "3 passed, 0 failed~%")
    (error "typed option or JSON constructor produced the wrong value"))
