(set *layout-failed* 0)
(set *layout-passed* 0)

(define layout-check
  Name Expected Actual -> (if (= Expected Actual)
                              (set *layout-passed* (+ 1 (value *layout-passed*)))
                              (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Actual)
                                  (set *layout-failed* (+ 1 (value *layout-failed*))))))

(define layout-flatten
  [] -> []
  [X | Y] -> (append (layout-flatten X) (layout-flatten Y))
  X -> [X])

(define layout-raises?
  F -> (trap-error (do (thaw F) false) (/. E true)))

(let B (buffer.new 64)
     _ (layout-test.ipv4.version-> B 0 4)
     _ (layout-test.ipv4.header-length-> B 0 5)
     _ (layout-test.ipv4.total-length-> B 0 40)
     _ (layout-test.ipv4.flags-> B 0 2)
     _ (layout-test.ipv4.fragment-offset-> B 0 100)
     _ (layout-test.ipv4.time-to-live-> B 0 64)
     _ (layout-test.ipv4.protocol-> B 0 6)
     _ (layout-test.ipv4.source-> B 0 3221225985)
     _ (buffer.u8-> B 32 255)
     _ (layout-test.tcp.data-offset-> B 20 5)
     _ (layout-test.tcp.flags-> B 20 18)
     _ (layout-test.tcp.sequence-> B 20 4000000000)
  (do (layout-check "ipv4 byte 0" 69 (buffer.u8 B 0))
      (layout-check "ipv4 flags share a word with the fragment" 16484 (buffer.u16-be B 6))
      (layout-check "ipv4 ttl and protocol" [64 6] [(buffer.u8 B 8) (buffer.u8 B 9)])
      (layout-check "ipv4 reads back" [4 5 40 2 100 64 6 3221225985]
                    [(layout-test.ipv4.version B 0) (layout-test.ipv4.header-length B 0)
                     (layout-test.ipv4.total-length B 0) (layout-test.ipv4.flags B 0)
                     (layout-test.ipv4.fragment-offset B 0) (layout-test.ipv4.time-to-live B 0)
                     (layout-test.ipv4.protocol B 0) (layout-test.ipv4.source B 0)])
      (layout-check "offsets and sizes" [12 16 4 20 20 14 8 24 40 4]
                    [(layout-test.ipv4.source-at 0) (layout-test.ipv4.destination-at 0)
                     (layout-test.tcp.sequence-at 0) (layout-test.tcp.size) (layout-test.ipv4.size)
                     (layout-test.ethernet.size) (layout-test.ipv6.source-at 0)
                     (layout-test.ipv6.destination-at 0) (layout-test.ipv6.size) (layout-test.odd.size)])
      (layout-check "tcp offset leaves the padding alone" 95 (buffer.u8 B 32))
      (layout-check "tcp reads back" [5 18 4000000000]
                    [(layout-test.tcp.data-offset B 20) (layout-test.tcp.flags B 20) (layout-test.tcp.sequence B 20)])
      (layout-check "payload start" 40 (layout-test.payload-start B 0))))

(let B (buffer.new 14)
     _ (layout-test.ethernet.destination-> B 0 2611340115970)
     _ (layout-test.ethernet.source-> B 0 281474976710655)
     _ (layout-test.ethernet.ethertype-> B 0 2048)
  (do (layout-check "mac bytes" [2 96 0 0 0 2] [(buffer.u8 B 0) (buffer.u8 B 1) (buffer.u8 B 2) (buffer.u8 B 3) (buffer.u8 B 4) (buffer.u8 B 5)])
      (layout-check "mac reads back" [2611340115970 281474976710655 2048]
                    [(layout-test.ethernet.destination B 0) (layout-test.ethernet.source B 0) (layout-test.ethernet.ethertype B 0)])
      (layout-check "48-bit store checks its range" true
                    (layout-raises? (freeze (layout-test.ethernet.source-> B 0 281474976710656))))))

(let B (buffer.new 40)
     _ (layout-test.ipv6.version-> B 0 6)
     _ (layout-test.ipv6.traffic-class-> B 0 171)
     _ (layout-test.ipv6.flow-label-> B 0 1048575)
     _ (layout-test.ipv6.hop-limit-> B 0 255)
  (do (layout-check "ipv6 first word" 1790967807 (buffer.u32-be B 0))
      (layout-check "ipv6 reads back" [6 171 1048575 255]
                    [(layout-test.ipv6.version B 0) (layout-test.ipv6.traffic-class B 0)
                     (layout-test.ipv6.flow-label B 0) (layout-test.ipv6.hop-limit B 0)])
      (layout-check "ipv6 addresses have only offsets" false
                    (trap-error (do (fn layout-test.ipv6.source) true) (/. E false)))))

(let B (buffer.new 4)
     _ (layout-test.odd.count-> B 0 12345678)
  (do (layout-check "24-bit field" [12345678 188 97 78] [(layout-test.odd.count B 0) (buffer.u8 B 1) (buffer.u8 B 2) (buffer.u8 B 3)])
      (layout-check "bit field refuses a value too wide" true
                    (layout-raises? (freeze (layout-test.ipv4.version-> B 0 16))))
      (layout-check "bit field refuses a negative value" true
                    (layout-raises? (freeze (layout-test.ipv4.flags-> B 0 -1))))))

