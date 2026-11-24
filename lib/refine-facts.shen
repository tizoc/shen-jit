\\ What is known of the kernel's functions, and of the operations that typed code reads and divides with.
\\ Those of buffer are named here, and known once it is loaded. What is said of a result holds whatever the
\\ arguments: a call that would raise is in a condition without being made.

(refine.pure = + - * / < > <= >= empty? cons? head tail hd tl fst snd cons @p append reverse length limit
  string? symbol? number? boolean? integer? tuple? variable?
  fx= fx+ fx- fx* fx< fx> fx<= fx>= fxquotient fxremainder fxlimit fixnum fx->number fx->fl fl->fx fl->number float
  fl+ fl- fl* fl/ fl< fl> fl<= fl>= flsqrt shen-jit.fixnum?
  shen-jit.bytes-length buffer.length shen-jit.bit-and shen-jit.bit-or shen-jit.bit-xor shen-jit.bit-not
  shen-jit.shift-left shen-jit.shift-right shen-jit.popcount shen-jit.clz shen-jit.ctz)

(refine.trust (length L) --> R where (and (>= R 0) (= (empty? L) (= R 0))))
(refine.trust (append A B) --> R where (= (length R) (+ (length A) (length B))))
(refine.trust (reverse A) --> R where (= (length R) (length A)))
(refine.trust (map F A) --> R where (= (length R) (length A)))
(refine.trust (tail L) --> R where (or (empty? L) (= (length R) (- (length L) 1))))
(refine.trust (limit V) --> R where (>= R 0))
(refine.trust (occurrences X L) --> R where (>= R 0))

(refine.trust (fxquotient A D) --> R where
  (or (fx<= D 0)
      (if (fx>= A 0)
          (and (fx<= 0 R) (fx<= (fx* R D) A) (fx< A (fx+ (fx* R D) D)))
          (and (fx<= R 0) (fx>= (fx* R D) A) (fx> A (fx- (fx* R D) D))))))
(refine.trust (fxremainder A D) --> R where
  (or (fx= D 0)
      (and (fx= A (fx+ (fx* (fxquotient A D) D) R))
           (if (fx>= A 0)
               (and (fx<= 0 R) (fx<= R A) (if (fx> D 0) (fx< R D) (fx< R (fx- 0 D))))
               (and (fx<= R 0) (fx>= R A) (if (fx> D 0) (fx> R (fx- 0 D)) (fx> R D)))))))
(refine.trust (shen-jit.bit-and A B) --> R where
  (and (or (fx< A 0) (and (fx<= 0 R) (fx<= R A))) (or (fx< B 0) (and (fx<= 0 R) (fx<= R B)))))
(refine.trust (shen-jit.bit-or A B) --> R where
  (or (fx< A 0) (fx< B 0)
      (and (fx<= A R) (fx<= B R) (fx<= R (fx+ A B))
           (or (fx> A 255) (fx> B 255) (fx<= R 255))
           (or (fx> A 65535) (fx> B 65535) (fx<= R 65535))
           (or (fx> A 4294967295) (fx> B 4294967295) (fx<= R 4294967295)))))
(refine.trust (shen-jit.bit-xor A B) --> R where
  (or (fx< A 0) (fx< B 0)
      (and (fx<= 0 R) (fx<= R (fx+ A B))
           (or (fx> A 255) (fx> B 255) (fx<= R 255))
           (or (fx> A 65535) (fx> B 65535) (fx<= R 65535))
           (or (fx> A 4294967295) (fx> B 4294967295) (fx<= R 4294967295)))))
(refine.trust (shen-jit.shift-right A K) --> R where (if (fx>= A 0) (and (fx<= 0 R) (fx<= R A)) (and (fx< R 0) (fx<= A R))))
(refine.trust (shen-jit.popcount N) --> R where (and (fx<= 0 R) (fx<= R 64)))
(refine.trust (fxlimit V) --> R where (fx<= 0 R))
(refine.trust (shen-jit.bytes-length B) --> R where (fx<= 0 R))
(refine.trust (shen-jit.u8 B I) --> R where (and (fx<= 0 R) (fx<= R 255)))
(refine.trust (shen-jit.u16 B I) --> R where (and (fx<= 0 R) (fx<= R 65535)))
(refine.trust (shen-jit.u32 B I) --> R where (and (fx<= 0 R) (fx<= R 4294967295)))
(refine.trust (shen-jit.s32 B I) --> R where (and (fx<= -2147483648 R) (fx<= R 2147483647)))
(refine.trust (shen-jit.bytes N) --> R where (or (fx< N 0) (fx= (shen-jit.bytes-length R) N)))
(refine.trust (shen-jit.u8! B I N) --> R where (fx= (shen-jit.bytes-length R) (shen-jit.bytes-length B)))
(refine.trust (shen-jit.u16! B I N) --> R where (fx= (shen-jit.bytes-length R) (shen-jit.bytes-length B)))
(refine.trust (shen-jit.u32! B I N) --> R where (fx= (shen-jit.bytes-length R) (shen-jit.bytes-length B)))
(refine.trust (shen-jit.s32! B I N) --> R where (fx= (shen-jit.bytes-length R) (shen-jit.bytes-length B)))
(refine.trust (shen-jit.s64! B I N) --> R where (fx= (shen-jit.bytes-length R) (shen-jit.bytes-length B)))
(refine.trust (shen-jit.copy-bytes B I C J N) --> R where (fx= (shen-jit.bytes-length R) (shen-jit.bytes-length B)))
(refine.trust (buffer.length V) --> R where (fx<= 0 R))
(refine.trust (buffer.new N) --> R where (or (fx< N 0) (fx= (buffer.length R) N)))
(refine.trust (buffer.wrap B) --> R where (fx= (buffer.length R) (shen-jit.bytes-length B)))
(refine.trust (buffer.bytes V) --> R where (fx= (shen-jit.bytes-length R) (buffer.length V)))
(refine.trust (buffer.slice V I N) --> R where (or (fx< N 0) (fx= (buffer.length R) N)))
(refine.trust (buffer.u8-> V I N) --> R where (fx= (buffer.length R) (buffer.length V)))
(refine.trust (buffer.u16-be-> V I N) --> R where (fx= (buffer.length R) (buffer.length V)))
(refine.trust (buffer.u32-be-> V I N) --> R where (fx= (buffer.length R) (buffer.length V)))
(refine.trust (buffer.copy-into! V I W J N) --> R where (fx= (buffer.length R) (buffer.length V)))
(refine.trust (buffer.u8 V I) --> R where (and (fx<= 0 R) (fx<= R 255)))
(refine.trust (buffer.u16-be V I) --> R where (and (fx<= 0 R) (fx<= R 65535)))
(refine.trust (buffer.u32-be V I) --> R where (and (fx<= 0 R) (fx<= R 4294967295)))

(map (/. F (put F refine.library buffer))
     [buffer.length buffer.new buffer.wrap buffer.bytes buffer.slice buffer.u8-> buffer.u16-be-> buffer.u32-be-> buffer.copy-into!
      buffer.u8 buffer.u16-be buffer.u32-be])
