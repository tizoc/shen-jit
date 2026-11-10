(set fs-test.passed 0)
(set fs-test.failed 0)

(define fs-test.check
  Name Expected F ->
    (let Actual (trap-error (thaw F) (/. X [raised (error-to-string X)]))
      (if (= Actual Expected)
          (set fs-test.passed (+ (value fs-test.passed) 1))
          (do (set fs-test.failed (+ (value fs-test.failed) 1))
              (output "FAIL ~A: ~S, expected ~S~%" Name Actual Expected)))))

(define fs-test.ok
  [ok Value] -> Value
  [error Error] -> (error "unexpected error ~A: ~A" (io.error-code Error) (io.error-message Error)))

(define fs-test.error
  [error Error] -> Error
  _ -> (error "expected filesystem failure"))

(define fs-test.path
  Name -> (fs.join (value fs-test.root) Name))

(define fs-test.bytes
  Path -> (buffer.string (fs-test.ok (io.read-file Path 1048576))))

(let Path (fs-test.path "data")
     Info (fs-test.ok (fs.stat Path))
     _ (shen-jit.collect)
  (do (fs-test.check "stat kind" file (freeze (fs.kind Info)))
      (fs-test.check "stat size" 6
        (freeze (fs.size Info)))
      (fs-test.check "nanosecond timestamps match independent oracle" (value fs-test.mtime)
        (freeze (fs.modified Info)))
      (fs-test.check "negative access time matches independent oracle" (value fs-test.atime)
        (freeze (fs.accessed Info)))
      (fs-test.check "owned metadata survives GC" "data"
        (freeze (fs.name (fs.path Info))))
      (fs-test.check "existing path" [ok true]
        (freeze (fs.exists? Path)))
      (fs-test.check "missing path" [ok false]
        (freeze (fs.exists? (fs-test.path "missing"))))
      (fs-test.check "non-directory prefix is absent" [ok false]
        (freeze (fs.exists? (fs.join Path "child"))))
      (fs-test.check "directory kind" directory
        (freeze (fs.kind (fs-test.ok (fs.stat (value fs-test.root))))))))

(if (value fs-test.sparse)
    (fs-test.check "size exceeds 32 bits" 5368709127
      (freeze (fs.size (fs-test.ok (fs.stat (fs-test.path "sparse")))))) skip)

(let Path (fs-test.path "listing")
     Names (fs-test.ok (fs.list Path [[entry-limit 2] [name-byte-limit 2]]))
     _ (shen-jit.collect)
  (do (fs-test.check "sorted listing survives GC" ["a" "b"] (freeze Names))
      (fs-test.check "entry budget fails rather than truncating" limit
        (freeze (io.error-domain (fs-test.error (fs.list Path [[entry-limit 1]])))))
      (fs-test.check "name-byte budget fails" limit
        (freeze (io.error-domain (fs-test.error (fs.list Path [[name-byte-limit 1]])))))
      (fs-test.check "empty directory with zero budgets" [ok []]
        (freeze (fs.list (fs-test.path "empty") [[entry-limit 0] [name-byte-limit 0]])))
      (fs-test.check "file is not a directory" true
        (freeze (io.error? (fs-test.error (fs.list (fs-test.path "data") [])))))))

(let Path (fs-test.path "new/deep")
  (do (fs-test.check "recursive directory creation" [ok] (freeze (fs.mkdirs Path)))
      (fs-test.check "recursive mkdir is idempotent" [ok]
        (freeze (fs.mkdirs Path)))
      (fs-test.check "single mkdir existing path is an error" true
        (freeze (io.error? (fs-test.error (fs.mkdir Path)))))
      (fs-test.check "remove nonempty directory fails" true
        (freeze (io.error? (fs-test.error (fs.remove-directory (fs-test.path "new"))))))
      (fs-test.check "remove empty directory" [ok]
        (freeze (fs.remove-directory Path)))
      (fs.remove-directory (fs-test.path "new"))))

(let A (fs-test.path "rename-a")
     B (fs-test.path "rename-b")
     _ (io.write-file A (buffer.from-string "first"))
     _ (io.write-file B (buffer.from-string "second"))
  (do (fs-test.check "rename refuses overwrite" true
        (freeze (io.error? (fs-test.error (fs.rename A B)))))
      (fs-test.check "failed rename preserves source" "first"
        (freeze (fs-test.bytes A)))
      (fs-test.check "failed rename preserves destination" "second"
        (freeze (fs-test.bytes B)))
      (fs-test.check "replacement rename" [ok]
        (freeze (fs.replace A B)))
      (fs-test.check "replacement contents" "first"
        (freeze (fs-test.bytes B)))
      (fs-test.check "replacement removes source" [ok false]
        (freeze (fs.exists? A)))
      (fs-test.check "rename to unused name" [ok]
        (freeze (fs.rename B A)))
      (fs-test.check "remove file" [ok]
        (freeze (fs.remove-file A)))
      (fs-test.check "missing unlink remains an error" true
        (freeze (io.error? (fs-test.error (fs.remove-file A)))))))

