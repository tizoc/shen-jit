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
  F Argument -> (let R (channel.new 1)
                     P (isolate.spawn F [Argument (channel.sender R)])
                     M (isolate.monitor P)
                     Reply (channel.receive R)
                     _ (channel.receive M)
                  Reply))

(define pt.reply
  [X Out] -> (channel.send Out X))

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

(define pt.ready
  [ready R] -> R)

(define pt.shared
  [X Out] -> (channel.send Out [(shen-jit.same? (hd X) (hd (tl X))) X]))

(define pt.cycle
  [V Out] -> (channel.send Out (shen-jit.same? V (<-address V 1))))

(define pt.symbols
  [S Out] -> (channel.send Out [S (shen-jit.same? S (intern (str S))) (intern "pt-made-in-a-isolate")]))

(define pt.twice
  X -> (* 2 X))

(define pt.call
  [F Out] -> (channel.send Out [((fn F) 21) (map (fn F) [1 2]) (map (function pt.twice) [3])]))

(define pt.start
  [_ Out] -> (channel.send Out [(trap-error (value *pt.global*) (/. E unbound))
                                 (do (set *pt.global* mine) (value *pt.global*))
                                 (trap-error (get pt.twice pt.note) (/. E none))
                                 (value *hush*)
                                 (string? (value *version*))
                                 (trap-error (eval [+ 1 2]) (/. E (error-to-string E)))]))

(defprolog pt.member
  X [X | _] <--;
  X [_ | Y] <-- (pt.member X Y);)

(define pt.prolog
  [_ Out] -> (channel.send Out [(prolog? (pt.member X [a b]) (return X)) (prolog? (pt.member c [a b]))]))

(define pt.collect
  _ 0 -> []
  R N -> [(channel.receive R) | (pt.collect R (- N 1))])

(define pt.send-all
  [Xs Out] -> (do (map (/. X (channel.send Out X)) Xs) (channel.close Out)))

(define pt.echo
  Requests -> (pt.echoed Requests (channel.next Requests)))

(define pt.echoed
  _ [closed] -> done
  Requests [ok M] -> (do (channel.send (hd M) (tl M)) (pt.echo Requests)))

(define pt.fail
  X -> (simple-error (cn "failing with " (str X))))

(define pt.down
  F X -> (let P (isolate.spawn F X) M (isolate.monitor P) Down (channel.receive M)
           [(hd Down) (= (hd (tl Down)) P) (pt.third Down)]))

(define pt.wait
  R -> (channel.receive R))

(define pt.block
  _ -> (channel.receive (channel.new 1)))

(define pt.wait-catching
  Out -> (let Never (channel.new 1)
           (trap-error (do (channel.send Out ready) (channel.receive Never))
                       (/. E (do (channel.send Out (error-to-string E)) cleaned)))))

(define pt.count
  0 Acc -> Acc
  N Acc -> (pt.count (- N 1) (+ Acc 1)))

(define pt.count-then-send
  [N Out] -> (channel.send Out (pt.count N 0)))

(define pt.save
  [_ Out] -> (channel.send Out (pt.message (freeze (shen-jit.save-executable "pt-never" [])))))

(define pt.sum
  [L Out] -> (channel.send Out (sum L)))

(define pt.in-turn
  0 -> true
  K -> (and (= (pt.ask pt.reply K) K) (pt.in-turn (- K 1))))

(define pt.wait-long
  Out -> (do (channel.send Out ready) (channel.wait-any [(channel.new 1)] 86400000)))

(define pt.spin
  Out -> (do (channel.send Out ready) (pt.spin-on 0)))

\\ A buffer of 300,000 bytes, whose bytes are their offsets' low eight bits, and back what one is
\\ given holds after a store and a collection.
(define pt.big-bytes
  N -> (pt.fill-big (shen-jit.bytes N) 0 N))

(define pt.fill-big
  B N N -> B
  B I N -> (do (shen-jit.u8! B I (shen-jit.bit-and I 255)) (pt.fill-big B (+ I 1) N)))

(define pt.big-echo
  [B Out] -> (let _ (shen-jit.u8! B 0 7)
                  _ (shen-jit.collect)
               (channel.send Out [(shen-jit.bytes-length B) (shen-jit.u8 B 0) (shen-jit.u8 B 299999) B])))

