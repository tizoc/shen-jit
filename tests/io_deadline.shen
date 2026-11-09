\\ Native clock and total socket budgets. No external network service is needed.
(set timed-test.passed 0)
(set timed-test.failed 0)

(define timed-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set timed-test.passed (+ 1 (value timed-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set timed-test.failed (+ 1 (value timed-test.failed)))))))

(define timed-test.raises
  Name F -> (timed-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define timed-test.pair
  ->
    (let L (socket.listen "127.0.0.1" 0)
         C (socket.connect "127.0.0.1" (socket.port L))
         S (socket.accept L)
         _ (socket.close L)
      [(io.socket C "timed client") (io.socket S "timed server")]))

(define timed-test.error
  [error E] -> E
  [error E _] -> E)

(define timed-test.progress
  [error E N] -> [(io.error-domain E) N (io.error-progress E)])

(define timed-test.advancing
  ->
    (let Time (io.record [-1])
      (deadline.after (freeze (let N (+ 1 (<-address Time 0)) _ (address-> Time 0 N) N)) 5)))

\\ Waits, on the real clock, until N bytes can be read from E at once, peeking with MSG_PEEK (2 on
\\ every system). On macOS loopback data can arrive a moment after the peer's send returns, and a
\\ wait then would spend ticks of a clock that counts its calls.
(define timed-test.buffered
  E N -> (timed-test.buffered-by (io.socket-id (io.endpoint.guard E)) N (+ (clock.monotonic) 2000)))

(define timed-test.buffered-by
  S N End -> (cond ((>= (socket.c-recv S (shen-jit.bytes N) N 2) N) true)
                   ((> (clock.monotonic) End) (error "timed test: input did not arrive"))
                   (true (do (socket.poll S (socket.readable-event) 10)
                             (timed-test.buffered-by S N End)))))

(if (trap-error (do (clock.monotonic) false)
                (/. X (= (error-to-string X) "foreign: this static build cannot load libraries")))
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(timed-test.check "native clock is nondecreasing" true
  (freeze (let A (clock.monotonic) B (clock.monotonic) (and (>= A 0) (>= B A)))))

(let Pair (timed-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     R (io.reader C [])
     _ (io.write-all S (buffer.from-string "a") [])
     _ (io.peek R 1)
     _ (io.socket-deadline C (clock.deadline 40))
     Before (clock.monotonic)
     Result (io.reader-exact R (buffer.new 5))
     Elapsed (- (clock.monotonic) Before)
  (do (timed-test.check "partial read timeout reports total" [timeout 1 1]
        (freeze (timed-test.progress Result)))
      (timed-test.check "real wait is bounded" true (freeze (< Elapsed 3000)))
      (io.socket-deadline C (clock.deadline 500))
      (io.write-all S (buffer.from-string "bcde") [])
      (let V (buffer.new 4)
        (do (timed-test.check "reader retries after timeout" [ok 4] (freeze (io.reader-exact R V)))
            (timed-test.check "retry delivers only the suffix" "bcde" (freeze (buffer.string V)))))
      (io.close C)
      (io.close S)))

(let Pair (timed-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     _ (io.endpoint.capacity-> C 1)
     _ (io.write-all S (buffer.from-string "abcdef") [])
     _ (timed-test.buffered C 6)
     _ (io.socket-deadline C (timed-test.advancing))
     V (buffer.new 6)
     Result (io.read-exact C V [])
  (do (timed-test.check "read budget spans successful short reads" [timeout 4 4]
        (freeze (timed-test.progress Result)))
      (timed-test.check "read keeps acknowledged prefix" "abcd"
        (freeze (buffer.string (buffer.slice V 0 4))))
      (io.socket-unlimited C)
      (timed-test.check "direct read resumes from known progress" [ok 2]
        (freeze (io.read-exact C (buffer.slice V 4 2) [])))
      (timed-test.check "whole resumed input" "abcdef" (freeze (buffer.string V)))
      (io.close C)
      (io.close S)))

(let Pair (timed-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     _ (io.endpoint.capacity-> C 1)
     _ (io.socket-deadline C (timed-test.advancing))
     Source (buffer.from-string "abcdef")
     Result (io.write-all C Source [])
     V (buffer.new 6)
     _ (io.read-exact S (buffer.slice V 0 4) [])
  (do (timed-test.check "write budget spans successful short writes" [timeout 4 4]
        (freeze (timed-test.progress Result)))
      (io.socket-unlimited C)
      (timed-test.check "write resumes without replay" [ok 2]
        (freeze (io.write-all C (buffer.slice Source 4 2) [])))
      (io.read-exact S (buffer.slice V 4 2) [])
      (timed-test.check "wire output appears exactly once" "abcdef" (freeze (buffer.string V)))
      (io.close C)
      (io.close S)))

(let Pair (timed-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     W (io.writer C [])
     _ (io.write W (buffer.from-string "pending"))
     _ (io.socket-deadline C (clock.deadline 0))
  (do (timed-test.check "flush timeout" [timeout 0 0] (freeze (timed-test.progress (io.flush W))))
      (timed-test.check "timeout preserves pending output" 7 (freeze (io.pending W)))
      (io.socket-unlimited C)
      (timed-test.check "explicit flush retry" [ok 7] (freeze (io.flush W)))
      (let V (buffer.new 7) _ (io.read-exact S V [])
        (timed-test.check "retry sends retained bytes" "pending" (freeze (buffer.string V))))
      (io.close C)
      (io.close S)))

(let Pair (timed-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     W (io.writer C [])
     _ (io.write W (buffer.from-string "pending"))
     _ (io.socket-deadline C (clock.deadline 0))
     Closed (io.close C)
  (do (timed-test.check "close reports timeout but closes anyway" timeout
        (freeze (io.error-domain (timed-test.error Closed))))
      (timed-test.check "timed close is one shot" Closed (freeze (io.close C)))
      (timed-test.check "peer observes close despite expired budget" [eof]
        (freeze (io.read-some S (buffer.new 1) [])))
      (io.close S)))

(let Pair (timed-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     _ (io.socket-deadline C (clock.deadline 0))
  (do (timed-test.check "empty read does not probe the transport" [read 0]
        (freeze (io.read-some C (buffer.new 0) [])))
      (timed-test.check "empty write does not probe the transport" [written 0]
        (freeze (io.write-some C (buffer.new 0) [])))
      (timed-test.check "expired shutdown does not send FIN" timeout
        (freeze (io.error-domain (timed-test.error (io.shutdown-write C)))))
      (io.socket-unlimited C)
      (timed-test.check "write direction survives timed shutdown" [ok 1]
        (freeze (io.write-all C (buffer.from-string "x") [])))
      (io.close C)
      (io.close S)))

(output "~A passed, ~A failed~%" (value timed-test.passed) (value timed-test.failed))
