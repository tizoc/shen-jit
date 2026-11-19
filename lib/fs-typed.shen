(shen.x.namespace fs
  (use io)
  (use result)
  (export resolve-at path kind size modified accessed)

(define resolve-at
  {string --> string --> (result.t (io.error * string))}
  Base Path -> (fs.resolve (join Base Path)))

(define info-check
  {info --> info}
  Info -> (if (info? Info) Info (error "fs: not metadata")))

(define path
  {info --> string}
  Info -> (info.path (info-check Info)))

(define kind
  {info --> symbol}
  Info -> (info.kind (info-check Info)))

(define size
  {info --> fixnum}
  Info -> (info.size (info-check Info)))

(define modified
  {info --> (number * number)}
  Info -> (info.modified (info-check Info)))

(define accessed
  {info --> (number * number)}
  Info -> (info.accessed (info-check Info)))

)
