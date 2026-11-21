(shen.x.namespace git
  (use fs)
  (use buffer)
  (import struct defstruct)
  (externals [file])

\\ With core.ignorecase, a rule's pattern is in lowercase, and so are the paths it is matched with.
(defstruct ignore-rule base pattern name-only directory-only negated fold)

(define trim-ignore-end
  V End ->
    (if (and (> End 0) (= (buffer.u8 V (- End 1)) 32)
             (not (escaped-at? V (- End 1) false)))
        (trim-ignore-end V (- End 1)) End))

(define escaped-at?
  _ 0 State -> State
  V At State -> (if (= (buffer.u8 V (- At 1)) 92) (escaped-at? V (- At 1) (not State)) State))

(define without-cr
  S -> (if (suffix? "c#13;" S) (before S "c#13;") S))

(define ignore-line
  S Base Fold ->
    (let V (buffer.from-string (if Fold (lowercase (without-cr S)) (without-cr S)))
         N (trim-ignore-end V (buffer.length V))
      (if (or (= N 0) (= (buffer.u8 V 0) 35)) []
          (let Negated (= (buffer.u8 V 0) 33)
               Start (if Negated 1 0)
               Dir (and (> N Start) (= (buffer.u8 V (- N 1)) 47))
               End (if Dir (- N 1) N)
               Anchored (and (< Start End) (= (buffer.u8 V Start) 47))
               At (if Anchored (+ Start 1) Start)
            (if (>= At End) []
                [(:ignore-rule base <- Base pattern <- (buffer.slice V At (- End At))
                    name-only <- (and (not Anchored) (= (find-byte V 47 At End) End))
                    directory-only <- Dir negated <- Negated fold <- Fold)])))))

(define ignore-source
  Repo Path Base ->
    (if (= (node Path) file)
        (let Text (buffer.string (read-view Path (control-limit)))
             Fold (config-bool Repo "core.ignorecase" false)
          (mapcan (/. S (ignore-line S Base Fold)) (split Text 10))) []))

(define local-ignore
  Repo Relative ->
    (ignore-source Repo (fs.join (fs.join (work-root Repo) (if (= Relative "") "." Relative)) ".gitignore")
                   Relative))

(define ignore-global
  Repo ->
    (let Path (setting (repo.config Repo) "core.excludesfile" "")
         Home (env "HOME")
         Xdg (env "XDG_CONFIG_HOME")
         Resolved (cases (= Path "") (cases (not (= Xdg "")) (fs.join Xdg "git/ignore")
                                            (not (= Home "")) (fs.join Home ".config/git/ignore")
                                            true "")
                         (and (prefix? "~/" Path) (not (= Home ""))) (fs.join Home (after "~/" Path))
                         true (fs.join (work-root Repo) Path))
      (append (if (= Resolved "") [] (ignore-source Repo Resolved ""))
              (ignore-source Repo (fs.join (repo.common Repo) "info/exclude") ""))))

(define ignore-matches?
  Rule Path Name IsDir ->
    (let Base (ignore-rule.base Rule)
         Input (if (ignore-rule.name-only Rule) Name
                   (if (= Base "") Path (after (cn Base "/") Path)))
         P (ignore-rule.pattern Rule)
         V (buffer.from-string (if (ignore-rule.fold Rule) (lowercase Input) Input))
      (and (or IsDir (not (ignore-rule.directory-only Rule)))
           (wild P V 0 0 (dictionary)))))

(define ignored-rules?
  [] _ _ _ State -> State
  [Rule | Rules] Path Name IsDir State ->
    (ignored-rules? Rules Path Name IsDir
      (if (ignore-matches? Rule Path Name IsDir) (not (ignore-rule.negated Rule)) State)))

(define ignored-here?
  Rules Path IsDir -> (ignored-rules? Rules Path (fs.name Path) IsDir false))

(define star-end
  P At -> (if (and (< At (buffer.length P)) (= (buffer.u8 P At) 42)) (star-end P (+ At 1)) At))

(define glob-char
  P At ->
    (let C (buffer.u8 P At)
      (if (and (= C 92) (< (+ At 1) (buffer.length P)))
          (@p (buffer.u8 P (+ At 1)) (+ At 2))
          (@p C (+ At 1)))))

(define glob-class
  P At Byte ->
    (let _ (ensure (< At (buffer.length P)) "unterminated ignore pattern class")
         Initial (buffer.u8 P At)
         Negated (element? Initial [33 94])
         Start (if Negated (+ At 1) At)
         Part (class-items P Start Byte false true)
      (@p (if Negated (not (fst Part)) (fst Part)) (snd Part))))

(define class-items
  P At Byte Found First ->
    (if (>= At (buffer.length P)) (@p false -1)
        (let Here (buffer.u8 P At)
          (if (and (= Here 93) (not First)) (@p Found (+ At 1))
              (let Char (glob-char P At)
                   End (snd Char)
                   Range (and (< (+ End 1) (buffer.length P)) (= (buffer.u8 P End) 45)
                              (not (= (buffer.u8 P (+ End 1)) 93)))
                   Last (if Range (glob-char P (+ End 1)) Char)
                   Hit (and (>= Byte (fst Char)) (<= Byte (fst Last)))
                (class-items P (snd Last) Byte (or Found Hit) false))))))

(define wild-star
  P V At Pos Memo ->
    (let Key [At Pos]
         Found (lookup Memo Key)
      (if (cons? Found) (hd Found)
          (let End (star-end P (+ At 1))
               Across (and (>= (- End At) 2)
                           (or (= At 0) (= (buffer.u8 P (- At 1)) 47))
                           (or (= End (buffer.length P)) (= (buffer.u8 P End) 47)))
               Slash (and Across (< End (buffer.length P)))
               Boundary (or (= Pos 0) (= (buffer.u8 V (- Pos 1)) 47))
               Hit (or (and (or (not Slash) Boundary)
                            (wild P V (if Slash (+ End 1) End) Pos Memo))
                       (and (< Pos (buffer.length V))
                            (or Across (not (= (buffer.u8 V Pos) 47)))
                            (wild-star P V At (+ Pos 1) Memo)))
            (do (remember Memo Key Hit) Hit)))))

(define wild
  P V At Pos Memo ->
    (cases (= At (buffer.length P)) (= Pos (buffer.length V))
           (= (buffer.u8 P At) 42) (wild-star P V At Pos Memo)
           (= Pos (buffer.length V)) false
           true (let Ch (buffer.u8 P At)
                     Byte (buffer.u8 V Pos)
                  (cases (= Ch 63) (and (not (= Byte 47)) (wild P V (+ At 1) (+ Pos 1) Memo))
                         (= Ch 91) (and (not (= Byte 47)) (< (+ At 1) (buffer.length P))
                                         (let Look (glob-class P (+ At 1) Byte)
                                           (and (> (snd Look) 0) (fst Look)
                                                (wild P V (snd Look) (+ Pos 1) Memo))))
                         true (let Char (glob-char P At)
                                (and (= (fst Char) Byte) (wild P V (snd Char) (+ Pos 1) Memo)))))))
)
