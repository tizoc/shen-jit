\\ A map over isolates (docs/parallel.md). No other library is needed.

(shen.x.namespace parallel
  (use shen-jit)
  (shadow map)
  (export map)

\\ (parallel.map N F Xs): F applied to each element of Xs, in order, by at most N isolates, each
\\ taking a run of Xs. F is a function's name, or [F | Args], called with Args and then the element:
\\ an isolate inherits nothing, and closures do not cross. Each run and its results are copied; a
\\ value shared once (isolate.share) crosses by pointer. It returns once every isolate has ended,
\\ so the program can change again, and raises the first error, in the order of Xs, that F raised.
\\ If its wait raises, it kills its isolates first; after a Ctrl-C, the REPL kills them.
(define map
  N F Xs -> (let _ (check N F Xs)
              (if (empty? Xs)
                  []
                  (let Launched (launch F (split Xs (sizes (length Xs) (smaller N (length Xs)))))
                    (shen-jit.on-error (freeze (gather Launched [] [])) (freeze (stop Launched)))))))

(define check
  N F Xs ->
    (do (if (and (integer? N) (> N 0)) true (error "parallel.map: ~S is not a number of isolates" N))
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

\\ An isolate for each run, with a channel for its reply and a monitor for its end: [Reply Down P].
\\ If a spawn fails, spawn-each stops those it started, and the replies' channels are closed here.
(define launch
  F Runs -> (let Replies (replies Runs)
              (launched Replies (shen-jit.on-error (freeze (isolate.spawn-each map-run (run-args F Runs Replies)))
                                                   (freeze (close-replies Replies))))))

(define close-replies
  Replies -> (map (/. R (trap-error (channel.close R) (/. E skip))) Replies))

(define replies
  [] -> []
  [_ | Runs] -> [(channel.new 1) | (replies Runs)])

(define run-args
  _ [] [] -> []
  F [Run | Runs] [Reply | Replies] -> [[F Run (channel.sender Reply)] | (run-args F Runs Replies)])

(define launched
  [] [] -> []
  [Reply | Replies] [[P | Down] | Started] -> [[Reply Down P] | (launched Replies Started)])

\\ Kills each isolate, waits for it to end, and closes its channels, some of which a wait may have
\\ closed already.
(define stop
  Launched -> (do (isolate.stop-each (map-pairs Launched))
                  (close-all Launched)))

(define map-pairs
  [] -> []
  [[_ Down P] | Launched] -> [[P | Down] | (map-pairs Launched)])

(define close-all
  [] -> true
  [[Reply Down _] | Launched] -> (do (trap-error (channel.close Reply) (/. E skip))
                                    (trap-error (channel.close Down) (/. E skip))
                                    (close-all Launched)))

(define map-run
  [F Run Out] ->
    (let Result (trap-error [done (each F Run [])] (/. E [failed (error-to-string E)]))
      (trap-error (channel.send Out Result)
        (/. E (channel.send Out [failed (error-to-string E)])))))

(define each
  _ [] Ys -> (reverse Ys)
  F [X | Xs] Ys -> (each F Xs [(apply-to F X) | Ys]))

(define apply-to
  [F | Args] X -> (shen-jit.apply F (append Args [X]))
  F X -> (shen-jit.apply F [X]))

\\ The replies in order, each once its isolate has ended. A reply is sent before its isolate ends,
\\ and its channel is listed first, so an isolate that ends without one has failed.
(define gather
  [] Results [] -> (concatenate (reverse Results) [])
  [] _ [Error | _] -> (error "parallel.map: ~A" Error)
  [[Reply Down _] | Rest] Results Errors ->
    (let Got (channel.receive-any [Reply Down])
         End (if (= (hd Got) Reply) (channel.receive Down) (hd (tl Got)))
         _ (channel.close Reply)
         _ (channel.close Down)
      (gather-reply Rest Results Errors (if (= (hd Got) Reply) (hd (tl Got)) [failed (ended End)]))))

(define gather-reply
  Rest Results Errors [done Ys] -> (gather Rest [Ys | Results] Errors)
  Rest Results Errors [failed Message] -> (gather Rest Results (append Errors [Message])))

(define ended
  [_ _ Reason] -> (make-string "an isolate ended without a reply: ~A" Reason))

(define concatenate
  [] Ys -> Ys
  [Xs | Xss] Ys -> (append Xs (concatenate Xss Ys)))

)
