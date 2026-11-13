\\ Isolates (docs/design.md, "The builder and isolates"): spawning, what crosses and how,
\\ channels, monitors, kill, and the program fixed while isolates run. The builder runs this file;
\\ every check ends in it, so an isolate that never answers hangs the suite rather than passing it.
\\ Everything is defined first: the builder cannot define while another isolate runs.

(set pt.passed 0)
(set pt.failed 0)

(define pt.check
  Name Expected Got -> (if (= Expected Got)
                           (set pt.passed (+ 1 (value pt.passed)))
                           (do (set pt.failed (+ 1 (value pt.failed)))
                               (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Got))))

(define pt.message
  F -> (trap-error (do (thaw F) none) (/. E (error-to-string E))))

\\ Spawns F with [Argument Replies], and gives the first reply once the isolate has ended.
(define pt.ask
  F Argument -> (let R (shen-jit.channel 1)
                     P (shen-jit.spawn F [Argument (shen-jit.sender R)])
                     M (shen-jit.monitor P)
                     Reply (shen-jit.receive R)
                     _ (shen-jit.receive M)
                  Reply))

(define pt.reply
  [X Out] -> (shen-jit.send Out X))

(define pt.suffix
  S N -> (pt.drop S (- (pt.length S) N)))

(define pt.length
  "" -> 0
  S -> (+ 1 (pt.length (tlstr S))))

(define pt.drop
  S 0 -> S
  S N -> (pt.drop (tlstr S) (- N 1)))

(define pt.third
  [_ _ X] -> X)

(define pt.shared
  [X Out] -> (shen-jit.send Out [(shen-jit.same? (hd X) (hd (tl X))) X]))

(define pt.cycle
  [V Out] -> (shen-jit.send Out (shen-jit.same? V (<-address V 1))))

(define pt.symbols
  [S Out] -> (shen-jit.send Out [S (shen-jit.same? S (intern (str S))) (intern "pt-made-in-a-isolate")]))

(define pt.twice
  X -> (* 2 X))

(define pt.call
  [F Out] -> (shen-jit.send Out [((fn F) 21) (map (fn F) [1 2]) (map (function pt.twice) [3])]))

(define pt.start
  [_ Out] -> (shen-jit.send Out [(trap-error (value *pt.global*) (/. E unbound))
                                 (do (set *pt.global* mine) (value *pt.global*))
                                 (trap-error (get pt.twice pt.note) (/. E none))
                                 (value *hush*)
                                 (string? (value *version*))
                                 (trap-error (eval [+ 1 2]) (/. E (error-to-string E)))]))

(defprolog pt.member
  X [X | _] <--;
  X [_ | Y] <-- (pt.member X Y);)

(define pt.prolog
  [_ Out] -> (shen-jit.send Out [(prolog? (pt.member X [a b]) (return X)) (prolog? (pt.member c [a b]))]))

(define pt.collect
  _ 0 -> []
  R N -> [(shen-jit.receive R) | (pt.collect R (- N 1))])

(define pt.send-all
  [Xs Out] -> (do (map (/. X (shen-jit.send Out X)) Xs) (shen-jit.close Out)))

(define pt.echo
  Requests -> (let M (shen-jit.receive Requests)
                (if (shen-jit.end? M)
                    done
                    (do (shen-jit.send (hd M) (tl M)) (pt.echo Requests)))))

(define pt.fail
  X -> (simple-error (cn "failing with " (str X))))

(define pt.down
  F X -> (let P (shen-jit.spawn F X) M (shen-jit.monitor P) Down (shen-jit.receive M)
           [(hd Down) (= (hd (tl Down)) P) (pt.third Down)]))

(define pt.wait
  R -> (shen-jit.receive R))

(define pt.wait-catching
  Out -> (let Never (shen-jit.channel 1)
           (trap-error (do (shen-jit.send Out ready) (shen-jit.receive Never))
                       (/. E (do (shen-jit.send Out (error-to-string E)) cleaned)))))

(define pt.count
  0 Acc -> Acc
  N Acc -> (pt.count (- N 1) (+ Acc 1)))

(define pt.count-then-send
  [N Out] -> (shen-jit.send Out (pt.count N 0)))

(define pt.save
  [_ Out] -> (shen-jit.send Out (pt.message (freeze (shen-jit.save-executable "pt-never" [])))))

(define pt.sum
  [L Out] -> (shen-jit.send Out (sum L)))