(define pt.spin-on
  N -> (do (isolate.check-kill) (pt.spin-on (+ N 1))))

\\ Spawns F with a sender, and kills it once it has sent: how it ended.
(define pt.kill-when-ready
  F -> (let R (channel.new 1)
            P (isolate.spawn F (channel.sender R))
            M (isolate.monitor P)
            _ (channel.receive R)
            _ (isolate.kill P)
         (pt.third (channel.receive M))))

(defstruct pt-point
  x
  (mutable y))

\\ What an isolate gets that was shared: whether it is the sender's own, and what it reads in it.
(define pt.shared-in
  [V Out] -> (channel.send Out [V (<-address V 2) (pt-point.y (<-address V 3))]))

(define pt.share-here
  [X Out] -> (channel.send Out (isolate.share X)))

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
  (let P (isolate.spawn pt.wait (channel.give (channel.new 1)))
       M (isolate.monitor P)
       Refused (pt.message (freeze (eval [define pt.later (intern "X") -> [cons later [cons (intern "X") []]]])))
       _ (isolate.kill P)
       Down (pt.third (channel.receive M))
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
  (pt.message (freeze (channel.send (channel.sender (channel.new 1)) (fn pt.twice)))))

(pt.check "a closure is refused" "#<procedure> cannot be sent: only the program's functions can"
  (pt.message (freeze (channel.send (channel.sender (channel.new 1)) [(/. X X)]))))

(pt.check "a stream is refused" "#<stream> cannot be sent"
  (pt.message (freeze (channel.send (channel.sender (channel.new 1)) (stoutput)))))

(pt.check "the end of a stream is refused" "the end of a stream cannot be sent"
  (pt.message (freeze (channel.send (channel.sender (channel.new 1)) [shen-jit.end-of-stream]))))

(pt.check "a receive endpoint moves only at spawn" true
  (let M (pt.message (freeze (channel.send (channel.sender (channel.new 1)) (channel.new 1))))
    (and (string? M) (= "can move only at spawn, through channel.give" (pt.suffix M 44)))))

(pt.check "spawn wants a defined function of one argument"
  "isolate.spawn: pt.nothing is not a function of one argument that the builder defined"
  (pt.message (freeze (isolate.spawn pt.nothing 1))))

(pt.check "or one argument exactly"
  "isolate.spawn: pt.check is not a function of one argument that the builder defined"
  (pt.message (freeze (isolate.spawn pt.check 1))))

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
  (let R (channel.new 1)
       _ (isolate.spawn pt.send-all [[1 2 3 4 5] (channel.sender R)])
       Got (pt.collect R 5)
    (append Got [(= (channel.next R) [closed])])))

(pt.check "a channel read to its end is freed" "channel closed"
  (let R (channel.new 2)
       S (channel.sender R)
       _ (channel.send S 1)
       _ (channel.close S)
       _ (channel.receive R)
       _ (channel.next R)
    (pt.message (freeze (channel.receive R)))))

(pt.check "a receive at the end of a stream raises" ["channel closed" "channel closed"]
  (let R (channel.new 2)
       S (channel.sender R)
       _ (channel.close S)
       R2 (channel.new 1)
       _ (channel.close (channel.sender R2))
    [(pt.message (freeze (channel.receive R))) (pt.message (freeze (channel.receive-any [R2])))]))

(pt.check "next gives each message, then the end once" [[ok 1] [ok [2 3]] [closed] "channel closed"]
  (let R (channel.new 2)
       S (channel.sender R)
       _ (channel.send S 1)
       _ (channel.send S [2 3])
       _ (channel.close S)
       A (channel.next R)
       B (channel.next R)
       C (channel.next R)
    [A B C (pt.message (freeze (channel.next R)))]))

(pt.check "sending on a closed channel raises" "channel closed"
  (let R (channel.new 1) S (channel.sender R) _ (channel.close R)
    (pt.message (freeze (channel.send S 1)))))

(pt.check "receive-any gives the endpoint too" [on-b true]
  (let A (channel.new 1)
       B (channel.new 1)
       _ (channel.send (channel.sender B) on-b)
       Got (channel.receive-any [A B])
    [(hd (tl Got)) (shen-jit.same? (hd Got) B)]))

