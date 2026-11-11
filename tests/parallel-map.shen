(set pm.passed 0)
(set pm.failed 0)
(define pm.check
  Name true -> (set pm.passed (+ (value pm.passed) 1))
  Name false -> (do (output "FAIL ~A~%" Name) (set pm.failed (+ (value pm.failed) 1))))
(define pm.error?
  Code -> (trap-error (do (thaw Code) false) (/. E true)))
(define pm.exact?
  A B -> (buffer.equal? (parallel.encode A 67108864) (parallel.encode B 67108864)))
(define pm.real
  High Low -> (let B (shen-jit.bytes 8) _ (shen-jit.u32! B 0 Low) _ (shen-jit.u32! B 4 High)
                (shen-jit.f64 B 0)))
(define pm.nest
  0 X -> X
  N X -> [(pm.nest (- N 1) X)])
(define pm.repeat
  0 _ Rest -> Rest
  N X Rest -> (pm.repeat (- N 1) X [X | Rest]))
(define pm.scope
  Name P Body -> (parallel.with-map (value pt.image) Name P (pt.config) Body))

(set pm.values [true false [] 0 1 -7 9007199254740993 2305843009213693951 -2305843009213693952
                (pm.real 1072693248 0) (pm.real 2147483648 0) (pm.real 2146435072 0)
                (pm.real 4293918720 0) (pm.real 2146959361 17) (pm.real 2146435072 1)
                (pm.real 0 1) "" "c#99;afé λc#0;tail" alpha (intern "hello world") (intern "")
                (intern "pm.echo") [nested [true false] [] [1 2 3]]])
(map (/. X (pm.check "exact scalar/list codec round trip"
             (pm.exact? X (parallel.decode (parallel.encode X 1048576))))) (value pm.values))
(let V (parallel.encode [true 7] 1048576) B (buffer.owner V)
  (pm.check "independent codec field positions"
    (and (= (buffer.length V) 23) (= (shen-jit.u32 B 0) 1347240241)
         (= (shen-jit.u32 B 4) 1) (= (shen-jit.u8 B 8) 7) (= (shen-jit.u32 B 9) 2)
         (= (shen-jit.u8 B 13) 2) (= (shen-jit.u8 B 14) 3) (= (shen-jit.s64 B 15) 7))))
(let Nested (pm.nest 64 1)
  (pm.check "codec nested boundary" (pm.exact? Nested (parallel.decode (parallel.encode Nested 1048576)))))
(pm.check "codec nesting rejected" (pm.error? (freeze (parallel.encode (pm.nest 65 1) 1048576))))
(let Flat (pm.repeat 1024 11 [])
  (pm.check "flat lists do not consume nesting depth" (pm.exact? Flat (parallel.decode (parallel.encode Flat 1048576)))))
(pm.check "exact byte limit" (= (buffer.length (parallel.encode "abc" 16)) 16))
(pm.check "text byte limit" (pm.error? (freeze (parallel.encode "abcd" 16))))
(pm.check "minimum codec budget" (pm.error? (freeze (parallel.encode [] 8))))
(map (/. X (pm.check "reject mutable/opaque/closure values"
             (pm.error? (freeze (parallel.encode X 1048576)))))
     [(vector 1) (shen-jit.bytes 1) (buffer.new 1) (freeze 1) (stoutput) [1 | 2]])
(map (/. Cut
       (let Good (parallel.encode [1 "hi"] 1048576)
         (pm.check "truncated packet"
           (pm.error? (freeze (parallel.decode (buffer.slice Good 0 Cut))))))) [0 8 9 13 17 25])
(map (/. Case
       (let B (parallel.bytes (parallel.encode [1] 1048576))
            _ (cond ((= Case 0) (shen-jit.u32! B 0 0))
                    ((= Case 1) (shen-jit.u32! B 4 99))
                    ((= Case 2) (shen-jit.u8! B 8 255))
                    (true (shen-jit.u32! B 9 262144)))
         (pm.check "malformed header/tag/node count"
           (pm.error? (freeze (parallel.decode (buffer.wrap B))))))) [0 1 2 3])
(let B (buffer.new 10) Good (parallel.encode [] 1048576)
     _ (buffer.copy! B 0 Good 0 9)
  (pm.check "trailing byte rejected" (pm.error? (freeze (parallel.decode B)))))

\\ The type checker describes supported values; entries are resolved in the child image.
(tc +)
(define pm.typed-map
  {parallel.map-scope --> [list parallel.value]}
  Scope -> (parallel.map Scope [1 true "hello" tag [1 2]]))
(tc -)
(tc +)
(define pm.typed-fixnum {number --> boolean} X -> (shen-jit.fixnum? X))
(define pm.typed-number {parallel.value --> number} X -> (parallel.number X))
(define pm.typed-boolean {parallel.value --> boolean} X -> (parallel.boolean X))
(define pm.typed-string {parallel.value --> string} X -> (parallel.string X))
(define pm.typed-symbol {parallel.value --> symbol} X -> (parallel.symbol X))
(define pm.typed-list {parallel.value --> [list parallel.value]} X -> (parallel.list X))
(tc -)
(pm.check "explicit fixnum representation"
  (and (pm.typed-fixnum 7) (not (pm.typed-fixnum (pm.real 1072693248 0)))
       (not (pm.typed-fixnum (pm.real 2147483648 0)))))
(pm.check "checked value accessors"
  (and (= (pm.typed-number 7) 7) (= (pm.typed-boolean false) false)
       (= (pm.typed-string "ok") "ok") (= (pm.typed-symbol tag) tag)
       (= (pm.typed-list [1 "two" [true]]) [1 "two" [true]])))
(map (/. F (pm.check "checked scalar rejects wrong type" (pm.error? (freeze (F [])))))
     [(function parallel.number) (function parallel.boolean)
      (function parallel.string) (function parallel.symbol)])