(define pt.in-turn
  0 -> true
  K -> (and (= (pt.ask pt.reply K) K) (pt.in-turn (- K 1))))

(define pt.wait-long
  Out -> (do (shen-jit.send Out ready) (shen-jit.wait-any [(shen-jit.channel 1)] 86400000)))

(define pt.spin
  Out -> (do (shen-jit.send Out ready) (pt.spin-on 0)))

(define pt.spin-on
  N -> (do (shen-jit.check-kill) (pt.spin-on (+ N 1))))

\\ Spawns F with a sender, and kills it once it has sent: how it ended.
(define pt.kill-when-ready
  F -> (let R (shen-jit.channel 1)
            P (shen-jit.spawn F (shen-jit.sender R))
            M (shen-jit.monitor P)
            _ (shen-jit.receive R)
            _ (shen-jit.kill P)
         (pt.third (shen-jit.receive M))))

(defstruct pt-point
  x
  (mutable y))

\\ What an isolate gets that was shared: whether it is the sender's own, and what it reads in it.
(define pt.shared-in
  [V Out] -> (shen-jit.send Out [V (<-address V 2) (pt-point.y (<-address V 3))]))

(define pt.share-here
  [X Out] -> (shen-jit.send Out (shen-jit.share X)))

\\ A loop over a buffer's bytes, which reads them through the registers it keeps for them.
(define pt.sum-bytes
  B I N Acc -> (if (= I N) Acc (pt.sum-bytes B (+ I 1) N (+ Acc (shen-jit.u8 B I)))))

(define pt.fill-bytes
  B I N -> (if (= I N) B (do (shen-jit.u8! B I 7) (pt.fill-bytes B (+ I 1) N))))

(set *pt.global* builder)
(put pt.twice pt.note builder)

\\ ---------------------------------------------------------------------------------------------
\\ What a definition's code may hold: what the reader makes, and nothing a form has to be built
\\ around.

(pt.check "code that holds a vector is refused"
  "pt.holds-a-vector: code may hold only symbols, numbers, strings, booleans and lists of them"
  (let V (vector 2) (pt.message (freeze (eval-kl [defun pt.holds-a-vector [] V])))))

(pt.check "and so is code that holds a closure"
  "pt.holds-a-closure: code may hold only symbols, numbers, strings, booleans and lists of them"
  (let F (let Y 1 (/. X (+ X Y))) (pt.message (freeze (eval-kl [defun pt.holds-a-closure [] F])))))

\\ ---------------------------------------------------------------------------------------------
\\ The program is fixed while another isolate runs, and can change again once none does. This is
\\ the file's first spawn, so nothing else runs meanwhile.

(pt.check "defining beside an isolate raises, and works once it has ended"
  ["the program cannot change while other isolates run" killed [later 20]]
  (let P (shen-jit.spawn pt.wait (shen-jit.give (shen-jit.channel 1)))
       M (shen-jit.monitor P)
       Refused (pt.message (freeze (eval [define pt.later (intern "X") -> [cons later [cons (intern "X") []]]])))
       _ (shen-jit.kill P)
       Down (pt.third (shen-jit.receive M))
       _ (eval [define pt.later (intern "X") -> [cons later [cons (intern "X") []]]])
    [Refused Down (pt.later 20)]))

\\ ---------------------------------------------------------------------------------------------
\\ What crosses: copied, with sharing and cycles kept; symbols and the program's functions as they
\\ are.

(pt.check "a value goes there and back" [a "text" 1.5 -7 [nested (@p 1 2)] true []]
  (pt.ask pt.reply [a "text" 1.5 -7 [nested (@p 1 2)] true []]))

(pt.check "sharing is kept" [true [[1 2] [1 2]]] (let L [1 2] (pt.ask pt.shared [L L])))

(pt.check "a cycle is kept" true (let V (absvector 2) (do (address-> V 0 cycle) (address-> V 1 V) (pt.ask pt.cycle V))))

(pt.check "a vector is copied" [true false] (let V (@v 1 2 3 <>) W (pt.ask pt.reply V) [(= V W) (shen-jit.same? V W)]))

(pt.check "a symbol is one symbol in every isolate" [true true true]
  (let S (gensym pt-sym)
       Got (pt.ask pt.symbols S)
    [(shen-jit.same? (hd Got) S) (hd (tl Got)) (shen-jit.same? (pt.third Got) (intern "pt-made-in-a-isolate"))]))

