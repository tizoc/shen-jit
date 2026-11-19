(load "tests/result_helpers.shen")

\\ Every split and truncation, bounded scan state, untouched body and total fake-clock budgets.
(set http-test.passed 0)
(set http-test.failed 0)

(define http-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set http-test.passed (+ 1 (value http-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set http-test.failed (+ 1 (value http-test.failed)))))))

(define http-test.raises
  Name F -> (http-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define http-test.value
  (:result.ok [V]) -> (buffer.string V)
  (:result.ok []) -> (:result.ok [])
  (:result.err E) -> [(io.error-domain E) (io.error-message E) (io.error-progress E)])

(define http-test.source
  Wire State Terminal Time ->
    (io.endpoint "HTTP fixture" read 128
      (/. B (let At (<-address State 0)
                 Step (if (= (<-address State 1) 0) (<-address State 2) 128)
                 N (io.min Step (io.min (shen-jit.bytes-length B) (- (buffer.length Wire) At)))
              (do (address-> State 1 (+ 1 (<-address State 1)))
                  (if (= N 0)
                      Terminal
                      (do (shen-jit.copy-bytes B 0 (buffer.owner Wire) (+ (buffer.offset Wire) At) N)
                          (address-> State 0 (+ At N))
                          (if (empty? Time) true (address-> Time 0 (+ 10 (<-address Time 0))))
                          (:result.ok [N]))))))
      (function io.no-write)
      (freeze (:result.ok []))))

(set http-test.head "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
(set http-test.wire (buffer.from-string (cn (value http-test.head) "body")))

(define http-test.split
  Split ->
    (let State (io.record [0 0 Split])
         E (http-test.source (value http-test.wire) State (:result.ok []) [])
         R (io.reader E [])
         F (http.head-reader R 35)
         Result (http.read-head F)
         Calls (<-address State 1)
         Again (http.read-head F)
         Position (io.position R)
         _ (http-test.check "completed capture is remembered" true
             (freeze (and (shen-jit.same? Result Again) (= Calls (<-address State 1)))))
         Body (io.read-all R 4)
         _ (io.close E)
      [(http-test.value Result) (buffer.string (fixture.success Body)) Position]))

(define http-test.splits
  0 -> true
  N ->
    (do (http-test.check "every delimiter/header split"
          [(value http-test.head) "body" 35] (freeze (http-test.split N)))
        (http-test.splits (- N 1))))

(http-test.splits 39)

(define http-test.truncations
  -1 -> true
  N ->
    (let E (io.input-buffer (buffer.slice (value http-test.wire) 0 N))
         F (http.head-reader (io.reader E [[chunk-size 1]]) 35)
         Expected (if (= N 0) (:result.ok []) [library "incomplete head" N])
         _ (http-test.check "every incomplete prefix" Expected
             (freeze (http-test.value (http.read-head F))))
         _ (io.close E)
      (http-test.truncations (- N 1))))

(http-test.truncations 34)

(let E (io.input-buffer (value http-test.wire))
     R (io.reader E [])
     F (http.head-reader R 34)
  (do (http-test.check "byte limit" [library "head exceeds byte limit" 34]
        (freeze (http-test.value (http.read-head F))))
      (http-test.check "limit preserves the unconsumed suffix" "c#10;body"
        (freeze (buffer.string (fixture.success (io.read-all R 5)))))
      (io.close E)))

(define http-test.bad
  Text ->
    (let E (io.input-buffer (buffer.from-string Text))
         F (http.head-reader (io.reader E [[chunk-size 1]]) 128)
         Result (http-test.value (http.read-head F))
         _ (io.close E)
      Result))

(http-test.check "bare LF" [library "bare LF" 2] (freeze (http-test.bad "xc#10;")))
(http-test.check "bare CR" [library "CR without LF" 3] (freeze (http-test.bad "xc#13;x")))
(http-test.check "NUL" [library "control byte in head" 2] (freeze (http-test.bad "xc#0;")))
(http-test.check "DEL" [library "control byte in head" 2] (freeze (http-test.bad "xc#127;")))
(http-test.check "HTAB is allowed in framing" "x:c#9;yc#13;c#10;c#13;c#10;"
  (freeze (http-test.bad "x:c#9;yc#13;c#10;c#13;c#10;")))
(http-test.check "empty delimiter is framing, not syntax validation" "c#13;c#10;c#13;c#10;"
  (freeze (http-test.bad "c#13;c#10;c#13;c#10;")))

(let E (io.input-buffer (buffer.new 0))
     R (io.reader E [])
  (do (http-test.raises "too small limit" (freeze (http.head-reader R 3)))
      (http-test.raises "too large limit" (freeze (http.head-reader R 1048577)))
      (http-test.raises "float limit" (freeze (http.head-reader R (+ 0.5 0.5))))
      (http-test.raises "not a reader" (freeze (http.head-reader [] 128)))
      (io.close E)))

(let Time (io.record [0])
     D (deadline.after (freeze (<-address Time 0)) 25)
     State (io.record [0 0 1])
     E (http-test.source (value http-test.wire) State (:result.ok []) Time)
     F (http.head-reader (io.reader E [[chunk-size 1]]) 128)
     Result (http.read-head-until F D)
  (do (http-test.check "header deadline is total across progress" [timeout "deadline expired" 3]
        (freeze (http-test.value Result)))
      (http-test.check "timeout is terminal for the framer" Result (freeze (http.read-head F)))
      (io.close E)))

(let State (io.record [0 0 128])
     E (http-test.source (value http-test.wire) State (:result.ok []) [])
     F (http.head-reader (io.reader E []) 128)
     D (deadline.after (freeze 0) 0)
  (do (http-test.check "expired budget does not read" [timeout "deadline expired" 0]
        (freeze (http-test.value (http.read-head-until F D))))
      (http-test.check "expired budget makes no backend call" 0 (freeze (<-address State 1)))
      (io.close E)))

(let State (io.record [0 0 128])
     E (http-test.source (buffer.slice (value http-test.wire) 0 8) State
                        (:result.err (io.native-error read posix 5 "peer" "read failed")) [])
     F (http.head-reader (io.reader E []) 128)
     Result (http.read-head F)
     Error (fixture.failure Result)
  (do (http-test.check "transport details and aggregate progress" [posix 5 8]
        (freeze [(io.error-domain Error) (io.error-code Error) (io.error-progress Error)]))
      (io.close E)))

(let Time (io.record [-6])
     D (deadline.after (freeze (let N (+ 6 (<-address Time 0)) _ (address-> Time 0 N) N)) 10)
     E (io.input-buffer (value http-test.wire))
     F (http.head-reader (io.reader E []) 128)
  (do (http-test.check "deadline is rechecked before publishing a completed head"
        [timeout "deadline expired" 35] (freeze (http-test.value (http.read-head-until F D))))
      (io.close E)))

(output "~A passed, ~A failed~%" (value http-test.passed) (value http-test.failed))
