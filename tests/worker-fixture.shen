\\ Private fixture image. Requests are one byte; replies are copied byte slices.
(set worker-fixture.stdin (value *stinput*))
(set worker-fixture.stdout (value *stoutput*))
(define worker-fixture.nest
  0 X -> X
  N X -> (worker-fixture.nest (- N 1) [X]))

(define worker-fixture.garbage
  0 -> true
  N -> (let Keep (worker-fixture.nest 320 N)
            _ (shen-jit.collect)
            _ (if (= Keep (worker-fixture.nest 320 N)) true (error "worker equality/GC differs"))
         (worker-fixture.garbage (- N 1))))

(define worker-fixture.slices
  0 _ -> []
  N B -> [[B 0 0] | (worker-fixture.slices (- N 1) B)])

(define worker-fixture.view-sum
  B I End Acc -> Acc where (= I End)
  B I End Acc -> (worker-fixture.view-sum B (+ I 4) End (+ Acc (shen-jit.u32 B I))))

(define worker-fixture.view-store
  B I I -> B
  B I End -> (do (shen-jit.u32! B I 1) (worker-fixture.view-store B (+ I 4) End)))

(define worker-fixture.until-cancelled
  -> (if (shen-jit.worker-cancelled?) [] (worker-fixture.until-cancelled)))

(define worker-fixture.entry
  B -> (let Op (if (= (shen-jit.bytes-length B) 0) 0 (shen-jit.u8 B 0))
         (cases (= Op 1) (do (worker-fixture.garbage 3) [[B 0 (shen-jit.bytes-length B)]])
                (= Op 2) (shen-jit.exit 0)
                (= Op 3) (shen-jit.save-executable "not-a-worker-output" [])
                (= Op 4) (thread (freeze true))
                (= Op 5) (shen-jit.mark-toplevel)
                (= Op 6) (error "injected worker error")
                (= Op 7) [[B 0 10000000]]
                (= Op 8) (let Out (shen-jit.bytes 4)
                               _ (shen-jit.u32! Out 0 (shen-jit.u32 (shen-jit.worker-shared-view) 0))
                            [[Out 0 4]])
                (= Op 9) (do (shen-jit.u32 (shen-jit.worker-shared-view) 1000000) [])
                (= Op 10) (if (= (shen-jit.worker-index) 0) (error "peer failed")
                              (worker-fixture.until-cancelled))
                (= Op 11) (worker-fixture.slices 17 B)
                (= Op 12) [[(absvector 0) 0 0]]
                (= Op 13) [[B -1 1]]
                (= Op 14) []
                (= Op 15) (open "not-a-worker-output" out)
                (= Op 16) (read-byte (value worker-fixture.stdin))
                (= Op 17) (write-byte 65 (value worker-fixture.stdout))
                (= Op 18) (shen-jit.write-bytes B 0 1 (value worker-fixture.stdout))
                (= Op 19) (close (value worker-fixture.stdout))
                (= Op 20) (let View (shen-jit.worker-shared-view)
                                _ (set worker-fixture.view View)
                                _ (shen-jit.collect)
                                N (worker-fixture.view-sum (value worker-fixture.view) 0 4 0)
                                Out (shen-jit.u32! (shen-jit.bytes 4) 0 N)
                             [[Out 0 4]])
                (= Op 21) (let _ (shen-jit.collect)
                                N (worker-fixture.view-sum (value worker-fixture.view) 0 4 0)
                                Out (shen-jit.u32! (shen-jit.bytes 4) 0 N)
                             [[Out 0 4]])
                (= Op 22) (shen-jit.u32! (shen-jit.worker-shared-view) 0 1)
                (= Op 23) (shen-jit.u32 (shen-jit.worker-shared-view) 4)
                (= Op 24) (shen-jit.pointer-address (shen-jit.worker-shared-view))
                (= Op 25) (shen-jit.pointer-sized (shen-jit.worker-shared-view) 100000)
                (= Op 26) (shen-jit.pointer->bytes (shen-jit.worker-shared-view) 0 100000)
                (= Op 27) (let View (shen-jit.worker-shared-view) [[View 0 4]])
                (= Op 28) (worker-fixture.view-store (shen-jit.worker-shared-view) 0 4)
                true [[B 0 (shen-jit.bytes-length B)]])))