(pt.check "a function goes by its name" [42 [2 4] [6]] (pt.ask pt.call pt.twice))

(pt.check "what fn makes in the builder stays there" "#<procedure> cannot be sent: only the program's functions can"
  (pt.message (freeze (shen-jit.send (shen-jit.sender (shen-jit.channel 1)) (fn pt.twice)))))

(pt.check "a closure is refused" "#<procedure> cannot be sent: only the program's functions can"
  (pt.message (freeze (shen-jit.send (shen-jit.sender (shen-jit.channel 1)) [(/. X X)]))))

(pt.check "a stream is refused" "#<stream> cannot be sent"
  (pt.message (freeze (shen-jit.send (shen-jit.sender (shen-jit.channel 1)) (stoutput)))))

(pt.check "the end of a stream is refused" "the end of a stream cannot be sent"
  (pt.message (freeze (shen-jit.send (shen-jit.sender (shen-jit.channel 1)) [shen-jit.end-of-stream]))))

(pt.check "a receive endpoint moves only at spawn" true
  (let M (pt.message (freeze (shen-jit.send (shen-jit.sender (shen-jit.channel 1)) (shen-jit.channel 1))))
    (and (string? M) (= "can move only at spawn, through shen-jit.give" (pt.suffix M 45)))))

(pt.check "spawn wants a defined function of one argument"
  "shen-jit.spawn: pt.nothing is not a function of one argument that the builder defined"
  (pt.message (freeze (shen-jit.spawn pt.nothing 1))))

(pt.check "or one argument exactly"
  "shen-jit.spawn: pt.check is not a function of one argument that the builder defined"
  (pt.message (freeze (shen-jit.spawn pt.check 1))))

\\ ---------------------------------------------------------------------------------------------
\\ An isolate starts as a program does: nothing of the builder's.

(pt.check "an isolate has its own globals and properties"
  [unbound mine none false true "eval: only the builder can evaluate or define code"]
  (pt.ask pt.start []))

(pt.check "the builder's global is its own" builder (value *pt.global*))

(pt.check "Prolog runs in an isolate" [a false] (pt.ask pt.prolog []))

\\ ---------------------------------------------------------------------------------------------
\\ Channels.

(pt.check "a sender parks while the channel is full, and its close ends the stream"
  [1 2 3 4 5 true]
  (let R (shen-jit.channel 1)
       _ (shen-jit.spawn pt.send-all [[1 2 3 4 5] (shen-jit.sender R)])
       Got (pt.collect R 5)
    (append Got [(shen-jit.end? (shen-jit.receive R))])))

(pt.check "a channel read to its end is freed" "channel closed"
  (let R (shen-jit.channel 2)
       S (shen-jit.sender R)
       _ (shen-jit.send S 1)
       _ (shen-jit.close S)
       _ (shen-jit.receive R)
       _ (shen-jit.receive R)
    (pt.message (freeze (shen-jit.receive R)))))

(pt.check "sending on a closed channel raises" "channel closed"
  (let R (shen-jit.channel 1) S (shen-jit.sender R) _ (shen-jit.close R)
    (pt.message (freeze (shen-jit.send S 1)))))

(pt.check "receive-any gives the endpoint too" [on-b true]
  (let A (shen-jit.channel 1)
       B (shen-jit.channel 1)
       _ (shen-jit.send (shen-jit.sender B) on-b)
       Got (shen-jit.receive-any [A B])
    [(hd (tl Got)) (shen-jit.same? (hd Got) B)]))

(pt.check "a given receive endpoint moves to the child" [[x y] "belongs to another isolate"]
  (let Requests (shen-jit.channel 2)
       Replies (shen-jit.channel 2)
       _ (shen-jit.spawn pt.echo (shen-jit.give Requests))
       Send (shen-jit.sender Requests)
       _ (shen-jit.send Send [(shen-jit.sender Replies) x y])
       Got (shen-jit.receive Replies)
       Refused (pt.message (freeze (shen-jit.receive Requests)))
       _ (shen-jit.close Send)
    [Got (pt.suffix Refused 26)]))

(pt.check "wait-any gives () once its time has passed" [] (shen-jit.wait-any [(shen-jit.channel 1)] 10))

