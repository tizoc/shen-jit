\\ Complete UTF-8 JSON over byte views. Load buffer.shen and grammar.shen first, under (tc -).
\\ Numbers decode to lossless [number Token] values; native numbers can also be encoded.

(define json.scan-fail
  I What -> (error "json: byte ~A: ~A" I What))

(define json.scan-byte
  Data I End -> (if (< I End) (shen-jit.u8 Data I) (json.scan-fail I "unexpected end")))

(define json.scan-continuation?
  B -> (and (>= B 128) (<= B 191)))

(define json.scan-utf8-width
  Data I End ->
    (let B (json.scan-byte Data I End)
      (cond ((< B 128) 1)
            ((and (>= B 194) (<= B 223)
                  (json.scan-continuation? (json.scan-byte Data (+ I 1) End))) 2)
            ((and (>= B 224) (<= B 239)
                  (let C (json.scan-byte Data (+ I 1) End)
                    (and (json.scan-continuation? C)
                         (or (not (= B 224)) (>= C 160))
                         (or (not (= B 237)) (< C 160))))
                  (json.scan-continuation? (json.scan-byte Data (+ I 2) End))) 3)
            ((and (>= B 240) (<= B 244)
                  (let C (json.scan-byte Data (+ I 1) End)
                    (and (json.scan-continuation? C)
                         (or (not (= B 240)) (>= C 144))
                         (or (not (= B 244)) (< C 144))))
                  (json.scan-continuation? (json.scan-byte Data (+ I 2) End))
                  (json.scan-continuation? (json.scan-byte Data (+ I 3) End))) 4)
            (true (json.scan-fail I "invalid UTF-8")))))

(define json.scan-hex
  B I -> (cond ((and (>= B 48) (<= B 57)) (- B 48))
               ((and (>= B 65) (<= B 70)) (- B 55))
               ((and (>= B 97) (<= B 102)) (- B 87))
               (true (json.scan-fail I "invalid Unicode escape"))))

(define json.scan-hex4
  _ I _ 0 Acc -> Acc
  Data I End N Acc -> (json.scan-hex4 Data (+ I 1) End (- N 1)
                       (+ (* Acc 16) (json.scan-hex (json.scan-byte Data I End) I))))

\\ A JSON scalar always uses UTF-8, including scalars below 256.
(define json.scan-scalar
  Out K N ->
    (cond ((< N 128) (do (shen-jit.u8! Out K N) (+ K 1)))
          ((< N 2048)
            (do (shen-jit.u8! Out K (+ 192 (shen-jit.shift-right N 6)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and N 63))) (+ K 2)))
          ((< N 65536)
            (do (shen-jit.u8! Out K (+ 224 (shen-jit.shift-right N 12)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 6) 63)))
                (shen-jit.u8! Out (+ K 2) (+ 128 (shen-jit.bit-and N 63))) (+ K 3)))
          (true
            (do (shen-jit.u8! Out K (+ 240 (shen-jit.shift-right N 18)))
                (shen-jit.u8! Out (+ K 1) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 12) 63)))
                (shen-jit.u8! Out (+ K 2) (+ 128 (shen-jit.bit-and (shen-jit.shift-right N 6) 63)))
                (shen-jit.u8! Out (+ K 3) (+ 128 (shen-jit.bit-and N 63))) (+ K 4)))))

(define json.scan-unicode
  Data I Stop Out K ->
    (let N (json.scan-hex4 Data (+ I 2) Stop 4 0)
      (cond ((and (>= N 55296) (<= N 56319))
              (if (and (< (+ I 7) Stop) (= (shen-jit.u8 Data (+ I 6)) 92)
                       (= (shen-jit.u8 Data (+ I 7)) 117))
                  (let Low (json.scan-hex4 Data (+ I 8) Stop 4 0)
                    (if (and (>= Low 56320) (<= Low 57343))
                        (json.scan-decode Data (+ I 12) Stop Out
                          (json.scan-scalar Out K (+ 65536 (+ (* (- N 55296) 1024) (- Low 56320)))))
                        (json.scan-fail I "invalid low surrogate")))
                  (json.scan-fail I "missing low surrogate")))
            ((and (>= N 56320) (<= N 57343)) (json.scan-fail I "unpaired low surrogate"))
            (true (json.scan-decode Data (+ I 6) Stop Out (json.scan-scalar Out K N))))))

