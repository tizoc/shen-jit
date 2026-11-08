\\ Load macros before reading the application definitions.
(let Quiet (hush?)
     _ (hush +)
     _ (map (function load)
         ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen" "lib/fs.shen"
          "lib/grammar.shen" "lib/json.shen" "lib/tree-sitter.shen"
          "example-apps/source-facts/facts.shen"])
  (set *hush* Quiet))

(source-facts.main (value *argv*))
