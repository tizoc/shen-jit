(shen.x.namespace fs
  (use io)
  (use option)
  (use result)
  (import result let-ok)
  (shadow getenv)
  (export resolve-at path kind size modified accessed real-path read-link fs.symlink => symlink getenv)

(define resolve-at
  {string --> string --> (result.t (io.error * string))}
  Base Path -> (fs.resolve (join Base Path)))

(define real-path
  {string --> (io.result string)}
  Path -> (let-ok Resolved (fs.resolve Path) (real-path-of Resolved)))

(define read-link
  {string --> (io.result string)}
  Path -> (let-ok Resolved (fs.resolve Path) (read-link-path Resolved)))

\\ Target is stored as it is, relative to the link's directory unless it is absolute.
(define fs.symlink
  {string --> string --> (io.result result.empty)}
  Target Path -> (let-ok Resolved (fs.resolve Path) (symlink-path Target Resolved)))

\\ An environment variable, as the C library's getenv gives it.
(define getenv
  {string --> (option.t string)}
  Name -> (environment-value Name))

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