(define json.scan-decode
  _ I I _ K -> K
  Data I Stop Out K ->
    (let B (shen-jit.u8 Data I)
      (if (= B 92)
          (let E (json.scan-byte Data (+ I 1) Stop)
            (if (= E 117)
                (json.scan-unicode Data I Stop Out K)
                (let Byte (cond ((element? E [34 47 92]) E)
                                 ((= E 98) 8) ((= E 102) 12) ((= E 110) 10)
                                 ((= E 114) 13) ((= E 116) 9)
                                 (true (json.scan-fail I "invalid escape")))
                  (do (shen-jit.u8! Out K Byte)
                      (json.scan-decode Data (+ I 2) Stop Out (+ K 1))))))
          (let Run (- (json.scan-run Data I Stop) I)
            (do (shen-jit.copy-bytes Out K Data I Run)
                (json.scan-decode Data (+ I Run) Stop Out (+ K Run)))))))

\\ The grammar has checked the text, so what runs to the next escape is copied as it is.
(define json.scan-run
  _ I I -> I
  Data I Stop -> (if (= (shen-jit.u8 Data I) 92) I (json.scan-run Data (+ I 1) Stop)))

\\ V is the span the grammar made: owner, start and end in slots 1 to 3.
(define json.unescape
  V -> (let Start (<-address V 2) Stop (<-address V 3) Out (shen-jit.bytes (- Stop Start))
         (shen-jit.bytes->string Out 0 (json.scan-decode (<-address V 1) Start Stop Out 0))))

(define json.new-key?
  Seen Key -> (if (trap-error (shen.<-dict Seen Key) (/. E false))
                  false
                  (do (shen.dict-> Seen Key true) true)))

(defgrammar json.<ws-byte> B where (or (= B 32) (= B 10) (= B 13) (= B 9));)
(defgrammar json.<ws> (* json.<ws-byte>);)

(defgrammar json.<digit> B where (and (>= B 48) (<= B 57));)
(defgrammar json.<nonzero> B where (and (>= B 49) (<= B 57));)
(defgrammar json.<e> B where (or (= B 69) (= B 101));)
(defgrammar json.<sign> B where (or (= B 43) (= B 45));)
(defgrammar json.<int> 48; json.<nonzero> (* json.<digit>);)
(defgrammar json.<fraction> 46 (require (+ json.<digit>) "expected digits");)
(defgrammar json.<exponent> json.<e> (? json.<sign>) (require (+ json.<digit>) "expected digits");)
(defgrammar json.<integer> 45 (require json.<int> "expected integer"); json.<int>;)
(defgrammar json.<number> json.<integer> (? json.<fraction>) (? json.<exponent>);)

\\ A string's bytes are its text unless it has escapes, which the decoder above turns into bytes.
(defgrammar json.<plain> B where (and (>= B 32) (< B 128) (not (= B 34)) (not (= B 92)));)
(defgrammar json.<tail> B where (json.scan-continuation? B);)
(defgrammar json.<utf8>
  B json.<tail> where (and (>= B 194) (<= B 223));
  B C json.<tail> where (and (>= B 224) (<= B 239) (json.scan-continuation? C)
                             (or (not (= B 224)) (>= C 160)) (or (not (= B 237)) (< C 160)));
  B C json.<tail> json.<tail> where (and (>= B 240) (<= B 244) (json.scan-continuation? C)
                                         (or (not (= B 240)) (>= C 144)) (or (not (= B 244)) (< C 144)));)