(pt.check "a given receive endpoint moves to the child" [[x y] "belongs to another isolate"]
  (let Requests (channel.new 2)
       Replies (channel.new 2)
       _ (isolate.spawn pt.echo (channel.give Requests))
       Send (channel.sender Requests)
       _ (channel.send Send [(channel.sender Replies) x y])
       Got (channel.receive Replies)
       Refused (pt.message (freeze (channel.receive Requests)))
       _ (channel.close Send)
    [Got (pt.suffix Refused 26)]))

\\ A channel closed after its endpoint was given takes a new one's place; the given endpoint must not
\\ move that one.
(pt.check "a given endpoint of a closed channel moves nothing"
  ["channel.give: only a channel's receiver can give it, while it is open" x]
  (let R (channel.new 1)
       G (channel.give R)
       _ (channel.close R)
       R2 (channel.new 1)
       Message (pt.message (freeze (isolate.spawn pt.wait G)))
       _ (channel.send (channel.sender R2) x)
    [Message (channel.receive R2)]))

(pt.check "wait-any gives [timeout] once its time has passed" [timeout] (channel.wait-any [(channel.new 1)] 10))

(pt.check "wait-any gives the first that has a message or is closed, and receives nothing" [true true x]
  (let Empty (channel.new 1)
       Full (channel.new 1)
       Closed (channel.new 1)
       _ (channel.send (channel.sender Full) x)
       _ (channel.close (channel.sender Closed))
    [(shen-jit.same? Full (pt.ready (channel.wait-any [Empty Full Closed] 0)))
     (shen-jit.same? Closed (pt.ready (channel.wait-any [Empty Closed] 0)))
     (channel.receive Full)]))

(pt.check "wait-any wakes when a message comes" [true x]
  (let R (channel.new 1)
       _ (isolate.spawn pt.reply [x (channel.sender R)])
    [(shen-jit.same? R (pt.ready (channel.wait-any [R] 60000))) (channel.receive R)]))

(pt.check "wait-any refuses what is not a receive endpoint" "channel.wait-any: 5 is not a receive endpoint"
  (pt.message (freeze (channel.wait-any [5] 0))))

\\ ---------------------------------------------------------------------------------------------
\\ Monitors and kill, which an isolate sees at its next channel operation.

(pt.check "a normal end" [down true normal] (pt.down pt.reply [x (channel.sender (channel.new 1))]))

(pt.check "an uncaught error ends an isolate" [down true "failing with 5"] (pt.down pt.fail 5))

\\ An isolate ended once its first monitor is told, so the second comes after: it gets down at once,
\\ with the reason, however long the builder took to ask.
(define pt.again
  P -> (let M (isolate.monitor P)
            _ (channel.receive M)
         (pt.third (channel.receive (isolate.monitor P)))))

(pt.check "a monitor of an ended isolate gets down at once, with its reason" normal
  (let R (channel.new 1) (pt.again (isolate.spawn pt.reply [x (channel.sender R)]))))

(pt.check "an error's message" "failing with 5" (pt.again (isolate.spawn pt.fail 5)))

(pt.check "or killed" killed
  (let P (isolate.spawn pt.wait (channel.give (channel.new 1)))
       _ (isolate.kill P)
    (pt.again P)))

(pt.check "kill raises an error that handlers see" ["killed" normal]
  (let R (channel.new 1)
       P (isolate.spawn pt.wait-catching (channel.sender R))
       M (isolate.monitor P)
       _ (channel.receive R)
       _ (isolate.kill P)
       Got (channel.receive R)
    [Got (pt.third (channel.receive M))]))

(pt.check "kill wakes a parked receiver" killed
  (let P (isolate.spawn pt.wait (channel.give (channel.new 1)))
       M (isolate.monitor P)
       _ (isolate.kill P)
    (pt.third (channel.receive M))))

(pt.check "kill wakes an isolate in wait-any" killed (pt.kill-when-ready pt.wait-long))

