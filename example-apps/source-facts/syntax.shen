\\ Parser-only C annotation compatibility. Keep every byte offset and line break unchanged.
\\ The compiler input is retained separately; this profile never edits compiler arguments.

(shen.x.namespace source-syntax
  (use buffer)
  (use io)
  (use shen-jit)
  (use treesitter)
  (shadow profile)
  (externals [annotation preprocessor])

(define space?
  Byte -> (element? Byte [9 10 11 12 13 32]))

(define word?
  Byte -> (or (and (>= Byte 65) (<= Byte 90)) (and (>= Byte 97) (<= Byte 122))
              (and (>= Byte 48) (<= Byte 57)) (= Byte 95) (>= Byte 128)))

(define word-end
  _ End End -> End
  Data At End ->
    (if (word? (shen-jit.u8 Data At)) (word-end Data (+ At 1) End) At))

(define quote-end
  _ End End _ -> End
  Data At End Quote ->
    (let Byte (shen-jit.u8 Data At)
      (cond ((= Byte Quote) (+ At 1))
            ((= Byte 92) (quote-end Data (io.min End (+ At 2)) End Quote))
            (true (quote-end Data (+ At 1) End Quote)))))

(define line-end
  _ End End -> End
  Data At End ->
    (cond ((= (shen-jit.u8 Data At) 10) (+ At 1))
          ((and (= (shen-jit.u8 Data At) 92) (< (+ At 1) End) (= (shen-jit.u8 Data (+ At 1)) 10))
            (line-end Data (+ At 2) End))
          ((and (= (shen-jit.u8 Data At) 92) (< (+ At 2) End)
                (= (shen-jit.u8 Data (+ At 1)) 13) (= (shen-jit.u8 Data (+ At 2)) 10))
            (line-end Data (+ At 3) End))
          (true (line-end Data (+ At 1) End))))

(define comment-end
  _ At End -> End where (>= (+ At 1) End)
  Data At End ->
    (if (and (= (shen-jit.u8 Data At) 42) (= (shen-jit.u8 Data (+ At 1)) 47))
        (+ At 2) (comment-end Data (+ At 1) End)))

\\ Skip trivia while looking for a parenthesis or a block-pointer name.
(define next
  _ End End -> End
  Data At End ->
    (let Byte (shen-jit.u8 Data At)
         Next (if (< (+ At 1) End) (shen-jit.u8 Data (+ At 1)) 0)
      (cond ((space? Byte) (next Data (+ At 1) End))
            ((and (= Byte 47) (= Next 42))
              (next Data (comment-end Data (+ At 2) End) End))
            ((and (= Byte 47) (= Next 47))
              (next Data (line-end Data (+ At 2) End) End))
            (true At))))

\\ An unfinished attribute is left intact for the grammar to diagnose.
(define attribute-end
  _ End End _ -> 0
  Data At End Depth ->
    (let Here (next Data At End)
         Byte (if (< Here End) (shen-jit.u8 Data Here) 0)
      (cond ((= Here End) 0)
            ((and (= Byte 41) (= Depth 1)) (+ Here 1))
            ((= Byte 41) (attribute-end Data (+ Here 1) End (- Depth 1)))
            ((= Byte 40) (attribute-end Data (+ Here 1) End (+ Depth 1)))
            ((element? Byte [34 39])
              (attribute-end Data (quote-end Data (+ Here 1) End Byte) End Depth))
            (true (attribute-end Data (+ Here 1) End Depth)))))

(define blank!
  _ End End -> true
  Data At End ->
    (do (if (element? (shen-jit.u8 Data At) [10 13]) true (shen-jit.u8! Data At 32))
        (blank! Data (+ At 1) End)))

\\ Profile state: copied bytes, GNU attributes, nullability qualifiers, block-pointer types.
(define profile
  Input ->
    (let Data (buffer.bytes Input)
         State (io.record [Data 0 0 0])
      (do (scan Data 0 (shen-jit.bytes-length Data) 0 State) State)))

(define scan
  _ End End _ _ -> true
  Data At End Previous State ->
    (let Byte (shen-jit.u8 Data At)
         Next (next Data At End)
      (cond ((> Next At) (scan Data Next End Previous State))
            ((element? Byte [34 39])
              (scan Data (quote-end Data (+ At 1) End Byte) End 0 State))
            ((= Byte 35) (scan Data (line-end Data (+ At 1) End) End 0 State))
            ((word? Byte)
              (word Data At (word-end Data (+ At 1) End) End State))
            ((and (= Byte 94) (= Previous 40)
                  (let After (next Data (+ At 1) End)
                    (and (< After End) (not (element? (shen-jit.u8 Data After) [40 123])))))
              (do (shen-jit.u8! Data At 42)
                  (address-> State 3 (+ (<-address State 3) 1))
                  (scan Data (+ At 1) End 42 State)))
            (true (scan Data (+ At 1) End Byte State)))))

(define word
  Data Start Stop End State ->
    (let Length (- Stop Start)
         Text (if (and (= (shen-jit.u8 Data Start) 95) (element? Length [9 11 13 16 17]))
                  (shen-jit.bytes->string Data Start Length) "")
      (cond ((element? Text ["_Nullable" "_Nullable_result" "_Null_unspecified"])
              (do (blank! Data Start Stop)
                  (address-> State 2 (+ (<-address State 2) 1))
                  (scan Data Stop End 0 State)))
            ((element? Text ["__attribute__" "__attribute"])
              (let Open (next Data Stop End)
                   Close (if (and (< Open End) (= (shen-jit.u8 Data Open) 40))
                             (attribute-end Data (+ Open 1) End 1) 0)
                (if (= Close 0) (scan Data Stop End 0 State)
                    (do (blank! Data Start Close)
                        (address-> State 1 (+ (<-address State 1) 1))
                        (scan Data Close End 0 State)))))
            (true (scan Data Stop End 0 State)))))

\\ Restrict suppression to syntax that cannot be a direct executable call.
(define capture-reason
  _ 0 -> []
  T ID ->
    (let Kind (treesitter.kind T ID)
         Parent (treesitter.parent T ID)
      (cond ((element? Kind ["attribute_specifier" "attribute_declaration" "attribute"]) annotation)
            ((element? Kind ["preproc_include" "preproc_call" "preproc_arg" "preproc_defined"]) preprocessor)
            ((and (not (= Parent 0)) (= (treesitter.field T ID) "condition")
                  (element? (treesitter.kind T Parent) ["preproc_if" "preproc_elif"])) preprocessor)
            ((= Kind "function_definition") [])
            (true (capture-reason T Parent)))))

\\ A diagnostic excerpt is byte-oriented and ASCII escaped, including malformed UTF-8.
(define excerpt
  View Start ->
    (excerpt-loop (buffer.owner View) (+ (buffer.offset View) Start)
      (+ (buffer.offset View) (io.min (buffer.length View) (+ Start 120))) ""))

(define excerpt-loop
  _ End End Text -> Text
  Data At End Text ->
    (let Byte (shen-jit.u8 Data At)
         Part (cond ((and (>= Byte 32) (<= Byte 126)) (n->string Byte))
                    ((= Byte 10) "c#92;n") ((= Byte 13) "c#92;r") ((= Byte 9) "c#92;t")
                    (true (cn "c#92;x" (cn (pos "0123456789abcdef" (/ (- Byte (shen.mod Byte 16)) 16))
                                            (pos "0123456789abcdef" (shen.mod Byte 16))))))
      (excerpt-loop Data (+ At 1) End (cn Text Part))))

)
