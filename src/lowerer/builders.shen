\\ Builders. A builder accumulates one code object in an absvector:
\\ 0 name, 1 arity, 2 sealed names, 3 instructions (reversed), 4 constants
\\ (reversed), 5 nested codes, 6 labels used, 7 frame size, 8 captured variables,
\\ 9 how many constants, 10 the constants' index, 11 how many instructions, kept so
\\ that mark need not take the length of a list that grows with the code, which made
\\ a definition with many inlined calls quadratic to lower. Code with registers
\\ (registers.shen) adds 12 the next float register, false for code without them, 13 its
\\ loops, innermost first, each [Label Layout Params F], and 14 the next word register.

(shen.x.namespace shen-jit.lower
  (use shen-jit)
  (externals [code l n skip])

(define builder
  Name Arity Sealed
  -> (let B (absvector 15)
       (do (address-> B 0 Name) (address-> B 1 Arity) (address-> B 2 Sealed)
           (address-> B 3 []) (address-> B 4 []) (address-> B 5 [])
           (address-> B 6 0) (address-> B 7 (+ Arity 2)) (address-> B 8 []) (address-> B 9 0)
           (address-> B 10 (shen.dict 8)) (address-> B 11 0) (address-> B 12 false) (address-> B 13 [])
           (address-> B 14 0))))

\\ Lower Body with Params in slots 2.. and return the finished code object.
(define shen-jit.lower.code
  Name Params Body Sealed
  -> (finish (builder Name (length Params) Sealed) Params Body))

(define finish
  B Params Body
  -> (do (expr B (shen-jit.lower.bind Params 2) Body tail
                                (+ 2 (length Params)))
         (code-form B)))

(define code-form
  B -> [code (<-address B 0) (<-address B 1) (<-address B 7) (reverse (<-address B 4))
             (reverse (<-address B 3)) (<-address B 5)])

(define shen-jit.lower.bind
  [] _ -> []
  [X | Xs] S -> [[X | S] | (shen-jit.lower.bind Xs (+ S 1))])

(define emit
  B Instruction -> (do (address-> B 11 (+ (<-address B 11) 1))
                       (address-> B 3 [Instruction | (<-address B 3)])))

\\ The code an inlined body of F lowers to, marked as F's for backtraces:
\\ (inline F N) before its N instructions, which compiled code keeps as a
\\ table of names by return address, at no cost when it runs. Not at stage 0,
\\ whose backtraces stay as they were.
(define mark
  B F Lower -> (if (cons? (<-address B 2))
                   (thaw Lower)
                   (let Before (<-address B 11)
                        Done (thaw Lower)
                        N (- (<-address B 11) Before)
                     (if (> N 0)
                         (do (address-> B 11 (+ (<-address B 11) 1))
                             (address-> B 3 (shen-jit.lower.insert N [inline F N] (<-address B 3)))
                             Done)
                         Done))))

\\ X put after the first N of the instructions, which are newest first.
(define shen-jit.lower.insert
  0 X Is -> [X | Is]
  N X [I | Is] -> [I | (shen-jit.lower.insert (- N 1) X Is)])

(define new-label
  B -> (let L (<-address B 6) (do (address-> B 6 (+ L 1)) L)))

(define reserve
  B S -> (if (> (+ S 1) (<-address B 7)) (address-> B 7 (+ S 1)) B))

\\ Constants are shared only when identical: numbers must also print the
\\ same, because Shen's = equates 8 and 8.0, and NaN, which is ordered against
\\ nothing, is never shared. A dictionary indexes them by a key that is = only for
\\ constants that are shared. A value with no literal syntax has no key.
(define constant
  B X -> (let Key (constant-key X)
              Index (<-address B 10)
              Found (if (cons? Key) (trap-error (shen.<-dict Index (hd Key)) (/. E -1)) -1)
           (if (>= Found 0)
               Found
               (let Count (<-address B 9)
                 (do (address-> B 4 [X | (<-address B 4)])
                     (address-> B 9 (+ Count 1))
                     (if (cons? Key) (shen.dict-> Index (hd Key) Count) skip)
                     Count)))))

\\ [K] for X's key K, or [] when X is never shared.
(define constant-key
  X -> (if (or (< X 1) (>= X 1)) [[n (str X)]] []) where (number? X)
  [X | Y] -> (list-key [X | Y] [])
  X -> [X] where (literal? X)
  _ -> [])

(define list-key
  [X | Y] Keys -> (let K (constant-key X)
                    (if (cons? K) (list-key Y [(hd K) | Keys]) []))
  X Keys -> (let K (constant-key X)
              (if (cons? K) [[l (hd K) | Keys]] [])))

(define add-code
  B Code -> (let Codes (<-address B 5)
              (do (address-> B 5 (append Codes [Code])) (length Codes))))

(define capture-index
  B X -> (let Captures (<-address B 8)
              I (shen-jit.lower.index X Captures 0)
           (do (if (= I (length Captures)) (address-> B 8 (append Captures [X])) B)
               I)))

(define shen-jit.lower.index
  _ [] I -> I
  X [X | _] I -> I
  X [_ | Ys] I -> (shen-jit.lower.index X Ys (+ I 1))))
