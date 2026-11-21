\\ Fixed fields from gitformat-index and gitformat-pack. The variable object IDs and
\\ entry bodies are handled by the index and pack readers.
(shen.x.namespace git
  (use buffer)
  (import layout deflayout write-layout)
  (export index-header.signature index-header.version index-header.count
    pack-header.signature pack-header.version pack-header.count)

(deflayout index-header
  (signature 32)
  (version 32)
  (count 32))

(deflayout index-stat
  (ctime-seconds 32) (ctime-nanoseconds 32)
  (mtime-seconds 32) (mtime-nanoseconds 32)
  (device 32) (inode 32)
  (mode 32) (uid 32) (gid 32)
  (file-size 32))

(deflayout pack-header
  (signature 32)
  (version 32)
  (count 32))

(deflayout pack-index-header
  (signature 32)
  (version 32))

(define index-signature
  {--> fixnum}
  -> 1145655875)

(define pack-signature
  {--> fixnum}
  -> 1346454347)

(define pack-index-signature
  {--> fixnum}
  -> 4285812579)

(define encode-index-header
  {fixnum --> fixnum --> buffer.view}
  Version Count ->
    (let Header (buffer.new (index-header.size))
      (write-layout index-header Header 0
        (signature (index-signature)) (version Version) (count Count))))

(define encode-pack-header
  {fixnum --> buffer.view}
  Count ->
    (let Header (buffer.new (pack-header.size))
      (write-layout pack-header Header 0
        (signature (pack-signature)) (version 2) (count Count))))

(define encode-pack-index-header
  {--> buffer.view}
  -> (let Header (buffer.new (pack-index-header.size))
       (write-layout pack-index-header Header 0
         (signature (pack-index-signature)) (version 2))))
)
