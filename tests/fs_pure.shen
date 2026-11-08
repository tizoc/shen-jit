(set fs-pure.passed 0)
(set fs-pure.failed 0)

(define fs-pure.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set fs-pure.passed (+ (value fs-pure.passed) 1))
          (do (set fs-pure.failed (+ (value fs-pure.failed) 1))
              (output "FAIL ~A: ~S, expected ~S~%" Name Actual Expected)))))

(define fs-pure.raises
  Name F -> (fs-pure.check Name true (freeze (trap-error (do (thaw F) false) (/. X true)))))

(map (/. Case (fs-pure.check "lexical parent" (snd Case) (freeze (fs.parent (fst Case)))))
  [(@p "a/b" "a") (@p "a/b///" "a") (@p "file" ".") (@p "/file" "/") (@p "/" "/")])
(map (/. Case (fs-pure.check "lexical name" (snd Case) (freeze (fs.name (fst Case)))))
  [(@p "a/b" "b") (@p "a/b/" "b") (@p "/" "") (@p ".env" ".env")])
(map (/. Case (fs-pure.check "lexical extension" (snd Case) (freeze (fs.extension (fst Case)))))
  [(@p "a.tar.gz" ".gz") (@p "a." "") (@p ".env" "") (@p "dir.x/file" "")])
(fs-pure.check "join keeps dot-dot" "base/../tests" (freeze (fs.join "base" "../tests")))
(fs-pure.check "join avoids duplicate separator" "base/file" (freeze (fs.join "base/" "file")))
(fs-pure.check "join accepts empty base" "file" (freeze (fs.join "" "file")))
(map (/. Path (fs-pure.raises "invalid path" (freeze (fs.checked Path)))) ["" "ac#0;b" 3])
(map (/. Prefix (fs-pure.raises "invalid temporary prefix" (freeze (fs.prefix Prefix))))
  ["" "../tests" "bad/name" "has space"])
(map (/. Options (fs-pure.raises "invalid listing options"
                  (freeze (fs.configure (io.record [1 1]) Options [] false))))
  [[[entry-limit -1]] [[entry-limit 1000001]] [[name-byte-limit 67108865]] [[depth-limit 1]]
   [[entry-limit 1] [entry-limit 2]] [[unknown 1]] [[entry-limit (+ 0.5 0.5)]]])
(if (io.file-windows?)
    (do (fs-pure.check "drive root parent" "C:c#92;" (freeze (fs.parent "C:c#92;file")))
        (fs-pure.check "UNC share stays a root" "c#92;c#92;hostc#92;share"
          (freeze (fs.parent "c#92;c#92;hostc#92;share")))
        (fs-pure.check "extended UNC share parent" "c#92;c#92;?c#92;UNCc#92;hostc#92;sharec#92;"
          (freeze (fs.parent "c#92;c#92;?c#92;UNCc#92;hostc#92;sharec#92;file")))) skip)
(if (io.file-windows?) skip
    (do (fs-pure.check "POSIX double-slash root is preserved" "//"
          (freeze (fs.parent "//file")))
        (fs-pure.check "POSIX repeated root is preserved" "///"
          (freeze (fs.parent "///file")))))
(output "~A passed, ~A failed~%" (value fs-pure.passed) (value fs-pure.failed))
