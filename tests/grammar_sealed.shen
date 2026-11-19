\\ Grammars that tests/grammar.shen loads while sealing is on, as a sealed build does.
(defgrammar <gs.digit> B where (and (>= B 48) (<= B 57));)
(defgrammar <gs.digits> (+ <gs.digit>);)
(defgrammar <gs.letter> B where (and (>= B 97) (<= B 122));)
(defgrammar <gs.word> (+ <gs.letter>);)

(define gs.digits?
  S -> (grammar.match? <gs.digits> (buffer.from-string S)))