(pt.check "stop-each kills what spawn-each started and waits for each to end" [killed killed killed]
  (let Started (isolate.spawn-each pt.block [1 2 3])
       _ (isolate.stop-each Started)
    (map (/. S (pt.third (channel.receive (isolate.monitor (hd S))))) Started)))

(pt.check "check-kill lets kill reach an isolate busy elsewhere" killed (pt.kill-when-ready pt.spin))

(pt.check "check-kill in the builder" false (isolate.check-kill))

(pt.check "a busy isolate sees kill when it next sends" [killed none]
  (let R (channel.new 1)
       P (isolate.spawn pt.count-then-send [50000000 (channel.sender R)])
       M (isolate.monitor P)
       _ (isolate.kill P)
       Down (pt.third (channel.receive M))
    [Down (pt.message (freeze (channel.close R)))]))

(pt.check "an isolate cannot save" "save-executable: only the builder can save" (pt.ask pt.save []))

(pt.check "the builder cannot save beside isolates" "save-executable: other isolates are running"
  (let P (isolate.spawn pt.wait (channel.give (channel.new 1)))
       M (isolate.monitor P)
       Refused (pt.message (freeze (shen-jit.save-executable "pt-never" [])))
       _ (isolate.kill P)
       _ (channel.receive M)
    Refused))

(pt.check "the builder cannot be killed" true
  (let Me (isolate.self) (shen-jit.same? Me (isolate.kill Me))))

(pt.check "a large buffer crosses, and is the receiver's own" [300000 7 223 7 true 0]
  (let B (pt.big-bytes 300000)
       Got (pt.ask pt.big-echo B)
       _ (shen-jit.collect)
    [(hd Got) (hd (tl Got)) (nth 3 Got) (shen-jit.u8 (nth 4 Got) 0) (= (shen-jit.u8 (nth 4 Got) 299999) 223)
     (shen-jit.u8 B 0)]))

\\ ---------------------------------------------------------------------------------------------
\\ Shared storage: a copy outside every heap, read by pointer in any isolate, which nothing changes.

(pt.check "a shared value equals what was shared" [true true true]
  (let V (@v 1 [a "b" 2.5] (@v x <>) <>)
       S (isolate.share V)
    [(= S V) (= V S) (= (hash S 1000) (hash V 1000))]))

(pt.check "and keeps its sharing and cycles" [true true]
  (let L [1 2]
       V (@v L L 0 <>)
       _ (address-> V 3 V)
       S (isolate.share V)
    [(shen-jit.same? (<-address S 1) (<-address S 2)) (shen-jit.same? S (<-address S 3))]))

(pt.check "what is already shared or has no copy comes back as it is" [true true 5 a]
  (let S (isolate.share [1 2])
    [(shen-jit.same? S (isolate.share S)) (shen-jit.same? S (hd (isolate.share [S]))) (isolate.share 5)
     (isolate.share a)]))

(pt.check "a shared vector reads as any" [true true 3 x true]
  (let S (isolate.share (@v x y z <>))
    [(absvector? S) (vector? S) (limit S) (<-address S 1) (= (map (/. I (<-address S I)) [1 2 3]) [x y z])]))

(pt.check "stores into a shared vector raise"
  ["address->: <1 2> is shared, and cannot change" "address->: <1 2> is shared, and cannot change"
   "shen-jit.newpv: <1 2> is not a vector of bindings"]
  (let S (isolate.share (@v 1 2 <>))
    [(pt.message (freeze (vector-> S 1 3))) (pt.message (freeze (address-> S 1 3)))
     (pt.message (freeze (shen-jit.newpv S 0)))]))

(pt.check "a shared dictionary reads, and cannot change" [1 "is shared, and cannot change" "is shared, and cannot change"]
  (let D (shen.dict 8)
       _ (shen.dict-> D a 1)
       S (isolate.share D)
    [(shen.<-dict S a) (pt.suffix (pt.message (freeze (shen.dict-> S b 2))) 28)
     (pt.suffix (pt.message (freeze (shen.dict-rm S a))) 28)]))