(pt.check "wait-any gives the first that has a message or is closed, and receives nothing" [true true x]
  (let Empty (shen-jit.channel 1)
       Full (shen-jit.channel 1)
       Closed (shen-jit.channel 1)
       _ (shen-jit.send (shen-jit.sender Full) x)
       _ (shen-jit.close (shen-jit.sender Closed))
    [(shen-jit.same? Full (shen-jit.wait-any [Empty Full Closed] 0))
     (shen-jit.same? Closed (shen-jit.wait-any [Empty Closed] 0))
     (shen-jit.receive Full)]))

(pt.check "wait-any wakes when a message comes" [true x]
  (let R (shen-jit.channel 1)
       _ (shen-jit.spawn pt.reply [x (shen-jit.sender R)])
    [(shen-jit.same? R (shen-jit.wait-any [R] 60000)) (shen-jit.receive R)]))

(pt.check "wait-any refuses what is not a receive endpoint" "shen-jit.wait-any: 5 is not a receive endpoint"
  (pt.message (freeze (shen-jit.wait-any [5] 0))))

\\ ---------------------------------------------------------------------------------------------
\\ Monitors and kill, which an isolate sees at its next channel operation.

(pt.check "a normal end" [down true normal] (pt.down pt.reply [x (shen-jit.sender (shen-jit.channel 1))]))

(pt.check "an uncaught error ends an isolate" [down true "failing with 5"] (pt.down pt.fail 5))

\\ An isolate ended once its first monitor is told, so the second comes after: it gets down at once,
\\ with the reason, however long the builder took to ask.
(define pt.again
  P -> (let M (shen-jit.monitor P)
            _ (shen-jit.receive M)
         (pt.third (shen-jit.receive (shen-jit.monitor P)))))

(pt.check "a monitor of an ended isolate gets down at once, with its reason" normal
  (let R (shen-jit.channel 1) (pt.again (shen-jit.spawn pt.reply [x (shen-jit.sender R)]))))

(pt.check "an error's message" "failing with 5" (pt.again (shen-jit.spawn pt.fail 5)))

(pt.check "or killed" killed
  (let P (shen-jit.spawn pt.wait (shen-jit.give (shen-jit.channel 1)))
       _ (shen-jit.kill P)
    (pt.again P)))

(pt.check "kill raises an error that handlers see" ["killed" normal]
  (let R (shen-jit.channel 1)
       P (shen-jit.spawn pt.wait-catching (shen-jit.sender R))
       M (shen-jit.monitor P)
       _ (shen-jit.receive R)
       _ (shen-jit.kill P)
       Got (shen-jit.receive R)
    [Got (pt.third (shen-jit.receive M))]))

(pt.check "kill wakes a parked receiver" killed
  (let P (shen-jit.spawn pt.wait (shen-jit.give (shen-jit.channel 1)))
       M (shen-jit.monitor P)
       _ (shen-jit.kill P)
    (pt.third (shen-jit.receive M))))

(pt.check "kill wakes an isolate in wait-any" killed (pt.kill-when-ready pt.wait-long))

(pt.check "check-kill lets kill reach an isolate busy elsewhere" killed (pt.kill-when-ready pt.spin))

(pt.check "check-kill in the builder" false (shen-jit.check-kill))

(pt.check "a busy isolate sees kill when it next sends" [killed true]
  (let R (shen-jit.channel 1)
       P (shen-jit.spawn pt.count-then-send [50000000 (shen-jit.sender R)])
       M (shen-jit.monitor P)
       _ (shen-jit.kill P)
       Down (pt.third (shen-jit.receive M))
    [Down (shen-jit.end? (trap-error (do (shen-jit.close R) shen-jit.end-of-stream) (/. E E)))]))

(pt.check "an isolate cannot save" "save-executable: only the builder can save" (pt.ask pt.save []))

(pt.check "the builder cannot save beside isolates" "save-executable: other isolates are running"
  (let P (shen-jit.spawn pt.wait (shen-jit.give (shen-jit.channel 1)))
       M (shen-jit.monitor P)
       Refused (pt.message (freeze (shen-jit.save-executable "pt-never" [])))
       _ (shen-jit.kill P)
       _ (shen-jit.receive M)
    Refused))

(pt.check "the builder cannot be killed" true
  (let Me (shen-jit.self) (shen-jit.same? Me (shen-jit.kill Me))))

\\ ---------------------------------------------------------------------------------------------
\\ Shared storage: a copy outside every heap, read by pointer in any isolate, which nothing changes.

(pt.check "a shared value equals what was shared" [true true true]
  (let V (@v 1 [a "b" 2.5] (@v x <>) <>)
       S (shen-jit.share V)
    [(= S V) (= V S) (= (hash S 1000) (hash V 1000))]))

