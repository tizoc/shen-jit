\\ Application and libraries are already in the image; every allocation here collects.
(counter-app.initialize (value export-gc.path))
(sqlite.with-database (value export-gc.path)
  (/. Db (do (sqlite.run Db "INSERT INTO counters VALUES (?, ?)" ["a" 1])
             (sqlite.run Db "INSERT INTO counters VALUES (?, ?)" ["é😀" 2]))))
(let Response (counter-app.export (value export-gc.path))
     Q (hd (tl (http.parse-request
                 (buffer.from-string "GET / HTTP/1.1c#13;c#10;Host: localc#13;c#10;c#13;c#10;") 0)))
     Out (buffer.new 1024)
     E (io.output-buffer Out)
     Sent (http.send-response E Q Response (deadline.after (freeze 0) 1000) [[response-chunk-size 7]])
     _ (io.close E)
     _ (if (= (hd Sent) ok) true
           (error "export GC send: ~A" (io.error-message (hd (tl Sent)))))
     Wire (buffer.slice Out 0 (hd (tl Sent)))
     Input (io.input-buffer Wire)
     R (io.reader Input [[chunk-size 3]])
     _ (http.read-head (http.head-reader R 1024))
     Chunked (hd (tl (http.parse-request
                       (buffer.from-string "POST / HTTP/1.1c#13;c#10;Host: localc#13;c#10;Transfer-Encoding: chunkedc#13;c#10;c#13;c#10;") 1024)))
     Full (hd (tl (http.read-body (http.body-reader R Chunked))))
     _ (io.close Input)
     Expected (cn "{c#34;namec#34;:c#34;ac#34;,c#34;valuec#34;:1}c#10;"
                  "{c#34;namec#34;:c#34;é😀c#34;,c#34;valuec#34;:2}c#10;")
  (if (and (= (buffer.string (http.body Full)) Expected)
           (= (http.source-close (http.response-source Response)) [ok]))
      (output "export gc ok~%")
      (error "batched export failed under GC stress")))
