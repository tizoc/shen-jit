\\ Isolates (docs/design.md, "The builder and isolates"): spawning, what crosses and how,
\\ channels, monitors, kill, and the builder defining while isolates run. The builder runs this
\\ file; every check ends in it, so an isolate that never answers hangs the suite rather than
\\ passing it.

(set pt.passed 0)
(set pt.failed 0)

(define pt.check
  Name Expected Got -> (if (= Expected Got)
                           (set pt.passed (+ 1 (value pt.passed)))
                           (do (set pt.failed (+ 1 (value pt.failed)))
                               (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Got))))

(define pt.message
  F -> (trap-error (do (thaw F) none) (/. E (error-to-string E))))

\\ Spawns F with [Argument Replies], and gives the first reply.
(define pt.ask
  F Argument -> (let R (shen-jit.channel 1)
                     _ (shen-jit.spawn F [Argument (shen-jit.sender R)])
                  (shen-jit.receive R)))

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

\\ ---------------------------------------------------------------------------------------------
\\ What crosses: copied, with sharing and cycles kept; symbols by name; the program's functions by
\\ pointer.

(pt.check "a value goes there and back" [a "text" 1.5 -7 [nested (@p 1 2)] true []]
  (pt.ask pt.reply [a "text" 1.5 -7 [nested (@p 1 2)] true []]))

(define pt.shared
  [X Out] -> (shen-jit.send Out [(shen-jit.same? (hd X) (hd (tl X))) X]))

(pt.check "sharing is kept" [true [[1 2] [1 2]]] (let L [1 2] (pt.ask pt.shared [L L])))

(define pt.cycle
  [V Out] -> (shen-jit.send Out (shen-jit.same? V (<-address V 1))))

(pt.check "a cycle is kept" true (let V (absvector 2) (do (address-> V 0 cycle) (address-> V 1 V) (pt.ask pt.cycle V))))

(pt.check "a vector is copied" [true false] (let V (@v 1 2 3 <>) W (pt.ask pt.reply V) [(= V W) (shen-jit.same? V W)]))

(define pt.gensym
  [S Out] -> (shen-jit.send Out [S (= S (intern (str S)))]))

(pt.check "an own symbol crosses by name" true
  (let S (gensym pt-sym) Got (pt.ask pt.gensym S) (and (= (hd Got) S) (hd (tl Got)))))

(define pt.twice
  X -> (* 2 X))

(define pt.call
  [F Out] -> (shen-jit.send Out [((fn F) 21) (map (fn F) [1 2]) (map (function pt.twice) [3])]))

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

(set *pt.global* builder)
(put pt.twice pt.note builder)

(define pt.start
  [_ Out] -> (shen-jit.send Out [(trap-error (value *pt.global*) (/. E unbound))
                                 (do (set *pt.global* mine) (value *pt.global*))
                                 (trap-error (get pt.twice pt.note) (/. E none))
                                 (value *hush*)
                                 (string? (value *version*))
                                 (trap-error (eval [+ 1 2]) (/. E (error-to-string E)))]))

(pt.check "an isolate has its own globals and properties"
  [unbound mine none false true "eval: only the builder can evaluate or define code"]
  (pt.ask pt.start []))

(pt.check "the builder's global is its own" builder (value *pt.global*))

(defprolog pt.member
  X [X | _] <--;
  X [_ | Y] <-- (pt.member X Y);)

(define pt.prolog
  [_ Out] -> (shen-jit.send Out [(prolog? (pt.member X [a b]) (return X)) (prolog? (pt.member c [a b]))]))

(pt.check "Prolog runs in an isolate" [a false] (pt.ask pt.prolog []))

\\ ---------------------------------------------------------------------------------------------
\\ Channels.

(define pt.collect
  _ 0 -> []
  R N -> [(shen-jit.receive R) | (pt.collect R (- N 1))])

(define pt.send-all
  [Xs Out] -> (do (map (/. X (shen-jit.send Out X)) Xs) (shen-jit.close Out)))

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

(define pt.echo
  Requests -> (let M (shen-jit.receive Requests)
                (if (shen-jit.end? M)
                    done
                    (do (shen-jit.send (hd M) (tl M)) (pt.echo Requests)))))

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

\\ ---------------------------------------------------------------------------------------------
\\ Monitors and kill.

(define pt.fail
  X -> (simple-error (cn "failing with " (str X))))

