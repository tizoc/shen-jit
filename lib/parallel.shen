(shen.x.namespace parallel
  (use shen-jit)
  (externals [buffer.owner buffer.offset buffer.length buffer.bytes buffer.wrap buffer.new buffer.view
              parallel.config-state parallel.scope-state])
  (shadow count)
  (export bytes config scope check-count with-workers count batch reply replies shared
          shared-length shared-u8 shared-u32 shared-copy cancelled? index)

\\ Structured workers: private runtimes, copied messages and one
\\ borrowed immutable input. Load buffer.shen first, under (tc -).

\\ A whole managed buffer needs no intermediate copy. Other views are
\\ materialized explicitly before the runtime snapshots/sends their bytes.
(define bytes
  View -> (let Owner (buffer.owner View) Start (buffer.offset View)
               Length (buffer.length View)
            (if (and (= Start 0) (= Length (shen-jit.bytes-length Owner))
                     (not (shen-jit.pointer? Owner)))
                Owner (buffer.bytes View))))

(define config
  Initial Maximum Input ->
    (address-> (address-> (address-> (address-> (absvector 4)
      0 parallel.config-state) 1 Initial) 2 Maximum) 3 (bytes Input)))

(define config-check
  C -> (if (shen-jit.tagged? C parallel.config-state) C (error "parallel: invalid configuration")))

(define check-count
  Count -> (if (and (integer? Count) (> Count 0) (<= Count 64))
               Count (error "parallel: expected an integer worker count from 1 to 64")))

(define with-workers
  Image Entry Count Config Body ->
    (let C (config-check Config)
         _ (check-count Count)
      (shen-jit.worker-scope Image Entry Count
        [(<-address C 1) (<-address C 2) (<-address C 3)]
        (/. Token (Body (address-> (address-> (address-> (absvector 3)
                          0 parallel.scope-state) 1 Token) 2 Count))))))

(define scope-check
  S -> (if (shen-jit.tagged? S parallel.scope-state) S (error "parallel: invalid scope")))

(define count
  Scope -> (<-address (scope-check Scope) 2))

\\ Exactly one request per worker. Applications can pack multiple jobs in a
\\ request, including an empty shard. Returned buffers belong to the parent.
(define batch
  Scope Requests ->
    (map (function buffer.wrap)
      (shen-jit.worker-batch (<-address (scope-check Scope) 1)
        (map (function bytes) Requests))))

(define reply
  View -> [[(buffer.owner View) (buffer.offset View) (buffer.length View)]])

(define replies
  Views -> (map (/. V [(buffer.owner V) (buffer.offset V) (buffer.length V)]) Views))

(define shared
  -> (shen-jit.worker-shared-view))

(define shared-length
  Input -> (shen-jit.bytes-length Input))

(define shared-u8
  Input Offset -> (shen-jit.u8 Input Offset))

(define shared-u32
  Input Offset -> (shen-jit.u32 Input Offset))

(define shared-copy
  Input Offset Count ->
    (let Out (buffer.new Count)
      (do (shen-jit.copy-bytes (buffer.owner Out) 0 Input Offset Count) Out)))

(define cancelled? -> (shen-jit.worker-cancelled?))
(define index -> (shen-jit.worker-index))

(declare config [number --> [number --> [buffer.view --> config]]])
(declare with-workers
  [string --> [symbol --> [number --> [config --> [[scope --> A] --> A]]]]])
(declare count [scope --> number])
(declare batch [scope --> [[list buffer.view] --> [list buffer.view]]])
(declare reply [buffer.view --> reply])
(declare replies [[list buffer.view] --> reply])
(declare shared [--> shared])
(declare shared-length [shared --> number])
(declare shared-u8 [shared --> [number --> number]])
(declare shared-u32 [shared --> [number --> number]])
(declare shared-copy [shared --> [number --> [number --> buffer.view]]])
(declare cancelled? [--> boolean])
(declare index [--> number])

)
