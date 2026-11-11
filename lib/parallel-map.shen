\\ Copied immutable values over structured workers. Load buffer.shen and
\\ parallel.shen first, under tc-. The byte API remains independent of this file.
\\ Codec v1: magic/version, then nil/false/true/i64/f64/string/symbol/list.
\\ Limits include the map envelope: 64 nested lists and 262144 value nodes.

(shen.x.namespace parallel
  (use buffer)
  (use shen-jit)
  (externals [parallel-values parallel.map-request parallel.map-response parallel.map-scope-state])
  (export encode decode try-encode encoded-size with-map parallel.map => map parallel.value => value map-scope
    parallel.number => number parallel.boolean => boolean parallel.string => string
    parallel.symbol => symbol parallel.list => list)

(define parallel.value-count
  [] _ N -> N
  [_ | Rest] Limit N ->
    (if (< N Limit) (parallel.value-count Rest Limit (+ N 1))
        (error "parallel: list limit exceeded"))
  _ _ _ -> (error "parallel: expected a proper list"))

(define parallel.value-node
  State -> (let N (<-address State 0)
             (if (< N 262144) (address-> State 0 (+ N 1))
                 (error "parallel: value node limit exceeded"))))

\\ Encoder-owned state: node count, limit, managed bytes, used length.
\\ Reserve checks the packet limit once; native stores still check bounds.
(define parallel.value-reserve
  State Count ->
    (let At (<-address State 3) Limit (<-address State 1)
         _ (if (and (>= Count 0) (<= Count (- Limit At))) true
               (error "parallel: value exceeds byte limit"))
         Need (+ At Count) Old (<-address State 2) Cap (shen-jit.bytes-length Old)
         _ (if (<= Need Cap) true
               (let Grow (if (< Cap (- Limit Cap)) (* Cap 2) Limit)
                    Next (shen-jit.bytes (if (> Need Grow) Need Grow))
                    _ (shen-jit.copy-bytes Next 0 Old 0 At)
                 (address-> State 2 Next)))
         _ (address-> State 3 Need)
      At))

(define parallel.value-tag
  State Tag -> (let At (parallel.value-reserve State 1)
                 (shen-jit.u8! (<-address State 2) At Tag)))

(define parallel.value-word
  State N -> (let At (parallel.value-reserve State 4)
               (shen-jit.u32! (<-address State 2) At N)))

(define parallel.value-number
  State N ->
    (let Fix (shen-jit.fixnum? N) At (parallel.value-reserve State 9)
         _ (shen-jit.u8! (<-address State 2) At (if Fix 3 4))
      (if Fix (shen-jit.s64! (<-address State 2) (+ At 1) N)
              (shen-jit.f64! (<-address State 2) (+ At 1) N))))

\\ Room is a nonnegative byte offset and Text is already known to be a string.
\\ Catch only pos's bounds error, never an allocation or other failure.
\\ This depends on P_POS's wording in runtime/prims.c; update both together.
(define parallel.text-fits?
  Text Room ->
    (and (>= Room 0)
      (trap-error (do (pos Text Room) false)
        (/. E (if (= (error-to-string E) (make-string "pos: ~S is not a valid index" Room))
                  true (simple-error (error-to-string E)))))))

(define parallel.value-text
  State Tag Text ->
    (let Room (- (- (<-address State 1) (<-address State 3)) 5)
         _ (if (parallel.text-fits? Text Room)
               true (error "parallel: text exceeds byte limit"))
         Bytes (shen-jit.string->bytes Text) N (shen-jit.bytes-length Bytes)
         At (parallel.value-reserve State (+ 5 N))
         _ (shen-jit.u8! (<-address State 2) At Tag)
         _ (shen-jit.u32! (<-address State 2) (+ At 1) N)
      (shen-jit.copy-bytes (<-address State 2) (+ At 5) Bytes 0 N)))

(define parallel.value-items
  _ [] _ Count -> Count
  State [X | Rest] Depth Count ->
    (do (parallel.value-write State X Depth)
        (parallel.value-items State Rest Depth (+ Count 1)))
  _ _ _ _ -> (error "parallel: expected a proper list"))

(define parallel.value-write
  State Value Depth ->
    (do (parallel.value-node State)
        (cond ((number? Value) (parallel.value-number State Value))
              ((= Value []) (parallel.value-tag State 0))
              ((= Value false) (parallel.value-tag State 1))
              ((= Value true) (parallel.value-tag State 2))
              ((string? Value) (parallel.value-text State 5 Value))
              ((shen-jit.symbol? Value) (parallel.value-text State 6 (str Value)))
              ((cons? Value)
                (let _ (if (< Depth 64) true (error "parallel: value depth limit exceeded"))
                     At (parallel.value-reserve State 5)
                     _ (shen-jit.u8! (<-address State 2) At 7)
                     N (parallel.value-items State Value (+ Depth 1) 0)
                  \\ Growth may have moved storage; reload it to patch the count.
                  (shen-jit.u32! (<-address State 2) (+ At 1) N)))
              (true (error "parallel: only immutable scalar values and proper lists can be copied")))))

(define parallel.encode
  Value Limit ->
    (let N (buffer.index Limit)
         _ (if (and (>= N 9) (<= N 67108864)) true (error "parallel: invalid codec byte limit"))
         State (address-> (address-> (address-> (address-> (absvector 4)
                  0 0) 1 N) 2 (shen-jit.bytes (if (< N 256) N 256))) 3 0)
         _ (parallel.value-word State 1347240241) _ (parallel.value-word State 1)
         _ (parallel.value-write State Value 0)
      (buffer.slice (buffer.wrap (<-address State 2)) 0 (<-address State 3))))

\\ Only the encoder's explicit transport limits permit sequential fallback.
\\ Type, allocation and other unexpected errors still propagate.
(define parallel.try-encode
  Value Limit ->
    (trap-error (parallel.encode Value Limit)
      (/. E (let Message (error-to-string E)
              (if (element? Message ["parallel: value exceeds byte limit"
                                     "parallel: text exceeds byte limit"
                                     "parallel: value node limit exceeded"
                                     "parallel: value depth limit exceeded"])
                  [] (simple-error Message))))))

\\ Convenience only: performs and allocates a full encoding to obtain its size.
(define parallel.encoded-size
  Value Limit -> (let Encoded (parallel.try-encode Value Limit)
                   (if (= Encoded []) [] (buffer.length Encoded))))

\\ Decoder state: bytes, cursor, node counter, end. Native reads check bounds too.
(define parallel.value-take
  State Count ->
    (let At (<-address State 1)
         _ (if (and (>= Count 0) (<= Count (- (<-address State 3) At))) true
               (error "parallel: truncated value"))
      (do (address-> State 1 (+ At Count)) At)))

(define parallel.value-u32
  State -> (let At (parallel.value-take State 4)
             (shen-jit.u32 (<-address State 0) At)))

(define parallel.value-read-text
  State Symbol ->
    (let N (parallel.value-u32 State) At (parallel.value-take State N)
         Text (shen-jit.bytes->string (<-address State 0) At N)
      (if Symbol (intern Text) Text)))

(define parallel.value-read-items
  _ 0 _ Reversed -> (reverse Reversed)
  State Left Depth Reversed ->
    (let X (parallel.value-read State Depth)
      (parallel.value-read-items State (- Left 1) Depth [X | Reversed])))

(define parallel.value-read
  State Depth ->
    (let Nodes (<-address State 2)
         _ (if (< Nodes 262144) (address-> State 2 (+ Nodes 1))
               (error "parallel: value node limit exceeded"))
         At (parallel.value-take State 1) Tag (shen-jit.u8 (<-address State 0) At)
      (cond ((= Tag 3) (let I (parallel.value-take State 8) (shen-jit.s64 (<-address State 0) I)))
            ((= Tag 0) []) ((= Tag 1) false) ((= Tag 2) true)
            ((= Tag 4) (let I (parallel.value-take State 8) (shen-jit.f64 (<-address State 0) I)))
            ((= Tag 5) (parallel.value-read-text State false))
            ((= Tag 6) (parallel.value-read-text State true))
            ((= Tag 7)
              (let N (parallel.value-u32 State)
                   _ (if (and (< Depth 64) (<= N (- 262144 (<-address State 2)))) true
                         (error "parallel: list depth or node limit exceeded"))
                (parallel.value-read-items State N (+ Depth 1) [])))
            (true (error "parallel: invalid value tag")))))

(define parallel.decode-bytes
  B Length ->
    (let N (buffer.index Length)
         _ (if (and (>= N 9) (<= N 67108864) (<= N (shen-jit.bytes-length B))) true
               (error "parallel: invalid encoded value size"))
         _ (if (and (= (shen-jit.u32 B 0) 1347240241) (= (shen-jit.u32 B 4) 1)) true
               (error "parallel: invalid value header"))
         State (address-> (address-> (address-> (address-> (absvector 4) 0 B) 1 8) 2 0) 3 N)
         Value (parallel.value-read State 0)
      (if (= (<-address State 1) N) Value (error "parallel: trailing value bytes"))))

(define parallel.decode
  View -> (parallel.decode-bytes (parallel.bytes View) (buffer.length View)))

\\ A map scope fixes a named unary function in the saved worker image.
(define parallel.with-map
  Image Entry Count Config Body ->
    (let _ (if (shen-jit.symbol? Entry) true (error "parallel: map entry must be a symbol"))
      (parallel.with-workers Image (intern "parallel.value-worker") Count Config
        (/. Scope (Body (address-> (address-> (address-> (absvector 3)
                          0 parallel.map-scope-state) 1 Scope) 2 Entry))))))

(define parallel.map-check
  S -> (if (shen-jit.tagged? S parallel.map-scope-state) S (error "parallel: invalid map scope")))

(define parallel.map-split
  0 Rest Reversed -> [(reverse Reversed) Rest]
  N [X | Rest] Reversed -> (parallel.map-split (- N 1) Rest [X | Reversed]))

(define parallel.map-requests
  _ _ 0 _ _ _ -> []
  Values Name Left Start Remaining Budget ->
    (let N (/ (- (+ Remaining (- Left 1)) (shen.mod (+ Remaining (- Left 1)) Left)) Left)
         Parts (parallel.map-split N Values [])
         Packet (parallel.encode [parallel.map-request Name Start Budget (hd Parts)] 1048576)
      [[Packet Start N] |
       (parallel.map-requests (hd (tl Parts)) Name (- Left 1) (+ Start N) (- Remaining N) Budget)]))

(define parallel.map-result
  [parallel.map-response Start Values] Start Count ->
    (if (= (parallel.value-count Values 4096 0) Count) Values
        (error "parallel: wrong map reply count"))
  _ _ _ -> (error "parallel: invalid map reply"))

(define parallel.map-responses
  [] [] -> []
  [View | Replies] [[_ Start N] | Requests] ->
    (append (parallel.map-result (parallel.decode View) Start N)
            (parallel.map-responses Replies Requests))
  _ _ -> (error "parallel: wrong number of map replies"))

(define parallel.map
  Scope Values ->
    (let S (parallel.map-check Scope) Raw (<-address S 1) P (parallel.count Raw)
         N (parallel.value-count Values 4096 0)
         Budget (/ (- 67108864 (shen.mod 67108864 P)) P)
         Requests (parallel.map-requests Values (<-address S 2) P 0 N Budget)
      (parallel.map-responses (parallel.batch Raw (map (function hd) Requests)) Requests)))

(define parallel.value-jobs
  _ [] Reversed -> (reverse Reversed)
  F [X | Rest] Reversed ->
    (if (parallel.cancelled?) (error "parallel: cancelled")
        (let Result (F X) (parallel.value-jobs F Rest [Result | Reversed]))))

(define parallel.value-request
  [parallel.map-request Name Start Budget Values] ->
    (let _ (if (and (shen-jit.symbol? Name) (= (arity Name) 1)) true
               (error "parallel: ~A must name a unary function in the worker image" Name))
         _ (if (and (integer? Start) (>= Start 0) (<= Start 4096)
                    (integer? Budget) (>= Budget 9) (<= Budget 67108864)) true
               (error "parallel: invalid map request bounds"))
         _ (parallel.value-count Values 4096 0)
         Results (parallel.value-jobs (fn Name) Values [])
      (parallel.encode [parallel.map-response Start Results] Budget))
  _ -> (error "parallel: invalid map request"))

(define parallel.value-worker
  Request -> (parallel.reply (parallel.value-request (parallel.decode-bytes Request (shen-jit.bytes-length Request)))))

\\ Checked elimination rules keep parallel.value from claiming every member type.
(define parallel.number
  X -> X where (number? X)
  _ -> (error "parallel: expected a number"))

(define parallel.boolean
  true -> true
  false -> false
  _ -> (error "parallel: expected a boolean"))

(define parallel.string
  X -> X where (string? X)
  _ -> (error "parallel: expected a string"))

(define parallel.symbol
  X -> X where (shen-jit.symbol? X)
  _ -> (error "parallel: expected a symbol"))

(define parallel.value-list-check
  [] _ -> true
  [X | Rest] Depth ->
    (do (parallel.value-shape X Depth) (parallel.value-list-check Rest Depth))
  _ _ -> (error "parallel: expected a proper list"))

(define parallel.value-shape
  X Depth -> true where (or (number? X) (string? X) (shen-jit.symbol? X)
                           (= X true) (= X false) (= X []))
  X Depth -> (if (< Depth 64) (parallel.value-list-check X (+ Depth 1))
                 (error "parallel: value depth limit exceeded")) where (cons? X)
  _ _ -> (error "parallel: expected an immutable scalar or proper list"))

(define parallel.list
  X -> (do (parallel.value-list-check X 1) X))

(datatype parallel-values
  X : number;
  ________________________
  X : parallel.value;

  X : boolean;
  ________________________
  X : parallel.value;

  X : string;
  ________________________
  X : parallel.value;

  X : symbol;
  ________________________
  X : parallel.value;

  X : (list parallel.value);
  ________________________
  X : parallel.value;)

(declare parallel.encode [parallel.value --> [number --> buffer.view]])
(declare parallel.decode [buffer.view --> parallel.value])
(declare parallel.with-map
  [string --> [symbol --> [number --> [parallel.config --> [[parallel.map-scope --> A] --> A]]]]])
(declare parallel.map [parallel.map-scope --> [[list parallel.value] --> [list parallel.value]]])

(declare parallel.number [parallel.value --> number])
(declare parallel.boolean [parallel.value --> boolean])
(declare parallel.string [parallel.value --> string])
(declare parallel.symbol [parallel.value --> symbol])
(declare parallel.list [parallel.value --> [list parallel.value]])

)
