\\ Heap-only buffer/cursor contracts, also run by static builds.
(set buffer-test.*passed* 0)
(set buffer-test.*failed* 0)

(define buffer-test.check
  Name Expected F ->
    (let Got (trap-error (thaw F) (/. E [error (error-to-string E)]))
      (if (= Expected Got)
          (set buffer-test.*passed* (+ 1 (value buffer-test.*passed*)))
          (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
              (set buffer-test.*failed* (+ 1 (value buffer-test.*failed*)))))))

(define buffer-test.raises
  Name F -> (buffer-test.check Name true
              (freeze (trap-error (do (thaw F) false) (/. E true)))))

(buffer-test.check "zero initialization" "c#0;c#0;c#0;"
  (freeze (buffer.string (buffer.new 3))))
(buffer-test.check "empty at the end" ""
  (freeze (buffer.string (buffer.slice (buffer.from-string "abc") 3 0))))
(buffer-test.raises "negative size" (freeze (buffer.new -1)))
(buffer-test.raises "float size" (freeze (buffer.new (+ 0.5 0.5))))
(buffer-test.raises "wrong storage" (freeze (buffer.wrap "abc")))
(buffer-test.check "not a view" false (freeze (buffer.view? (absvector 0))))
(buffer-test.raises "not a view operation" (freeze (buffer.length [])))

(let B (buffer.from-string "!abcdef?") V (buffer.slice B 2 3)
  (do (buffer-test.check "logical extent" [2 5 3]
        (freeze [(buffer.offset V) (buffer.end V) (buffer.length V)]))
      (buffer-test.check "range bytes" "bcd" (freeze (buffer.string V)))
      (buffer-test.check "last byte" 100 (freeze (buffer.u8 V 2)))
      (buffer-test.raises "parent bound" (freeze (buffer.slice V 1 3)))
      (buffer-test.raises "view read bound" (freeze (buffer.u8 V 3)))
      (buffer-test.raises "negative index" (freeze (buffer.u8 V -1)))
      (buffer-test.raises "integral float index" (freeze (buffer.u8 V (+ 0.5 0.5))))
      (buffer-test.raises "negative count" (freeze (buffer.slice V 0 -1)))
      (buffer-test.raises "count overflow" (freeze (buffer.slice V 1 2305843009213693951)))
      (buffer-test.raises "invalid byte" (freeze (buffer.u8! V 1 256)))
      (buffer-test.check "failed store changes nothing" "!abcdef?" (freeze (buffer.string B)))
      (let Saved (buffer.string V) Bytes (buffer.bytes V)
        (do (buffer.u8! V 1 88)
            (buffer-test.check "shared mutation" "!abXdef?" (freeze (buffer.string B)))
            (buffer-test.check "independent string" "bcd" (freeze Saved))
            (buffer-test.check "independent bytes" "bcd"
              (freeze (buffer.string (buffer.wrap Bytes))))))
      (shen-jit.collect)
      (buffer-test.check "owner remains reachable" "bXd" (freeze (buffer.string V)))))

(let B (buffer.from-string "abcdef")
  (do (buffer.copy! B 1 B 0 5)
      (buffer-test.check "overlap to the right" "aabcde" (freeze (buffer.string B)))
      (buffer.copy! B 0 B 1 5)
      (buffer-test.check "overlap to the left" "abcdee" (freeze (buffer.string B)))
      (buffer-test.raises "copy destination range" (freeze (buffer.copy! B 2 B 0 5)))
      (buffer-test.raises "copy source range" (freeze (buffer.copy! B 0 B 2 5)))
      (buffer-test.check "failed copies change nothing" "abcdee" (freeze (buffer.string B)))
      (buffer-test.check "empty copy" true (freeze (shen-jit.same? B (buffer.copy! B 6 B 6 0))))))

