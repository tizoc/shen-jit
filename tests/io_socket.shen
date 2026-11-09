\\ Real loopback endpoints and the framed echo application, without external network access.
(set io-socket-test.passed 0)
(set io-socket-test.failed 0)

(define io-socket-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Expected Got)
          (set io-socket-test.passed (+ 1 (value io-socket-test.passed)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set io-socket-test.failed (+ 1 (value io-socket-test.failed)))))))

(define io-socket-test.raises
  Name F -> (io-socket-test.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(define io-socket-test.wait
  Name -> (if (= (value Name) waiting) (io-socket-test.wait Name) (value Name)))

(define io-socket-test.worker
  Name F ->
    (do (set Name waiting)
        (thread (freeze (set Name (trap-error (thaw F) (/. X [raised (error-to-string X)])))))))

(define io-socket-test.pair
  ->
    (let L (socket.listen "127.0.0.1" 0)
         C (socket.connect "127.0.0.1" (socket.port L))
         S (socket.accept L)
         _ (socket.close L)
      [(io.socket C "client") (io.socket S "server")]))

(define io-socket-test.frame-value
  [frame Tag Payload] -> [Tag (buffer.string Payload)]
  [eof] -> [eof]
  [error E] -> [error (io.error-operation E) (io.error-progress E)])

(if (trap-error (do (socket.close (socket.listen "127.0.0.1" 0)) false)
                (/. X (= (error-to-string X) "foreign: this static build cannot load libraries")))
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(let Pair (io-socket-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     W (io.writer C [[chunk-size 3]])
     R (io.reader S [[chunk-size 2]])
     F (frame.reader R 32)
  (do (io-socket-test.check "buffer a binary frame" [accepted 11]
        (freeze (io.write W (frame.encode 42 (buffer.from-string "hello") 32))))
      (io-socket-test.check "shutdown flushes before FIN" [ok] (freeze (io.shutdown-write C)))
      (io-socket-test.check "shutdown is idempotent" [ok] (freeze (io.shutdown-write C)))
      (io-socket-test.check "frame spans small network reader chunks" [42 "hello"]
        (freeze (io-socket-test.frame-value (frame.next F))))
      (io-socket-test.check "peer EOF after frame" [eof] (freeze (frame.next F)))
      (io-socket-test.check "read EOF leaves write direction open" [ok 3]
        (freeze (io.write-all S (buffer.from-string "ack") [])))
      (let V (buffer.new 3)
        (do (io-socket-test.check "shutdown preserves the read direction" [ok 3]
              (freeze (io.read-exact C V [])))
            (io-socket-test.check "reply after FIN" "ack" (freeze (buffer.string V)))))
      (io-socket-test.raises "direct write after shutdown" (freeze (io.write-some C (buffer.new 0) [])))
      (io-socket-test.raises "old buffered writer after shutdown" (freeze (io.write W (buffer.new 0))))
      (io-socket-test.check "close after shutdown" [ok] (freeze (io.close C)))
      (io-socket-test.check "close once" [ok] (freeze (io.close C)))
      (io-socket-test.raises "shutdown after full close" (freeze (io.shutdown-write C)))
      (io.close S)))

\\ Main waits for input while a different task accepts and echoes a series of frames.
(let L (socket.listen "127.0.0.1" 0)
     _ (io-socket-test.worker io-socket-test.echo
         (freeze (frame-echo.serve (io.socket (socket.accept L) "echo peer") 1048576)))
     C (io.socket (socket.connect "127.0.0.1" (socket.port L)) "echo client")
     W (io.writer C [[chunk-size 8192]])
     F (frame.reader (io.reader C [[chunk-size 4096]]) 1048576)
     Payload (buffer.new 1048576)
     _ (buffer.u8! Payload 0 17)
     _ (buffer.u8! Payload 1048575 255)
  (do (io-socket-test.check "large frame accepted" [accepted 1048582]
        (freeze (io.write W (frame.encode 65535 Payload 1048576))))
      (io.flush W)
      (let Result (frame.next F)
        (do (io-socket-test.check "large frame tag" 65535 (freeze (hd (tl Result))))
            (io-socket-test.check "large payload survives partial transfers" true
              (freeze (buffer.equal? Payload (hd (tl (tl Result))))))))
      (io.write W (frame.encode 0 (buffer.new 0) 0))
      (io.flush W)
      (io-socket-test.check "empty message is echoed without peer EOF" [0 ""]
        (freeze (io-socket-test.frame-value (frame.next F))))
      (io.shutdown-write C)
      (io-socket-test.check "echo stops after clean stream end" [ok 2]
        (freeze (io-socket-test.wait io-socket-test.echo)))
      (io-socket-test.check "echo sends EOF" [eof] (freeze (frame.next F)))
      (io.close C)
      (socket.close L)))

(let Pair (io-socket-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     ErrorHeader (buffer.new 6)
     _ (buffer.u8! ErrorHeader 5 9)
     _ (io.write-all C ErrorHeader [])
     _ (io.shutdown-write C)
     Result (frame-echo.serve S 8)
  (do (io-socket-test.check "echo rejects oversized frame" frame
        (freeze (io.error-operation (hd (tl Result)))))
      (io-socket-test.check "oversized frame consumes only its header" 6
        (freeze (io.error-progress (hd (tl Result)))))
      (io-socket-test.raises "echo closes on framing error" (freeze (io.read-some S (buffer.new 0) [])))
      (io.close C)))

\\ Inject EBADF/WSAENOTSOCK without any new socket being created before the failed call.
(let Pair (io-socket-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     Token (io.endpoint.guard S)
     _ (socket.c-close (io.socket-id Token))
     Result (io.read-some S (buffer.new 1) [])
     Error (hd (tl Result))
     Close (io.close S)
  (do (io-socket-test.check "native receive failure is structured" read
        (freeze (io.error-operation Error)))
      (io-socket-test.check "native error retains domain and code" true
        (freeze (and (= (io.error-domain Error) (if (socket.windows?) winsock posix))
                     (> (io.error-code Error) 0))))
      (io-socket-test.check "native close failure is remembered" Close (freeze (io.close S)))
      (io-socket-test.check "failed close kills socket identity" 0
        (freeze (shen-jit.pointer-address Token)))
      (io.close C)))

(let Pair (io-socket-test.pair)
     C (hd Pair)
     S (hd (tl Pair))
     W (io.writer S [])
     _ (io.write W (buffer.from-string "pending"))
     _ (socket.c-close (io.socket-id (io.endpoint.guard S)))
     Result (io.shutdown-write S)
     Error (hd (tl Result))
  (do (io-socket-test.check "shutdown reports failed flush" write
        (freeze (io.error-operation Error)))
      (io-socket-test.check "failed shutdown retains pending bytes" 7 (freeze (io.pending W)))
      (io-socket-test.check "failed shutdown leaves write state open" read-write
        (freeze (io.endpoint.mode S)))
      (io.close S)
      (io.close C)))

(let E (io.input-buffer (buffer.new 0))
  (do (io-socket-test.raises "file/memory endpoint is not a socket" (freeze (io.shutdown-write E)))
      (io.close E)))
(io-socket-test.raises "negative socket" (freeze (io.socket -1 "bad")))
(io-socket-test.raises "boxed real socket" (freeze (io.socket (+ 0.5 0.5) "bad")))
(io-socket-test.check "64-bit identity is preserved" 4294967305
  (freeze (let Token (io.socket-token 4294967305)
               S (io.socket-id Token)
               _ (shen-jit.pointer-kill Token)
            S)))

(output "~A passed, ~A failed~%" (value io-socket-test.passed) (value io-socket-test.failed))
