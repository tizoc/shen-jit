\\ What buffer's functions need, for typed code of a module that requires this to prove (docs/refine.md).
\\ They test it as they run, as they do anyway. What they give is known to refine.

(refine.contract (buffer.new N) requires (fx<= 0 N))
(refine.contract (buffer.slice V Start Count)
  requires (fx<= 0 Start) (fx<= 0 Count) (fx<= (fx+ Start Count) (buffer.length V)))
(refine.contract (buffer.offset-at V I N)
  requires (fx<= 0 I) (fx<= 0 N) (fx<= (fx+ I N) (buffer.length V)))
(refine.contract (buffer.copy-into! To I From J Count)
  requires (fx<= 0 Count) (fx<= 0 I) (fx<= (fx+ I Count) (buffer.length To))
           (fx<= 0 J) (fx<= (fx+ J Count) (buffer.length From)))

(refine.contract (buffer.u8 V I) requires (fx<= 0 I) (fx< I (buffer.length V)))
(refine.contract (buffer.u16-be V I) requires (fx<= 0 I) (fx<= (fx+ I 2) (buffer.length V)))
(refine.contract (buffer.u32-be V I) requires (fx<= 0 I) (fx<= (fx+ I 4) (buffer.length V)))

(refine.contract (buffer.u8-> V I Byte)
  requires (fx<= 0 I) (fx< I (buffer.length V)) (fx<= 0 Byte) (fx<= Byte 255))
(refine.contract (buffer.u16-be-> V I X)
  requires (fx<= 0 I) (fx<= (fx+ I 2) (buffer.length V)) (fx<= 0 X) (fx<= X 65535))
(refine.contract (buffer.u32-be-> V I X)
  requires (fx<= 0 I) (fx<= (fx+ I 4) (buffer.length V)) (fx<= 0 X) (fx<= X 4294967295))
