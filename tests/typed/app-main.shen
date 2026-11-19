\\ The untyped part of the program in app.shenmod, typed, and app-untyped.shenmod: its results, and
\\ which definitions were compiled with their types: its own typechecked ones, then this one, then one
\\ that a library it requires typechecks.
(define app-main
  -> (output "~A ~A annotated ~A ~A ~A ~A~%" (app-mean 1.5 3.5) (app-steps 10 0)
             (tl (get app-mean shen-jit.annotated)) (tl (get app-steps shen-jit.annotated))
             (tl (get app-main shen-jit.annotated)) (tl (get buffer.index shen-jit.annotated))))
