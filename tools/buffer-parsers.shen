\\ Complete-buffer examples over buffer/cursor and the public JSON library.
\\ A module, tools/buffer-parsers.shenmod: -m tools/buffer-parsers.shenmod loads it and what it requires.

(shen.x.namespace buffer-example
  (use buffer)
  (use buffer-example)
  (use cursor)
  (use json)
  (externals [byte-limit packet])

(define json
  View -> (json.decode View [[byte-limit (buffer.length View)]]))

(define uint
  _ 0 Acc -> Acc
  C N Acc -> (uint C (- N 1) (+ (* Acc 256) (cursor.read C))))

(define buffer-example.packet
  View Limit ->
    (let C (cursor.new View) _ (buffer.index Limit)
         _ (if (< (cursor.remaining C) 6) (error "packet: incomplete header") true)
         Tag (uint C 2 0) N (uint C 4 0)
         _ (if (> N Limit) (error "packet: payload exceeds limit") true)
         _ (if (= N (cursor.remaining C)) true (error "packet: payload length mismatch"))
      [packet Tag (cursor.bytes C N)]))

)