(defgrammar json.<char> (+ json.<plain>); json.<utf8>;)
(defgrammar json.<raw> (* json.<char>);)
(defgrammar json.<hex> B where (or (and (>= B 48) (<= B 57)) (and (>= B 65) (<= B 70)) (and (>= B 97) (<= B 102)));)
(defgrammar json.<escape>
  B where (element? B [34 47 92 98 102 110 114 116]);
  117 (require json.<hex> json.<hex> json.<hex> json.<hex> "invalid Unicode escape");)
(defgrammar json.<part> json.<char>; 92 (require json.<escape> "invalid escape");)
(defgrammar json.<escaped> (* json.<part>);)
(defgrammar json.<string>
  34 (text json.<raw>) 34 := json.<raw>;
  34 (span json.<escaped>) (require 34 "unterminated string") := (json.unescape json.<escaped>);)

\\ Depth counts the containers around a value; a container at the limit is refused.
(defgrammar (json.<value> Depth Limit)
  json.<string> := json.<string>;
  "n" (require "ull" "invalid literal") := null;
  "t" (require "rue" "invalid literal") := true;
  "f" (require "alse" "invalid literal") := false;
  "[" (require (where (< Depth Limit)) "nesting limit") json.<ws> (json.<elements> (+ Depth 1) Limit)
    := json.<elements>;
  "{" (require (where (< Depth Limit)) "nesting limit") json.<ws> (json.<members> (+ Depth 1) Limit (shen.dict 8))
    := [object | json.<members>];
  (text json.<number>) := [number json.<number>];)

(defgrammar (json.<elements> Depth Limit)
  "]" := [];
  (require (json.<value> Depth Limit) "expected value") json.<ws> (json.<more> Depth Limit)
    := [json.<value> | json.<more>];)

(defgrammar (json.<more> Depth Limit)
  "]" := [];
  "," json.<ws> (require (json.<value> Depth Limit) "expected value") json.<ws> (json.<more> Depth Limit)
    := [json.<value> | json.<more>];
  (require (where false) "expected comma or closing bracket") := [];)

(defgrammar (json.<members> Depth Limit Seen)
  "}" := [];
  (require (json.<member> Depth Limit Seen) "expected object key") json.<ws> (json.<more-members> Depth Limit Seen)
    := [json.<member> | json.<more-members>];)

(defgrammar (json.<more-members> Depth Limit Seen)
  "}" := [];
  "," json.<ws> (require (json.<member> Depth Limit Seen) "expected object key") json.<ws>
    (json.<more-members> Depth Limit Seen) := [json.<member> | json.<more-members>];
  (require (where false) "expected comma or closing brace") := [];)

(defgrammar (json.<member> Depth Limit Seen)
  json.<string> (require (where (json.new-key? Seen json.<string>)) "duplicate object key")
  json.<ws> (require ":" "expected colon") json.<ws> (require (json.<value> Depth Limit) "expected value")
    := [json.<string> json.<value>];)

(defgrammar (json.<document> Limit)
  json.<ws> (require (json.<value> 0 Limit) "expected value") json.<ws> := json.<value>;)

(defgrammar json.<token> (text json.<number>) := [number json.<number>];)

\\ From a reader: the whitespace before a value, and the value; what follows stays unread, as
\\ reading on would wait for the next value. Whitespace and then the end is the end.
(defgrammar (json.<next> Limit)
  json.<ws> <end> := json.end;
  json.<ws> (require (json.<value> 0 Limit) "expected value") := json.<value>;)

(define json.read
  R Options -> (json.read-result (grammar.read (json.<next> (snd (json.options Options))) R (function json.scan-fail))))

(define json.read-result
  [ok json.end] -> [eof]
  Result -> Result)

(define json.decode-view
  View DepthLimit -> (grammar.parse (json.<document> DepthLimit) View (/. At Message (json.syntax View At Message))))

