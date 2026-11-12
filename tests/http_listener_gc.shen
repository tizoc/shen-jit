\\ The libraries are already loaded in the saved image. Every allocation collects. The handler stops
\\ the server, which then closes the connection after its response.
(set listener-gc.server [])

(let S (http.listen "127.0.0.1" 0
          (/. Q (do (http.stop (value listener-gc.server)) (http.response 200 [] (buffer.from-string "ok"))))
          [[shutdown-grace 0]])
     _ (set listener-gc.server S)
     C (socket.connect "127.0.0.1" (http.port S))
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     Result (http.run S)
     Reply (socket.recv-string C 4096)
     _ (socket.close C)
  (if (and (= Result [ok]) (= (http.state S) stopped) (= (hd (http.stats S)) 0)
           (= (shen-jit.bytes->string (shen-jit.string->bytes Reply) 0 12) "HTTP/1.1 200"))
      (output "listener gc ok~%")
      (error "listener failed under GC stress")))
