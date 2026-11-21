\\ What the command line needs from the runtime, which has no types: the console, the
\\ arguments and the exit status.
(shen.x.namespace shen-git
  (use buffer)
  (use shen-jit)
  (import git prefix?)
  (externals [*argv*])

(define write-console
  View Stream ->
    (do (shen-jit.write-bytes (buffer.owner View) (buffer.offset View) (buffer.length View) Stream)
        true))

(define stdout
  View -> (write-console View (stoutput)))

(define print-text
  Text -> (stdout (buffer.from-string Text)))

(define print-line
  Text -> (print-text (cn Text "c#10;")))

(define first-bytes
  S N -> (shen-jit.bytes->string (shen-jit.string->bytes S) 0 N))

(define arguments
  -> (tl (value *argv*)))

(define quit
  Code -> (shen-jit.exit Code))

(define cli-error
  E ->
    (let Text (error-to-string E)
         V (buffer.from-string (cn (if (prefix? "git: " Text) Text (cn "git: " Text)) "c#10;"))
      (do (write-console V (sterror)) (shen-jit.exit 1))))

(declare stdout [buffer.view --> boolean])
(declare print-text [string --> boolean])
(declare print-line [string --> boolean])
(declare first-bytes [string --> [number --> string]])
(declare arguments [--> [list string]])
(declare quit [number --> boolean])
(declare cli-error [exception --> boolean])
)