\\ Inlined code keeps an inline marker naming the function; a call would be a call instruction.
(define layout-calls?
  F [[Op | Args] | More] -> true where (and (element? Op [call call-sealed tail-call tail-call-sealed])
                                            (element? F Args))
  F [X | More] -> (or (and (cons? X) (layout-calls? F X)) (layout-calls? F More))
  _ _ -> false)

(layout-check "accessors inline into typed callers" [true false false]
              (let Code (shen-jit.code layout-test.payload-start)
                [(element? layout-test.tcp.data-offset (layout-flatten Code))
                 (layout-calls? layout-test.tcp.data-offset Code)
                 (layout-calls? layout-test.ipv4.size Code)]))

(let B (layout-test.write-ipv4 (buffer.new 20) 0 40 17 3221225985 3221225986)
  (do (layout-check "write-layout ipv4 bytes" [69 0 0 40 0 0 64 0 64 17 0 0]
                    [(buffer.u8 B 0) (buffer.u8 B 1) (buffer.u8 B 2) (buffer.u8 B 3) (buffer.u8 B 4) (buffer.u8 B 5)
                     (buffer.u8 B 6) (buffer.u8 B 7) (buffer.u8 B 8) (buffer.u8 B 9) (buffer.u8 B 10) (buffer.u8 B 11)])
      (layout-check "write-layout ipv4 fields" [4 5 40 2 0 64 17 3221225985 3221225986]
                    [(layout-test.ipv4.version B 0) (layout-test.ipv4.header-length B 0)
                     (layout-test.ipv4.total-length B 0) (layout-test.ipv4.flags B 0)
                     (layout-test.ipv4.fragment-offset B 0) (layout-test.ipv4.time-to-live B 0)
                     (layout-test.ipv4.protocol B 0) (layout-test.ipv4.source B 0) (layout-test.ipv4.destination B 0)])
      (layout-check "write-layout checks a packed value" [true true false]
                    [(layout-raises? (freeze (layout-test.write-ipv4 B 0 65536 17 1 2)))
                     (layout-raises? (freeze (layout-test.write-ipv4 B 0 40 256 1 2)))
                     (layout-raises? (freeze (layout-test.write-ipv4 B 0 40 17 1 2)))])))

(let B (layout-test.write-ethernet (buffer.new 14) 2611340115970 281474976710655)
  (do (layout-check "write-layout ethernet bytes" [2 96 0 0 0 2 255 255 255 255 255 255 8 0]
                    [(buffer.u8 B 0) (buffer.u8 B 1) (buffer.u8 B 2) (buffer.u8 B 3) (buffer.u8 B 4) (buffer.u8 B 5)
                     (buffer.u8 B 6) (buffer.u8 B 7) (buffer.u8 B 8) (buffer.u8 B 9) (buffer.u8 B 10) (buffer.u8 B 11)
                     (buffer.u8 B 12) (buffer.u8 B 13)])
      (layout-check "write-layout checks a split value" true
                    (layout-raises? (freeze (layout-test.write-ethernet B 281474976710656 0))))))

(let B (buffer.new 40)
     _ (layout-test.fill-bytes B 0 40 170)
     _ (layout-test.write-ipv6 B 1000 1048575)
  (do (layout-check "write-layout ipv6 fields" [6 0 1048575 1000 17 255]
                    [(layout-test.ipv6.version B 0) (layout-test.ipv6.traffic-class B 0)
                     (layout-test.ipv6.flow-label B 0) (layout-test.ipv6.payload-length B 0)
                     (layout-test.ipv6.next-header B 0) (layout-test.ipv6.hop-limit B 0)])
      (layout-check "write-layout leaves addresses alone" [170 170 170 170]
                    [(buffer.u8 B 8) (buffer.u8 B 23) (buffer.u8 B 24) (buffer.u8 B 39)])))

(layout-check "deflayout refuses a field named size, and a name used twice" [true true false]
              [(layout-raises? (freeze (macroexpand [deflayout layout-test.sized [kind 8] [size 8]])))
               (layout-raises? (freeze (macroexpand [deflayout layout-test.twice [kind 8] [kind 8]])))
               (layout-raises? (freeze (macroexpand [deflayout layout-test.padded [_ 8] [kind 8] [_ 16]])))])

(layout-check "write-layout refuses a field given twice"
              ["write-layout: layout-test.ipv4.protocol is given twice" false]
              [(trap-error (do (macroexpand [write-layout layout-test.ipv4 B 0 [protocol 6] [protocol 6]]) false)
                           (/. E (error-to-string E)))
               (layout-raises? (freeze (macroexpand [write-layout layout-test.ipv4 B 0 [protocol 6] [time-to-live 6]])))])

(if (= (value *layout-failed*) 0)
    (output "~A passed, 0 failed~%" (value *layout-passed*))
    (error "~A layout checks failed" (value *layout-failed*)))
