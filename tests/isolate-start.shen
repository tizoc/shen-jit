\\ What an isolate starts with: the builder loads this file, sets a global and a property, and spawns
\\ an isolate that runs start-test.main, with none of the builder's globals or properties and its
\\ gensyms numbered past 2^32, which sends back how many checks it ran and how many failed
\\ (start-test.run).

(set *start-test.global* builder)
(put start-test.twice start-test.note builder)

(define start-test.twice
  X -> (* 2 X))

(define start-test.pair
  X Y -> [X Y])

(define start-test.five
  A B C D E -> [A B C D E])

(defprolog start-test.member
  X [X | _] <--;
  X [_ | Y] <-- (start-test.member X Y);)

(define start-test.check
  Name Expected Got -> (if (= Expected Got)
                           (do (output "ok - ~A~%" Name) 0)
                           (do (output "not ok - ~A: expected ~S, got ~S~%" Name Expected Got) 1)))

(define start-test.message
  F -> (trap-error (do (thaw F) none) (/. E (error-to-string E))))

(define start-test.refused?
  F -> (let M (start-test.message F)
         (and (string? M) (= "only the builder" (start-test.prefix M 0 16 "")))))

(define start-test.prefix
  _ N N Acc -> Acc
  S I N Acc -> (start-test.prefix S (+ I 1) N (cn Acc (pos S I))) where (> (length (explode S)) I)
  _ _ _ Acc -> Acc)

(define start-test.after-colon
  F -> (let M (start-test.message F)
         (start-test.prefix M (+ 2 (start-test.colon M 0)) (+ 18 (start-test.colon M 0)) "")))

(define start-test.colon
  S I -> I where (= (pos S I) ":")
  S I -> (start-test.colon S (+ I 1)))

(define start-test.sum
  [] -> 0
  [X | Xs] -> (+ X (start-test.sum Xs)))

(define start-test.main
  -> (let Results
            [(start-test.check "printing" "1 c#34;ac#34; [b c]" (make-string "~A ~S ~A" 1 "a" [b c]))
             (start-test.check "output" "done" (do (output "isolate: output works~%") "done"))
             (start-test.check "prolog" true (prolog? (start-test.member 2 [1 2 3])))
             (start-test.check "gensym range" true (> (length (explode (str (gensym x)))) 10))
             (start-test.check "fn of a definition" [2 4] (map (fn start-test.twice) [1 2]))
             (start-test.check "fn of two arguments" [a b] (let F start-test.pair (((fn F) a) b)))
             (start-test.check "fn of five arguments" [1 2 3 4 5]
                                 (let F start-test.five ((((((fn F) 1) 2) 3) 4) 5)))
             (start-test.check "fn of a primitive" 3 (let F + ((fn F) 1 2)))
             (start-test.check "arity" 2 (arity start-test.pair))
             (start-test.check "no properties of the builder" none
                                 (trap-error (get start-test.twice start-test.note) (/. E none)))
             (start-test.check "properties of its own" mine
                                 (do (put start-test.twice start-test.note mine)
                                     (get start-test.twice start-test.note)))
             (start-test.check "no globals of the builder" unbound
                                 (trap-error (value *start-test.global*) (/. E unbound)))
             (start-test.check "a global named in code" 5
                                 (do (set *start-test.new* 5) (value *start-test.new*)))
             (start-test.check "a global made here" 7
                                 (let S (intern "start-test.made-here") (do (set S 7) (value S))))
             (start-test.check "not typechecking" false (tc?))
             (start-test.check "eval refuses" "only the builder"
                                 (start-test.after-colon (freeze (eval [+ 1 2]))))
             (start-test.check "eval-kl refuses" "only the builder"
                                 (start-test.after-colon (freeze (eval-kl [+ 1 2]))))
             (start-test.check "install refuses" true
                                 (start-test.refused?
                                   (freeze (shen-jit.install
                                             [defun start-test.new [code start-test.new 0 3 [] [[return 0]] []]]))))
             (start-test.check "vectors" 3 (<-vector (vector-> (vector 2) 1 3) 1))
             (start-test.check "errors" "e" (trap-error (simple-error "e") (/. E (error-to-string E))))]
       [(length Results) (start-test.sum Results)]))

(define start-test.in-isolate
  Out -> (channel.send Out (start-test.main)))

(define start-test.run
  -> (let R (channel.new 1)
          _ (isolate.spawn start-test.in-isolate (channel.sender R))
          Got (channel.receive R)
       (output "~A passed, ~A failed (isolate start)~%" (- (hd Got) (hd (tl Got))) (hd (tl Got)))))
