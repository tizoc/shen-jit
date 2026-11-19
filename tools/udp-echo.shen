\\ Run with shen-jit eval -m tools/udp-echo.shenmod -e '(udp-echo.run "hello")'.

(define udp-echo.run
  {string --> string}
  Text ->
    (let Link (udp.make-link 2 1500 0 (freeze 0))
         Address (udp.ipv4 192 0 2 2)
         Client (udp.bind (udp.left Link) (udp.ipv4 192 0 2 1) 12345)
         Server (udp.bind (udp.right Link) Address 7)
         Payload (buffer.from-string Text)
         N (buffer.length Payload)
         Out (buffer.new N)
         Info (udp.make-recv-info)
      (cases (not (= (udp.send Client Address 7 Payload N) udp.sent)) (error "UDP echo send failed")
             (not (= (udp.echo-step Server 1) 1)) (error "UDP echo server made no progress")
             (not (= (udp.recv-into Client Out Info 1) udp.received)) (error "UDP echo reply missing")
             true (buffer.string Out))))
