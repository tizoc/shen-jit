# Byte scans and conversions

The [`bytes` module](../lib/bytes.shen) finds, skips, lowercases and converts the bytes of a range, which parsers and
formats do over and over: HTTP, curl, Git, JSON and the filesystem library use it. Each function is native code written
by hand, and takes the storage `B`, a string, a byte buffer or [memory outside the heap](guide.md#memory-outside-the-heap),
with a range from `At` up to `End`. Every read is checked, as any is, and one call does the whole range. What comes back
is a fixnum, a string or the storage, which cross a call without being boxed.

```shen
(let B (shen-jit.string->bytes "Content-Type:  text/plain ")
     Colon (bytes.find B 0 26 58)
     Blank (bytes.class [9 32])
     Start (bytes.span B (+ Colon 1) 26 Blank)
     Stop (bytes.span-back B Start 26 Blank)
  [(bytes.lower (shen-jit.bytes->string B 0 Colon)) (shen-jit.bytes->string B Start (- Stop Start))])
\\ ["content-type" "text/plain"]
```

To use it, add `bytes` to a module's `requires`, and `(use bytes)` to a namespace that calls it. It loads
[`native`](guide.md#native-code-written-by-hand), and runs on static builds.

| Function | Result |
| --- | --- |
| `(bytes.find B At End Byte)` | Where the first `Byte` from `At` is, or `End` |
| `(bytes.span B At End Class)` | Where the first byte from `At` not in `Class` is, or `End` |
| `(bytes.span-back B At End Class)` | The least `I` from `At` such that the bytes from `I` to `End` are all in `Class` |
| `(bytes.class Members)` | A class: the bytes of a list of strings, bytes, and `[Lo Hi]` for those from `Lo` to `Hi` |
| `(bytes.class-not Class)` | The bytes not in `Class`: `(bytes.span B At End (bytes.class-not C))` finds one in `C` |
| `(bytes.lower! B At End)` | `B`, a buffer, with the ASCII capitals from `At` to `End` made small in place |
| `(bytes.lower Text)` | A new string, `Text` with its ASCII capitals made small |
| `(bytes.hex B At End)` | The bytes from `At` to `End` as a string of small hexadecimal digits, two a byte |
| `(bytes.unhex! To I B At End)` | `To`, with the bytes that the hexadecimal digits from `At` to `End` stand for stored from `I`; `[]` for an odd count or a byte that is no digit |
| `(bytes.decimal B At End Limit)` | The number the decimal digits from `At` to `End` make, from 0 to `Limit`; -1 if there are none or a byte is no digit, -2 past `Limit` |

A class is a string of 32 bytes, a bit for each byte. Written with a list of constants, as above,
`(bytes.class ...)` is made as the code is read, and is then a constant of the code: an
[isolate](guide.md#isolates), whose globals start unbound, has it too, and naming it costs nothing.

In typed code, `B` is a `buffer.storage`, the positions and results are `fixnum`s, and a class is a `string`.
`bytes.class` and `bytes.unhex!` have no type, as their arguments and results mix kinds; a typed program writes its
classes as constants.

`make test-bytes` checks each function against a loop in Shen over random ranges and every byte value, and from typed
code and another isolate.
