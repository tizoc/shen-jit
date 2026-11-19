(shen.x.namespace tun-test
  (use shen-jit)
  (externals [define-foreign-procedure])
  (export mark words notify)

(shen-jit.library probe ["shen-test-tun.so" "build/shen-test-tun.so"])
(define-foreign-procedure mark probe "shen_test_tun_mark" 1)
(define-foreign-procedure words probe "shen_test_tun_words" 1)
(define-foreign-procedure notify probe "shen_test_tun_notify" 1)
(declare mark [fixnum --> fixnum])
(declare words [fixnum --> fixnum])
(declare notify [fixnum --> boolean])
)

(define tun-test.main
  -> (let Args (tl (value *argv*))
       (if (= (hd (tl Args)) "tap") (tun-test.run-tap (hd Args)) (tun-test.run (hd Args)))))

(define net-host-test.main
  -> (let Args (tl (value *argv*))
       (if (= (hd (tl Args)) "tap") (net-host-test.tap (hd Args)) (net-host-test.tun (hd Args)))))

(define net-dual-test.main
  -> (let Args (tl (value *argv*))
       (if (= (hd (tl Args)) "tap") (net-dual-test.tap (hd Args)) (net-dual-test.tun (hd Args)))))

(define net-multicast-test.main
  -> (let Args (tl (value *argv*))
       (if (= (hd (tl Args)) "tap") (net-multicast-test.tap (hd Args)) (net-multicast-test.tun (hd Args)))))
