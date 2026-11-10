\\ Sockets (lib/socket.shen), on loopback. Run by make test-ffi, after loading lib/ffi.shen and
\\ that file. Each test has a client and a server, in threads of their own or in the main one.

(set socket-test.*passed* 0)
(set socket-test.*failed* 0)

(define socket-test.result
  F -> (trap-error (thaw F) (/. E [error (error-to-string E)])))

(define socket-test.check
  Name Expected F -> (socket-test.compare Name Expected (socket-test.result F)))

(define socket-test.compare
  _ X X -> (set socket-test.*passed* (+ 1 (value socket-test.*passed*)))
  Name Expected Got -> (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                           (set socket-test.*failed* (+ 1 (value socket-test.*failed*)))))

(define socket-test.prefix
  0 _ -> ""
  N S -> (cn (pos S 0) (socket-test.prefix (- N 1) (tlstr S))))

\\ Only how its message starts, since the rest depends on the system.
(define socket-test.raises
  Name Text F -> (socket-test.check Name Text
                   (freeze (socket-test.prefix (socket-test.length Text) (hd (tl (socket-test.result F)))))))

(define socket-test.length
  "" -> 0
  S -> (+ 1 (socket-test.length (tlstr S))))

\\ A thread signals by setting a global, and this spins on it, as a program without join would.
(define socket-test.wait
  Name -> (if (= (value Name) waiting) (socket-test.wait Name) (value Name)))

(define socket-test.in-thread
  Name F -> (do (set Name waiting)
                (thread (freeze (set Name (socket-test.result F))))))

(if (= (socket-test.result (freeze (socket.listen "127.0.0.1" 0)))
       [error "foreign: this static build cannot load libraries"])
    (do (output "1 passed, 0 failed (a static build)~%") (shen-jit.exit 0))
    skip)

(define socket-test.listener
  -> (socket.listen "127.0.0.1" 0))

\\ ---------------------------------------------------------------------------
\\ A client and a server.

(set l (socket-test.listener))
(socket-test.check "a port" true (freeze (> (socket.port (value l)) 0)))

\\ An echo that goes on until the client finishes, whatever pieces its data comes in.
(define socket-test.echo
  S -> (let B (socket.recv S 4096)
         (if (= (shen-jit.bytes-length B) 0)
             (socket.close S)
             (do (socket.send S B) (socket-test.echo S)))))

(socket-test.in-thread server (freeze (socket-test.echo (socket.accept (value l)))))
(set c (socket.connect "127.0.0.1" (socket.port (value l))))
(socket-test.check "a string out" 5 (freeze (socket.send (value c) "hello")))
(socket-test.check "and back" "hello" (freeze (socket.recv-string (value c) 100)))
(socket-test.check "a buffer" 3 (freeze (socket.send (value c) (shen-jit.string->bytes "abc"))))
(socket-test.check "and back" "abc" (freeze (socket.recv-string (value c) 3)))
(socket-test.check "into a buffer" [2 "xy"]
  (freeze (let Buffer (shen-jit.bytes 10)
               Sent (socket.send (value c) "xy")
               Got (socket.recv-into (value c) Buffer)
            [Got (shen-jit.bytes->string Buffer 0 Got)])))
(socket-test.check "no delay" true (freeze (socket.no-delay (value c))))
(socket-test.check "finished" true (freeze (socket.shutdown (value c))))
(socket-test.check "and the server sees it" true (freeze (socket-test.wait server)))
(socket-test.check "and so does the client" 0 (freeze (shen-jit.bytes-length (socket.recv (value c) 100))))
(socket-test.check "closed" true (freeze (socket.close (value c))))

\\ The other way round: the main thread waits in accept, and another must still run to connect.
(socket-test.in-thread client (freeze (let S (socket.connect "127.0.0.1" (socket.port (value l)))
                                        (do (socket.send S "from a thread") (socket.close S)))))
(socket-test.check "accepted while another ran" "from a thread"
  (freeze (let S (socket.accept (value l))
               Text (socket.recv-string S 100)
            (do (socket.close S) Text))))
(socket-test.check "and it finished" true (freeze (socket-test.wait client)))

\\ A name with more than one address, of which one has nothing listening, on most systems.
(socket-test.in-thread client (freeze (let S (socket.connect "localhost" (socket.port (value l)))
                                        (socket.close S))))
(socket-test.check "by name" true (freeze (socket.close (socket.accept (value l)))))
(socket-test.check "whichever address worked" true (freeze (socket-test.wait client)))

\\ ---------------------------------------------------------------------------
\\ More than the system will take at once: send has to wait, while the other end reads.

