\\ shen-jit stage 0 driver.
\\
\\ Lowers every defun in the kernel KLambda files and writes one file of
\\ (defun Name Code) forms, one per line, per input: OUT-DIR/<file>.sbc.
\\ Every defun name in the input is sealed. Run from the shen-jit
\\ directory, under a previous release of shen-jit or Shen/Scheme, once make
\\ has written build/tools/lower.shen:
\\
\\   HOST script src/lowerer/stage0.shen [KLAMBDA-DIR [OUT-DIR [FILE ...]]]
\\
\\ The defaults are .deps/kernel/klambda/, build/stage0/ and the 22 kernel
\\ files; OUT-DIR must exist. FILE names omit the .kl extension.
\\
\\ Output syntax, for a simple reader: lists in parentheses, separated by
\\ single spaces; () is the empty list; true and false are the Booleans;
\\ integers are decimal; reals contain "." or "e" (shortest round-trip
\\ digits); strings are in double quotes, where \" is a quote, \\ a
\\ backslash, \xHH any other byte outside 32-126; any other token is a
\\ symbol. Symbols never start like a number and contain no space,
\\ parenthesis, quote or backslash.

(set *hush* true)
(load "src/lowerer/host.shen")
(load "build/tools/lower.shen")
(set *hush* false)

(define shen-jit.stage0.files
  -> ["toplevel" "core" "sys" "dict" "sequent" "yacc" "reader" "prolog" "track" "load"
      "writer" "macros" "declarations" "types" "t-star" "init"
      "extension-features" "extension-launcher" "extension-programmable-pattern-matching"
      "extension-namespaces" "extension-expand-dynamic" "extension-type-annotations"])

(define shen-jit.stage0.main
  [_ In Out] -> (shen-jit.stage0.run Out (shen-jit.stage0.kernel-inputs In))
  [_ In Out | Files] -> (shen-jit.stage0.run Out (shen-jit.stage0.named In Files))
  [_ In] -> (shen-jit.stage0.run "build/stage0/" (shen-jit.stage0.kernel-inputs In))
  _ -> (shen-jit.stage0.run "build/stage0/"
                              (shen-jit.stage0.kernel-inputs ".deps/kernel/klambda/")))

\\ The kernel files, then the port: its handwritten KLambda and the lowerer
\\ compiled to KLambda by src/lowerer/tokl.shen.
(define shen-jit.stage0.kernel-inputs
  In -> (append (shen-jit.stage0.named In (shen-jit.stage0.files))
                [["shen-jit" "build/port/shen-jit.kl"] ["lower" "build/port/lower.kl"]]))

(define shen-jit.stage0.named
  In Files -> (map (/. F [F (cn In (cn F ".kl"))]) Files))

(define shen-jit.stage0.run
  Out Files
  -> (let Start (get-time unix)
          \\ KLambda is read unprocessed: read-file would macroexpand it, and
          \\ the kernel's own definitions are the raw forms.
          Read (map (/. F [(hd F) | (read-from-string-unprocessed
                                       (read-file-as-string (hd (tl F))))])
                    Files)
          Inputs (shen-jit.stage0.select-overrides Read)
          Sealed (shen-jit.stage0.defun-names Inputs)
          \\ What shen-jit.sealed? and shen-jit.inline-body give in
          \\ shen-jit, for the same definitions (src/lowerer/host.shen).
          Tables (shen-jit.host.set-tables (mapcan (/. I (tl I)) Inputs))
          Lowering (get-time unix)
          Outputs (map (/. I [(hd I) | (shen-jit.stage0.lower-file (tl I) Sealed)]) Inputs)
          Lowered (get-time unix)
          Write (map (/. O (shen-jit.stage0.write-file (cn Out (cn (hd O) ".sbc")) (tl O)))
                     Outputs)
          \\ The defuns exactly as read, so shen-jit's self-hosting check
          \\ lowers the same data, independent of how each reader reads reals.
          Forms (map (/. I (shen-jit.stage0.write-file
                             (cn Out (cn (hd I) ".forms"))
                             (stage0.filter (/. X (cons? X)) (tl I))))
                     Inputs)
          End (get-time unix)
       (do (shen-jit.stage0.report (mapcan (/. O (tl O)) Outputs))
           (output "files written: ~A, to ~A~%" (length Write) Out)
           (output "time: read ~As, lower ~As, write ~As~%"
                   (- Lowering Start) (- Lowered Lowering) (- End Lowered)))))

