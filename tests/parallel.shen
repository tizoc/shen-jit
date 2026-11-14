\\ parallel.map over isolates. Load lib/parallel.shen first. Everything is defined before the first
\\ map, and each map returns once its isolates have ended.
(set par.passed 0)
(set par.failed 0)

(define par.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. E [raised (error-to-string E)]))
      (if (= Expected Got)
          (set par.passed (+ 1 (value par.passed)))
          (do (set par.failed (+ 1 (value par.failed)))
              (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Got)))))

(define par.raises?
  F -> (trap-error (do (thaw F) false) (/. E true)))

(define par.square X -> (* X X))
(define par.add A X -> (+ A X))
(define par.three X -> (if (= X 3) (error "three") X))
(define par.closure X -> (/. Y X))
(define par.global X -> (trap-error (value *par.global*) (/. E unbound)))
(define par.first Table X -> (<-address Table X))
(define par.same Table X -> (shen-jit.same? Table X))
(define par.range
  N N -> []
  I N -> [I | (par.range (+ I 1) N)])

(set *par.global* builder)

(par.check "squares, in order" (map (function par.square) (par.range 0 100))
  (freeze (parallel.map 7 par.square (par.range 0 100))))
(par.check "more isolates than elements" [1 4 9] (freeze (parallel.map 16 par.square [1 2 3])))
(par.check "one isolate" [1 4 9] (freeze (parallel.map 1 par.square [1 2 3])))
(par.check "nothing to map" [] (freeze (parallel.map 4 par.square [])))
(par.check "a function with its first arguments" [101 102] (freeze (parallel.map 2 [par.add 100] [1 2])))
(par.check "an isolate inherits no globals" [unbound unbound] (freeze (parallel.map 2 par.global [a b])))
(par.check "the first error raises, once every isolate has ended" [raised "parallel.map: three"]
  (freeze (parallel.map 4 par.three [1 2 3 4 5 3])))
(par.check "a result that cannot cross raises" true
  (freeze (par.raises? (freeze (parallel.map 1 par.closure [1])))))
(par.check "a closure is not a function's name" true
  (freeze (par.raises? (freeze (parallel.map 1 (/. X X) [1])))))
(par.check "nor is a function of other arguments" true
  (freeze (par.raises? (freeze (parallel.map 1 par.add [1])))))
(par.check "nor a count that is not one" true
  (freeze (par.raises? (freeze (parallel.map 0 par.square [1])))))

\\ A table shared once crosses to every isolate by pointer.
(let Table (isolate.share (@v a b c <>))
  (do (par.check "a shared argument reads in every isolate" [a b c]
        (freeze (parallel.map 3 [par.first Table] [1 2 3])))
      (par.check "by pointer" [true true]
        (freeze (parallel.map 2 [par.same Table] [Table Table])))))

\\ Every isolate has ended, so the program can change again.
(define par.later X -> X)
(par.check "defining after a map" ok (freeze (par.later ok)))

\\ A map whose spawn fails closes the channels it made for replies.
(par.check "a failed launch's replies are closed" "channel closed"
  (freeze (let R (channel.new 1)
               _ (parallel.close-replies [R])
            (trap-error (channel.receive R) (/. E (error-to-string E))))))
(par.check "a map whose argument cannot cross raises" true
  (freeze (trap-error (do (parallel.map 2 [par.square (/. X X)] [1 2]) false) (/. E true))))

(output "~A passed, ~A failed (parallel)~%" (value par.passed) (value par.failed))
