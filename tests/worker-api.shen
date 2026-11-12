\\ Verify the normal image bootstrap before any worker fixture/library loads.
\\ Check their arities too, and currying for primitives taking arguments.
(map (/. Entry
        (let Name (hd Entry) N (hd (tl Entry))
          (if (= (arity Name) N)
              (if (= N 0) true (do (fn Name) true))
              (error "worker bootstrap: ~A must have arity ~A" Name N))))
     [[shen-jit.worker-scope 5]
      [shen-jit.worker-batch 2]
      [shen-jit.worker-index 0]
      [shen-jit.worker-live 0]
      [shen-jit.worker-cancelled? 0]
      [shen-jit.worker-shared-view 0]])
