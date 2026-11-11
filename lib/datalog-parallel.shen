\\ Opt-in parallel Datalog. Load native, datalog, buffer, parallel and
\\ parallel-map first, under tc-. All returned databases belong to the parent.

(shen.x.namespace datalog.parallel
  (use shen-jit)
  (import struct defstruct)
  (externals [aggregate db integer none not parallel relation rule sequential var word for when u8 u32 u32! return-word define-native])
  (externals [buffer.length buffer.make buffer.view? buffer.wrap datalog.*fresh* datalog.*merges*
    datalog.check-fact datalog.count datalog.count-of datalog.define datalog.dict-find
    datalog.index-range datalog.index.keys datalog.index.mask datalog.index.table datalog.intern-all
    datalog.load-facts datalog.match datalog.holds? datalog.tuples datalog.max datalog.merge-state datalog.new-index
    datalog.new-relation datalog.new-state datalog.nth datalog.program
    datalog.read-tuples datalog.relation-of datalog.relation-slot datalog.run datalog.stride
    datalog.types-of datalog.upto datalog.value-type datalog.values-vector parallel.batch
    parallel.bytes parallel.check-count parallel.config parallel.count parallel.decode parallel.decode-bytes
    parallel.encode parallel.try-encode parallel.index parallel.reply parallel.shared
    parallel.shared-length parallel.value-count parallel.with-workers])
  (shadow concat count match run)
  (export count holds? match match-many materialize plan run tuples view with-db)

(set *state* [])
(set *derived* [])
(set *owned* [])
(set *reply-limit* 1048576)

(defstruct view
  name
  facts
  source
  shared
  (mutable active))

(define view-check
  D -> (if (and (view? D) (view.active D)
                (or (= (view.shared D) []) (> (parallel.shared-length (view.shared D)) 0)))
           D (error "datalog.parallel: database view is closed")))

(define call-body
  D Body ->
    (shen-jit.finally (freeze (Body D)) (freeze (view.active-> D false))))

(define serial-body
  Name Facts Body -> (call-body (view.make Name Facts (datalog.run Name Facts) [] true) Body))

(define require
  true _ -> true
  false Message -> (error "datalog.parallel: ~A" Message))

(define scalar-types?
  [] -> true
  [T | Ts] -> (and (element? T [integer symbol string]) (scalar-types? Ts)))

(define schemas
  [] -> true
  [[_ | Types] | Rs] ->
    (and (cons? Types) (and (scalar-types? Types) (schemas Rs))))

(define derived
  [] Acc -> Acc
  [[[Rel | _] _] | Rs] Acc -> (derived Rs (adjoin Rel Acc)))

(define body-check
  [] _ _ -> []
  [[Op | Terms] | Rest] Key Derived ->
    (cond ((element? Op [not aggregate]) "negation and aggregates are not partitioned")
          ((and (element? Op Derived) (not (= (hd Terms) Key)))
            "a derived body atom changes the partition key")
          (true (body-check Rest Key Derived))))

(define anchored?
  _ [] _ -> false
  Key [[Rel | Terms] | Rest] Relations ->
    (or (and (cons? (assoc Rel Relations)) (element? Key Terms))
        (anchored? Key Rest Relations)))

(define rule-check
  [[_ Key | _] Body] Derived Relations Type ->
    (if (or (= (datalog.value-type Key) Type)
            (and (key-variable? Key) (anchored? Key Body Relations)))
        (body-check Body Key Derived)
        "the head key must be a constant or a variable read from a body atom"))

(define key-variable?
  [var _] -> true
  _ -> false)

(define same-key-types?
  [] _ _ -> true
  [R | Rs] Schemas Type ->
    (and (= (hd (tl (assoc R Schemas))) Type) (same-key-types? Rs Schemas Type)))

(define rules-check
  [] _ _ _ -> []
  [R | Rules] Derived Relations Type ->
    (let Reason (rule-check R Derived Relations Type)
      (if (= Reason []) (rules-check Rules Derived Relations Type) Reason)))

\\ Refusals are data. An unexpected failure while inspecting a checked
\\ program must propagate rather than silently choose a different engine.
(define inspect
  Name ->
    (let P (datalog.program Name) Rs (datalog.nth 3 P) Rules (datalog.nth 4 P)
         Ds (derived Rules [])
         Reason (cond ((empty? Ds) "no derived relations")
                  ((not (and (= (datalog.nth 7 P) [])
                         (= (datalog.nth 8 P) []) (= (datalog.nth 9 P) [])))
                    "records, equivalences and keyed relations are not partitioned")
                  ((not (= (assoc partition-key Rs) [])) "reserved relation name")
                  ((not (schemas Rs)) "only nonempty scalar relations are supported")
                  (true []))
      (if (not (= Reason [])) [sequential Reason]
          (let Type (hd (tl (assoc (hd Ds) Rs)))
               Reason (if (same-key-types? Ds Rs Type) (rules-check Rules Ds Rs Type)
                          "derived relations need the same key type")
            (if (= Reason []) [Rs Rules Ds Type] [sequential Reason])))))

(define check
  Name -> (let Checked (inspect Name)
            (if (= (hd Checked) sequential)
                (error "datalog.parallel: ~A" (hd (tl Checked))) Checked)))

(define key-values
  [] _ _ Acc -> Acc
  [V | Vs] Type Seen Acc ->
    (key-values Vs Type Seen
      (if (and (= (datalog.value-type V) Type)
               (= (datalog.dict-find Seen V) []))
          (do (shen.dict-> Seen V true) [V | Acc]) Acc)))

(define keys
  [] _ _ Acc -> (reverse Acc)
  [[_ | Vs] | Fs] Type Seen Acc ->
    (keys Fs Type Seen (key-values Vs Type Seen Acc)))

(define prepare
  Checked Facts ->
    (let Rs (hd Checked) Rules (datalog.nth 2 Checked)
         Ds (datalog.nth 3 Checked) Type (datalog.nth 4 Checked)
         _ (map (/. F (datalog.check-fact Rs [] F)) Facts)
         Seen (shen.dict 64)
         Constants (map (/. R (hd (tl (hd R)))) Rules)
         Keys (keys Facts Type Seen (key-values Constants Type Seen []))
      [Rs Rules Ds Facts Keys]))

(define open-workers
  Prepared Input Count Image Body ->
    (parallel.with-workers Image worker Count
      (parallel.config 16777216 536870912 Input)
      (/. Raw (Body (address-> (address-> (address-> (address-> (absvector 4)
                        0 Raw) 1 (hd Prepared)) 2 (datalog.nth 3 Prepared)) 3 [])))))

(define with-workers
  Name Facts Count Image Body ->
    (let _ (parallel.check-count Count) Prepared (prepare (check Name) Facts)
         Input (parallel.encode (append Prepared [Count]) 67108864)
      (open-workers Prepared Input Count Image Body)))

(define owned
  [] _ _ _ Acc -> (reverse Acc)
  [K | Ks] Count Index At Acc ->
    (owned Ks Count Index (+ At 1)
      (if (= (shen.mod At Count) Index) [K | Acc] Acc)))

(define keep-facts
  [] _ _ Acc -> Acc
  [[Rel | Vs] | Fs] Derived Owned Acc ->
    (keep-facts Fs Derived Owned
      (if (or (not (element? Rel Derived))
              (cons? (datalog.dict-find Owned (hd Vs))))
          [[Rel | Vs] | Acc] Acc)))

(define init
  [Rs Rules Ds Facts Keys Count] ->
    (let Mine (owned Keys Count (parallel.index) 0 [])
         Owned (shen.dict 64) _ (map (/. K (shen.dict-> Owned K true)) Mine)
         Type (hd (tl (assoc (hd Ds) Rs)))
         Items (append (map (/. R [relation (hd R) (tl R)]) Rs)
           [[relation partition-key [Type]] |
            (map (/. R [rule (hd R) [[partition-key (hd (tl (hd R)))] | (hd (tl R))]]) Rules)])
         _ (datalog.define program Items)
         _ (set *derived* Ds)
         _ (set *owned* Owned)
         _ (set *reply-limit* (/ (- 67108864 (shen.mod 67108864 Count)) Count))
         Input (append (map (/. K [partition-key K]) Mine)
                       (keep-facts Facts Ds Owned []))
      (set *state* [Rs Input []])))

(define worker-counts
  Db Rs -> (map (/. R (datalog.count Db (hd R))) Rs))

(define query-here?
  [Rel Key | _] ->
    (if (element? Rel (value *derived*))
        (or (= (datalog.value-type Key) none)
            (cons? (datalog.dict-find (value *owned*) Key)))
        (= (parallel.index) 0)))

(define worker-run
  [0] ->
    (rebuild (hd (value *state*)) (datalog.nth 2 (value *state*)))
  [1 Rel Start End] ->
    (let Db (datalog.nth 3 (value *state*))
         Rec (datalog.relation-of Db Rel)
         _ (require (and (<= Start End) (<= End (<-address Rec 6))) "invalid tuple range")
      (datalog.read-tuples Start End (<-address Rec 2) (<-address Rec 7)
        (datalog.types-of program Rel) [(datalog.nth 3 Db)] []))
  [2 I Start End] ->
    (let Rel (hd (datalog.nth I (hd (value *state*))))
         Rec (datalog.relation-of (datalog.nth 3 (value *state*)) Rel)
         Stride (<-address Rec 7)
         _ (require (and (>= Start 0) (<= Start End) (<= End (<-address Rec 6))) "invalid tuple range")
      (buffer.make (<-address Rec 2) (* Start Stride) (* End Stride)))
  [3 Start End] ->
    (let Db (datalog.nth 3 (value *state*)) Values (<-address (datalog.nth 3 Db) 0)
         _ (require (and (>= Start 0) (<= Start End)
                         (<= End (shen.dict-count (datalog.nth 4 Db)))) "invalid vocabulary range")
      (vocabulary Values Start End 22 []))
  [5 Pattern] ->
    (if (query-here? Pattern)
        (datalog.match (datalog.nth 3 (value *state*)) Pattern) [])
  [6 Fact] ->
    (if (query-here? Fact)
        (datalog.holds? (datalog.nth 3 (value *state*)) Fact) false)
  [7 Patterns] -> (map (/. Q (worker-run [5 Q])) Patterns)
  [4] ->
    (let Db (datalog.nth 3 (value *state*)) Rs (hd (value *state*))
      [(shen.dict-count (datalog.nth 4 Db)) (datalog.nth 5 Db) (datalog.nth 6 Db)
       (value datalog.*merges*) |
       (map (/. R (let Rec (datalog.relation-of Db (hd R))
                     [(datalog.count-of Rec) (<-address Rec 7)
                      (shen-jit.s64 (<-address Rec 4) 24)
                      (map (/. M [(hd M) (tl M)]) (<-address Rec 9))])) Rs)]))

\\ Pass only the schema and facts across the tail call, so neither a local
\\ state record nor the global keeps the previous database alive during run.
(define rebuild
  Rs Facts ->
    (let _ (set *state* [Rs Facts []])
         Db (datalog.run program Facts)
         _ (set *state* [Rs Facts Db])
      (worker-counts Db Rs)))

(define worker
  Request ->
    (let _ (if (= (value *state*) [])
               (let Shared (parallel.shared)
                 (init (parallel.decode-bytes Shared (parallel.shared-length Shared)))) true)
         Result (worker-run (parallel.decode (buffer.wrap Request)))
      (parallel.reply (if (buffer.view? Result) Result (parallel.encode Result (value *reply-limit*))))))

\\ Interned vocabulary consists only of numbers, strings and symbols.
\\ Sizes exclude the packet header and require no codec state or list walk.
(define vocabulary-size
  V -> 9 where (number? V)
  V -> (+ 5 (shen-jit.bytes-length (shen-jit.string->bytes V))) where (string? V)
  V -> (+ 5 (shen-jit.bytes-length (shen-jit.string->bytes (str V)))))

\\ [Next | Values] starts with an 8-byte header, 5-byte list and 9-byte cursor.
\\ Each worker advances its own cursor because text lengths differ by shard.
(define vocabulary
  _ I End _ Acc -> [I | (reverse Acc)] where (= I End)
  Values I End Used Acc ->
    (let V (<-vector Values (+ I 1)) Size (vocabulary-size V)
         Next (+ Used Size)
         Limit (if (= Acc []) (value *reply-limit*) (minimum 1048576 (value *reply-limit*)))
      (if (> Next Limit)
          (do (require (cons? Acc) "vocabulary value exceeds worker reply budget")
              [I | (reverse Acc)])
          (vocabulary Values (+ I 1) End Next [V | Acc]))))

(define requests
  0 _ -> []
  N Packet -> [Packet | (requests (- N 1) Packet)])

(define sum-column
  [] _ -> 0
  [Row | Rows] I -> (+ (datalog.nth I Row) (sum-column Rows I)))

(define counts
  [] _ _ _ -> []
  [[Rel | _] | Rs] Derived Rows I ->
    [[Rel (if (element? Rel Derived) (sum-column Rows I) (datalog.nth I (hd Rows)))] |
     (counts Rs Derived Rows (+ I 1))])

(define evaluate
  Scope ->
    (let Raw (<-address Scope 0)
         Rows (map (function parallel.decode)
                (parallel.batch Raw (requests (parallel.count Raw) (parallel.encode [0] 64))))
         _ (address-> Scope 3 Rows)
      (counts (<-address Scope 1) (<-address Scope 2) Rows 1)))

(define chunk-requests
  [] _ _ _ -> []
  [Row | Rows] Rel I Start ->
    (let N (datalog.nth I Row) From (if (< Start N) Start N)
         End (if (< (+ From 256) N) (+ From 256) N)
      [(parallel.encode [1 Rel From End] 1024) | (chunk-requests Rows Rel I Start)]))

(define max-count
  [] _ Acc -> Acc
  [Row | Rows] I Acc ->
    (let N (datalog.nth I Row) (max-count Rows I (if (> N Acc) N Acc))))

\\ Flatten exactly one level: tuples themselves are lists.
(define concat
  [] -> []
  [Xs | Xss] -> (append Xs (concat Xss)))

(define scope-tuples
  Scope Rel ->
    (fold-tuples Scope Rel (/. Acc Tuples (append Tuples Acc)) []))

\\ Export/check large results without retaining a second copy of the database.
(define fold-chunks
  _ _ _ _ Start End _ Acc -> Acc where (>= Start End)
  Raw Rel I Rows Start End F Acc ->
    (let Replies (parallel.batch Raw (chunk-requests Rows Rel I Start))
         Next (fold-replies Replies F Acc)
      (fold-chunks Raw Rel I Rows (+ Start 256) End F Next)))

(define fold-replies
  [] _ Acc -> Acc
  [Reply | Replies] F Acc ->
    (fold-replies Replies F (F Acc (parallel.decode Reply))))

(define fold-tuples
  Scope Rel F Acc ->
    (let Rs (<-address Scope 1) Raw (<-address Scope 0) Rows (<-address Scope 3)
         _ (require (cons? Rows) "evaluate before requesting tuples")
         _ (require (cons? (assoc Rel Rs)) "unknown relation")
         I (datalog.relation-slot Rel Rs)
         Counts (if (element? Rel (<-address Scope 2)) Rows
                    [(hd Rows) | (map (/. R (map (/. X 0) R)) (tl Rows))])
      (fold-chunks Raw Rel I Counts 0 (max-count Counts I 0) F Acc)))

\\ Planning is conservative. Invalid/unknown programs still raise; a checked
\\ program outside the partitioned subset has an ordinary sequential plan.
(define plan
  Name -> (let Checked (inspect Name)
            (if (= (hd Checked) sequential) Checked
                [parallel (datalog.nth 4 Checked) (datalog.nth 3 Checked)])))

(define run
  Name Facts Image Count ->
    (with-db Name Facts Image Count (function materialize)))

(define with-db
  Name Facts Image Count Body ->
    (let _ (parallel.check-count Count)
         _ (require (string? Image) "the worker image must be a path string")
      (if (= Count 1) (serial-body Name Facts Body)
          (let Checked (inspect Name)
            (if (= (hd Checked) sequential) (serial-body Name Facts Body)
                (with-selected Name Facts Image Count Body Checked))))))

(define with-selected
  Name Facts Image Count Body Checked ->
    (let Prepared (prepare Checked Facts) N (length (datalog.nth 5 Prepared))
         P (if (< N Count) N Count)
         \\ Encoding has no worker effects. A packet that cannot be represented
         \\ within the codec bounds uses the serial engine.
         Input (if (> P 1) (parallel.try-encode (append Prepared [P]) 67108864) [])
      (if (= Input []) (serial-body Name Facts Body)
          (open-workers Prepared Input P Image
            (/. Scope (do (evaluate Scope)
                         (call-body (view.make Name Facts Scope (parallel.shared) true) Body)))))))

(define count
  D Rel ->
    (let V (view-check D) S (view.source V)
      (if (= (view.shared V) []) (datalog.count S Rel)
          (let E (assoc Rel (counts (<-address S 1) (<-address S 2) (<-address S 3) 1))
            (if (cons? E) (hd (tl E)) (error "datalog: no relation ~A" Rel))))))

(define match
  D Pattern ->
    (let V (view-check D)
      (if (= (view.shared V) []) (datalog.match (view.source V) Pattern)
          (concat (rpc (view.source V) [5 Pattern])))))

\\ Keep query order, combining each query's disjoint shard answers.
(define combine-matches
  [[] | _] -> []
  Replies -> [(concat (map (function hd) Replies)) |
              (combine-matches (map (function tl) Replies))])

(define match-many
  D Patterns ->
    (let V (view-check D) N (parallel.value-count Patterns 4096 0)
      (if (= N 0) []
          (if (= (view.shared V) [])
              (map (/. Q (datalog.match (view.source V) Q)) Patterns)
              (combine-matches (rpc (view.source V) [7 Patterns]))))))

(define any-true?
  [] -> false
  [true | _] -> true
  [_ | Rest] -> (any-true? Rest))

(define holds?
  D Fact ->
    (let V (view-check D)
      (if (= (view.shared V) []) (datalog.holds? (view.source V) Fact)
          (any-true? (rpc (view.source V) [6 Fact])))))

(define tuples
  D Rel ->
    (let V (view-check D)
      (if (= (view.shared V) []) (datalog.tuples (view.source V) Rel)
          (scope-tuples (view.source V) Rel))))

\\ Finish reading through the view before taking a mutable normal database.
\\ Consuming the view also keeps serial fallback's alias behavior identical.
(define materialize
  D ->
    (let V (view-check D)
         Db (if (= (view.shared V) []) (view.source V)
                (collect-db (view.name V) (view.facts V) (view.source V)))
         _ (view.active-> V false)
      Db))

(define rpc
  Scope Request ->
    (let Raw (<-address Scope 0)
      (map (function parallel.decode)
        (parallel.batch Raw (requests (parallel.count Raw) (parallel.encode Request 1048576))))))

\\ Build only the parent's initial facts. Its normal relation records,
\\ interner, fact history and program name will also serve future queries
\\ and incremental add/remove, after workers have joined.
(define initial-db
  Name Facts ->
    (let P (datalog.program Name) Rs (datalog.nth 3 P) Interned (shen.dict 8)
         _ (set datalog.*fresh* []) _ (datalog.intern-all (datalog.nth 5 P) Interned)
         S (datalog.new-state Rs [] Interned [] [])
         _ (datalog.load-facts Facts Rs S Interned [] [])
         _ (set datalog.*fresh* []) _ (address-> S 0 (datalog.values-vector Interned))
         _ (datalog.merge-state S 1 (length Rs))
      [db Name S Interned 0 0 Facts]))

(define minimum
  A B -> (if (< A B) A B))

(define max-info
  [] _ N -> N
  [I | Is] Field N -> (max-info Is Field (datalog.max N (datalog.nth Field I))))

(define sum-info
  [] _ -> 0
  [I | Is] Field -> (+ (datalog.nth Field I) (sum-info Is Field)))

(define nonintegers?
  [] _ -> false
  [R | Rs] Schemas ->
    (or (not (every-integer? (tl (assoc R Schemas)))) (nonintegers? Rs Schemas)))

(define every-integer?
  [] -> true
  [integer | Ts] -> (every-integer? Ts)
  _ -> false)

(define vocab-requests
  [] [] -> []
  [Info | Infos] [Start | Starts] ->
    (let N (hd Info) From (minimum Start N) End (minimum (+ From 256) N)
      [(parallel.encode [3 From End] 1024) | (vocab-requests Infos Starts)]))

(define intern-vocabulary
  [] _ _ _ -> true
  [V | Vs] Interned Map I ->
    (do (shen-jit.u32! Map (* I 4) (received-id V Interned))
        (intern-vocabulary Vs Interned Map (+ I 1))))

\\ Collection rebuilds the values vector once, so it need not populate the
\\ evaluator's global fresh-value log (which could retain values on failure).
(define received-id
  V Interned ->
    (let Entry (datalog.dict-find Interned V)
      (if (cons? Entry) (tl Entry)
          (let Id (shen.dict-count Interned) _ (shen.dict-> Interned V Id) Id))))

(define fill-vocabulary
  [] [] [] _ [] -> []
  [[Next | Values] | More] [Map | Maps] [Info | Infos] Interned [Start | Starts] ->
    (let End (minimum (+ Start 256) (hd Info))
         _ (require (and (integer? Next) (<= Start Next) (<= Next End)
                         (= (length Values) (- Next Start))
                         (or (= Start End) (> Next Start))) "invalid vocabulary reply")
         _ (intern-vocabulary Values Interned Map Start)
      [Next | (fill-vocabulary More Maps Infos Interned Starts)]))

(define vocabulary-done?
  [] [] -> true
  [Info | Infos] [Start | Starts] ->
    (and (= Start (hd Info)) (vocabulary-done? Infos Starts)))

(define collect-vocabulary
  Raw Infos Maps Interned Starts ->
    (if (vocabulary-done? Infos Starts) true
        (let Values (map (function parallel.decode) (parallel.batch Raw (vocab-requests Infos Starts)))
             Next (fill-vocabulary Values Maps Infos Interned Starts)
          (collect-vocabulary Raw Infos Maps Interned Next))))

\\ Only noninteger columns use this map; each runtime interns by its own
\\ encounter order. Integers remain signed 32-bit words without translation.
(define-native remap (B Lookup Flags Stride Rows Width)
  (for I 0 Rows
    (word Base (* I Stride))
    (for J 0 Width
      (when (= (u8 Flags J) 1)
        (word At (+ Base (* J 4)))
        (word Old (u32 B At))
        (u32! B At (u32 Lookup (* Old 4))))))
  (return-word 0))

(define flags
  Types -> (let B (shen-jit.bytes (length Types)) _ (fill-flags B Types 0) B))

(define fill-flags
  _ [] _ -> true
  B [T | Ts] I -> (do (shen-jit.u8! B I (if (= T integer) 0 1)) (fill-flags B Ts (+ I 1))))

(define tuple-requests
  [] _ _ _ -> []
  [Meta | Metas] Rel Start Step ->
    (let From (minimum Start (hd Meta)) End (minimum (+ From Step) (hd Meta))
      [(parallel.encode [2 Rel From End] 1024) | (tuple-requests Metas Rel Start Step)]))

(define copy-replies
  [] [] [] _ _ _ _ _ _ -> true
  [View | Views] [Meta | Metas] [Map | Maps] Out Flags Width Stride Start Offset ->
    (let From (minimum Start (hd Meta)) Size (buffer.length View)
         Expected (minimum (* (- (hd Meta) From) Stride) (- 1048576 (shen.mod 1048576 Stride)))
         _ (require (= Size Expected) "invalid tuple reply length")
         B (parallel.bytes View)
         _ (if (and (> Size 0) (not (= Flags []))) (remap B Map Flags Stride (/ Size Stride) Width) true)
         _ (if (> Size 0) (shen-jit.copy-bytes Out (* (+ Offset From) Stride) B 0 Size) true)
      (copy-replies Views Metas Maps Out Flags Width Stride Start (+ Offset (hd Meta)))))

(define copy-tuples
  _ _ _ _ _ _ _ _ Start End _ -> true where (>= Start End)
  Raw Metas Maps Rel Out Flags Width Stride Start End Step ->
    (let Replies (parallel.batch Raw (tuple-requests Metas Rel Start Step))
         _ (copy-replies Replies Metas Maps Out Flags Width Stride Start 0)
      (copy-tuples Raw Metas Maps Rel Out Flags Width Stride (+ Start Step) End Step)))

(define merge-history
  [] _ _ Acc -> Acc
  [Meta | Metas] Base Offset Acc ->
    (merge-history Metas Base (+ Offset (hd Meta))
      (append (map (/. M [(+ Base (hd M)) | (+ Offset (hd (tl M)))]) (datalog.nth 4 Meta)) Acc)))

(define collect-relation
  Rel Types Scope Infos Maps Base ->
    (let Rs (<-address Scope 1) I (datalog.relation-slot Rel Rs)
         Metas (map (/. Info (datalog.nth (+ I 4) Info)) Infos)
         N (sum-info Metas 1) Width (length Types) Stride (datalog.stride Width)
         _ (require (< N 4294967295) "relation exceeds tuple position limit")
         _ (map (/. M (require (= (datalog.nth 2 M) Stride) "invalid tuple stride")) Metas)
         Rec (datalog.new-relation Width false) Fits (datalog.max 8 N)
         Meta (<-address Rec 4)
         Out (shen-jit.bytes (* Fits Stride))
         _ (address-> Rec 2 Out) _ (shen-jit.s64! Meta 0 N)
         _ (shen-jit.s64! Meta 16 Fits)
         _ (shen-jit.s64! Meta 24 (sum-info Metas 3))
         _ (address-> Rec 5 N) _ (address-> Rec 6 N)
         _ (address-> Rec 9 (merge-history Metas Base 0 []))
         Flags (if (every-integer? Types) [] (flags Types))
         Step (/ (- 1048576 (shen.mod 1048576 Stride)) Stride)
         _ (require (> Step 0) "tuple exceeds packet limit")
         _ (copy-tuples (<-address Scope 0) Metas Maps I Out Flags Width Stride
                       0 (max-info Metas 1 0) Step)
         \\ The existing full-column index kernel builds the same fingerprint
         \\ table as insertion. Partitions guarantee all copied tuples differ.
         Index (datalog.new-index Width (datalog.upto 1 Width) N)
         _ (datalog.index-range Rec Index 0 N)
         _ (require (= (datalog.index.keys Index) N) "duplicate partitioned tuples")
         _ (address-> Rec 3 (datalog.index.table Index))
         _ (shen-jit.s64! Meta 8 (datalog.index.mask Index))
      Rec))

(define collect-db
  Name Facts Scope ->
    (let Infos (rpc Scope [4]) Db (initial-db Name Facts)
         S (datalog.nth 3 Db) Interned (datalog.nth 4 Db)
         Rs (<-address Scope 1) Ds (<-address Scope 2) Base (value datalog.*merges*)
         Translate (nonintegers? Ds Rs)
         Maps (map (/. Info (shen-jit.bytes (if Translate (* 4 (hd Info)) 0))) Infos)
         _ (if Translate (collect-vocabulary (<-address Scope 0) Infos Maps Interned
                               (map (/. Info 0) Infos)) true)
         _ (map (/. R (address-> S (datalog.relation-slot R Rs)
                         (collect-relation R (tl (assoc R Rs)) Scope Infos Maps Base))) Ds)
         _ (address-> S 0 (datalog.values-vector Interned))
         _ (set datalog.*fresh* [])
         _ (set datalog.*merges* (+ Base (max-info Infos 4 0)))
      [db Name S Interned (max-info Infos 2 0) (sum-info Infos 3) Facts]))

)
