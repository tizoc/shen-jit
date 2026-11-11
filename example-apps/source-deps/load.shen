\\ Load before reading files that use io.let-ok or defdatalog.
(let Quiet (hush?)
     _ (hush +)
     _ (map (function load)
         ["lib/ffi.shen" "lib/buffer.shen" "lib/io.shen" "lib/io-file.shen" "lib/fs.shen"
          "lib/grammar.shen" "lib/json.shen" "lib/native.shen" "lib/datalog.shen"
          "example-apps/source-deps/model.shen" "example-apps/source-deps/read.shen"
          "example-apps/source-deps/report.shen" "lib/parallel.shen"
          "example-apps/source-deps/batch-graph.shen" "example-apps/source-deps/batch.shen"
          "example-apps/source-deps/command.shen"])
  (set *hush* Quiet))
