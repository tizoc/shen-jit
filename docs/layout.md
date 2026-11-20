# Binary layouts

[lib/layout.shen](../lib/layout.shen) declares fixed binary formats the way their specifications draw them:
fields in order, most significant bit first, each a name and a width in bits. It defines typed accessors for
each field, which read and write [byte views](buffers.md), and which a typed caller inlines, so that they
cost what the reads and writes one would write by hand do. Its module is `layout`.

```shen
(deflayout header
  (tag 16) (length 32))
```

```sh
shen-jit eval -m layout -l header.shen \
  -e '(let B (buffer.new 6) (do (header.tag-> B 0 42) (header.length-> B 0 5) [(header.tag B 0) (buffer.u8 B 1) (header.size)]))'
```

This gives `[42 42 6]`. The [frame](framing.md) library declares its header so.

## Fields

`(deflayout Name (Field Bits) ...)` defines, for a layout at offset `I` of a view `B`:

| Definition | What it is |
| --- | --- |
| `(Name.Field B I)` | The field, a fixnum, for a field of up to 56 bits |
| `(Name.Field-> B I X)` | Stores X there, and gives B; X must fit the field, or it raises |
| `(Name.Field-at I)` | The field's offset, for a field that starts on a byte |
| `(Name.size)` | The layout's length in bytes, which must be whole |

Fields are big-endian. A field of whole bytes is one read of 8, 16 or 32 bits, or a few for 24, 40, 48 or
56. A field that is not whole bytes must lie within one byte, 16-bit or 32-bit word at its own alignment, and
is shifted and masked out of it. A field of 64 bits or more, such as an IPv6 address, has only its offset.
`_` names padding, which defines nothing. No two fields share a name, and none is named `size`, which is the
layout's length. Write a header one 32-bit row to a line, as an RFC draws it:

```shen
(deflayout ipv4
  (version 4) (header-length 4) (service 8) (total-length 16)
  (identification 16) (reserved 1) (dont-fragment 1) (more-fragments 1) (fragment-offset 13)
  (time-to-live 8) (protocol 8) (checksum 16)
  (source 32)
  (destination 32))
```

## Whole layouts

Writing a layout field by field makes a read, a mask and a store for each field narrower than a byte.
`(write-layout Name B I (Field Value) ...)` writes every field at once, in 32-bit stores, then 16 and 8, each
the given fields shifted into place, so that constants fold into one number:

```shen
(write-layout ipv4 B I
  (version 4) (header-length 5) (total-length Count)
  (dont-fragment 1) (time-to-live 64) (protocol Proto)
  (source Src) (destination Dst))
```

stores IPv4's first word as `0x45000000` combined with the count. Fields not given are 0; fields of 64 bits or
more are left as they are, for the caller to write. Each value is checked against its field's width, and the
bytes the stores cover against B, once and before any is stored; the stores then go straight to B's storage. It
gives B.

## Named bits

`(defflags Name Bit ...)` names the bits of a flags field, the most significant first, and
`(flag-bits Name Bit ...)` is the number with those bits set, made as the code is read:

```shen
(defflags control cwr ece urg ack psh rst syn fin)
(define handshake? Flags -> (= Flags (flag-bits control syn ack)))
```

`(flag-bits control syn ack)` is 18. It is a constant, so it can also be a pattern.

## In namespaces and typed code

In a namespace, `(import layout deflayout write-layout defflags flag-bits)`. A layout's name is then the
namespace's, as a struct's is, and its field names stay as written: `(deflayout header ...)` in namespace `frame`
defines `frame.header.tag`, which the namespace calls `header.tag`. A layout declared in a typed source has
typed definitions, which a sealed typed caller inlines; `(shen-jit.code F)` then shows the reads and stores
with no call. `write-layout` reads the layout's fields from its property list, which a saved image keeps.
