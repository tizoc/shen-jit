\\ Modules (src/port/module.shen, docs/modules.md), over the descriptors in tests/modules/. Run from
\\ the repository's root: shen-jit eval -l tests/modules.shen

(set mods.passed 0)
(set mods.failed 0)

(define mods.check
  Name Expected Got -> (if (= Expected Got)
                           (set mods.passed (+ 1 (value mods.passed)))
                           (do (output "FAIL ~A: expected ~S, got ~S~%" Name Expected Got)
                               (set mods.failed (+ 1 (value mods.failed))))))

(define mods.message
  F -> (trap-error (do (thaw F) none) (/. E (error-to-string E))))

\\ Whether the message of what F raises starts with Prefix.
(define mods.raises?
  Prefix F -> (let M (mods.message F)
                (and (string? M) (mods.starts? Prefix M))))

(define mods.starts?
  "" _ -> true
  (@s C P) (@s C M) -> (mods.starts? P M)
  _ _ -> false)

(define mods.descriptor
  Name -> (cn "tests/modules/" (cn Name ".shenmod")))

(module.set-path ["tests/modules"])
(mods.check "the path set" ["tests/modules"] (module.path))
(mods.check "nothing loaded yet" [] (module.loaded))

\\ Requirements first, each once, in the order given; a slash in a name is a directory.
(mods.check "use gives what it loaded, in order" [b c/d a] (module.use [a]))
(mods.check "a module's functions" 23 (mod-a 2))
(mods.check "loaded once" [] (module.use [b a c/d]))
(mods.check "a symbol for a list of one" [] (module.use a))
(mods.check "loaded, in order" [b c/d a] (module.loaded))

\\ Sources in order, each with its mode, and the caller's mode afterwards.
(let Before (inferences)
     _ (set shen.*infs* (maxinferences -1))
     Loaded (module.use [both])
     After (inferences)
     _ (set shen.*infs* Before)
  (do (mods.check "sources in order" [both] Loaded)
      (mods.check "module sources have their own inference budget" (maxinferences -1) After)))
(mods.check "two sources ran in order" [two one] (value mod-order))
(mods.check "a tc+ source typechecks" true (mods.raises? "type error" (freeze (module.use [typed]))))
(mods.check "a tc- source does not" [untyped] (module.use [untyped]))
(mods.check "typechecking off again" false (tc?))
(define mods.on-after
  Names -> (do (tc +) (module.use Names) (let On (tc?) (do (tc -) On))))
(mods.check "typechecking on again" true (mods.on-after [featured]))
(mods.check "a failed module is not loaded" false (element? typed (module.loaded)))

\\ A source that raises leaves its module unloaded, and the next use tries again.
(mods.check "a raising source" "source failed" (mods.message (freeze (module.use [raises]))))
(mods.check "tried again" "source failed" (mods.message (freeze (module.use [raises]))))
(mods.check "each time from the start" 2 (value mod-attempts))
(mods.check "the home directory kept" "" (value *home-directory*))

\\ Features, extensions, and the descriptor's path.
(mods.check "a feature the build has" yes (value mod-featured))
(mods.check "a feature it lacks" true
  (mods.raises? "module: lacking requires the feature shen-jit/nothing" (freeze (module.use [lacking]))))
(mods.check "an extension is left alone" [extended] (module.use [extended]))
(mods.check "by its path, with its directory first" [other] (module.load "tests/modules/other/other.shenmod"))
(mods.check "that directory first" ["tests/modules/other" "tests/modules"] (module.path))
(mods.check "its function" 30 (mod-other 3))

\\ What is refused, each with what the message starts with.
(define mods.refused
  [] -> skip
  [[Name Prefix F] | More] -> (do (mods.check Name true (mods.raises? Prefix F)) (mods.refused More)))

