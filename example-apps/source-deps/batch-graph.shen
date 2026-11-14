\\ The call graph as integer adjacency, forward and reverse, in one byte buffer, which a batch's
\\ isolates read shared, and the BFS each query runs over it. Requires buffer.shen, under tc-.

(define sdg.count
  _ End End _ _ _ -> true
  Edges At End Forward Reverse Nodes ->
    (let X (shen-jit.u32 Edges At) Y (shen-jit.u32 Edges (+ At 4))
         _ (if (and (< X Nodes) (< Y Nodes)) true (error "batch: invalid edge"))
         _ (shen-jit.u32! Forward (* X 4) (+ 1 (shen-jit.u32 Forward (* X 4))))
         _ (shen-jit.u32! Reverse (* Y 4) (+ 1 (shen-jit.u32 Reverse (* Y 4))))
      (sdg.count Edges (+ At 8) End Forward Reverse Nodes)))

(define sdg.offsets
  Graph Base _ End End Total -> (shen-jit.u32! Graph (+ Base (* End 4)) Total)
  Graph Base Cursor At End Total ->
    (let N (shen-jit.u32 Cursor (* At 4))
         _ (shen-jit.u32! Graph (+ Base (* At 4)) Total)
         _ (shen-jit.u32! Cursor (* At 4) Total)
      (sdg.offsets Graph Base Cursor (+ At 1) End (+ Total N))))

(define sdg.fill
  _ End End _ _ _ _ _ -> true
  Edges At End Graph F R FD RD ->
    (let X (shen-jit.u32 Edges At) Y (shen-jit.u32 Edges (+ At 4))
         FI (shen-jit.u32 F (* X 4)) RI (shen-jit.u32 R (* Y 4))
         _ (shen-jit.u32! Graph (+ FD (* FI 4)) Y)
         _ (shen-jit.u32! Graph (+ RD (* RI 4)) X)
         _ (shen-jit.u32! F (* X 4) (+ FI 1))
         _ (shen-jit.u32! R (* Y 4) (+ RI 1))
      (sdg.fill Edges (+ At 8) End Graph F R FD RD)))

(define sdg.build
  Nodes Edges ->
    (let Bytes (shen-jit.bytes-length Edges)
         RO (+ 64 (* 4 (+ Nodes 1))) FD (+ RO (* 4 (+ Nodes 1)))
         RD (+ FD (/ Bytes 2)) Size (+ RD (/ Bytes 2))
         _ (if (and (integer? Nodes) (>= Nodes 0) (= (shen.mod Bytes 8) 0)
                    (<= Size 67108864)) true (error "batch: invalid graph size"))
         Graph (shen-jit.bytes Size) F (shen-jit.bytes (* Nodes 4)) R (shen-jit.bytes (* Nodes 4))
         _ (shen-jit.u32! Graph 8 Nodes) _ (shen-jit.u32! Graph 12 (/ Bytes 8))
         _ (shen-jit.u32! Graph 16 64) _ (shen-jit.u32! Graph 20 RO)
         _ (shen-jit.u32! Graph 24 FD) _ (shen-jit.u32! Graph 28 RD)
         _ (shen-jit.u32! Graph 32 Size)
         _ (sdg.count Edges 0 Bytes F R Nodes)
         _ (sdg.offsets Graph 64 F 0 Nodes 0) _ (sdg.offsets Graph RO R 0 Nodes 0)
         _ (sdg.fill Edges 0 Bytes Graph F R FD RD)
      Graph))

\\ A node is marked when enqueued. The root is not premarked: a positive-length
\\ cycle includes it, just as the Datalog walk does. Every node is queued once.
(define sdg.neighbors
  _ _ End End _ _ Tail _ -> Tail
  G Base At End Seen Queue Tail Nodes ->
    (let Y (shen-jit.u32 G (+ Base (* At 4)))
         _ (if (< Y Nodes) true (error "batch: corrupt neighbor"))
         Next (if (= (shen-jit.u8 Seen Y) 0)
                  (do (shen-jit.u8! Seen Y 1) (shen-jit.u32! Queue (* Tail 4) Y) (+ Tail 1)) Tail)
      (sdg.neighbors G Base (+ At 1) End Seen Queue Next Nodes)))

(define sdg.visit
  G Rows Base Node Seen Queue Tail Nodes ->
    (let Start (shen-jit.u32 G (+ Rows (* Node 4))) Stop (shen-jit.u32 G (+ Rows (* (+ Node 1) 4)))
         _ (if (and (<= Start Stop) (<= Stop (shen-jit.u32 G 12))) true
               (error "batch: corrupt row"))
      (sdg.neighbors G Base Start Stop Seen Queue Tail Nodes)))

(define sdg.bfs
  _ _ _ _ _ Head Head _ -> Head
  G Rows Base Seen Queue Head Tail Nodes ->
    (let Next (sdg.visit G Rows Base (shen-jit.u32 Queue (* Head 4)) Seen Queue Tail Nodes)
      (sdg.bfs G Rows Base Seen Queue (+ Head 1) Next Nodes)))

(define sdg.sorted
  _ End End Out _ -> Out
  Seen At End Out Pos ->
    (let Next (if (= (shen-jit.u8 Seen At) 0) Pos
                  (do (shen-jit.u32! Out Pos At) (+ Pos 4)))
      (sdg.sorted Seen (+ At 1) End Out Next)))

\\ The sorted IDs a query reaches, as u32s.
(define sdg.query
  G Mode Root ->
    (let N (shen-jit.u32 G 8)
         _ (if (and (element? Mode [0 1]) (< Root N)) true (error "batch: invalid query"))
         Rows (shen-jit.u32 G (if (= Mode 0) 16 20))
         Base (shen-jit.u32 G (if (= Mode 0) 24 28))
         Seen (shen-jit.bytes N) Queue (shen-jit.bytes (* N 4))
         Tail (sdg.visit G Rows Base Root Seen Queue 0 N)
         Count (sdg.bfs G Rows Base Seen Queue 0 Tail N)
      (sdg.sorted Seen 0 N (shen-jit.bytes (* Count 4)) 0)))