(let Parent (value fs-test.root)
     Pair (fs-test.ok (fs.temp-file Parent "temp-"))
     Path (fst Pair)
     E (snd Pair)
     _ (io.write-all E (buffer.from-string "private") [])
     _ (io.close E)
     Scoped (io.record [[] []])
     Result (fs.with-temp-file Parent "scope-"
              (/. P Out
                (do (address-> Scoped 0 P)
                    (address-> Scoped 1 Out)
                    (error "scope failed"))))
     Dir (fs-test.ok (fs.temp-directory Parent "dir-"))
  (do (fs-test.check "exclusive temporary file stays open for I/O" "private"
        (freeze (fs-test.bytes Path)))
      (fs-test.check "temporary name remains in requested parent" (fs-test.ok (fs.resolve Parent))
        (freeze (fs.parent Path)))
      (fs-test.check "temporary scope catches exceptions" shen
        (freeze (io.error-domain (fs-test.error Result))))
      (fs-test.check "temporary scope removes its file" [ok false]
        (freeze (fs.exists? (<-address Scoped 0))))
      (fs-test.check "temporary scope closes endpoint" [ok]
        (freeze (io.close (<-address Scoped 1))))
      (fs-test.check "temporary directory exists" directory
        (freeze (fs.kind (fs-test.ok (fs.stat Dir)))))
      (fs.remove-directory Dir)
      (fs.remove-file Path)))

(let Path (fs-test.path "destination")
     _ (io.write-file Path (buffer.from-string "old"))
     Before (fs-test.ok (fs.list (value fs-test.root) []))
     Error (fs.with-replacement Path
               (/. E
                 (do (io.write-all E (buffer.from-string "partial") [])
                     [error (io.native-error write fixture 37 Path "injected error")])))
     Throw (fs.with-replacement Path (/. E (error "writer threw")))
  (do (fs-test.check "replacement preserves callback error" 37
        (freeze (io.error-code (fs-test.error Error))))
      (fs-test.check "replacement catches exceptions" shen
        (freeze (io.error-domain (fs-test.error Throw))))
      (fs-test.check "failed replacement keeps original bytes" "old"
        (freeze (fs-test.bytes Path)))
      (fs-test.check "failed replacement leaves no temporary files" Before
        (freeze (fs-test.ok (fs.list (value fs-test.root) []))))
      (fs-test.check "write and replace" [ok 3]
        (freeze (fs.write-replace Path (buffer.from-string "new"))))
      (fs-test.check "successful replacement contents" "new"
        (freeze (fs-test.bytes Path)))
      (fs-test.check "copy byte limit failure" limit
        (freeze (io.error-domain (fs-test.error (fs.copy-file (fs-test.path "data") Path 5)))))
      (fs-test.check "failed copy keeps original destination" "new"
        (freeze (fs-test.bytes Path)))
      (fs-test.check "bounded binary copy" [ok 6]
        (freeze (fs.copy-file (fs-test.path "data") Path 6)))
      (fs-test.check "copy preserves binary bytes" true
        (freeze (buffer.equal? (fs-test.ok (io.read-file (fs-test.path "data") 6))
                              (fs-test.ok (io.read-file Path 6)))))
      (fs-test.check "copy directory rejected" true
        (freeze (io.error? (fs-test.error (fs.copy-file (fs-test.path "listing") Path 10)))))
      (let Result (fs.write-replace (fs-test.path "listing") (buffer.from-string "unchanged"))
        (fs-test.check "failed rename preserves written progress" 9
          (freeze (io.error-progress (fs-test.error Result)))))
      (fs-test.check "failed rename leaves no temporary files" Before
        (freeze (fs-test.ok (fs.list (value fs-test.root) []))))))

(let Home (value *home-directory*)
     _ (set *home-directory* (value fs-test.relative))
     Copied (fs.copy-file "data" "relative-copy" 6)
     Info (fs-test.ok (fs.stat "data"))
     ViaInfo (io.read-file (fs.path Info) 6)
     _ (set *home-directory* Home)
  (do (fs-test.check "relative home resolved once during copy" [ok 6] (freeze Copied))
      (fs-test.check "metadata paths can be reused by I/O" 6
        (freeze (buffer.length (fs-test.ok ViaInfo))))))

