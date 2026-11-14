\\ One connected client, bounded frames, one flushed reply per frame.
\\ Load ffi.shen, socket.shen, buffer.shen, io.shen, io-socket.shen and frame.shen first.

(shen.x.namespace frame-echo
  (use frame)
  (use io)
  (externals [accepted eof frame ok])

(define serve
  E Limit ->
    (let Max (frame.limit Limit)
      (io.with-endpoint E
        (/. Connection
          (let F (frame.reader (io.reader Connection []) Max)
               W (io.writer Connection [])
            (loop F W Max 0))))))

(define loop
  F W Limit Count -> (next F W Limit Count (frame.next F)))

(define next
  _ _ _ Count [eof] -> [ok Count]
  _ _ _ _ [error Error] -> [error Error]
  F W Limit Count [frame Tag Payload] ->
    (written F W Limit Count (io.write W (frame.encode Tag Payload Limit))))

(define written
  _ _ _ _ [error Error _] -> [error Error]
  F W Limit Count [accepted _] -> (flushed F W Limit Count (io.flush W)))

(define flushed
  _ _ _ _ [error Error _] -> [error Error]
  F W Limit Count [ok _] -> (loop F W Limit (+ Count 1)))

)
