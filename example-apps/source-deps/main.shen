(let Quiet (hush?)
     _ (hush +)
     _ (load "example-apps/source-deps/load.shen")
  (set *hush* Quiet))

(source-deps.entry)
