\\ Compiles the lowerer (src/lowerer/lower.shen) to KLambda, as the kernel's
\\ make.shen does for kernel sources, so stage 0 can lower it with the kernel:
\\
\\   HOST script src/lowerer/tokl.shen [OUT-FILE [SOURCE-FILE]]
\\
\\ The default output is build/port/lower.kl.

\\ The arities of the port primitives the lowerer calls, so calls to them compile
\\ as direct calls whatever the host knows of them.
(put shen-jit.symbol? arity 1)
(put shen-jit.sealed? arity 1)
(put shen-jit.inline-body arity 1)
\\ The struct expander calls these from the pinned namespace extension. Older bootstrap
\\ hosts do not know their arities yet; compilation must still make the same direct calls.
(put shen.x.namespaces.register-syntax arity 2)
(put shen.x.namespaces.register-definitions arity 2)
(put shen.x.namespaces.publish arity 2)

\\ The KLambda is printed with ~R, which would cut lists longer than this to
\\ "... etc": a function with more than 20 clauses would be lost.
(set *maximum-print-sequence-size* 100000)

(define shen-jit.tokl.main
  [_ Out Source | _] -> (shen-jit.tokl.run Source Out)
  [_ Out] -> (shen-jit.tokl.run "src/lowerer/lower.shen" Out)
  _ -> (shen-jit.tokl.run "src/lowerer/lower.shen" "build/port/lower.kl"))

(define shen-jit.tokl.run
  Source Out -> (let Code (map (fn shen-jit.tokl.kl) (read-file Source))
              Text (shen-jit.tokl.text Code)
              Write (write-to-file Out Text)
           (output "~A definitions written to ~A~%" (length Code) Out)))

\\ The compiler names variables with gensym, whose count differs by host. From
\\ zero in each definition, every host names them alike, so that the output does
\\ not depend on it, and a change to one function does not rename the rest.
(define shen-jit.tokl.kl
  [define F | Rules] -> (do (set shen.*gensym* 0) (shen.shendef->kldef F Rules))
  X -> (simple-error (make-string "tokl: unexpected top-level form ~R" X)))

(define shen-jit.tokl.text
  [] -> ""
  [X | Y] -> (@s (make-string "~R~%~%" X) (shen-jit.tokl.text Y)))

(shen-jit.tokl.main (value *argv*))
