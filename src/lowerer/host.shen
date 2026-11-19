\\ What the lowerer needs when it runs under a host, to make the stage 0 output
\\ (stage0.shen, check.shen). The host is a previous release of shen-jit or
\\ Shen/Scheme, and these work under both.
\\
\\ The tools load the lowerer as build/tools/lower.shen, which the Makefile makes
\\ from the lowerer's files with the namespace shen-jit.lower renamed stage0.lower,
\\ as a host that is shen-jit has its own lowerer sealed under the real names. Its
\\ calls to shen-jit.sealed? and shen-jit.inline-body, primitives inside shen-jit,
\\ become the two below, which the copy's (use stage0) leaves as they are.

\\ Whether X is a symbol object. The kernel's portable symbol? also checks the
\\ characters of the name (it rejects :=), and ports override it differently,
\\ so the lowerer uses this exact test. In shen-jit it is a primitive, and
\\ sealed, so this definition is refused there. Shen/Scheme's symbol? is exact.
(trap-error (eval [define shen-jit.symbol? X -> [symbol? X]]) (/. E skip))

\\ Whether calls to F may be sealed, and F's inline body: stage 0 sets these
\\ tables from its input; elsewhere they are empty.
(define stage0.sealed?
  F -> (element? F (trap-error (value shen-jit.host.sealed) (/. E []))))

(define stage0.inline-body
  F -> (let Entry (assoc F (trap-error (value shen-jit.host.inline) (/. E [])))
         (if (cons? Entry) (tl Entry) [])))

\\ Stage 0 and the checker set both tables from the definitions they lower.
(define shen-jit.host.set-tables
  Defuns -> (do (set shen-jit.host.sealed (mapcan (/. D (shen-jit.host.name D)) Defuns))
                (set shen-jit.host.inline (mapcan (/. D (shen-jit.host.inline-entry D)) Defuns))))

(define shen-jit.host.name
  [defun F | _] -> [F]
  _ -> [])

(define shen-jit.host.inline-entry
  [defun F Params Body] -> (let Inline (stage0.lower.inline-form F Params Body true)
                             (if (empty? Inline) [] [[F | Inline]]))
  _ -> [])

\\ Not every host has one.
(define stage0.filter
  _ [] -> []
  F [X | Xs] -> [X | (stage0.filter F Xs)] where (F X)
  F [_ | Xs] -> (stage0.filter F Xs))

\\ A KLambda file's forms as read, unprocessed: read-file would macroexpand them, and the
\\ kernel's own definitions are the raw forms. From the file's bytes, which the kernel reads with
\\ an accumulator: read-from-string-unprocessed of read-file-as-string builds the string by
\\ concatenation and takes it apart recursing once for each character, which ran an earlier
\\ release out of memory on the lowerer's KLambda. The lambda is KLambda, as the host knows no
\\ arity for shen.<s-exprs> to call it by.
(define shen-jit.host.read-kl
  File -> (compile (eval-kl [lambda bytes [shen.<s-exprs> bytes]]) (read-file-as-bytelist File)))

\\ A port defun replaces the kernel defun of the same name, which is omitted.
(define shen-jit.host.select-overrides
  Inputs -> (let Port (mapcan (/. I (if (= (hd I) "shen-jit") (tl I) [])) Inputs)
                 Overrides (mapcan (/. X (shen-jit.host.defun-signature X)) Port)
              (map (/. I (if (= (hd I) "shen-jit")
                             I
                             [(hd I) | (shen-jit.host.omit Overrides (tl I))]))
                   Inputs)))

(define shen-jit.host.defun-signature
  [defun F Params | _] -> [[F | (length Params)]]
  _ -> [])

(define shen-jit.host.omit
  _ [] -> []
  Overrides [[defun F Params | Body] | Forms]
  -> (let Entry (assoc F Overrides)
       (cond ((empty? Entry) [[defun F Params | Body] | (shen-jit.host.omit Overrides Forms)])
             ((= (tl Entry) (length Params))
              (shen-jit.host.omit Overrides Forms))
             (true (simple-error (make-string "override of ~A changes its parameter count" F)))))
  Overrides [X | Forms] -> [X | (shen-jit.host.omit Overrides Forms)])