(pt.check "and keeps its sharing and cycles" [true true]
  (let L [1 2]
       V (@v L L 0 <>)
       _ (address-> V 3 V)
       S (shen-jit.share V)
    [(shen-jit.same? (<-address S 1) (<-address S 2)) (shen-jit.same? S (<-address S 3))]))

(pt.check "what is already shared or has no copy comes back as it is" [true true 5 a]
  (let S (shen-jit.share [1 2])
    [(shen-jit.same? S (shen-jit.share S)) (shen-jit.same? S (hd (shen-jit.share [S]))) (shen-jit.share 5)
     (shen-jit.share a)]))

(pt.check "a shared vector reads as any" [true true 3 x true]
  (let S (shen-jit.share (@v x y z <>))
    [(absvector? S) (vector? S) (limit S) (<-address S 1) (= (map (/. I (<-address S I)) [1 2 3]) [x y z])]))

(pt.check "stores into a shared vector raise"
  ["address->: <1 2> is shared, and cannot change" "address->: <1 2> is shared, and cannot change"
   "shen-jit.newpv: <1 2> is not a vector of bindings"]
  (let S (shen-jit.share (@v 1 2 <>))
    [(pt.message (freeze (vector-> S 1 3))) (pt.message (freeze (address-> S 1 3)))
     (pt.message (freeze (shen-jit.newpv S 0)))]))

(pt.check "a shared dictionary reads, and cannot change" [1 "is shared, and cannot change" "is shared, and cannot change"]
  (let D (shen.dict 8)
       _ (shen.dict-> D a 1)
       S (shen-jit.share D)
    [(shen.<-dict S a) (pt.suffix (pt.message (freeze (shen.dict-> S b 2))) 28)
     (pt.suffix (pt.message (freeze (shen.dict-rm S a))) 28)]))

(pt.check "a shared byte buffer reads, in a loop too, and refuses stores" [104 532 532 true true true]
  (let B (shen-jit.string->bytes "hello")
       S (shen-jit.share B)
    [(shen-jit.u8 S 0) (pt.sum-bytes S 0 5 0) (pt.sum-bytes B 0 5 0) (= S B)
     (not (= (pt.message (freeze (shen-jit.u8! S 0 1))) none))
     (not (= (pt.message (freeze (pt.fill-bytes S 0 5))) none))]))

(pt.check "and copying into one raises" true
  (not (= (pt.message (freeze (shen-jit.copy-bytes (shen-jit.share (shen-jit.bytes 4)) 0 (shen-jit.bytes 4) 0 4)))
          none)))

(pt.check "a shared record matches, reads, and refuses its setter" [true 1 2 true]
  (let R (shen-jit.share (pt-point.make 1 2))
    [(pt-point? R) (pt-point.x R) (pt-point.y R) (not (= (pt.message (freeze (pt-point.y-> R 3))) none))]))

(pt.check "a shared value crosses to an isolate by pointer" [true y 9]
  (let S (shen-jit.share (@v x y (pt-point.make 8 9) <>))
       Got (pt.ask pt.shared-in S)
    [(shen-jit.same? S (hd Got)) (hd (tl Got)) (pt.third Got)]))

(pt.check "an isolate shares, and the builder reads it by pointer" [true [1 "two" 3.0]]
  (let S (pt.ask pt.share-here [1 "two" 3.0])
    [(shen-jit.same? S (shen-jit.share S)) S]))

(pt.check "what cannot be sent cannot be shared"
  ["#<procedure> cannot be sent: only the program's functions can" "can move only at spawn, through shen-jit.give"]
  [(pt.message (freeze (shen-jit.share [(/. X X)])))
   (pt.suffix (pt.message (freeze (shen-jit.share (shen-jit.channel 1)))) 45)])

\\ ---------------------------------------------------------------------------------------------
\\ Many at once, and many in turn.

(pt.check "eight at once" [36 36 36 36 36 36 36 36]
  (let R (shen-jit.channel 8)
       S (shen-jit.sender R)
       _ (map (/. I (shen-jit.spawn pt.sum [[1 2 3 4 5 6 7 8] S])) [1 2 3 4 5 6 7 8])
    (pt.collect R 8)))

(pt.check "two hundred in turn" true (pt.in-turn 200))

(output "~A passed, ~A failed (isolates)~%" (value pt.passed) (value pt.failed))
