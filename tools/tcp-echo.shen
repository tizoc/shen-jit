\\ Run with shen-jit eval -m tools/tcp-echo.shenmod -e '(tcp-echo.run "hello")'.

(define tcp-echo.open
  {tcp.peer --> tcp.peer --> boolean}
  Client Server ->
    (do (tcp.listen Server 100)
        (tcp.connect Client 1)
        (tcp.poll Client 2)
        (tcp.poll Server 2)
        (tcp.poll Client 2)
        (tcp.poll Server 2)
        (and (= (tcp.state Client) tcp.established) (= (tcp.state Server) tcp.established))))

(define tcp-echo.close
  {tcp.peer --> tcp.peer --> boolean}
  Client Server ->
    (do (tcp.shutdown-write Client)
        (tcp.poll Client 2)
        (tcp.poll Server 2)
        (tcp.poll Client 2)
        (tcp.shutdown-write Server)
        (tcp.poll Server 2)
        (tcp.poll Client 2)
        (tcp.poll Server 2)
        (and (= (tcp.state Client) tcp.time-wait) (= (tcp.state Server) tcp.closed))))

(define tcp-echo.run
  {string --> string}
  Text ->
    (let Input (buffer.from-string Text)
         N (buffer.length Input)
         _ (if (fx<= N 536) true (error "TCP echo example takes up to 536 bytes"))
         Link (net-link.make 2 1500 0 (freeze 0))
         A (net-ipv4.address 192 0 2 1)
         B (net-ipv4.address 192 0 2 2)
         Client (tcp.make-peer (net-link.left Link) A 12345 B 7)
         Server (tcp.make-peer (net-link.right Link) B 7 A 12345)
         Scratch (buffer.new N)
         Output (buffer.new N)
      (if (and (tcp-echo.open Client Server)
               (= (tcp.send Client Input N) N)
               (do (tcp.poll Client 2) (tcp.poll Server 2) (= (tcp.recv-into Server Scratch N) N))
               (= (tcp.send Server Scratch N) N)
               (do (tcp.poll Server 2) (tcp.poll Client 2) (= (tcp.recv-into Client Output N) N))
               (do (tcp.poll Server 2) (tcp-echo.close Client Server)))
          (buffer.string Output)
          (error "TCP echo did not complete"))))