\\ A port defun replaces the kernel defun of the same name, which is omitted.
\\ The replacement must take the same number of parameters.
(define shen-jit.stage0.select-overrides
  Inputs -> (let Port (mapcan (/. I (if (= (hd I) "shen-jit") (tl I) [])) Inputs)
                 Overrides (mapcan (/. X (shen-jit.stage0.defun-signature X)) Port)
              (map (/. I (if (= (hd I) "shen-jit")
                             I
                             [(hd I) | (shen-jit.stage0.omit Overrides (tl I))]))
                   Inputs)))

(define shen-jit.stage0.defun-signature
  [defun F Params | _] -> [[F | (length Params)]]
  _ -> [])

(define shen-jit.stage0.omit
  _ [] -> []
  Overrides [[defun F Params | Body] | Forms]
  -> (let Entry (assoc F Overrides)
       (cond ((empty? Entry) [[defun F Params | Body] | (shen-jit.stage0.omit Overrides Forms)])
             ((= (tl Entry) (length Params)) (shen-jit.stage0.omit Overrides Forms))
             (true (simple-error (make-string "override of ~A changes its parameter count" F)))))
  Overrides [X | Forms] -> [X | (shen-jit.stage0.omit Overrides Forms)])

(define shen-jit.stage0.defun-names
  Inputs -> (mapcan (/. I (mapcan (/. X (shen-jit.stage0.defun-name X)) (tl I))) Inputs))

(define shen-jit.stage0.defun-name
  [defun F | _] -> [F]
  _ -> [])

\\ Top-level strings are copyright notices; anything else is unexpected.
(define shen-jit.stage0.lower-file
  [] _ -> []
  [[defun | X] | Forms] Sealed -> [(stage0.lower.defun [defun | X] Sealed)
                                   | (shen-jit.stage0.lower-file Forms Sealed)]
  [X | Forms] Sealed -> (shen-jit.stage0.lower-file Forms Sealed) where (string? X)
  [X | _] _ -> (simple-error (make-string "stage 0: unexpected top-level form ~R" X)))

\\ ---------------------------------------------------------------------------
\\ Printing

(define shen-jit.stage0.write-file
  Path Defuns -> (let S (open Path out)
                   (do (map (/. D (do (shen-jit.stage0.write S D) (pr (n->string 10) S))) Defuns)
                       (close S))))

(define shen-jit.stage0.write
  S [] -> (pr "()" S)
  S [X | Xs] -> (do (pr "(" S) (shen-jit.stage0.write S X) (shen-jit.stage0.write-rest S Xs))
  S X -> (shen-jit.stage0.write-string S X) where (string? X)
  S X -> (pr (str X) S) where (or (number? X) (boolean? X))
  S X -> (pr (shen-jit.stage0.symbol-name X) S) where (symbol? X)
  _ X -> (simple-error (make-string "stage 0: cannot print ~S" X)))

(define shen-jit.stage0.write-rest
  S [] -> (pr ")" S)
  S [X | Xs] -> (do (pr " " S) (shen-jit.stage0.write S X) (shen-jit.stage0.write-rest S Xs))
  _ X -> (simple-error (make-string "stage 0: improper list ending in ~S" X)))

(define shen-jit.stage0.write-string
  S X -> (do (pr (n->string 34) S) (shen-jit.stage0.write-bytes S X) (pr (n->string 34) S)))

(define shen-jit.stage0.write-bytes
  _ "" -> skip
  S (@s C Cs) -> (do (pr (shen-jit.stage0.escape (string->n C)) S)
                     (shen-jit.stage0.write-bytes S Cs)))

