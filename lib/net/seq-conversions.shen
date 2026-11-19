\\ TCP's sequence numbers, which wrap at 2^32: a type of their own, fixnums underneath, so that typed
\\ code keeps them in registers. The conversions are the identity, loaded unchecked; seq.shen types them.
(shen.x.namespace net-seq
  (use shen-jit)
  (export seq seq-of seq-number seq-add seq-distance seq-after?)

(define seq-of X -> X)
(define seq-number X -> X)
(shen-jit.represent seq fixnum)
)