(define pt.down
  F X -> (let P (shen-jit.spawn F X) M (shen-jit.monitor P) Down (shen-jit.receive M)
           [(hd Down) (= (hd (tl Down)) P) (pt.third Down)]))

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

(define pt.spin
  N -> (pt.spin (+ N 1)))

(define pt.spin-catching
  Out -> (trap-error (do (shen-jit.send Out ready) (pt.spin 0))
                     (/. E (do (shen-jit.send Out (error-to-string E)) cleaned))))

(pt.check "kill raises an error that handlers see" ["killed" normal]
  (let R (shen-jit.channel 1)
       P (shen-jit.spawn pt.spin-catching (shen-jit.sender R))
       M (shen-jit.monitor P)
       _ (shen-jit.receive R)
       _ (shen-jit.kill P)
       Got (shen-jit.receive R)
    [Got (pt.third (shen-jit.receive M))]))

(define pt.wait
  R -> (shen-jit.receive R))

(pt.check "kill wakes a parked receiver" killed
  (let P (shen-jit.spawn pt.wait (shen-jit.give (shen-jit.channel 1)))
       M (shen-jit.monitor P)
       _ (shen-jit.kill P)
    (pt.third (shen-jit.receive M))))

(define pt.save
  [_ Out] -> (shen-jit.send Out (pt.message (freeze (shen-jit.save-executable "pt-never" [])))))

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
\\ The builder defines while isolates run: they stop meanwhile, see the new code, and replace
\\ their own symbols of names published since.

(define pt.call-later
  [Go Out] -> (let _ (shen-jit.receive Go) (shen-jit.send Out (pt.later 20))))

(pt.check "a function defined after spawn" [later 20]
  (let Go (shen-jit.channel 1)
       Out (shen-jit.channel 1)
       _ (shen-jit.spawn pt.call-later [(shen-jit.give Go) (shen-jit.sender Out)])
       _ (eval [define pt.later (intern "X") -> [cons later [cons (intern "X") []]]])
       _ (shen-jit.send (shen-jit.sender Go) go)
    (shen-jit.receive Out)))

(define pt.holds-own
  [Go Out] -> (let Mine (intern "pt-own-symbol")
                   _ (shen-jit.receive Go)
                (shen-jit.send Out [(= Mine (pt.fresh)) (= Mine (intern "pt-own-symbol"))])))

(pt.check "an own symbol is replaced once its name is published" [true true]
  (let Go (shen-jit.channel 1)
       Out (shen-jit.channel 1)
       _ (shen-jit.spawn pt.holds-own [(shen-jit.give Go) (shen-jit.sender Out)])
       _ (eval [define pt.fresh -> pt-own-symbol])
       _ (shen-jit.send (shen-jit.sender Go) go)
    (shen-jit.receive Out)))

(define pt.busy
  [N Out] -> (shen-jit.send Out (pt.count N 0)))

(define pt.count
  0 Acc -> Acc
  N Acc -> (pt.count (- N 1) (+ Acc 1)))

(define pt.define-many
  0 -> done
  K -> (do (eval [define (concat pt.def- K) -> K]) (pt.define-many (- K 1))))

(pt.check "definitions beside busy isolates" [[3000000 3000000 3000000] 7]
  (let R (shen-jit.channel 3)
       S (shen-jit.sender R)
       _ (map (/. I (shen-jit.spawn pt.busy [3000000 S])) [1 2 3])
       _ (pt.define-many 50)
    [(pt.collect R 3) (pt.def-7)]))

\\ ---------------------------------------------------------------------------------------------
\\ Many at once, and many in turn.

(define pt.sum
  [L Out] -> (shen-jit.send Out (sum L)))

(pt.check "eight at once" [36 36 36 36 36 36 36 36]
  (let R (shen-jit.channel 8)
       S (shen-jit.sender R)
       _ (map (/. I (shen-jit.spawn pt.sum [[1 2 3 4 5 6 7 8] S])) [1 2 3 4 5 6 7 8])
    (pt.collect R 8)))

(define pt.in-turn
  0 -> true
  K -> (and (= (pt.ask pt.reply K) K) (pt.in-turn (- K 1))))

(pt.check "two hundred in turn" true (pt.in-turn 200))

(output "~A passed, ~A failed (isolates)~%" (value pt.passed) (value pt.failed))
