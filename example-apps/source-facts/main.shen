\\ Load macros before reading the application definitions.
(let Quiet (hush?)
     _ (hush +)
     Args (value *argv*)
     _ (map (function load)
         ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen" "lib/fs.shen"
          "lib/grammar.shen" "lib/json.shen" "lib/tree-sitter.shen"])
     _ (if (and (= (length Args) 6) (= (hd (tl (tl Args))) "--compile-commands"))
           (map (function load)
             ["lib/deadline.shen" "lib/clock.shen" "lib/process.shen" "lib/process-io.shen"
              "example-apps/source-facts/build.shen"]) true)
     _ (map (function load)
         ["example-apps/source-facts/syntax.shen" "example-apps/source-facts/diagnostics.shen"
          "example-apps/source-facts/facts.shen"])
  (set *hush* Quiet))

(source-facts.main (value *argv*))
