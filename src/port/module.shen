\\ Modules (docs/modules.md). A module is described by a file NAME.shenmod, which holds one form:
\\
\\   (shen.module
\\     (version 1)
\\     (name http/server)
\\     (requires buffer io http/response)
\\     (requires-features shen-jit/ffi)
\\     (sources tc- "server.shen"))
\\
\\ (module.use Names) loads each named module once, those it requires first. A name resolves to
\\ the first directory of (module.path) holding NAME.shenmod, a slash in the name being one in
\\ the path, and the sources are relative to the descriptor, each loaded with typechecking on
\\ after tc+ and off after tc-; the caller's setting comes back afterwards. A feature required is
\\ one the kernel's features extension lists. Loading a module only reads and evaluates its
\\ sources, as load does, so only the builder can.

(shen.x.namespace shen-jit.module
  (use module)
  (use shen)
  (use shen-jit)
  (externals [version name requires requires-features sources extension shen-jit tc+ tc- *hush* *home-directory* *os*
    read-from-string-unprocessed module use path set-path loaded main typed list symbol string -->])

(define initialise
  -> (do (shen.x.namespaces.publish module
           [[use | module.use] [load | module.load] [path | module.path] [set-path | module.set-path]
            [loaded | module.loaded]])
         (map (/. F (systemf F)) [module.use module.load module.path module.set-path module.loaded])
         (declare module.use [[list symbol] --> [list symbol]])
         (declare module.load [string --> [list symbol]])
         (declare module.path [--> [list string]])
         (declare module.set-path [[list string] --> [list string]])
         (declare module.loaded [--> [list symbol]])))

\\ The modules loaded, the last first.
(define loaded-list
  -> (trap-error (value *loaded*) (/. E [])))

(define module.loaded
  -> (reverse (loaded-list)))

\\ The directories searched, in order: those set, or else those the executable gives each run
\\ (main.c): SHEN_JIT_PATH's, then the installation's lib/.
(define module.path
  -> (let Roots (trap-error (value *roots*) (/. E none))
       (if (= Roots none) (trap-error (value shen-jit.*module-roots*) (/. E [])) Roots)))

(define module.set-path
  Roots -> (set *roots* Roots) where (strings? Roots)
  Roots -> (error "module.set-path: ~S is not a list of directories" Roots))

(define strings?
  [] -> true
  [S | Ss] -> (strings? Ss) where (string? S)
  _ -> false)

\\ The modules newly loaded, in order.
(define module.use
  Names -> (in-modules (freeze (do (map (/. Name (use-name Name [])) (names Names)) skip))))

\\ The module a descriptor's path names, wherever it is, with its directory put first in the
\\ path for the modules it requires.
(define module.load
  Path -> (let Dir (directory Path)
               _ (module.set-path [Dir | (remove Dir (module.path))])
            (in-modules (freeze (load-path Path none [])))))

\\ Runs Load with paths taken as they are, and gives the modules it loaded.
(define in-modules
  Load -> (let Before (loaded-list)
               _ (without-home-directory Load)
            (difference (reverse (loaded-list)) Before)))

\\ File opens by the loader use the process directory even if a source called cd.
(define without-home-directory
  F -> (let Home (value *home-directory*)
         (shen-jit.finally (freeze (do (set *home-directory* "") (thaw F)))
                           (freeze (set *home-directory* Home)))))

(define names
  Name -> [Name] where (symbol? Name)
  Names -> Names where (symbols? Names)
  Names -> (error "module.use: ~S is not a module's name, or a list of them" Names))

(define symbols?
  [] -> true
  [S | Ss] -> (symbols? Ss) where (symbol? S)
  _ -> false)

(define use-name
  Name _ -> (already-loaded Name) where (element? Name (loaded-list))
  Name Chain -> (error "module: ~A requires itself, through ~A" Name (chain-text (reverse [Name | Chain])))
      where (element? Name Chain)
  Name Chain -> (load-path (descriptor-path Name) Name Chain))

\\ A build must load its graph in the requested compilation mode. Modules loaded during this
\\ build can be shared; ones inherited from its image cannot be compiled again by loading them.
(define build-preloaded
  -> (trap-error (value *build-preloaded*) (/. E [])))

(define already-loaded
  Name -> (if (element? Name (build-preloaded))
              (error "build: module ~A is already loaded; build from an image without it" Name)
              skip))

(define chain-text
  [Name] -> (str Name)
  [Name | Names] -> (cn (str Name) (cn " -> " (chain-text Names))))

(define descriptor-path
  Name -> (let File (cn (str Name) ".shenmod")
               Roots (module.path)
            (without-home-directory (freeze (path-in File Roots Roots)))))

(define path-in
  File [] Roots -> (error "module: no ~A in ~S" File Roots)
  File [Root | More] Roots -> (let Path (cn Root (cn "/" File))
                                (if (exists? Path) Path (path-in File More Roots))))

(define exists?
  Path -> (trap-error (do (close (open Path in)) true) (/. E false)))

\\ Expected is the name the module was asked for by, or none for a descriptor given by its path. A
\\ module that a source uses while that module loads, itself or one requiring it, is refused, as
\\ requiring it would be.
(define load-path
  Path Expected Chain
  -> (let Fields (descriptor Path)
          Name (the-name Fields Path Expected)
          Loading (loading-list)
       (cond ((element? Name (loaded-list)) (already-loaded Name))
             ((element? Name Loading) (error "module: ~A is used while it loads" Name))
             (true (let Defined (definition-log)
                     (shen-jit.finally (freeze (do (set *loading* [Name | Loading])
                                                   (set *defined* [])
                                                   (load-module Name Fields Path Chain)))
                                       (freeze (do (unsealed-unless-loaded Name (definition-log))
                                                   (set *loading* Loading)
                                                   (set *defined* Defined)))))))))

\\ The runtime adds each name it seals to the innermost module's list. False disables recording.
(define definition-log
  -> (trap-error (value *defined*) (/. E false)))

\\ A module whose load failed leaves what it defined unsealed, as a typed module and what it requires
\\ load sealed, so that the next try, which loads it again from the start, can redefine it.
(define unsealed-unless-loaded
  Name Defined -> (if (and (cons? Defined) (not (element? Name (loaded-list))))
                     (map (/. F (shen-jit.sealing F)) Defined)
                     skip))

\\ A typed module, (typed), loads what it requires sealed, and its sources sealed and under
\\ (optimise +), so that what typechecks compiles with its types and its calls are direct
\\ (docs/modules.md).
(define load-module
  Name Fields Path Chain
  -> (let Requires (optional requires Fields)
          Typed (cons? (assoc typed Fields))
          _ (require-features (optional requires-features Fields) Name)
          _ (sealed-if Typed (freeze (map (/. Required (use-name Required [Name | Chain])) Requires)))
          _ (set *requires* [[Name | Requires] | (requires-list)])
       (load-sources Name (sources-of Fields Path) Typed (optional extension Fields))))

\\ F, sealed if Sealed, then with sealing as it was, however F ends.
(define sealed-if
  false F -> (thaw F)
  true F -> (let Sealing (sealing)
              (shen-jit.finally (freeze (do (shen-jit.seal +) (thaw F)))
                                (freeze (shen-jit.seal Sealing)))))

\\ Whether definitions are sealed now, as shen-jit.seal takes it.
(define sealing
  -> (if (shen-jit.sealed? (gensym probe)) + -))

\\ The modules loading now, the innermost first.
(define loading-list
  -> (trap-error (value *loading*) (/. E [])))

\\ What each module loaded requires, the last loaded first.
(define requires-list
  -> (trap-error (value *requires*) (/. E [])))

(define the-name
  Fields Path Expected
  -> (let Name (hd (field name Fields Path))
       (if (or (= Expected none) (= Name Expected))
           Name
           (error "module: ~A names ~A, not ~A" Path Name Expected))))

(define require-features
  [] _ -> skip
  [Feature | Features] Name -> (require-features Features Name)
      where (element? Feature (shen.x.features.current))
  [Feature | _] Name -> (error "module: ~A requires the feature ~A, which this build lacks" Name Feature))

\\ The descriptor's fields, checked: (version 1), (name Symbol) and (sources ...) once each,
\\ (requires ...) and (requires-features ...) of symbols, (main Function), the entry point build
\\ takes, and (typed), at most once each, and any number of (extension Symbol ...),
\\ of which shen-jit can set the inference limit.
(define descriptor
  Path -> (let Text (without-home-directory (freeze (read-file-as-string Path)))
               Forms (read-from-string-unprocessed Text)
            (if (and (cons? Forms) (= (tl Forms) []) (cons? (hd Forms)) (= (hd (hd Forms)) shen.module))
                (checked (tl (hd Forms)) Path [])
                (error "module: ~A must hold one (shen.module ...) form" Path))))

(define checked
  [] Path Seen -> (do (map (/. Key (if (element? Key Seen) skip (error "module: ~A has no ~A" Path Key)))
                          [version name sources])
                      [])
  [[extension shen-jit [maxinferences N]] | Fields] Path Seen
    -> (if (element? extension Seen) (error "module: ~A gives the shen-jit extension twice" Path)
           [[extension N] | (checked Fields Path [extension | Seen])])
    where (and (integer? N) (>= N 0))
  [[extension shen-jit | Options] | _] Path _ ->
    (error "module: ~A expects (extension shen-jit (maxinferences N)) with a nonnegative integer, got ~S" Path Options)
  [[extension Id | _] | Fields] Path Seen -> (checked Fields Path Seen) where (symbol? Id)
  [[Key | Values] | Fields] Path Seen
  -> (if (element? Key Seen)
         (error "module: ~A gives ~A twice" Path Key)
         [[Key | (field-values Key Values Path)] | (checked Fields Path [Key | Seen])])
  [Field | _] Path _ -> (error "module: ~A has a field ~S that is not one" Path Field))

(define field-values
  version [1] _ -> [1]
  name [Name] _ -> [Name] where (symbol? Name)
  requires Names _ -> Names where (symbols? Names)
  requires-features Names _ -> Names where (symbols? Names)
  main [Main] _ -> [Main] where (symbol? Main)
  typed [] _ -> []
  sources Sources Path -> (sources-checked Sources Path) where (cons? Sources)
  Key Values Path -> (error "module: ~A has ~S, which is not a valid ~A" Path [Key | Values] Key))

\\ Each source after its mode, tc+ or tc-, which holds until the next.
(define sources-checked
  [Mode | Files] Path -> (sources-in Mode Files Path) where (element? Mode [tc+ tc-])
  Sources Path -> (error "module: ~A's sources must start with tc+ or tc-" Path))

(define sources-in
  _ [] _ -> []
  Mode [Mode2 File | Files] Path -> (sources-in Mode2 [File | Files] Path) where (element? Mode2 [tc+ tc-])
  Mode [File | Files] Path -> [[Mode | File] | (sources-in Mode Files Path)] where (relative? File)
  _ [File | _] Path -> (error "module: ~A has a source ~S, which is not a relative path" Path File))

(define relative?
  File -> (and (string? File) (not (= File "")) (not (= (pos File 0) "/")) (not (backslash? File))
               (not (and (> (string-length File) 1) (= (pos File 1) ":")))))

(define backslash?
  "" -> false
  (@s C S) -> (or (= C (n->string 92)) (backslash? S)))

(define string-length
  "" -> 0
  (@s _ S) -> (+ 1 (string-length S)))

(define field
  Key Fields Path -> (let Field (assoc Key Fields)
                       (if (cons? Field) (tl Field) (error "module: ~A has no ~A" Path Key))))

(define optional
  Key Fields -> (let Field (assoc Key Fields)
                  (if (cons? Field) (tl Field) [])))

(define sources-of
  Fields Path -> (let Dir (directory Path)
                   (map (/. S [(hd S) | (cn Dir (cn "/" (tl S)))]) (field sources Fields Path))))

\\ The directory of a path, or . for none.
(define directory
  Path -> (let Slash (last-slash Path 0 -1)
            (cond ((< Slash 0) ".")
                  ((= Slash 0) "/")
                  (true (prefix Path Slash)))))

(define last-slash
  "" _ Last -> Last
  (@s C S) I Last -> (last-slash S (+ I 1) (if (or (= C "/") (= C (n->string 92))) I Last)))

(define prefix
  _ 0 -> ""
  (@s C S) N -> (@s C (prefix S (- N 1))))

\\ The sources, in order, sealed and under (optimise +) if Typed, then the caller's typechecking,
\\ *hush*, optimise and sealing again, however it ends.
(define load-sources
  Name Sources Typed Budget
  -> (let Checking (if (tc?) + -)
          Quiet (value *hush*)
          Optimising (if (optimise?) + -)
          Sealing (sealing)
          Limit (maxinferences -1)
          Outer (trap-error (value *outer-limit*) (/. E []))
          Default (if (empty? Outer) Limit Outer)
          SourceLimit (if (cons? Budget) (hd Budget) Default)
          Inferences (inferences)
          Caller (value shen.*datatypes*)
          Seen (append (image-rules) (mapcan (fn public-rules) (required-by Name)))
          Loaded (loaded-list)
          _ (set *owned* (shen.assoc-> Name [] (owned-list)))
       (shen-jit.finally
         (freeze (do (set *outer-limit* Default)
                     (if Typed (do (optimise +) (shen-jit.seal +)) skip)
                     (put Name public-rules [])
                     (map (/. Source
                            (do (maxinferences SourceLimit) (set shen.*infs* 0)
                                (set shen.*datatypes* (scope (append Seen (public-rules Name))))
                                (load-source Source)
                                (put Name public-rules (intersection (rules-of [Name])
                                                        (datatype-names (value shen.*datatypes*)))))) Sources)
                     (set *loaded* [Name | (loaded-list)])))
         (freeze (let Own (mapcan (fn public-rules) (difference (loaded-list) Loaded))
                      _ (set shen.*datatypes* (append Caller (scope (difference Own (datatype-names Caller)))))
                   (do (set *outer-limit* Outer) (maxinferences Limit) (set shen.*infs* Inferences)
                       (tc Checking) (set *hush* Quiet) (optimise Optimising)
                       (shen-jit.seal Sealing)))))))

\\ Definitions, including redefinitions, belong to the innermost loading module. include only
\\ changes scope, so the notification comes from rules->prolog, not remember-datatype.
(define note-datatype
  D -> (let Current (loading-list)
         (if (cons? Current)
             (set *owned* (shen.assoc-> (hd Current) (adjoin D (rules-of Current)) (owned-list)))
             skip)))

\\ A source sees the image, its dependencies' public rules and its own active rules.
\\ Only rules defined by this module can be published. An earlier image may have
\\ recorded ownership before modules recorded which of those rules were public.
(define public-rules
  Name -> (trap-error (get Name public-rules) (/. E (rules-of [Name]))))

(define scope
  Names -> (keep-named Names (value shen.*alldatatypes*)))

(define keep-named
  _ [] -> []
  Names [Entry | Entries] -> [Entry | (keep-named Names Entries)] where (element? (hd Entry) Names)
  Names [_ | Entries] -> (keep-named Names Entries))

(define datatype-names
  Entries -> (map (/. Entry (hd Entry)) Entries))

\\ The image's own: those it started with (main.c), but for those a loaded module defined.
(define image-rules
  -> (difference (datatype-names (trap-error (value shen-jit.*startup-datatypes*) (/. E (value shen.*datatypes*))))
                 (all-owned (owned-list))))

(define owned-list
  -> (trap-error (value *owned*) (/. E [])))

(define all-owned
  [] -> []
  [[_ | Names] | More] -> (append Names (all-owned More)))

(define rules-of
  Modules -> (all-owned (keep-named Modules (owned-list))))

\\ Every module Name requires, directly or not.
(define required-by
  Name -> (required-from (direct Name) []))

(define required-from
  [] Found -> Found
  [Module | More] Found -> (required-from More Found) where (element? Module Found)
  [Module | More] Found -> (required-from (append (direct Module) More) [Module | Found]))

(define direct
  Name -> (let Entry (assoc Name (requires-list))
            (if (cons? Entry) (tl Entry) [])))

\\ Module sources use the same evaluation as load, without its type reports or timing.
(define load-source
  [Mode | File] -> (let Checked (= Mode tc+)
                       _ (tc (if Checked + -))
                       Forms (without-home-directory (freeze (read-file File)))
                    (if Checked
                        (shen.check-eval-and-print Forms)
                        (map (/. Form (eval-kl (shen.shen->kl Form))) Forms))))

\\ -m on the command line: a descriptor's path, or a module's name.
(define command
  Argument -> (module.load Argument) where (shenmod? Argument)
  Argument -> (module.use [(intern Argument)]))

\\ shen-jit build FILE.shenmod [-o OUTPUT] [--open]: the module and what it requires loaded, sealed
\\ unless --open is given, then saved as an executable that runs the module's main (docs/modules.md).
\\ OUTPUT is the last part of the module's name by default, with .exe on Windows. Loading is quiet,
\\ and *hush*, sealing and the module path are as they were when it saves, so the program starts as
\\ the caller did, and finds modules where it runs.
\\ A typed program, (typed), loads under (optimise +), so that what typechecks, in every module it
\\ loads, compiles with its types (docs/modules.md), and is always sealed, as its code will rely on
\\ which definition each call reaches.
(define build-command
  Args -> (build-options Args none true none))

(define build-options
  [] File Seal Output -> (build File Seal Output)
  ["-o" Output | Args] File Seal _ -> (build-options Args File Seal Output)
  ["--open" | Args] File _ Output -> (build-options Args File false Output)
  [Arg | Args] none Seal Output -> (build-options Args Arg Seal Output) where (shenmod? Arg)
  [Arg | _] _ _ _ -> (error "build: ~A is not FILE.shenmod, -o OUTPUT or --open" Arg))

(define build
  none _ _ -> (error "usage: shen-jit build FILE.shenmod [-o OUTPUT] [--open]")
  File Seal Output
  -> (let Fields (descriptor File)
          Main (main-of Fields File)
          Typed (cons? (assoc typed Fields))
          _ (if (and Typed (not Seal))
                (error "build: ~A is a typed program, which is always sealed, so --open does not apply" File)
                skip)
          Sealing (sealing)
          Optimising (if (optimise?) + -)
          Quiet (value *hush*)
          Preloaded (build-preloaded)
          Roots (trap-error (value *roots*) (/. E none))
          _ (shen-jit.finally (freeze (do (set *build-preloaded* (loaded-list))
                                          (set *hush* true)
                                          (shen-jit.seal (if Seal + -))
                                          (optimise (if Typed + -))
                                          (module.load File)))
                              (freeze (do (set *build-preloaded* Preloaded)
                                          (set *roots* Roots)
                                          (set *hush* Quiet)
                                          (shen-jit.seal Sealing)
                                          (optimise Optimising))))
       (shen-jit.save-executable (if (= Output none) (default-output (hd (field name Fields File))) Output) Main)))

(define main-of
  Fields File -> (let Main (assoc main Fields)
                   (if (cons? Main)
                       (hd (tl Main))
                       (error "build: ~A has no (main Function), the entry point it needs" File))))

(define default-output
  Name -> (let Base (last-part (str Name))
            (if (= (value *os*) "Windows") (cn Base ".exe") Base)))

(define last-part
  Name -> (let Slash (last-slash Name 0 -1)
            (if (< Slash 0) Name (suffix Name (+ Slash 1)))))

(define shenmod?
  Path -> (and (> (string-length Path) 8) (= (suffix Path (- (string-length Path) 8)) ".shenmod")))

(define suffix
  S 0 -> S
  (@s _ S) N -> (suffix S (- N 1)))

)

\\ The kernel's datatype compiler, with ownership recorded after the definition succeeds.
(define shen.rules->prolog
  D Rules -> (let Clauses (mapcan (/. Rule (shen.rule->clause Rule)) Rules)
                 Result (eval [defprolog D | Clauses])
              (do (shen-jit.module.note-datatype D) Result)))
