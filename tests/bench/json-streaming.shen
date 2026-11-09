\\ A JSON value arriving in chunks, decoded by restarting, after framing it, or by reading it from
\\ a reader as it arrives. Load buffer.shen, io.shen, grammar.shen and json.shen first;
\\ SHEN_JIT_STATS=1 adds the collections at exit:
\\
\\   shen-jit eval -l lib/buffer.shen -l lib/io.shen -l lib/grammar.shen -l lib/json.shen \\
\\     -l tests/bench/json-streaming.shen -e '(stream.run restart string 65536 1)'
\\
\\ Strategy is restart, frame or read, Kind string (a string of N letters) or api (N objects), and
\\ the last argument the size of each chunk. It prints attempts, bytes decoded or scanned, and the time.

(define stream.text
  string N -> (cn "[c#34;" (cn (stream.letters N) "c#34;]"))
  api N -> (cn "[" (cn (stream.objects N "") "]")))

(define stream.letters
  N -> (let B (shen-jit.bytes N) _ (stream.fill B 0 N) (shen-jit.bytes->string B 0 N)))

(define stream.fill
  _ I I -> true
  B I N -> (do (shen-jit.u8! B I 97) (stream.fill B (+ I 1) N)))

(define stream.objects
  0 Acc -> Acc
  N Acc -> (stream.objects (- N 1)
             (cn "{c#34;idc#34;: 1234, c#34;namec#34;: c#34;counter-visitsc#34;, c#34;valuec#34;: 98765, c#34;activec#34;: true}"
                 (if (= Acc "") "" (cn ", " Acc)))))

\\ Every strategy reads through the same reader, over an endpoint that gives Chunk bytes a read.
(define stream.reader
  V Chunk ->
    (let State (io.record [0])
         E (io.endpoint "chunks" read (buffer.length V)
             (/. Out (let At (<-address State 0)
                          N (stream.min Chunk (stream.min (shen-jit.bytes-length Out) (- (buffer.length V) At)))
                       (if (= N 0) [eof]
                           (do (shen-jit.copy-bytes Out 0 (buffer.owner V) (+ (buffer.offset V) At) N)
                               (address-> State 0 (+ At N)) [read N]))))
             (function io.no-write) (freeze [ok]))
      (io.reader E [])))

\\ Restart: after each chunk, decode all that has arrived; an error at its end means not yet.
(define stream.restart
  R B Attempts Decoded ->
    (let Chunk (io.read-chunk R)
         _ (if (= (hd Chunk) chunk) (buffer.append! B (hd (tl Chunk))) B)
         Have (buffer.builder-length B)
         Prefix (buffer.slice (stream.contents B) 0 Have)
         Result (trap-error [ok (json.decode Prefix [])] (/. E [error (error-to-string E)]))
      (if (and (= (hd Result) error) (stream.at-end? (hd (tl Result)) Have) (= (hd Chunk) chunk))
          (stream.restart R B (+ Attempts 1) (+ Decoded Have))
          [(+ Attempts 1) (+ Decoded Have) (hd Result)])))

\\ The bytes a builder holds, without finishing it.
(define stream.contents
  B -> (buffer.builder-state.storage B))

(define stream.at-end?
  Message Now -> (= Message (make-string "json: byte ~A: unexpected end" Now)))

\\ Frame: scan only the bytes that arrived for the newline that ends a value, then decode once.
(define stream.frame
  R B Scanned ->
    (let Some (io.peek-some R)
         V (hd (tl Some))
         Line (stream.newline (buffer.owner V) (buffer.offset V) (buffer.end V))
      (if (< Line 0)
          (do (buffer.append! B V) (io.consume R (buffer.length V))
              (stream.frame R B (+ Scanned (buffer.length V))))
          (let N (- Line (buffer.offset V))
               _ (buffer.append! B (buffer.slice V 0 N))
               _ (io.consume R (+ N 1))
               Length (buffer.builder-length B)
               Value (json.decode (buffer.finish B) [])
            [1 (+ Scanned N 1 Length) ok]))))

\\ Read: json.read, which reads the value as it arrives, in place.
(define stream.read
  R -> (let Result (json.read R []) [1 (io.position R) (hd Result)]))

(define stream.newline
  _ At At -> -1
  B At End -> (if (= (shen-jit.u8 B At) 10) At (stream.newline B (+ At 1) End)))

(define stream.min
  A B -> (if (< A B) A B))

(define stream.run
  Strategy Kind N Chunk ->
    (let V (buffer.from-string (cn (stream.text Kind N) "c#10;"))
         Value (buffer.slice V 0 (- (buffer.length V) 1))
         _ (json.read (stream.reader (buffer.from-string (cn (stream.text api 2) "c#10;")) 64) [])
         _ (json.decode (buffer.from-string (stream.text api 2)) [])
         T0 (get-time unix)
         R (stream.reader V Chunk)
         Result (cases (= Strategy restart) (stream.restart R (buffer.builder (buffer.length V)) 0 0)
                       (= Strategy read) (stream.read R)
                       true (stream.frame R (buffer.builder (buffer.length V)) 0))
         T1 (get-time unix)
      (output "~A ~A ~A bytes, chunks of ~A: ~A attempts, ~A bytes decoded, ~A, ~A ms~%"
        Strategy Kind (buffer.length Value) Chunk (hd Result) (hd (tl Result)) (hd (tl (tl Result)))
        (/ (stream.floor (* 10000 (- T1 T0))) 10))))

(define stream.floor X -> (- X (shen.mod X 1)))