(define shen-jit.stage0.escape
  N -> (cn (n->string 92) (n->string N)) where (or (= N 34) (= N 92))
  N -> (n->string N) where (and (>= N 32) (<= N 126))
  N -> (cn (n->string 92) (cn "x" (shen-jit.stage0.hex N 0))) where (< N 256)
  N -> (simple-error (make-string "stage 0: character ~A is not a byte" N)))

(define shen-jit.stage0.hex
  N High -> (shen-jit.stage0.hex (- N 16) (+ High 1)) where (>= N 16)
  N High -> (cn (pos "0123456789abcdef" High) (pos "0123456789abcdef" N)))

(define shen-jit.stage0.symbol-name
  X -> (let Name (str X)
         (if (and (shen-jit.stage0.plain? Name) (not (shen-jit.stage0.numeric? Name)))
             Name
             (simple-error (make-string "stage 0: symbol ~A cannot be printed plainly" Name)))))

(define shen-jit.stage0.plain?
  "" -> true
  (@s C Cs) -> (let N (string->n C)
                 (and (> N 32) (< N 127) (not (element? C ["(" ")" "c#34;" "c#92;"]))
                      (shen-jit.stage0.plain? Cs))))

(define shen-jit.stage0.numeric?
  (@s C _) -> true where (shen-jit.stage0.digit? C)
  (@s C D _) -> (shen-jit.stage0.digit? D) where (element? C ["-" "+" "."])
  _ -> false)

(define shen-jit.stage0.digit?
  C -> (let N (string->n C) (and (>= N 48) (<= N 57))))

\\ ---------------------------------------------------------------------------
\\ Statistics

(define shen-jit.stage0.report
  Defuns
  -> (let Tops (map (/. D (hd (tl (tl D)))) Defuns)
          Codes (mapcan (/. C (shen-jit.stage0.all-codes C)) Tops)
          Instructions (mapcan (/. C (shen-jit.stage0.instructions C)) Codes)
          Frames (map (/. C (shen-jit.stage0.frame C)) Codes)
          TopFrames (map (/. C (shen-jit.stage0.frame C)) Tops)
       (do (output "defuns lowered: ~A~%" (length Defuns))
           (output "code objects: ~A (~A nested)~%" (length Codes) (- (length Codes) (length Tops)))
           (output "instructions: ~A~%" (length Instructions))
           (output "constants: ~A~%"
                   (shen-jit.stage0.sum (map (/. C (length (shen-jit.stage0.constants C))) Codes)))
           (output "frame size, defuns: max ~A, mean ~A~%"
                   (shen-jit.stage0.max TopFrames 0) (/ (shen-jit.stage0.sum TopFrames) (length TopFrames)))
           (output "frame size, all code objects: max ~A, mean ~A~%"
                   (shen-jit.stage0.max Frames 0) (/ (shen-jit.stage0.sum Frames) (length Frames)))
           (output "named calls: ~A sealed, ~A open; dynamic calls: ~A~%"
                   (shen-jit.stage0.count [call-sealed tail-call-sealed] Instructions)
                   (shen-jit.stage0.count [call tail-call] Instructions)
                   (shen-jit.stage0.count [call-value tail-call-value] Instructions)))))

(define shen-jit.stage0.all-codes
  [code N A F K I Codes | Inline] -> [[code N A F K I Codes | Inline]
                                      | (mapcan (/. C (shen-jit.stage0.all-codes C)) Codes)])

(define shen-jit.stage0.frame
  [code _ _ F | _] -> F)

(define shen-jit.stage0.constants
  [code _ _ _ K | _] -> K)

(define shen-jit.stage0.instructions
  [code _ _ _ _ I | _] -> I)

(define shen-jit.stage0.sum
  [] -> 0
  [X | Xs] -> (+ X (shen-jit.stage0.sum Xs)))

(define shen-jit.stage0.max
  [] M -> M
  [X | Xs] M -> (shen-jit.stage0.max Xs (if (> X M) X M)))

(define shen-jit.stage0.count
  Ops Instructions -> (length (mapcan (/. I (if (element? (hd I) Ops) [I] [])) Instructions)))

(shen-jit.stage0.main (value *argv*))
