\\ Memory that releases itself: lib/handle.shen, over guarded pointers. Run by make test-ffi, from
\\ build/, after lib/ffi.shen, lib/memory.shen and lib/handle.shen.

(set handle-test.*passed* 0)
(set handle-test.*failed* 0)

(define handle-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define handle-test.check
  Name Expected F -> (handle-test.compare Name Expected (handle-test.result F)))

(define handle-test.compare
  _ X X -> (set handle-test.*passed* (+ 1 (value handle-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set handle-test.*failed* (+ 1 (value handle-test.*failed*)))))

(define handle-test.prefix
  0 _ -> ""
  N S -> (cn (pos S 0) (handle-test.prefix (- N 1) (tlstr S))))

(define handle-test.string-length
  "" -> 0
  S -> (+ 1 (handle-test.string-length (tlstr S))))

\\ That it raises, with a message starting so.
(define handle-test.raises
  Name Start F -> (handle-test.compare Name Start
                    (trap-error (do (thaw F) no-error)
                                (/. E (handle-test.prefix (handle-test.string-length Start) (error-to-string E))))))

\\ ---------------------------------------------------------------------------
\\ A static build cannot load libraries, and so has no memory from C.

(if (= (handle-test.result (freeze (memory.alloc 8))) [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

\\ ---------------------------------------------------------------------------
\\ How many have been released, and a handle that counts when it is.

(set handle-test.*released* 0)

(define handle-test.count
  -> (value handle-test.*released*))

(define handle-test.free
  M -> (do (set handle-test.*released* (+ 1 (value handle-test.*released*)))
           (memory.free M)))

(define handle-test.new
  N -> (handle.wrap (memory.alloc N) (/. M (handle-test.free M))))

\\ A frame can hold what the frame before it there left behind, which counts as reached, and a
\\ collection clears only what is above the frames in use. So what is to die is made deep down,
\\ further than any frame that collects will reach.
(define handle-test.deep
  0 F -> (thaw F)
  N F -> (let R (handle-test.deep (- N 1) F)
           (if (= N -1) 0 R)))

(define handle-test.drop
  N -> (handle-test.deep 30 (freeze (let H (handle-test.new N)
                                      (do (shen-jit.u8! H 0 1) 0)))))

(define handle-test.collect
  -> (do (shen-jit.collect) (handle.sweep)))

\\ Under GC stress a collection may have run before this, so it counts what has been released.
(define handle-test.settle
  -> (do (handle-test.collect) (handle-test.collect) (handle-test.count)))

(define handle-test.reset
  -> (do (handle-test.settle) (set handle-test.*released* 0)))

\\ ---------------------------------------------------------------------------
\\ What a handle is.

(set h (handle-test.new 16))

(handle-test.check "a handle is a pointer" true (freeze (shen-jit.pointer? (value h))))
(handle-test.check "with the length" 16 (freeze (shen-jit.bytes-length (value h))))
(handle-test.check "all zero" 0 (freeze (shen-jit.u32 (value h) 12)))
(handle-test.check "it reads what it writes" 1.5 (freeze (shen-jit.f64 (shen-jit.f64! (value h) 8 1.5) 8)))
(handle-test.raises "and is bounded" "bytes: 16" (freeze (shen-jit.u8 (value h) 16)))

(set m (memory.alloc 8))
(shen-jit.u8! (value m) 3 77)
(set on-m (handle.wrap (value m) (/. M (memory.free M))))
(handle-test.check "the same memory" 77 (freeze (shen-jit.u8 (value on-m) 3)))
(handle-test.check "at the same address" true
                   (freeze (= (shen-jit.pointer-address (value on-m)) (shen-jit.pointer-address (value m)))))
(handle-test.raises "only a live pointer" "shen-jit.pointer-guard: 1" (freeze (handle.wrap 1 (/. M M))))

\\ ---------------------------------------------------------------------------
\\ When it dies.

(handle-test.reset)

(handle-test.check "one still reached is kept" 0 (freeze (handle-test.settle)))
(handle-test.check "and still reads" 1.5 (freeze (shen-jit.f64 (value h) 8)))

(handle-test.drop 8)
(handle-test.check "one let go is released" 1 (freeze (handle-test.settle)))
(handle-test.check "once" 1 (freeze (handle-test.settle)))

\\ Under GC stress, making the second may have released the first.
(handle-test.check "sweep gives how many"
                   true
                   (freeze (do (handle-test.reset)
                               (handle-test.drop 8)
                               (handle-test.drop 8)
                               (shen-jit.collect)
                               (let Before (handle-test.count)
                                    Swept (handle.sweep)
                                 (and (= (handle-test.count) 2) (= Swept (- 2 Before)))))))
(handle-test.check "and then none" 0 (freeze (handle.sweep)))

\\ Everything a collection does to the handle's memory: nothing.
(define handle-test.churn
  0 Acc -> Acc
  N Acc -> (handle-test.churn (- N 1) [N | (if (> N 20) [] Acc)]))

(shen-jit.u32! (value h) 0 123456)
(handle-test.churn 100000 [])
(handle-test.check "it survives collections" 123456 (freeze (shen-jit.u32 (value h) 0)))

\\ ---------------------------------------------------------------------------
\\ A copy keeps it alive.

(handle-test.reset)

(set view (handle-test.deep 30 (freeze (let H (handle-test.new 16) (shen-jit.pointer-sized (shen-jit.u8! H 4 9) 8)))))
(handle-test.check "a copy keeps it" 0 (freeze (handle-test.settle)))
(handle-test.check "and reads it" 9 (freeze (shen-jit.u8 (value view) 4)))
(handle-test.check "a copy's owner is what it came from" true
                   (freeze (shen-jit.same? (value h) (shen-jit.pointer-owner (shen-jit.pointer-sized (value h) 4)))))
(set view [])
(handle-test.check "and is then released" 1 (freeze (handle-test.settle)))

\\ ---------------------------------------------------------------------------
\\ Closing it first.

(handle-test.reset)

(set closing (handle-test.deep 30 (freeze (handle-test.new 8))))
(handle-test.check "close" true (freeze (handle.close (value closing))))
(handle-test.check "releases" 1 (freeze (handle-test.count)))
(handle-test.raises "using it raises" "bytes: 0" (freeze (shen-jit.u8 (value closing) 0)))
(handle-test.check "closing it again does nothing" false (freeze (handle.close (value closing))))
(set closing [])
(handle-test.check "nor does sweep count it when it dies" 0 (freeze (do (shen-jit.collect) (handle.sweep))))
(handle-test.check "nor is it released again" 1 (freeze (handle-test.settle)))
(handle-test.raises "not a handle" "handle.close: " (freeze (handle.close (shen-jit.pointer-sized (value h) 4))))
(handle-test.raises "not a pointer" "shen-jit.pointer-owner: 1" (freeze (handle.close 1)))

(set failing (handle.wrap (memory.alloc 8) (/. M (error "from release"))))
(handle-test.raises "close raises what release does" "from release" (freeze (handle.close (value failing))))
(set failing [])

\\ ---------------------------------------------------------------------------
\\ When it does not go well.

(handle-test.reset)

(define handle-test.drop-failing
  -> (handle-test.deep 30 (freeze (let H (handle.wrap (memory.alloc 8) (/. M (error "from release")))
                                    0))))

(handle-test.check "an error is dropped, and the others run"
                   2
                   (freeze (do (handle-test.drop 8)
                               (handle-test.drop-failing)
                               (handle-test.drop 8)
                               (handle-test.settle))))

\\ What releases one may use another, which then lasts until it has run.
(handle-test.reset)

(set inner-read 0)

(define handle-test.drop-chain
  -> (handle-test.deep 30 (freeze (let Inner (shen-jit.u8! (handle-test.new 8) 0 42)
                                       Outer (handle.wrap (memory.alloc 8)
                                                          (/. M (do (set inner-read (shen-jit.u8 Inner 0))
                                                                    (memory.free M))))
                                    0))))

(handle-test.drop-chain)
(handle-test.check "the one using the other goes first" 42
                   (freeze (do (handle-test.collect) (value inner-read))))
(handle-test.check "and then the other" 1 (freeze (handle-test.settle)))

\\ ---------------------------------------------------------------------------
\\ Memory counts towards a collection, with none asked for here: this holds 400 MB in all, and
\\ would not fit in the limit without it.

(handle-test.reset)
(set held (value handle.*held*))

(define handle-test.spend
  0 Most -> Most
  N Most -> (do (handle-test.drop 1048576)
                (handle-test.spend (- N 1) (if (> (value handle.*held*) Most) (value handle.*held*) Most))))

(set most (handle-test.spend 400 0))
(handle-test.check "they are released with no collection asked for" true (freeze (> (handle-test.count) 300)))
(handle-test.check "and what is held stays near the limit" true (freeze (< (value most) (+ (value handle.*limit*) 2097152))))
(handle-test.settle)
(handle-test.check "and all of it comes back" (value held) (freeze (value handle.*held*)))

(handle-test.reset)

(define handle-test.many
  0 -> done
  N -> (do (handle-test.drop 8) (handle-test.many (- N 1))))

(handle-test.many 2000)
(handle-test.check "and many small ones" 2000 (freeze (handle-test.settle)))

\\ ---------------------------------------------------------------------------
\\ The rest of a pointer's life.

(handle-test.check "a bare pointer has no owner" [] (freeze (shen-jit.pointer-owner (shen-jit.bytes->pointer (shen-jit.string->bytes "12345678") 0 thing))))

(handle.close (value h))
(handle.close (value on-m))

\\ An isolate releases what its handles still hold as it ends, whether its function returns or a kill
\\ ends it, so that a server's connections leak nothing.
(define handle-test.hold
  [Out Wait] -> (let H (handle.wrap (memory.alloc 64) (/. M (do (memory.free M) (channel.send Out released))))
                  (if Wait (channel.receive (channel.new 1)) (shen-jit.u8! H 0 1))))

(define handle-test.released
  Wait -> (let R (channel.new 2)
               I (isolate.spawn handle-test.hold [(channel.sender R) Wait])
               M (isolate.monitor I)
               _ (if Wait (do (channel.wait-any [R] 200) (isolate.kill I)) skip)
               Down (channel.receive M)
            [(hd (tl (tl Down))) (if (= (channel.wait-any [R] 5000) [timeout]) unreleased (channel.receive R))]))

\\ A release that uses another handle runs before that one's, as a collection orders them: the
\\ outer one, made last, holds the inner one in its release.
(define handle-test.nested
  [Out _] -> (let Inner (handle.wrap (memory.alloc 8) (/. M (do (memory.free M) (channel.send Out inner))))
                  Outer (handle.wrap (memory.alloc 8) (/. M (do (shen-jit.u8 Inner 0) (memory.free M) (channel.send Out outer))))
               (shen-jit.u8! Outer 0 1)))

(define handle-test.order
  -> (let R (channel.new 2)
          M (isolate.monitor (isolate.spawn handle-test.nested [(channel.sender R) []]))
          _ (channel.receive M)
          A (if (= (channel.wait-any [R] 5000) [timeout]) none (channel.receive R))
          B (if (= (channel.wait-any [R] 5000) [timeout]) none (channel.receive R))
       [A B]))

(handle-test.check "an isolate that returns releases its handles" [normal released]
  (freeze (handle-test.released false)))
(handle-test.check "and one that is killed" [killed released] (freeze (handle-test.released true)))
(handle-test.check "a release that uses another handle runs first" [outer inner] (freeze (handle-test.order)))

\\ Handles a global still holds as the isolate ends are left, as a program's are when it ends, so
\\ that no release runs out of order or without the globals it reads; what it registered with
\\ shen-jit.at-end runs once.
(define handle-test.boxed
  [Out _] -> (let Box (absvector 1)
                  Older (handle.wrap (memory.alloc 8)
                          (/. M (do (shen-jit.u8 (<-address Box 0) 0) (memory.free M) (channel.send Out older))))
                  Newer (handle.wrap (memory.alloc 8) (/. M (do (memory.free M) (channel.send Out newer))))
                  _ (address-> Box 0 Newer)
                  _ (set handle-test.kept [Older Newer])
                  _ (set handle-test.out Out)
               (shen-jit.at-end handle-test.ended)))

(define handle-test.ended
  -> (channel.send (value handle-test.out) ended))

(define handle-test.boxed-order
  -> (let R (channel.new 4)
          M (isolate.monitor (isolate.spawn handle-test.boxed [(channel.sender R) []]))
          _ (channel.receive M)
       (handle-test.drain R)))

(define handle-test.drain
  R -> (if (= (channel.wait-any [R] 0) [timeout]) [] [(channel.receive R) | (handle-test.drain R)]))

(handle-test.check "handles a global holds are left, and the at-end function runs once" [ended]
  (freeze (handle-test.boxed-order)))

\\ A handle the isolate's last call to C took, which an argument slot held, is released too.
(define handle-test.last-call
  [Out _] -> (let H (handle.wrap (memory.alloc 64) (/. M (do (memory.free M) (channel.send Out released))))
               (shen-jit.pointer! H 0 H)))

\\ So too when the outer release passes the inner handle to C, or catches an error that holds it:
\\ neither keeps it from the next round.
(define handle-test.passing
  [Out How] -> (let Inner (handle.wrap (memory.alloc 8) (/. M (do (memory.free M) (channel.send Out inner))))
                    Outer (handle.wrap (memory.alloc 8)
                            (/. M (do (memory.free M) (channel.send Out outer) (handle-test.use How Inner))))
                 (shen-jit.u8! Outer 0 1)))

(define handle-test.use
  c Inner -> (shen-jit.pointer! Inner 0 Inner)
  caught Inner -> (trap-error (cn Inner "x") (/. E skip)))

(define handle-test.released-by
  How -> (let R (channel.new 2)
              M (isolate.monitor (isolate.spawn handle-test.passing [(channel.sender R) How]))
              _ (channel.receive M)
           (handle-test.drain R)))

(handle-test.check "an inner handle passed to C in a release is released after" [outer inner]
  (freeze (handle-test.released-by c)))
(handle-test.check "and one held by an error a release caught" [outer inner]
  (freeze (handle-test.released-by caught)))

(handle-test.check "a handle its last call to C took is released" released
  (freeze (let R (channel.new 2)
               M (isolate.monitor (isolate.spawn handle-test.last-call [(channel.sender R) []]))
               _ (channel.receive M)
            (if (= (channel.wait-any [R] 5000) [timeout]) unreleased (channel.receive R)))))

(output "~A passed, ~A failed~%" (value handle-test.*passed*) (value handle-test.*failed*))
