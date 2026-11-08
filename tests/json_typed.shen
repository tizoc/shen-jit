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
            (json-typed.read))))

(define json-typed.read
  {--> boolean}
  -> (let R (io.reader (io.input-buffer (buffer.from-string "[1] {}")) [])
          First (json.read R [])
          Second (json.read R [])
       (= [First Second (json.read R [])] [[ok [[number "1"]]] [ok [object]] [eof]])))
(output "~A~%" (if (json-typed.run) "1 passed, 0 failed" "0 passed, 1 failed"))
