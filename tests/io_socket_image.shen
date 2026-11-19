(define fixture.frame-tag (:result.ok [(:frame.frame Tag _)]) -> Tag)
(define fixture.frame-payload (:result.ok [(:frame.frame _ V)]) -> V)

\\ Loaded once before saving; callers select save, reload or targeted GC work.
(define io-socket-image.pair
  ->
    (let L (socket.listen "127.0.0.1" 0)
         C (socket.connect "127.0.0.1" (socket.port L))
         S (socket.accept L)
         _ (socket.close L)
      [(io.socket C "image client") (io.socket S "image server")]))

(define io-socket-image.raises?
  F -> (trap-error (do (thaw F) false) (/. X true)))

(define io-socket-image.save
  ->
    (let Pair (trap-error (io-socket-image.pair)
                 (/. X (if (= (error-to-string X) "foreign: this static build cannot load libraries")
                           []
                           (simple-error (error-to-string X)))))
      (if (empty? Pair)
          (do (set io-socket-image.old []) true)
          (let C (hd Pair)
               S (hd (tl Pair))
               W (io.writer C [])
               _ (io.write W (buffer.from-string "old"))
               _ (io.close S)
            (do (set io-socket-image.old [C W]) true)))))

(define io-socket-image.reload
  ->
    (let Saved (value io-socket-image.old)
      (if (empty? Saved)
          (output "socket image unavailable~%")
          (let Pair (io-socket-image.pair)
               C (hd Pair)
               S (hd (tl Pair))
               Old (hd Saved)
               W (hd (tl Saved))
               Dead (and (io-socket-image.raises? (freeze (io.read-some Old (buffer.new 0) [])))
                         (and (io-socket-image.raises? (freeze (io.flush W)))
                              (io-socket-image.raises? (freeze (io.shutdown-write Old)))))
               Closed (io.close Old)
               Memo (io.close Old)
               Written (io.write-all C (buffer.from-string "ok") [])
               V (buffer.new 2)
               Read (io.read-exact S V [])
               _ (io.close C)
               _ (io.close S)
            (if (and Dead (and (= Closed Memo)
                              (and (= Written (:result.ok 2)) (and (= Read (:result.ok (:io.transfer true 2))) (= (buffer.string V) "ok")))))
                (output "socket image ok~%")
                (error "saved socket affected a new connection"))))))

(define io-socket-image.gc
  ->
    (if (empty? (value io-socket-image.old))
        (output "socket gc unavailable~%")
        (let Pair (io-socket-image.pair)
             C (hd Pair)
             S (hd (tl Pair))
             W (io.writer C [[chunk-size 2]])
             F (frame.reader (io.reader S [[chunk-size 1]]) 8)
             _ (io.write W (frame.encode 42 (buffer.from-string "abc") 8))
             Shutdown (io.shutdown-write C)
             Result (frame.next F)
             End (frame.next F)
             _ (io.close C)
             _ (io.close S)
          (if (and (= Shutdown (:result.ok []))
                   (and (= (fixture.frame-tag Result) 42)
                        (and (= (buffer.string (fixture.frame-payload Result)) "abc") (= End (:result.ok [])))))
              (output "socket gc ok~%")
              (error "socket framing failed under GC stress")))))
