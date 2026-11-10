(define json-typed.builder
  {--> boolean}
  -> (let B (buffer.builder 1)
          _ (buffer.append-byte! B 33)
       (= (buffer.string (buffer.finish B)) "!")))

(define json-typed.run
  {--> boolean}
  -> (let Value [object ["name" "Shen"] ["values" [true null [number "-0"]]]]
          Wire (json.encode Value [[byte-limit 1024]])
          Parsed (json.decode Wire [[depth-limit 8]])
       (and (json-typed.builder) (= (json.stringify Parsed []) (json.stringify Value []))
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
  -> (let R (io.reader (io.input-buffer (buffer.from-string "[1] {}")) [])
          First (json.read R [])
          Second (json.read R [])
       (= [First Second (json.read R [])] [[ok [[number "1"]]] [ok [object]] [eof]])))
(output "~A~%" (if (json-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))