(pt.check "a shared byte buffer reads, in a loop too, and refuses stores" [104 532 532 true true true]
  (let B (shen-jit.string->bytes "hello")
       S (isolate.share B)
    [(shen-jit.u8 S 0) (pt.sum-bytes S 0 5 0) (pt.sum-bytes B 0 5 0) (= S B)
     (not (= (pt.message (freeze (shen-jit.u8! S 0 1))) none))
     (not (= (pt.message (freeze (pt.fill-bytes S 0 5))) none))]))

(pt.check "and copying into one raises" true
  (not (= (pt.message (freeze (shen-jit.copy-bytes (isolate.share (shen-jit.bytes 4)) 0 (shen-jit.bytes 4) 0 4)))
          none)))

(pt.check "a shared record matches, reads, and refuses its setter" [true 1 2 true]
  (let R (isolate.share (pt-point.make 1 2))
    [(pt-point? R) (pt-point.x R) (pt-point.y R) (not (= (pt.message (freeze (pt-point.y-> R 3))) none))]))

(pt.check "a shared value crosses to an isolate by pointer" [true y 9]
  (let S (isolate.share (@v x y (pt-point.make 8 9) <>))
       Got (pt.ask pt.shared-in S)
    [(shen-jit.same? S (hd Got)) (hd (tl Got)) (pt.third Got)]))

(pt.check "an isolate shares, and the builder reads it by pointer" [true [1 "two" 3.0]]
  (let S (pt.ask pt.share-here [1 "two" 3.0])
    [(shen-jit.same? S (isolate.share S)) S]))

(pt.check "what cannot be sent cannot be shared"
  ["#<procedure> cannot be sent: only the program's functions can" "can move only at spawn, through channel.give"]
  [(pt.message (freeze (isolate.share [(/. X X)])))
   (pt.suffix (pt.message (freeze (isolate.share (channel.new 1)))) 44)])

\\ A monitor is closed once its one message is queued: a receive after that raises rather than
\\ waits, and stop-each passes over a monitor already read. An isolate prints what the kernel's
\\ printers print, whose lambda forms it has not got.
(define pt.id
  X -> X)

(define pt.printed
  [_ Out] -> (channel.send Out [(make-string "~S" (@p 1 2)) (make-string "~S" (shen.dict 2))]))

(pt.check "a monitor's second receive raises rather than waits" "channel closed"
  (let M (isolate.monitor (isolate.spawn pt.id 1))
       _ (channel.receive M)
    (pt.message (freeze (channel.receive M)))))

(pt.check "stop-each passes over a monitor already read" true
  (let Started (isolate.spawn-each pt.id [1 2 3])
       _ (channel.receive (tl (hd Started)))
    (isolate.stop-each Started)))

(pt.check "an isolate prints tuples and dictionaries" ["(@p 1 2)" "(dict ...)"] (pt.ask pt.printed []))

\\ What an isolate registers with shen-jit.at-end runs once as it ends. A shared exception formats
\\ alike each time, keeping nothing of a heap.
(define pt.tell-end
  -> (channel.send (value pt.out) ended-once))

(define pt.register-end
  [_ Out] -> (do (set pt.out Out) (shen-jit.at-end pt.tell-end) done))

(pt.check "an at-end function runs once" [ended-once [timeout]]
  (let R (channel.new 4)
       M (isolate.monitor (isolate.spawn pt.register-end [[] (channel.sender R)]))
       _ (channel.receive M)
       X (if (= (channel.wait-any [R] 0) [timeout]) none (channel.receive R))
    [X (channel.wait-any [R] 0)]))

(pt.check "a shared exception formats alike each time" ["three: 3" "three: 3"]
  (let E (isolate.share (trap-error (error "three: ~A" 3) (/. X X)))
       A (error-to-string E)
       _ (shen-jit.collect)
    [A (error-to-string E)]))

\\ ---------------------------------------------------------------------------------------------
\\ Many at once, and many in turn.

(pt.check "eight at once" [36 36 36 36 36 36 36 36]
  (let R (channel.new 8)
       S (channel.sender R)
       _ (map (/. I (isolate.spawn pt.sum [[1 2 3 4 5 6 7 8] S])) [1 2 3 4 5 6 7 8])
    (pt.collect R 8)))

(pt.check "two hundred in turn" true (pt.in-turn 200))

(output "~A passed, ~A failed (isolates)~%" (value pt.passed) (value pt.failed))
