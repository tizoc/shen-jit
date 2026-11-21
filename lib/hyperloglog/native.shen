\\ The native code of module hyperloglog (docs/hyperloglog.md), written with lib/native.shen, which
\\ the module requires: runs of sparse cells into the table, and merges of dense registers.

(shen.x.namespace hyperloglog
  (use shen-jit)
  (externals [define-native word vector v128 v128! vmax != while when exit return return-word u32 u32!
              bit-and shift-left shift-right buffer.storage fixnum])

\\ The cells from I to End of Cells, 4 bytes each, into Table, an open-addressed table of Mask + 1,
\\ skipping a zero one; it gives Count, how many cells the table held, with those it added. A cell
\\ goes in the first slot from its index's home that is vacant or holds the same index, where the
\\ greater rank stays. The caller leaves room for all of them.
(define-native insert-run (Table Mask Cells I End Count)
  (word M Mask)
  (word N Count)
  (word J I)
  (word E End)
  (while (< J E)
    (word Cell (u32 Cells J))
    (when (!= Cell 0)
      (word Index (shift-right Cell 6))
      (word Slot (bit-and Index M))
      (while true
        (word At (shift-left Slot 2))
        (word Old (u32 Table At))
        (when (= Old 0)
          (u32! Table At Cell)
          (word N (+ N 1))
          (exit))
        (when (= (shift-right Old 6) Index)
          (when (> Cell Old) (u32! Table At Cell))
          (exit))
        (word Slot (bit-and (+ Slot 1) M))))
    (word J (+ J 4)))
  (return-word N))

\\ To with each of its first N bytes the greater of its own and From's, 16 at a time: N, a dense
\\ sketch's register count, is a multiple of 16.
(define-native max-bytes! (To From N)
  (word I 0)
  (word E N)
  (while (< I E)
    (v128! To I (vmax (v128 To I) (v128 From I)))
    (word I (+ I 16)))
  (return To))

(declare insert-run [buffer.storage --> [fixnum --> [buffer.storage --> [fixnum --> [fixnum --> [fixnum --> fixnum]]]]]])
(declare max-bytes! [buffer.storage --> [buffer.storage --> [fixnum --> buffer.storage]]])
)
