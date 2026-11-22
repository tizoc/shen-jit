\\ A map over isolates (docs/parallel.md). No other library is needed.

(shen.x.namespace parallel
  (use shen-jit)
  (shadow map)
  (externals [ok])
  (export map)

\\ (parallel.map N F Xs): F applied to each element of Xs, in order, by at most N isolates. Xs is
\\ cut into runs, up to four for each isolate, and an isolate is sent the next run once it replies,
\\ so that one with slow elements holds up only its own. F is a function's name, or [F | Args],
\\ called with Args and then the element: an isolate inherits nothing, and closures do not cross.
\\ Each run and its results are copied; a value shared once (isolate.share) crosses by pointer. It
\\ returns once every isolate has ended, so the program can change again. Once F raises, no further
\\ run starts, and it raises the first error, in the order of Xs, that F raised. If its wait
\\ raises, it kills its isolates first; after a Ctrl-C, the REPL kills them.
(define map
  N F Xs -> (let _ (check N F Xs)
              (if (empty? Xs)
                  []
                  (let K (smaller N (length Xs))
                       Runs (numbered (split Xs (sizes (length Xs) (smaller (* 4 K) (length Xs)))) 0)
                       Back (channel.new K)
                       Works (works K)
                       Senders (senders Works)
                    (shen-jit.on-error
                      (freeze (isolate.spawn-each work (work-args F Works (channel.sender Back))
                                (/. Started (serve Back Started (first-runs Senders Started Runs) (after K Runs)
                                                   none (vector (length Runs))))))
                      (freeze (close-quietly [Back | (append Works Senders)])))))))

(define check
  N F Xs ->
    (do (if (and (shen-jit.fixnum? N) (> N 0)) true (error "parallel.map: ~S is not a number of isolates" N))
        (if (list? Xs) true (error "parallel.map: ~S is not a list" Xs))
        (function-check F)))

(define function-check
  F -> (arity-check F 0) where (symbol? F)
  [F | Args] -> (arity-check F (length Args)) where (and (symbol? F) (list? Args))
  F -> (error "parallel.map: ~S is not a function's name, or a list of one and its first arguments" F))

(define list?
  [] -> true
  [_ | Xs] -> (list? Xs)
  _ -> false)

(define arity-check
  F N -> (let A (arity F)
           (if (or (= A -1) (= A (+ N 1)))
               true
               (error "parallel.map: ~A takes ~A arguments, not ~A and an element" F A N))))

(define smaller
  A B -> (if (< A B) A B))

\\ K runs whose lengths differ by one at most, the longer first.
(define sizes
  L K -> (sizes-from (shen.mod L K) (/ (- L (shen.mod L K)) K) K))

(define sizes-from
  _ _ 0 -> []
  Long Size K -> [(if (> Long 0) (+ Size 1) Size) | (sizes-from (- Long 1) Size (- K 1))])

(define split
  _ [] -> []
  Xs [N | Ns] -> (split-run Xs N [] Ns))

(define split-run
  Xs 0 Run Ns -> [(reverse Run) | (split Xs Ns)]
  [X | Xs] N Run Ns -> (split-run Xs (- N 1) [X | Run] Ns))

\\ A run goes as [I | Elements], I counting from 0 in the order of Xs.
(define numbered
  [] _ -> []
  [Run | Runs] I -> [[I | Run] | (numbered Runs (+ I 1))])

(define after
  0 Xs -> Xs
  N [_ | Xs] -> (after (- N 1) Xs))

\\ Each isolate reads runs on a channel of its own, given to it, and replies on Back. If anything
\\ raises, spawn-each stops the isolates, each killed and waited for, and the channels are closed
\\ here; those given to isolates it started are theirs, and closing one raises, which is dropped.
(define close-quietly
  [] -> true
  [C | Cs] -> (do (trap-error (channel.close C) (/. E skip)) (close-quietly Cs)))

(define works
  0 -> []
  K -> [(channel.new 1) | (works (- K 1))])

(define senders
  [] -> []
  [W | Works] -> [(channel.sender W) | (senders Works)])

(define work-args
  _ [] _ -> []
  F [W | Works] Back -> [[F (channel.give W) Back] | (work-args F Works Back)])

\\ In an isolate: each run it is sent, until its channel ends or a run fails, as no run starts
\\ after a failure; a kill caught as F runs is one.
(define work
  [F Runs Back] -> (let Next (channel.next Runs)
                     (if (and (= (hd Next) ok) (reply F (hd (tl Next)) Back))
                         (work [F Runs Back])
                         done)))

\\ Whether the run's results were sent.
(define reply
  F [I | Run] Back ->
    (let Result (trap-error [done (each F Run [])] (/. E [failed (error-to-string E)]))
      (trap-error (do (channel.send Back [I | Result]) (= (hd Result) done))
        (/. E (do (channel.send Back [I failed (error-to-string E)]) false)))))

(define each
  _ [] Ys -> (reverse Ys)
  F [X | Xs] Ys -> (each F Xs [(apply-to F X) | Ys]))

(define apply-to
  [F | Args] X -> (shen-jit.apply F (append Args [X]))
  F X -> (shen-jit.apply F [X]))

\\ A run for each isolate, which is then busy: [Monitor Sender I], I being the run it has.
(define first-runs
  [] _ _ -> []
  [S | Senders] [[_ | Monitor] | Started] [[I | Run] | Runs]
  -> (do (channel.send S [I | Run]) [[Monitor S I] | (first-runs Senders Started Runs)]))

\\ Replies, each answered by the next run or by the end of that isolate's channel, until no isolate
\\ is busy. A reply is sent before its isolate ends, and Back is listed first, so a busy isolate
\\ that ends without one has failed. Once one has, no further run starts.
(define serve
  Back Started [] _ Failure Results -> (finish Back Started Failure Results)
  Back Started Busy Runs Failure Results
  -> (let Got (channel.receive-any [Back | (monitors Busy)])
       (if (= (hd Got) Back)
           (replied Back Started Busy Runs Failure Results (hd (tl Got)))
           (let Entry (busy 1 (hd Got) Busy)
                _ (channel.close (hd Got))
             (serve Back Started (remove Entry Busy) Runs (earlier Failure (nth 3 Entry) (ended (hd (tl Got))))
                    Results)))))

(define replied
  Back Started Busy Runs Failure Results [I | Result]
  -> (let _ (vector-> Results (+ I 1) Result)
          Failure (if (= (hd Result) failed) (earlier Failure I (hd (tl Result))) Failure)
          Entry (busy 3 I Busy)
          S (nth 2 Entry)
       (if (and (= Failure none) (cons? Runs))
           (do (channel.send S (hd Runs))
               (serve Back Started [[(hd Entry) S (hd (hd Runs))] | (remove Entry Busy)] (tl Runs) Failure Results))
           (do (close-quietly [S])
               (serve Back Started (remove Entry Busy) Runs Failure Results)))))

(define monitors
  [] -> []
  [[Monitor | _] | Busy] -> [Monitor | (monitors Busy)])

\\ The busy isolate whose entry has X at position N.
(define busy
  N X [Entry | Busy] -> (if (= (nth N Entry) X) Entry (busy N X Busy)))

\\ The first failure in the order of Xs: [I Message], or none.
(define earlier
  none I Message -> [I Message]
  [J Then] I Message -> (if (< I J) [I Message] [J Then]))

(define ended
  [_ _ Reason] -> (make-string "an isolate ended without a reply: ~A" Reason))

\\ Once every isolate has ended, the results in order, or the first failure.
(define finish
  Back Started Failure Results
  -> (do (await Started)
         (channel.close Back)
         (if (= Failure none)
             (concatenate Results (limit Results) [])
             (error "parallel.map: ~A" (hd (tl Failure))))))

\\ A monitor whose isolate failed was read and closed already.
(define await
  [] -> true
  [[_ | Monitor] | Started]
  -> (do (trap-error (do (channel.receive Monitor) (channel.close Monitor)) (/. E skip)) (await Started)))

(define concatenate
  _ 0 Ys -> Ys
  Results I Ys -> (concatenate Results (- I 1) (append (hd (tl (<-vector Results I))) Ys)))

)
