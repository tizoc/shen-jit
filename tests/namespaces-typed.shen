\\ Read with type checking enabled, after the libraries' declarations are installed.
(shen.x.namespace library-ns.typed
  (use buffer => b)
  (use cursor => c)
  (import buffer view => bytes-view)
  (export first-byte preserve)

  (define first-byte {string --> number}
    Text -> (c.read (c.new (b.from-string Text))))

  (define preserve {bytes-view --> bytes-view}
    View -> View)
)