(define socket-test.count
  S Total -> (let N (shen-jit.bytes-length (socket.recv S 65536))
               (if (= N 0) Total (socket-test.count S (+ Total N)))))

(set size 8000000)
(define socket-test.big
  -> (shen-jit.u8! (shen-jit.u8! (shen-jit.bytes (value size)) 0 7) (- (value size) 1) 9))

(socket-test.in-thread client
  (freeze (let S (socket.connect "127.0.0.1" (socket.port (value l)))
               Sent (socket.send S (socket-test.big))
            (do (socket.close S) Sent))))
(socket-test.check "a lot received" 8000000
  (freeze (let S (socket.accept (value l))
               Got (socket-test.count S 0)
            (do (socket.close S) Got))))
(socket-test.check "and sent" 8000000 (freeze (socket-test.wait client)))

\\ Its last byte arrives last, which a copy of the wrong place would change.
(define socket-test.fill
  _ Buffer At -> Buffer where (= At (shen-jit.bytes-length Buffer))
  S Buffer At -> (let Part (socket.recv S (- (shen-jit.bytes-length Buffer) At))
                      Copied (shen-jit.copy-bytes Buffer At Part 0 (shen-jit.bytes-length Part))
                   (socket-test.fill S Buffer (+ At (shen-jit.bytes-length Part)))))

(socket-test.in-thread client
  (freeze (let S (socket.connect "127.0.0.1" (socket.port (value l)))
               Sent (socket.send S (socket-test.big))
            (socket.close S))))
(socket-test.check "and it arrives in order" [7 0 9]
  (freeze (let S (socket.accept (value l))
               B (socket-test.fill S (shen-jit.bytes (value size)) 0)
            (do (socket.close S)
                [(shen-jit.u8 B 0) (shen-jit.u8 B 65536) (shen-jit.u8 B (- (value size) 1))]))))
(socket-test.check "and that finished" true (freeze (socket-test.wait client)))

\\ ---------------------------------------------------------------------------
\\ Waiting with a limit.

(set c (socket.connect "127.0.0.1" (socket.port (value l))))
(set a (socket.accept (value l)))
(socket-test.check "nothing to read yet" false (freeze (socket.readable? (value a) 50)))
(socket-test.check "nothing, at once" false (freeze (socket.readable? (value a) 0)))
(socket.send (value c) "x")
(socket-test.check "something to read" true (freeze (socket.readable? (value a) 5000)))
(socket-test.check "and it is there" "x" (freeze (socket.recv-string (value a) 10)))
(socket.close (value c))
(socket-test.check "a close is something to read" true (freeze (socket.readable? (value a) 5000)))

\\ ---------------------------------------------------------------------------
\\ What goes wrong.

\\ Writing to a closed connection ends a process by default, with SIGPIPE. It raises here, at
\\ the latest once the other end has answered.
(define socket-test.send-until-it-fails
  S 0 -> no-failure
  S N -> (do (socket.send S "x")
             (socket.readable? S 5)
             (socket-test.send-until-it-fails S (- N 1))))
(socket-test.raises "a send to a closed connection" "socket: send"
  (freeze (socket-test.send-until-it-fails (value a) 1000)))
(socket.close (value a))

(socket-test.raises "a port already in use" "socket: bind"
  (freeze (socket.listen "127.0.0.1" (socket.port (value l)))))
(socket-test.raises "a closed socket" "socket: send" (freeze (socket.send (value a) "x")))
(socket-test.raises "closed twice" "socket: close" (freeze (socket.close (value a))))
(socket-test.raises "a name that does not exist" "socket: cannot find"
  (freeze (socket.connect "no-such-host.invalid" 80)))

(set closed-port (socket.port (value l)))
(socket.close (value l))
(socket-test.raises "nothing listening" "socket: connect"
  (freeze (socket.connect "127.0.0.1" (value closed-port))))

(let L (socket.listen "127.0.0.1" 0)
     C (socket.connect "127.0.0.1" (socket.port L))
     S (socket.accept L)
     _ (socket.send C "x")
  (do
    (socket-test.check "negative wait refused" true
      (freeze
        (trap-error
          (do (socket.readable? S -1) false)
          (/. E true))))
    (socket-test.check "fractional wait refused" true
      (freeze
        (trap-error
          (do (socket.readable? S 100.5) false)
          (/. E true))))
    (socket.close S)
    (socket.close C)
    (socket.close L)))

(output "~A passed, ~A failed~%" (value socket-test.*passed*) (value socket-test.*failed*))