(map (/. X (pm.check "checked list rejects unsupported structure"
             (pm.error? (freeze (parallel.list X))))) [7 [1 | 2] [(vector 1)]])
(pm.check "namespace extends base exports and preserves system names"
  (= (read-from-string
       "(shen.x.namespace pm.ns (use parallel => p) (define f X -> (p.map (p.with-workers X X X X X) (p.number X))))")
     [[define pm.ns.f X -> [parallel.map [parallel.with-workers X X X X X] [parallel.number X]]]]))
(map (/. X (let Encoded (parallel.encode X 1048576)
             (pm.check "size preflight matches encoding"
               (= (parallel.encoded-size X 1048576) (buffer.length Encoded))))) (value pm.values))
(pm.check "bounds probe propagates other errors"
  (pm.error? (freeze (parallel.text-fits? 7 0))))
(pm.check "fixnum predicate is registered as a first-class function"
  (and (= (arity shen-jit.fixnum?) 1)
       ((fn shen-jit.fixnum?) 7)
       (not ((fn shen-jit.fixnum?) "seven"))))
(pm.check "size boundary accepted" (= (parallel.encoded-size "abc" 16) 16))
(pm.check "oversize is an explicit refusal" (= (parallel.try-encode "abcd" 16) []))
(pm.check "depth limit is an explicit refusal" (= (parallel.try-encode (pm.nest 65 1) 1048576) []))
(pm.check "unsupported values still raise"
  (pm.error? (freeze (parallel.try-encode [(vector 1)] 1048576))))
(pm.check "invalid budgets still raise" (pm.error? (freeze (parallel.try-encode [] 8))))
(pm.check "proper-list errors still raise" (pm.error? (freeze (parallel.try-encode [1 | 2] 1048576))))
(let V (parallel.encode [17 "shared" [true]] 1048576)
     Result (parallel.with-workers (value pt.image) (intern "pt.worker") 1
               (parallel.config 16777216 67108864 V)
               (/. Scope (let Shared (parallel.shared)
                            (parallel.decode-bytes Shared (parallel.shared-length Shared)))))
  (pm.check "decode directly from immutable shared bytes" (= Result [17 "shared" [true]])))
(let V (parallel.encode [] 1048576)
  (pm.check "direct decoder rejects length beyond storage"
    (pm.error? (freeze (parallel.decode-bytes (buffer.owner V) 67108865)))))
(map (/. P
       (let Results (pm.scope (intern "pm.echo") P
                       (/. Scope
                         (do (set pm.escaped Scope)
                             (pm.check "empty map" (= (parallel.map Scope []) []))
                             (pm.check "fewer jobs than workers" (= (parallel.map Scope [only]) [only]))
                             (pm.check "typed map" (= (pm.typed-map Scope) [1 true "hello" tag [1 2]]))
                             (parallel.map Scope (value pm.values)))))
            _ (shen-jit.collect)
         (do (pm.check "ordered exact values survive joins and collection" (pm.exact? Results (value pm.values)))
             (pm.check "escaped map scope, including empty inputs"
               (pm.error? (freeze (parallel.map (value pm.escaped) []))))))) [1 2 3 4 5 8])
(pm.scope (intern "pm.counter") 1
  (/. S (do (pm.check "named function runs in a reused private runtime" (= (parallel.map S [[] []]) [1 2]))
            (pm.check "second batch retains worker state" (= (parallel.map S [[]]) [3]))
            (pm.check "preflight rejects an unsupported later value"
              (pm.error? (freeze (parallel.map S [[] (vector 1)]))))
            (pm.check "invalid inputs did not dispatch any jobs" (= (parallel.map S [[]]) [4]))
            (pm.check "request byte limit"
              (pm.error? (freeze (parallel.map S [(buffer.string (buffer.new 1048576))]))))
            (pm.check "oversized input did not dispatch a job" (= (parallel.map S [[]]) [5])))))
(let Results (pm.scope (intern "pm.where") 4 (/. S (parallel.map S [a b c d e f g h])))
  (pm.check "real worker placement and shared snapshot"
    (= Results [[0 1977 a] [0 1977 b] [1 1977 c] [1 1977 d]
                [2 1977 e] [2 1977 f] [3 1977 g] [3 1977 h]])))
(map (/. Name
       (pm.check "named-entry, child error and unsupported reply cleanup"
         (pm.error? (freeze (pm.scope Name 2 (/. S (parallel.map S [1 2 3])))))))
     [(intern "pm.missing") (intern "pm.binary") (intern "pm.zero")
      (intern "pm.fail") (intern "pm.bad-result")])
(pm.check "parent callback error joins"
  (pm.error? (freeze (pm.scope (intern "pm.echo") 2 (/. S (error "parent map failure"))))))
(pm.check "a new scope succeeds after errors"
  (= (pm.scope (intern "pm.echo") 1 (/. S (parallel.map S [[after failure]]))) [[after failure]]))
(pm.check "closures are not named entries"
  (pm.error? (freeze (pm.scope (/. X X) 1 (/. S true)))))
(pm.check "wrong map scope" (pm.error? (freeze (parallel.map [] []))))
(pm.check "too many jobs"
  (pm.error? (freeze (pm.scope (intern "pm.echo") 1 (/. S (parallel.map S (pm.repeat 4097 1 [])))))))
(pm.scope (intern "pm.echo") 1
  (/. S (pm.check "borrowed shared data cannot be sent as a value"
          (pm.error? (freeze (parallel.map S [(parallel.shared)]))))))
(output "~A passed, ~A failed (copied-value parallel map)~%" (value pm.passed) (value pm.failed))
(if (= (value pm.failed) 0) true (shen-jit.exit 1))
