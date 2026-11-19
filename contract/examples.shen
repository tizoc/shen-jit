\* Shen/JIT contract examples.

   Each case is [Name Form Expectation]. Form is KLambda, evaluated with
   eval-kl. Expectation is one of:

     [value E]                 the result is = to the value of KLambda form E
     [error]                   evaluating Form raises an error
     [any]                     anything, including an error
     [deviation Ours Theirs]   shen-jit expects Ours; Shen/Scheme, Theirs

   Cases run in order, so later cases can use earlier definitions. Run with
   any Shen: `shen-scheme script contract/examples.shen`. Messages are not
   compared, except through error-to-string where a case says so. *\

(define contract.impl
  -> (if (= (language) "Scheme") shen-scheme shen-jit))

(define contract.outcome
  Form -> (trap-error [value (eval-kl Form)] (/. E [error])))

(define contract.expected
  [value E] -> [value (eval-kl E)]
  [deviation Ours Theirs] -> (if (= (contract.impl) shen-scheme)
                                 (contract.expected Theirs)
                                 (contract.expected Ours))
  Other -> Other)

(define contract.matches?
  [any] _ -> true
  [error] [error] -> true
  [value V] [value R] -> (= V R)
  _ _ -> false)

(define contract.deviation?
  [_ _ [deviation | _]] -> true
  _ -> false)

(define contract.run
  [] Pass Fail -> (output "~%~A passed, ~A failed (~A)~%" Pass Fail (contract.impl))
  [[Name Form Expectation] | Cases] Pass Fail
  -> (let Expected (contract.expected Expectation)
          Actual (contract.outcome Form)
          Mark (if (contract.deviation? [Name Form Expectation]) " (deviation)" "")
       (if (contract.matches? Expected Actual)
           (do (output "PASS ~A~A~%" Name Mark)
               (contract.run Cases (+ Pass 1) Fail))
           (do (output "FAIL ~A~A: expected ~S, got ~S~%" Name Mark Expected Actual)
               (contract.run Cases Pass (+ Fail 1))))))

