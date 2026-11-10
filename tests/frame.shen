\\ Framing over managed/scripted I/O, including every split and every truncation.
(set frame-test.passed 0)
(set frame-test.failed 0)

(define frame-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set frame-test.passed (+ 1 (value frame-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set frame-test.failed (+ 1 (value frame-test.failed)))))))

(define frame-test.raises
  Name F -> (frame-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define frame-test.bytes
  Bytes -> (frame-test.fill (buffer.new (length Bytes)) 0 Bytes))

(define frame-test.fill
  V _ [] -> V
  V At [Byte | Rest] -> (frame-test.fill (buffer.u8! V At Byte) (+ At 1) Rest))

(define frame-test.value
  [frame Tag Payload] -> [Tag (buffer.string Payload)]
  [eof] -> [eof]
  [error E] -> [error (io.error-message E) (io.error-progress E)])

(define frame-test.source
  Wire State Terminal ->
    (io.endpoint "scripted frame" read 32
      (/. B (let At (<-address State 0)
                 Steps (<-address State 2)
                 Step (if (empty? Steps) 32 (hd Steps))
                 N (io.min Step (io.min (shen-jit.bytes-length B) (- (buffer.length Wire) At)))
              (do (address-> State 1 (+ 1 (<-address State 1)))
                  (if (empty? Steps) true (address-> State 2 (tl Steps)))
                  (if (= N 0)
                      Terminal
                      (do (shen-jit.copy-bytes B 0 (buffer.owner Wire) (+ (buffer.offset Wire) At) N)
                          (address-> State 0 (+ At N))
                          [read N])))))
      (function io.no-write)
      (freeze [ok])))

(define frame-test.split
  Wire Split ->
    (let State (io.record [0 0 [Split]])
         E (frame-test.source Wire State [eof])
         F (frame.reader (io.reader E []) 8)
         First (frame-test.value (frame.next F))
         Second (frame-test.value (frame.next F))
         Third (frame.next F)
         _ (io.close E)
      [First Second Third]))

(define frame-test.splits
  _ 0 -> true
  Wire N ->
    (do (frame-test.check "every first-chunk boundary" [[4660 "abc"] [9 "defg"] [eof]]
          (freeze (frame-test.split Wire N)))
        (frame-test.splits Wire (- N 1))))

(set frame-test.first (frame-test.bytes [18 52 0 0 0 3 97 98 99]))
(set frame-test.wire (frame-test.bytes [18 52 0 0 0 3 97 98 99 0 9 0 0 0 4 100 101 102 103]))
(frame-test.splits (value frame-test.wire) 19)

(frame-test.check "encoder matches independent wire bytes" true
  (freeze (buffer.equal? (value frame-test.first) (frame.encode 4660 (buffer.from-string "abc") 3))))
(frame-test.check "encode only the logical range" true
  (freeze (buffer.equal? (value frame-test.first)
                        (frame.encode 4660 (buffer.slice (buffer.from-string "!abc?") 1 3) 3))))
(frame-test.check "zero length and maximum tag" true
  (freeze (buffer.equal? (frame-test.bytes [255 255 0 0 0 0]) (frame.encode 65535 (buffer.new 0) 0))))
(frame-test.raises "negative tag" (freeze (frame.encode -1 (buffer.new 0) 0)))
(frame-test.raises "tag overflow" (freeze (frame.encode 65536 (buffer.new 0) 0)))
(frame-test.raises "boxed real tag" (freeze (frame.encode (+ 0.5 0.5) (buffer.new 0) 0)))
(frame-test.raises "negative limit" (freeze (frame.encode 1 (buffer.new 0) -1)))
(frame-test.raises "wire limit overflow" (freeze (frame.encode 1 (buffer.new 0) 4294967296)))
(frame-test.raises "encode over limit" (freeze (frame.encode 1 (buffer.new 2) 1)))

(define frame-test.truncated
  Wire N ->
    (let E (io.input-buffer (buffer.slice Wire 0 N))
         F (frame.reader (io.reader E [[chunk-size 1]]) 8)
         Result (frame-test.value (frame.next F))
         Again (frame-test.value (frame.next F))
         Position (frame.position F)
         _ (io.close E)
      [Result Again Position]))

(define frame-test.truncations
  _ 0 -> true
  Wire N ->
    (let Expected [error (if (< N 6) "incomplete header" "incomplete payload") N]
      (do (frame-test.check "every incomplete header/payload length" [Expected Expected N]
            (freeze (frame-test.truncated Wire N)))
          (frame-test.truncations Wire (- N 1)))))

(frame-test.truncations (value frame-test.first) 8)
(frame-test.check "empty stream is clean EOF" [[eof] [eof] 0]
  (freeze (frame-test.truncated (value frame-test.first) 0)))

(let State (io.record [0 0 []])
     Wire (frame-test.bytes [0 1 255 255 255 255 99 100])
     E (frame-test.source Wire State [eof])
     R (io.reader E [[chunk-size 1]])
     F (frame.reader R 8)
     Result (frame.next F)
     Calls (<-address State 1)
  (do (frame-test.check "oversized length refused before payload" [error "payload exceeds limit" 6]
        (freeze (frame-test.value Result)))
      (frame-test.check "oversized frame consumed only its header" [6 6]
        (freeze [(frame.position F) (<-address State 0)]))
      (frame-test.check "oversized failure is terminal" Result (freeze (frame.next F)))
      (frame-test.check "terminal failure makes no backend call" Calls (freeze (<-address State 1)))
      (io.close E)))

(let E (io.input-buffer (value frame-test.wire))
     R (io.reader E [])
     F (frame.reader R 8)
     First (frame.next F)
  (do (frame-test.check "first frame leaves next one queued" [9 10]
        (freeze [(frame.position F) (io.available R)]))
      (frame-test.check "second queued frame" [9 "defg"] (freeze (frame-test.value (frame.next F))))
      (io.close E)
      (frame-test.check "payload owns bytes after close" [4660 "abc"] (freeze (frame-test.value First)))
      (frame-test.raises "closed framer refused" (freeze (frame.next F)))))

(let E (io.input-buffer (frame.encode 0 (buffer.new 0) 0))
     F (frame.reader (io.reader E [[chunk-size 1]]) 0)
  (do (frame-test.check "empty frame is not EOF" [0 ""] (freeze (frame-test.value (frame.next F))))
      (frame-test.check "EOF follows empty frame" [eof] (freeze (frame.next F)))
      (io.close E)))

(define frame-test.transport-error
  N ->
    (let Error (io.native-error read posix 5 "source" "transport failed")
         State (io.record [0 0 []])
         E (frame-test.source (buffer.slice (value frame-test.first) 0 N) State [error Error])
         F (frame.reader (io.reader E [[chunk-size 1]]) 8)
         Result (frame.next F)
         Saved (hd (tl Result))
         _ (io.close E)
      [(io.error-domain Saved) (io.error-code Saved) (io.error-progress Saved)]))

(frame-test.check "header transport error preserves native details" [posix 5 2]
  (freeze (frame-test.transport-error 2)))
(frame-test.check "body transport error counts header progress" [posix 5 8]
  (freeze (frame-test.transport-error 8)))

(let E (io.input-buffer (buffer.new 0))
     R (io.reader E [])
  (do (frame-test.raises "invalid reader limit" (freeze (frame.reader R -1)))
      (frame-test.raises "not an I/O reader" (freeze (frame.reader [] 8)))
      (io.close E)))

(frame-test.check "an exception keeps the current frame's progress"
  [true 2 8]
  (freeze
    (let At (io.record [0])
         E (io.endpoint "throwing frame input" read 2
             (/. B (if (< (<-address At 0) 8)
                       (do (shen-jit.u8! B 0 0) (shen-jit.u8! B 1 0) (address-> At 0 (+ 2 (<-address At 0))) [read 2])
                       (error "read interrupted")))
             (function io.no-write)
             (freeze [ok]))
         F (frame.reader (io.reader E []) 8)
         _ (frame.next F)
         Raised (trap-error (do (frame.next F) false) (/. X true))
         Again (frame.next F)
         Position (frame.position F)
         _ (io.close E)
      [Raised (io.error-progress (hd (tl Again))) Position])))

(output "~A passed, ~A failed~%" (value frame-test.passed) (value frame-test.failed))
