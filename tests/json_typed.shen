(define json-typed.builder
  {--> boolean}
  -> (let B (buffer.builder 1)
          _ (buffer.append-byte! B 33)
       (= (buffer.string (buffer.finish B)) "!")))

\\ The let binds each Boolean before stringify supplies the expected JSON type.
(define json-typed.boolean-fields
  {--> boolean}
  -> (let A true
          B false
          C true
          D false
          E true
          F false
          G true
          H false
          Text (json.stringify
                 [object ["a" A] ["b" B] ["c" C] ["d" D] ["e" E] ["f" F] ["g" G] ["h" H]] [])
       (= (json.parse Text [])
          [object ["a" true] ["b" false] ["c" true] ["d" false]
                  ["e" true] ["f" false] ["g" true] ["h" false]])))

(define json-typed.null?
  {json.value --> boolean}
  null -> true
  _ -> false)

(define json-typed.null-fields
  {--> boolean}
  -> (let A (json.from-null)
          B (json.from-null)
          C (json.from-null)
          D (json.from-null)
          E (json.from-null)
          F (json.from-null)
          G (json.from-null)
          H (json.from-null)
          Text (json.stringify
                 [object ["a" A] ["b" B] ["c" C] ["d" D] ["e" E] ["f" F] ["g" G] ["h" H]] [])
       (and (json-typed.null? A)
            (not (json-typed.null? true))
            (= (json.stringify null []) "null")
            (= (json.parse Text [])
               [object ["a" null] ["b" null] ["c" null] ["d" null]
                       ["e" null] ["f" null] ["g" null] ["h" null]]))))

(define json-typed.rebuild-object
  {json.value --> json.value}
  [object | Members] -> [object | Members]
  Value -> Value)

(define json-typed.empty-objects
  {--> boolean}
  -> (let A (json.empty-object)
          B (json.empty-object)
          C (json.empty-object)
          D (json.empty-object)
          E (json.empty-object)
          F (json.empty-object)
          G (json.empty-object)
          H (json.empty-object)
          Text (json.stringify
                 [object ["a" A] ["b" B] ["c" C] ["d" D] ["e" E] ["f" F] ["g" G] ["h" H]] [])
       (and (= (json.stringify (json-typed.rebuild-object [object]) []) "{}")
            (= (json-typed.rebuild-object (json.parse Text []))
               [object ["a" [object]] ["b" [object]] ["c" [object]] ["d" [object]]
                       ["e" [object]] ["f" [object]] ["g" [object]] ["h" [object]]]))))

(define json-typed.run
  {--> boolean}
  -> (let Value [object ["name" "Shen"] ["values" [true null [number "-0"]]]]
          Wire (json.encode Value [[byte-limit 1024]])
          Parsed (json.decode Wire [[depth-limit 8]])
       (and (json-typed.builder) (json-typed.boolean-fields)
            (json-typed.null-fields) (json-typed.empty-objects)
            (= (json.stringify Parsed []) (json.stringify Value []))
            (= (json.integer (json.number "42")) 42)
            (json-typed.read) (json-typed.parts))))

\\ A string and an array taken out of values with json.string and json.array, which raise for
\\ any other value.
(define json-typed.parts
  {--> boolean}
  -> (let Name (json.string (json.parse "c#34;Shenc#34;" []))
          Items (json.array (json.parse "[1,c#34;ac#34;]" []))
          Empty (json.array (json.parse "[]" []))
          Wrong (map (/. V (trap-error (do (json.array V) false) (/. E true)))
                     [[number "1"] [object] "a" true])
          Other (trap-error (do (json.string [number "1"]) false) (/. E true))
       (and (= Name "Shen") (= Items [[number "1"] "a"]) (= Empty []) (= Wrong [true true true true])
            Other)))

(define json-typed.read
  {--> boolean}
  -> (let R (io.reader (io.input-buffer (buffer.from-string "[1] {} []")) [])
          First (json.read R [])
          Second (json.read R [])
          EmptyArray (json.read R [])
          End (json.read R [])
       (and (= First (:result.ok [[[number "1"]]])) (= Second (:result.ok [[object]]))
            (= EmptyArray (:result.ok [[]])) (= End (:result.ok [])))))
(output "~A~%" (if (json-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))