(let Root (fs-test.path "tree")
     Expected (if (value fs-test.links) 6 5)
     Result (fs.walk Root [] (/. Info Depth continue))
     Shallow (fs.walk Root [[depth-limit 0]] (/. Info Depth continue))
     Stop (fs.walk Root [] (/. Info Depth stop))
     Limited (fs-test.error (fs.walk Root [[entry-limit 1]] (/. Info Depth continue)))
     Skip (fs.walk Root []
            (/. Info Depth (if (= (fs.name (fs.path Info)) "b") skip continue)))
     Fault (fs-test.error (fs.walk Root [] (/. Info Depth (error "visitor threw"))))
     Home (value *home-directory*)
     Change (fs.walk Root []
              (/. Info Depth (do (set *home-directory* "does-not-exist") continue)))
     _ (set *home-directory* Home)
  (do (fs-test.check "walk visits tree and does not follow loops" [ok (@p Expected false)]
        (freeze Result))
      (fs-test.check "depth zero visits root only" [ok (@p 1 false)]
        (freeze Shallow))
      (fs-test.check "walk supports early stop" [ok (@p 1 true)]
        (freeze Stop))
      (fs-test.check "walk enforces global entry budget" limit
        (freeze (io.error-domain Limited)))
      (fs-test.check "walk error reports visited count" 1
        (freeze (io.error-progress Limited)))
      (fs-test.check "walk prunes selected directory" [ok (@p (- Expected 2) false)]
        (freeze Skip))
      (fs-test.check "walk catches visitor exception" shen
        (freeze (io.error-domain Fault)))
      (fs-test.check "walk snapshots home setting" [ok (@p Expected false)]
        (freeze Change))))

(if (value fs-test.links)
    (fs-test.check "walk does not follow a linked root with a trailing slash"
      [ok (@p 1 false)]
      (freeze (fs.walk (fs-test.path "tree/loop/") [] (/. Info Depth continue))))
    skip)

(if (value fs-test.links)
    (do (fs-test.check "lstat preserves symlink kind" symlink
          (freeze (fs.kind (fs-test.ok (fs.lstat (fs-test.path "file-link"))))))
        (fs-test.check "stat follows symlink" file
          (freeze (fs.kind (fs-test.ok (fs.stat (fs-test.path "file-link"))))))
        (fs-test.check "broken symlink exists only without following" [ok false]
          (freeze (fs.exists? (fs-test.path "broken-link"))))) skip)

(if (value fs-test.denied)
    (fs-test.check "exists does not hide permission errors" 13
      (freeze (io.error-code (fs-test.error (fs.exists? (fs-test.path "denied/file")))))) skip)

(if (value fs-test.raw)
    (let Bytes (shen-jit.u8! (shen-jit.bytes 1) 0 255)
         Path (cn (fs-test.path "raw/") (shen-jit.bytes->string Bytes 0 1))
         Names (fs-test.ok (fs.list (fs-test.path "raw") []))
      (do (fs-test.check "POSIX names preserve non-UTF-8 bytes" 255
            (freeze (shen-jit.u8 (shen-jit.string->bytes (hd Names)) 0)))
          (fs-test.check "POSIX non-UTF-8 metadata" 1
            (freeze (fs.size (fs-test.ok (fs.stat Path))))))) skip)

(let Path (fs-test.path "collision")
     _ (io.write-file Path (buffer.from-string "existing"))
     Error (fs-test.error (fs.temp-open Path))
  (do (fs-test.check "exclusive creation refuses an existing file" 17
        (freeze (io.error-code Error)))
      (fs-test.check "exclusive creation does not change existing bytes" "existing"
        (freeze (fs-test.bytes Path)))))

(let Saved (io.record [[]])
     Result (fs.with-temp-file (value fs-test.root) "cleanup-"
              (/. Path E
                (do (address-> Saved 0 Path)
                    (io.close E)
                    (fs.remove-file Path)
                    (fs.mkdir Path)
                    [error (io.native-error callback fixture 37 Path "primary error")])))
     Error (fs-test.error Result)
     _ (fs.remove-directory (<-address Saved 0))
  (do (fs-test.check "primary error survives failed temporary cleanup" 37
        (freeze (io.error-code Error)))
      (fs-test.check "cleanup failure is retained separately" unlink
        (freeze (io.error-operation (hd (io.error-secondary Error)))))))

(let From (fs-test.path "unicode-λ.bin")
     To (fs-test.path "renamed-λ.bin")
     Info (fs-test.ok (fs.stat From))
     Renamed (fs.rename From To)
     Restored (fs.rename To From)
  (do (fs-test.check "Unicode metadata" 6
        (freeze (fs.size Info)))
      (fs-test.check "Unicode rename" [ok]
        (freeze Renamed))
      (fs-test.check "Unicode rename restored" [ok]
        (freeze Restored))))

(output "~A passed, ~A failed~%" (value fs-test.passed) (value fs-test.failed))