(mods.refused
  [["a cycle" "module: cycle-1 requires itself, through cycle-1 -> cycle-2 -> cycle-1"
    (freeze (module.use [cycle-1]))]
   ["a source using its own module" "module: use-self is used while it loads"
    (freeze (module.use [use-self]))]
   ["a source using one that requires its own" "module: use-a is used while it loads"
    (freeze (module.use [use-a]))]
   ["a missing module" "module: no nowhere.shenmod in" (freeze (module.use [nowhere]))]
   ["not a name" "module.use: " (freeze (module.use "a"))]
   ["another name" "module: tests/modules/misnamed.shenmod names misnamed-other, not misnamed"
    (freeze (module.use [misnamed]))]
   ["version 2" "module: tests/modules/v2.shenmod has [version 2]" (freeze (module.use [v2]))]
   ["a field twice" "module: tests/modules/twice.shenmod gives name twice" (freeze (module.use [twice]))]
   ["an unknown field" "module: tests/modules/unknown.shenmod has [author me]" (freeze (module.use [unknown]))]
   ["no sources" "module: tests/modules/nameless-sources.shenmod has no sources"
    (freeze (module.use [nameless-sources]))]
   ["no mode" "module: tests/modules/nomode.shenmod's sources must start with tc+ or tc-"
    (freeze (module.use [nomode]))]
   ["an absolute source" "module: tests/modules/absolute.shenmod has a source c#34;/a.shenc#34;"
    (freeze (module.use [absolute]))]
   ["a drive" "module: tests/modules/drive.shenmod has a source" (freeze (module.use [drive]))]
   ["a backslash" "module: tests/modules/backslash.shenmod has a source" (freeze (module.use [backslash]))]
   ["two forms" "module: tests/modules/two-forms.shenmod must hold one (shen.module ...) form"
    (freeze (module.use [two-forms]))]
   ["a main that is not a name" "module: tests/modules/bad-main.shenmod has [main c#34;xc#34;]"
    (freeze (module.use [bad-main]))]
   ["a path that is not a list" "module.set-path: " (freeze (module.set-path "tests"))]])

(mods.check "none of them loaded" [b c/d a both untyped featured extended other] (module.loaded))

\\ A source's cd changes the home for evaluation, including later sources, but not loader reads.
(define mods.observe-home
  -> (do (set mods.source-homes [(@p (tc?) (value *home-directory*)) | (value mods.source-homes)])
         true))
(declare mods.observe-home [--> boolean])

(let Home (value *home-directory*)
     Caller (cd "tests")
     Loaded (module.load (mods.descriptor "cd-parent"))
     After (value *home-directory*)
     _ (set *home-directory* Home)
     SourceHome "tests/modules/other/"
  (do (mods.check "sources and sibling dependencies load after cd" [source-cd cd-sibling cd-parent] Loaded)
      (mods.check "checked and unchecked sources see the changed home"
        [(@p false SourceHome) (@p false SourceHome) (@p true SourceHome)] (value mods.source-homes))
      (mods.check "module load restores the caller's home" Caller After)))

(set mods.budget-fail true)
(let Original (maxinferences -1)
     _ (maxinferences 900000)
     Error (mods.message (freeze (module.use [budget])))
     _ (mods.check "limit restored on error" ["budget failed" 900000] [Error (maxinferences -1)])
     _ (set mods.budget-fail false)
     _ (module.use [budget])
     _ (mods.check "limits for parent, nested module and caller" [1300000 900000 1300000 900000]
          [(value mods.parent-limit) (value mods.nested-limit) (value mods.after-nested) (maxinferences -1)])
  (maxinferences Original))
(mods.check "invalid module inference limit" true
  (mods.raises? "module: tests/modules/budget-invalid.shenmod expects" (freeze (module.use [budget-invalid]))))

\\ A source that turns optimise or sealing on leaves them as the caller had them.
(mods.check "optimise and sealing come back" [[modes] false false]
  [(module.use [modes]) (optimise?) (shen-jit.sealed? (gensym probe))])

\\ A typed module, (typed): what it requires, then its sources, sealed, and those under (optimise +),
\\ so that what typechecks compiles with its types; then the caller's modes again.
(define mods.occurs?
  X X -> true
  X [Y | Ys] -> (or (mods.occurs? X Y) (mods.occurs? X Ys))
  _ _ -> false)
(mods.check "a typed module" [typed-dep typed-lib] (module.use [typed-lib]))
(mods.check "with its types, sealed, and what it requires sealed" [true false true true true true]
  [(tl (get tmod-x shen-jit.annotated)) (tl (get tmod-untyped shen-jit.annotated))
   (mods.occurs? shen-jit.field (shen-jit.code tmod-x)) (shen-jit.sealed? tmod-x)
   (shen-jit.sealed? tmod-untyped) (shen-jit.sealed? tmod-twice)])
(mods.check "the caller's modes after it" [false false false]
  [(optimise?) (shen-jit.sealed? (gensym probe)) (tc?)])
(mods.check "a typed module of untyped sources" [typed-field] (module.use [typed-field]))

\\ A typed module that fails part-way leaves what it defined unsealed, so that it can load again.
(module.set-path ["tests/modules" "lib"])
(set mods.typed-retry-fail true)
(mods.check "a typed module that fails" "typed retry failed" (mods.message (freeze (module.use [typed-retry]))))
(set mods.retry-functions [tretry-f tretry-kl tretry-native tretry-install tretry-strlen tretry-procedure])
(mods.check "leaves its definitions unsealed" [false false false false false false]
  (map (fn shen-jit.sealed?) (value mods.retry-functions)))