\\ At the end of the input, whatever was expected, the input ended. A string that stopped short
\\ did so at a control byte or at bytes that are not UTF-8.
(define json.syntax
  View At _ -> (json.scan-fail At "unexpected end") where (>= At (buffer.end View))
  View At "unterminated string" ->
    (json.scan-fail At (if (< (shen-jit.u8 (buffer.owner View) At) 32) "unescaped control byte" "invalid UTF-8"))
  _ At Message -> (json.scan-fail At Message))

(define json.options
  Options -> (json.configure Options 1048576 128 []))

(define json.configure
  [] Bytes Depth _ -> (@p Bytes Depth)
  [[Name Value] | Rest] Bytes Depth Seen ->
    (let _ (if (element? Name Seen) (error "json: duplicate option") true)
         N (buffer.index Value)
      (cases (= Name byte-limit) (json.configure Rest N Depth [Name | Seen])
             (= Name depth-limit)
               (if (<= N 256) (json.configure Rest Bytes N [Name | Seen])
                   (error "json: depth limit must be 0..256"))
             true (error "json: unknown option")))
  _ _ _ _ -> (error "json: options must be [Name Number] pairs"))

(define json.decode
  View Options ->
    (let Limits (json.options Options)
         _ (if (<= (buffer.length View) (fst Limits)) true (error "json: input exceeds byte limit"))
      (json.decode-view View (snd Limits))))

(define json.parse
  Text Options -> (json.decode (buffer.from-string Text) Options))

(define json.number
  Token -> (grammar.parse json.<token> (buffer.from-string Token) (/. At Message (error "json: invalid number token"))))

(define json.integer
  [number Token] ->
    (let _ (json.number Token)
         B (shen-jit.string->bytes Token)
         N (shen-jit.bytes-length B)
         Negative (= (shen-jit.u8 B 0) 45)
         Value (json.integer-digits B (if Negative 1 0) N 0 (if Negative 2 1))
      (if Negative Value (- 0 Value)))
  N -> (shen-jit.bit-or N 0) where (number? N)
  _ -> (error "json: expected an integer"))

(define json.integer-digits
  _ At At N _ -> N
  B At End N Last ->
    (let Digit (- (shen-jit.u8 B At) 48)
      (if (and (>= Digit 0) (<= Digit 9)
               (>= N -230584300921369395)
               (or (> N -230584300921369395) (<= Digit Last)))
          (json.integer-digits B (+ At 1) End (- (* N 10) Digit) Last)
          (error "json: number is not a decimal integer in the fixnum range"))))

(define json.put-text
  Out Text -> (buffer.append! Out (buffer.from-string Text)))

(define json.hex-digit
  N -> (pos "0123456789abcdef" N))

(define json.escape
  34 -> "c#92;c#34;"
  92 -> "c#92;c#92;"
  8 -> "c#92;b"
  9 -> "c#92;t"
  10 -> "c#92;n"
  12 -> "c#92;f"
  13 -> "c#92;r"
  N -> (cn "c#92;u00" (cn (json.hex-digit (shen-jit.shift-right N 4))
                          (json.hex-digit (shen-jit.bit-and N 15)))))

(define json.emit-string
  Out Text ->
    (let B (shen-jit.string->bytes Text)
         _ (buffer.append-byte! Out 34)
      (json.emit-string-run Out B 0 0 (shen-jit.bytes-length B))))

(define json.emit-string-run
  Out B Start End End ->
    (do (buffer.append! Out (buffer.make B Start End)) (buffer.append-byte! Out 34))
  Out B Start At End ->
    (let Byte (shen-jit.u8 B At)
      (if (or (< Byte 32) (= Byte 34) (= Byte 92))
          (do (buffer.append! Out (buffer.make B Start At))
              (json.put-text Out (json.escape Byte))
              (json.emit-string-run Out B (+ At 1) (+ At 1) End))
          (json.emit-string-run Out B Start (+ At (json.scan-utf8-width B At End)) End))))