(buffer-test.check "logical equality ignores owner margins" true
  (freeze (buffer.equal? (buffer.slice (buffer.from-string "!abc?") 1 3)
                         (buffer.from-string "abc"))))
(buffer-test.check "logical inequality" false
  (freeze (buffer.equal? (buffer.from-string "abc") (buffer.from-string "abd"))))
(buffer-test.check "different lengths" false
  (freeze (buffer.equal? (buffer.from-string "abc") (buffer.from-string "ab"))))
(buffer-test.check "empty equality" true
  (freeze (buffer.equal? (buffer.new 0) (buffer.slice (buffer.from-string "x") 1 0))))

(let C (cursor.new (buffer.slice (buffer.from-string "!tag=42?") 1 6))
  (do (buffer-test.check "cursor initial position" [0 1 6]
        (freeze [(cursor.position C) (cursor.offset C) (cursor.remaining C)]))
      (buffer-test.check "peek does not move" [116 0]
        (freeze [(cursor.peek C) (cursor.position C)]))
      (buffer-test.check "text and byte reads" ["tag" 61 "42" -1 -1 6]
        (freeze [(cursor.string C 3) (cursor.read C) (cursor.string C 2)
                 (cursor.read C) (cursor.read C) (cursor.position C)]))
      (cursor.seek C 1)
      (buffer-test.raises "failed capture" (freeze (cursor.string C 6)))
      (buffer-test.raises "failed skip" (freeze (cursor.skip C 6)))
      (buffer-test.raises "failed seek" (freeze (cursor.seek C 7)))
      (buffer-test.raises "float skip" (freeze (cursor.skip C (+ 0.5 0.5))))
      (buffer-test.check "failed movement leaves position" 1 (freeze (cursor.position C)))
      (let Fork (cursor.fork C)
        (do (cursor.skip Fork 2)
            (buffer-test.check "forked positions" [1 3]
              (freeze [(cursor.position C) (cursor.position Fork)]))))
      (let Borrowed (cursor.view C 2)
        (do (buffer.u8! Borrowed 0 88)
            (buffer-test.check "borrowed cursor capture" "tXg=42"
              (freeze (buffer.string (cursor.buffer C))))))
      (cursor.seek C 0)
      (let Owned (cursor.bytes C 3)
        (do (buffer.u8! (cursor.buffer C) 0 90)
            (buffer-test.check "owned cursor capture" "tXg"
              (freeze (buffer.string (buffer.wrap Owned))))))
      (cursor.seek C 6)
      (buffer-test.check "empty capture at boundary" ["" 6]
        (freeze [(cursor.string C 0) (cursor.position C)]))))

\\ Every subrange of a small poisoned owner, with an independent string oracle.
(define buffer-test.subranges
  Owner Start Count ->
    (if (> Count (- 6 Start))
        (if (= Start 6) true (buffer-test.subranges Owner (+ Start 1) 0))
        (do (buffer-test.check "subrange oracle"
              (shen-jit.bytes->string Owner (+ Start 1) Count)
              (freeze (buffer.string (buffer.slice (buffer.slice (buffer.wrap Owner) 1 6) Start Count))))
            (buffer-test.subranges Owner Start (+ Count 1)))))
(buffer-test.subranges (shen-jit.string->bytes "!abcdef?") 0 0)

\\ buffer.shen's operations call the typed checks of a file read before them, so each call knows
\\ the arity of what it calls and tests nothing for it.
(define buffer-test.tests-arity?
  [shen-jit.arity? | _] -> true
  [X | Y] -> (or (buffer-test.tests-arity? X) (buffer-test.tests-arity? Y))
  _ -> false)
(buffer-test.check "calls of the checks know their arities" [false false false false]
  (freeze (map (/. F (buffer-test.tests-arity? (shen-jit.code F)))
               [buffer.slice buffer.copy! buffer.append! buffer.append-byte!])))

(output "~A passed, ~A failed~%" (value buffer-test.*passed*) (value buffer-test.*failed*))