(mods.check "keeps its successfully loaded dependencies sealed" [true true]
  (map (fn shen-jit.sealed?) [shen-jit.ffi.define shen-jit.native.define]))
(set mods.typed-retry-fail false)
(mods.check "loads again with its dependencies already present" [typed-retry] (module.use [typed-retry]))
(mods.check "seals its definitions after a successful retry" [true true true true true true]
  (map (fn shen-jit.sealed?) (value mods.retry-functions)))
(mods.check "the retried Shen, KLambda and native definitions run" [3 4 5 6]
  [(tretry-f 2) (tretry-kl) (tretry-native) (tretry-install)])
(if (element? shen-jit/ffi (shen.x.features.current))
    (mods.check "the retried foreign function runs" 6 (tretry-strlen "sqlite"))
    skip)
(module.set-path ["tests/modules"])
(mods.check "typed takes nothing" true
  (mods.raises? "module: tests/modules/typed-bad.shenmod has [typed yes]" (freeze (module.use [typed-bad]))))

\\ Rule scope: a module's sources see the image's rules, those of the modules it requires, directly
\\ or not, and its own; code outside modules sees their public rules.
(define mods.top-typechecks?
  File -> (do (tc +) (let Checked (trap-error (do (load File) true) (/. E false)) (do (tc -) Checked))))

(datatype mods-top
  N : number;
  ==========
  [mtop N] : mods-top;)

(mods.check "a rule the module requires" [rules-base rules-user] (module.use [rules-user]))
(mods.check "a rule loaded, but not required" true
  (mods.raises? "type error" (freeze (module.use [rules-stranger]))))
(mods.check "a rule two modules away" [rules-far] (module.use [rules-far]))
(mods.check "the image's rules" [rules-image] (module.use [rules-image]))
(load "tests/modules/rules-own-a.shen")
(mods.check "its own earlier sources' rules" [rules-own] (module.use [rules-own]))
(mods.check "precluding a dependency rule lasts one source" [rules-precluded] (module.use [rules-precluded]))
(mods.check "a rule defined outside modules" true
  (mods.raises? "type error" (freeze (module.use [rules-top]))))
(mods.check "outside, a module's rules" true (mods.top-typechecks? "tests/modules/rules-late.shen"))
(mods.check "outside, its own rules" true (mods.top-typechecks? "tests/modules/rules-top.shen"))
(mods.check "outside, as before" true (element? (intern "rules-base-t#type") (map (/. E (hd E)) (value shen.*datatypes*))))
(mods.check "a module a source uses" [rules-inner rules-nested] (module.use [rules-nested]))
(mods.check "outside, the rules of a module a source used" true
  (mods.top-typechecks? "tests/modules/rules-inner-top.shen"))
(mods.check "a rule after a nested load belongs to the outer module" [rules-nested-user]
  (module.use [rules-nested-user]))
(mods.check "the dependant can use the outer rule" [rout 7] (mods-nested-value 7))

\\ Datatypes defined before a failed load are defined again on retry, and still belong to it.
(set mods.retry-fail true)
(mods.check "a datatype before an error" "retry failed" (mods.message (freeze (module.use [rules-retry]))))
(set mods.retry-fail false)
(mods.check "a failed module does not publish its datatype" false (element? mods-retry-t (included)))
(mods.check "a retry sees its own datatype" [rules-retry] (module.use [rules-retry]))
(mods.check "a retry's rules reach dependants" [rules-retry-user] (module.use [rules-retry-user]))
(mods.check "a retried definition runs" [retry "ok"] (mods-retry "ok"))
(mods.check "including does not own a datatype" [rules-included] (module.use [rules-included]))
(mods.check "an included rule does not reach dependants" true
  (mods.raises? "type error" (freeze (module.use [rules-included-user]))))

(module.use [rules-private-user])
(mods.check "own preclude persists into the next source" false (value mods.private-in-second))
(mods.check "only active owned rules reach dependants" [false true true] (value mods.dependency-rules))
(mods.check "only active owned rules reach the caller" [false true true]
  [(element? mods-internal (included)) (element? mods-public (included)) (element? mods-reenabled (included))])

\\ A descriptor's directory wins even when it was already later in the path.
(module.set-path ["tests/modules" "tests/modules/other"])
(mods.check "an existing directory moved first" [path-dep precedence]
  (module.load "tests/modules/other/precedence.shenmod"))
(mods.check "dependency next to its descriptor" right (value mods.path-dep))
(mods.check "no duplicate directory" ["tests/modules/other" "tests/modules"] (module.path))

(output "~A passed, ~A failed (modules)~%" (value mods.passed) (value mods.failed))