(contract.run [

  \\ Calls and application
  [call-defun [defun c-add [x y] [+ x y]] [value c-add]]
  [call-saturated [c-add 1 2] [value 3]]
  [call-too-few [c-add 1] [error]]
  [call-too-many [c-add 1 2 3] [error]]
  [call-zero-args [c-add] [error]]
  [call-undefined [c-undefined-fn 1] [error]]
  [call-closure-overapply [[lambda x [lambda y [+ x y]]] 1 2] [value 3]]
  [call-closure-too-few [[lambda x x]] [error]]
  [call-thunk [[freeze 5]] [value 5]]
  [call-thunk-with-arg [[freeze 5] 1] [error]]
  [call-symbol-value [let f c-add [f 1 2]] [error]]
  [call-non-procedure [1 2] [error]]
  [call-self-evaluating [if true a b] [value a]]
  [call-lexical-scope [let x 1 [let f [lambda y [+ x y]] [let x 10 [f x]]]] [value 11]]
  [call-defun-loop [defun c-loop [n acc] [if [= n 0] acc [c-loop [- n 1] [+ acc 1]]]] [value c-loop]]
  [call-tail-loop [c-loop 1000000 0] [value 1000000]]
  [call-defun-even [defun c-even [n] [if [= n 0] true [c-odd [- n 1]]]] [value c-even]]
  [call-defun-odd [defun c-odd [n] [if [= n 0] false [c-even [- n 1]]]] [value c-odd]]
  [call-mutual-tail [c-even 1000001] [value false]]
  [call-defun-len [defun c-len [n] [if [= n 0] 0 [+ 1 [c-len [- n 1]]]]] [value c-len]]
  [call-deep-non-tail [c-len 100000] [value 100000]]
  [call-defun-doloop [defun c-doloop [n] [if [= n 0] done [do n [c-doloop [- n 1]]]]] [value c-doloop]]
  [call-do-tail [c-doloop 1000000] [value done]]
  [call-eval-kl-expr [eval-kl [cons + [cons 1 [cons 2 []]]]] [value 3]]
  [call-eval-kl-defun [eval-kl [cons defun [cons c-id [cons [cons x []] [cons x []]]]]] [value c-id]]
  [call-eval-kl-defined [c-id 4] [value 4]]

  \\ Handlers
  [handler-message [trap-error [simple-error "boom"] [lambda e [error-to-string e]]] [value "boom"]]
  [handler-no-error [trap-error 5 [lambda e 6]] [value 5]]
  [handler-primitive-error [trap-error [hd []] [lambda e caught]] [value caught]]
  [handler-nested [trap-error [trap-error [simple-error "in"] [lambda e [simple-error [cn "re-" [error-to-string e]]]]] [lambda e [error-to-string e]]] [value "re-in"]]
  [handler-defun-deep [defun h-deep [n] [if [= n 0] [simple-error "bottom"] [+ 1 [h-deep [- n 1]]]]] [value h-deep]]
  [handler-unwinds-frames [trap-error [h-deep 1000] [lambda e [error-to-string e]]] [value "bottom"]]
  [handler-argument-error [trap-error [c-add 1 [hd []]] [lambda e arg-error]] [value arg-error]]
  [handler-not-procedure [trap-error [simple-error "x"] 7] [error]]
  [handler-defun-loop [defun h-loop [n] [if [= n 0] ok [h-loop [trap-error [- n 1] [lambda e 0]]]]] [value h-loop]]
  [handler-in-tail-loop [h-loop 100000] [value ok]]
  [handler-returns-closure [[trap-error [simple-error "x"] [lambda e [lambda y [+ y 1]]]] 1] [value 2]]
  [error-non-string [simple-error 1] [error]]
  [error-to-string-non-exception [error-to-string 1]
    [deviation [error] [value "Exception occurred with non-condition value 1"]]]

  \\ Equality and hashing
  [eq-int-float-literal [= 8 [+ 0.5 7.5]] [value true]]
  [eq-int-float-variables [let x [+ 0.5 7.5] [let y 8 [= x y]]] [value true]]
  [eq-signed-zero [let z [* -1 [+ 0.5 -0.5]] [let w 0.5 [= z [- w w]]]] [value true]]
  [hash-int-float [= [hash 8 1000] [hash [+ 0.5 7.5] 1000]] [deviation [value true] [value false]]]
  [hash-bound [let h [hash abc 10] [and [>= h 0] [<= h 10]]] [value true]]
  [eq-strings [= "abc" [cn "ab" "c"]] [value true]]
  [eq-lists [= [cons 1 [cons 2 []]] [cons 1 [cons 2 []]]] [value true]]
  [eq-lists-differ [= [cons 1 2] [cons 1 3]] [value false]]
  [eq-fresh-absvectors [let v [absvector 1] [let w [absvector 1] [= v w]]] [value true]]
  [eq-absvectors-differ [let v [absvector 1] [let w [address-> [absvector 1] 0 1] [= v w]]] [value false]]
  [eq-closures-distinct [= [lambda x x] [lambda x x]] [value false]]
  [eq-closure-identity [let f [lambda x x] [= f f]] [value true]]
  [eq-closures-loop [defun c-lams [n acc] [if [= n 0] acc [c-lams [- n 1] [cons [cons [lambda x x] [lambda x n]] acc]]]] [value c-lams]]
  [eq-closure-made-once [let l [c-lams 2 []] [= [hd [hd l]] [hd [hd [tl l]]]]] [value true]]
  [eq-closure-capturing [let l [c-lams 2 []] [= [tl [hd l]] [tl [hd [tl l]]]]] [value false]]
  [eq-boolean-symbol [= true [intern "true"]] [value true]]
  [eq-symbol [= a [intern "a"]] [value true]]
  [eq-number-string [= 1 "1"] [value false]]

  \\ Numbers
  [num-divide-exact [/ 4 2] [value 2]]
  [num-divide-exact-integer [integer? [/ 4 2]] [value true]]
  [num-divide-inexact [/ 5 2] [value 2.5]]
  [num-divide-zero [/ 1 0] [error]]
  [num-divide-float-zero [/ [+ 0.5 0.5] 0] [error]]
  [num-divide-by-float-zero [/ 1 [+ 0.5 -0.5]] [deviation [error] [value [let b [* [+ 0.5 0.5] 1e200] [* b b]]]]]
  [num-overflow-add [+ 2305843009213693951 1] [deviation [error] [value 2305843009213693952]]]
  [num-overflow-multiply [* 2305843009213693951 2] [deviation [error] [value 4611686018427387902]]]
  [num-non-number [+ 1 a] [error]]
  [num-compare-non-number [< 1 a] [error]]
  [num-str-integer [str 1] [value "1"]]
  [num-str-integral-float [str [+ 0.5 0.5]] [value "1.0"]]

  \\ Strings and symbols
  [str-pos [pos "abc" 0] [value "a"]]
  [str-pos-past-end [pos "abc" 3] [error]]
  [str-pos-negative [pos "abc" -1] [error]]
  [str-tlstr [tlstr "abc"] [value "bc"]]
  [str-tlstr-empty [tlstr ""] [error]]
  [str-string-n [string->n "a"] [value 97]]
  [str-string-n-empty [string->n ""] [error]]
  [str-n-string [n->string 97] [value "a"]]
  [str-n-string-byte [string->n [n->string 233]] [value 233]]
  [str-n-string-above-byte [n->string 955] [value "c#955;"]]
  [str-n-string-not-scalar [n->string 55296] [deviation [error] [any]]]
  [str-cn-non-string [cn "a" 1] [error]]
  [str-of-string [str "a"] [value "c#34;ac#34;"]]
  [str-of-symbol [str a] [value "a"]]
  [str-of-boolean [str true] [value "true"]]
  [str-of-empty-list [str []] [value "()"]]
  [sym-intern-digits [= [intern "1"] 1] [value false]]
  [sym-intern-non-string [intern 1] [error]]

  \\ Control forms
  [ctl-if-non-boolean [if 1 a b] [error]]
  [ctl-and-short-circuit [and false 1] [value false]]
  [ctl-and-second-non-boolean [and true 1] [error]]
  [ctl-or-short-circuit [or true 1] [value true]]
  [ctl-or-second-non-boolean [or false 1] [error]]
  [ctl-cond [cond [false 1] [true 2]] [value 2]]
  [ctl-cond-no-match [cond [false 1]] [error]]
  [ctl-type [type 1 [list a]] [value 1]]

  \\ Mutation and globals
  [mut-address [let v [absvector 2] [let w [address-> v 0 x] [<-address v 0]]] [value x]]
  [mut-closure-sees-store [let v [absvector 1] [let f [lambda y [<-address v 0]] [let w [address-> v 0 9] [f 0]]]] [value 9]]
  [mut-fresh-element [<-address [absvector 2] 1] [value shen.fail!]]
  [mut-address-returns-vector [let v [absvector 1] [= v [address-> v 0 5]]] [value true]]
  [mut-index-past-end [<-address [absvector 2] 2] [error]]
  [mut-index-empty [<-address [absvector 0] 0] [error]]
  [mut-negative-length [absvector -1] [error]]
  [glob-set [set m-var 1] [value 1]]
  [glob-reset [let x [set m-var 2] [value m-var]] [value 2]]
  [glob-unbound [value m-unbound-var] [error]]
  [glob-set-non-symbol [set 1 2] [error]]

  \\ Streams and time
  [io-write [let s [open "contract-tmp.bin" out] [let a [write-byte 65 s] [let b [write-byte 255 s] [let c [close s] [cons a [cons b [cons c []]]]]]]]
    [value [cons 65 [cons 255 [cons [] []]]]]]
  [io-read [let s [open "contract-tmp.bin" in] [let a [read-byte s] [let b [read-byte s] [let c [read-byte s] [let x [close s] [cons a [cons b [cons c []]]]]]]]]
    [value [cons 65 [cons 255 [cons -1 []]]]]]
  [io-close-twice [let s [open "contract-tmp.bin" in] [let a [close s] [close s]]] [value []]]
  [io-read-closed [let s [open "contract-tmp.bin" in] [let a [close s] [read-byte s]]] [error]]
  [io-write-to-input [let s [open "contract-tmp.bin" in] [write-byte 1 s]] [error]]
  [io-write-non-byte [write-byte 256 [value *stoutput*]] [error]]
  [io-open-missing [open "contract-nonexistent-xyz" in] [error]]
  [io-open-bad-direction [open "contract-tmp.bin" sideways] [error]]
  [io-char-stream [char-stream? [value *stinput*]] [value false]]
  [io-read-unit-string [read-unit-string [value *stinput*]] [error]]
  [io-home-directory [value *home-directory*] [value ""]]
  [time-run [number? [get-time run]] [value true]]
  [time-unix [number? [get-time unix]] [value true]]
  [time-bad-option [get-time sideways] [error]]
  [time-real [number? [get-time real]] [deviation [error] [value true]]]

  \\ Redefinition
  [redef-g1 [defun r-g1 [] 1] [value r-g1]]
  [redef-g2 [defun r-g2 [] [r-g1]] [value r-g2]]
  [redef-before [r-g2] [value 1]]
  [redef-g1-again [defun r-g1 [] 2] [value r-g1]]
  [redef-open-call [r-g2] [value 2]]
  [redef-arity-1 [defun r-g3 [x] [+ x 1]] [value r-g3]]
  [redef-arity-2 [defun r-g3 [x y] [+ x y]] [value r-g3]]
  [redef-arity-new [r-g3 1 2] [value 3]]
  [redef-arity-old-call [r-g3 1] [error]]
  [redef-mk [defun r-mk [] [lambda x old]] [value r-mk]]
  [redef-save [set r-saved [r-mk]] [any]]
  [redef-mk-again [defun r-mk [] [lambda x new]] [value r-mk]]
  [redef-saved-closure [[value r-saved] 0] [value old]]
  [redef-new-closure [[r-mk] 0] [value new]]
  [redef-g4 [defun r-g4 [x] x] [value r-g4]]
  [redef-malformed [defun r-g4 [x] [lambda]] [deviation [error] [value r-g4]]]
  [redef-after-malformed [r-g4 5] [deviation [value 5] [error]]]
  [redef-fixed-name [defun hd [x] x] [deviation [error] [value hd]]]

  \\ ((fn F) X Y) with F's arity: shen-jit calls a sealed F directly.
  [fn-applied [[fn append] [cons 1 []] [cons 2 []]] [value [cons 1 [cons 2 []]]]]
  [fn-partial [[[fn append] [cons 1 []]] [cons 2 []]] [value [cons 1 [cons 2 []]]]]

  \\ get, vector?, shen.+vector?, @p and tlstr, which shen-jit overrides or
  \\ compiles inline; get's messages are the kernel's.
  [get-present [let d [shen.dict 10] [do [put c-gk c-gp 7 d] [get c-gk c-gp d]]] [value 7]]
  [get-no-entry [trap-error [get c-gk c-gp [shen.dict 10]] [lambda e [error-to-string e]]]
   [value [cn "c-gk has no attributes: c-gp" [n->string 10]]]]
  [get-no-attribute [trap-error [let d [shen.dict 10] [do [put c-gk c-gq 1 d] [get c-gk c-gp d]]]
                                [lambda e [error-to-string e]]]
   [value [cn "attribute c-gp not found for c-gk" [n->string 10]]]]
  [get-not-a-dict [trap-error [get c-gk c-gp 7] [lambda e [error-to-string e]]]
   [value [cn "c-gk has no attributes: c-gp" [n->string 10]]]]
  [vector-float [let v [absvector 1] [do [address-> v 0 2.5] [vector? v]]] [value true]]
  [vector-negative [let v [absvector 1] [do [address-> v 0 -1] [vector? v]]] [value false]]
  [vector-empty [vector? [absvector 0]] [value false]]
  [vector-symbol-length [let v [absvector 1] [do [address-> v 0 a] [vector? v]]] [value false]]
  [plus-vector-zero [shen.+vector? [vector 0]] [value false]]
  [plus-vector-one [shen.+vector? [vector 1]] [value true]]
  [plus-vector-long-zero [let v [absvector 2] [do [address-> v 0 0] [do [address-> v 1 x] [shen.+vector? v]]]]
   [value true]]
  [tuple-parts [let t [@p 1 2] [cons [fst t] [cons [snd t] [cons [tuple? t] []]]]]
   [value [cons 1 [cons 2 [cons true []]]]]]
  [tlstr-1 [tlstr "a"] [value ""]]
  [tlstr-8 [tlstr "abcdefgh"] [value "bcdefgh"]]
  [tlstr-9 [tlstr "abcdefghi"] [value "bcdefghi"]]
  [tlstr-17 [tlstr "abcdefghijklmnopq"] [value "bcdefghijklmnopq"]]
  [tlstr-18 [tlstr "abcdefghijklmnopqr"] [value "bcdefghijklmnopqr"]]
  [tlstr-empty [tlstr ""] [error]]

  \\ Prolog variables.
  [pvar-is-pvar [shen.pvar? [shen.make-prolog-variable 5]] [value true]]
  [pvar-not-pvar [shen.pvar? 5] [value false]]
  [pvar-equal [= [shen.make-prolog-variable 5] [shen.make-prolog-variable 5]] [value true]]
  [pvar-differ [= [shen.make-prolog-variable 5] [shen.make-prolog-variable 6]] [value false]]
  [pvar-print [shen.app [shen.make-prolog-variable 5] "" shen.s] [value "Var5"]]

  \\ Sealing: kept last, because Shen/Scheme lets it redefine a kernel
  \\ function. In shen-jit kernel functions are sealed: redefining one
  \\ raises an error, so every call keeps the kernel's definition.
  [seal-redefine-kernel [defun shen.misc? [x] true] [deviation [error] [value shen.misc?]]]
  [seal-open-call [shen.misc? 32] [deviation [value false] [value true]]]
  [seal-kernel-call [shen.alpha? 32] [value false]]
] 0 0)
