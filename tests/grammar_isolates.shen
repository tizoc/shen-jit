\\ Grammars in isolates, which cannot compile: the builder compiles a rule's loops, and prepares
\\ the streaming variants of the rules that reads name, before it spawns (shen-jit.publish).
\\ Load buffer.shen, io.shen and grammar.shen first.
(set gp.passed 0)
(set gp.failed 0)

(define gp.check
  Name Expected Got -> (if (= Expected Got)
                           (set gp.passed (+ 1 (value gp.passed)))
                           (do (set gp.failed (+ 1 (value gp.failed)))
                               (output "FAIL ~A: wanted ~S, got ~S~%" Name Expected Got))))

(defgrammar <gp.digits> (+ <gp.digit>);)
(defgrammar <gp.digit> B where (and (>= B 48) (<= B 57));)
(defgrammar <gp.word> (* <gp.letter>) ";";)
(defgrammar <gp.letter> B where (and (>= B 97) (<= B 122));)

(define gp.reader
  Text -> (io.reader (io.input-buffer (buffer.from-string Text)) []))

(define gp.fail
  At Message -> [failed At Message])

(define gp.ask
  F Text -> (let R (shen-jit.channel 1)
                 _ (shen-jit.spawn F [Text (shen-jit.sender R)])
              (shen-jit.receive R)))

(define gp.work
  [Text Out] -> (shen-jit.send Out [(grammar.match? <gp.digits> (buffer.from-string Text))
                                    (grammar.match? <gp.digits> (buffer.from-string "12a"))
                                    (grammar.read <gp.word> (gp.reader "abc;rest") (function gp.fail))
                                    (grammar.read <gp.word> (gp.reader "ab1;") (function gp.fail))]))

(gp.check "loops and a streaming read in an isolate" [true false [ok skip] [failed 0 "no match"]]
  (gp.ask gp.work "2026"))

\\ Defined after the first spawn: the next spawn publishes it.
(defgrammar <gp.late> (+ <gp.digit>) "!";)

(define gp.late
  [Text Out] -> (shen-jit.send Out (grammar.match? <gp.late> (buffer.from-string Text))))

(gp.check "a rule defined after a spawn" true (gp.ask gp.late "12!"))

\\ A rule no read names is not prepared: an isolate says so.
(defgrammar <gp.unread> (+ <gp.letter>);)

(define gp.unread
  [Text Out] -> (shen-jit.send Out (trap-error (grammar.read-from <gp.unread> [] (gp.reader Text) 10 (function gp.fail))
                                               (/. E (error-to-string E)))))

(gp.check "an unprepared variant is refused"
  "grammar: <gp.unread> was not prepared before isolates started: read it in a read form, or call (grammar.prepare <gp.unread>), in the builder"
  (gp.ask gp.unread "abc"))

(output "~A passed, ~A failed (grammars in isolates)~%" (value gp.passed) (value gp.failed))