(define json.container-depth
  Depth Limit -> (if (< Depth Limit) (+ Depth 1) (error "json: nesting limit")))

(define json.emit
  Out null _ _ -> (json.put-text Out "null")
  Out true _ _ -> (json.put-text Out "true")
  Out false _ _ -> (json.put-text Out "false")
  Out Text _ _ -> (json.emit-string Out Text) where (string? Text)
  Out N _ _ -> (json.emit-number Out (str N)) where (number? N)
  Out [number Token] _ _ -> (json.emit-number Out Token)
  Out [object | Members] Depth Limit ->
    (let Next (json.container-depth Depth Limit)
         _ (buffer.append-byte! Out 123)
      (json.emit-members Out Members Next Limit (shen.dict 8) false))
  Out Values Depth Limit ->
    (let Next (json.container-depth Depth Limit)
         _ (buffer.append-byte! Out 91)
      (json.emit-elements Out Values Next Limit false)) where (or (empty? Values) (cons? Values))
  _ _ _ _ -> (error "json: not a JSON value"))

(define json.emit-number
  Out Token -> (do (json.number Token) (json.put-text Out Token)))

(define json.emit-elements
  Out [] _ _ _ -> (buffer.append-byte! Out 93)
  Out [Value | Rest] Depth Limit Comma ->
    (do (if Comma (buffer.append-byte! Out 44) Out)
        (json.emit Out Value Depth Limit)
        (json.emit-elements Out Rest Depth Limit true))
  _ _ _ _ _ -> (error "json: array must be a proper list"))

(define json.emit-members
  Out [] _ _ _ _ -> (buffer.append-byte! Out 125)
  Out [[Key Value] | Rest] Depth Limit Seen Comma ->
    (let _ (if (string? Key) true (error "json: object keys must be strings"))
         _ (if (trap-error (shen.<-dict Seen Key) (/. X false))
               (error "json: duplicate object key") true)
         _ (shen.dict-> Seen Key true)
      (do (if Comma (buffer.append-byte! Out 44) Out)
          (json.emit-string Out Key)
          (buffer.append-byte! Out 58)
          (json.emit Out Value Depth Limit)
          (json.emit-members Out Rest Depth Limit Seen true)))
  _ _ _ _ _ _ -> (error "json: object members must be [Key Value] pairs"))

(define json.encode
  Value Options ->
    (let Limits (json.options Options)
         Out (buffer.builder (fst Limits))
         _ (json.emit Out Value 0 (snd Limits))
      (buffer.finish Out)))

(define json.stringify
  Value Options -> (buffer.string (json.encode Value Options)))

(datatype json-values
  S : string;
  ===========================
  S : json.value;

  N : number;
  ===========================
  N : json.value;

  ___________________________
  null : json.value;

  ___________________________
  true : json.value;

  ___________________________
  false : json.value;

  Token : string;
  ===========================
  [number Token] : json.value;

  Values : (list json.value);
  ===========================
  Values : json.value;

  Key : string; Value : json.value;
  ===========================
  [Key Value] : json.member;

  Members : (list json.member);
  ===========================
  [object | Members] : json.value;)

(datatype json-options
  N : number;
  ===========================
  [byte-limit N] : json.option;

  N : number;
  ===========================
  [depth-limit N] : json.option;)

(declare json.decode [buffer.view --> [[list json.option] --> json.value]])
(declare json.parse [string --> [[list json.option] --> json.value]])
(declare json.read [io.reader --> [[list json.option] --> [grammar.read-result json.value]]])
(declare json.number [string --> json.value])
(declare json.integer [json.value --> number])
(declare json.encode [json.value --> [[list json.option] --> buffer.view]])
(declare json.stringify [json.value --> [[list json.option] --> string]])
