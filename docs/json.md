# JSON

[lib/json.shen](../lib/json.shen) decodes and encodes complete UTF-8 JSON values over
[buffers](buffers.md). Load `buffer.shen`, `grammar.shen` and `json.shen` under `(tc -)` before checking clients
with `(tc +)`. They work in static builds and have no FFI, kernel-stream or I/O dependency. The decoder is a
[grammar](grammar.md) of RFC 8259. An application
can obtain its bounded input view from our [I/O readers](io.md) or [HTTP bodies](http.md).

```shen
(let Value (json.parse "{c#34;namec#34;:c#34;Shenc#34;,c#34;countc#34;:42}" [])
     Wire (json.encode Value [[byte-limit 1024]])
  (buffer.string Wire))
```

This returns `{"name":"Shen","count":42}`. `json.decode View Options` accepts an existing logical byte
view; `json.parse Text Options` copies a Shen string into one first. Both require exactly one complete
value with optional JSON whitespace before/after it. They reject trailing values and bytes outside JSON
syntax. Text syntax follows [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.html), with strict UTF-8,
paired surrogate escapes and duplicate-key rejection. A BOM is rejected.

`json.read Reader Options` reads one value from an [I/O reader](io.md) as it arrives, with `io.shen` loaded:
the whitespace before it and the value, leaving what follows unread, so concatenated or newline-delimited
values need no framing.

```shen
(let R (io.reader (io.input-buffer (buffer.from-string "{c#34;nc#34;:1} c#10;[2] 3")) [])
  [(json.read R []) (json.read R []) (json.read R []) (json.read R [])])
```

This returns `[ok [object ["n" [number "1"]]]]`, `[ok [[number "2"]]]`, `[ok [number "3"]]` and `[eof]`.
It gives `[error Error]` when the reader fails, and raises for a syntax error as `json.decode` does, with an
offset counted in the stream, or `"input ended"` when the input stops inside a value. The value must fit
the reader's capacity, which takes the place of `byte-limit`; `depth-limit` applies. In typed code its
type is `io.reader --> (list json.option) --> (grammar.read-result json.value)`, as [grammar](grammar.md#types)
gives it.

## Values and numbers

| JSON | Shen value |
| --- | --- |
| String | An owned string, including NUL when escaped in the JSON source |
| Number | `[number Token]`, retaining the exact decimal spelling |
| Boolean | `true` / `false` |
| Null | `null` |
| Array | A list of JSON values; `[]` is the empty array |
| Object | `[object [Key Value] ...]`, retaining member order |

Object keys are strings. Duplicate keys are rejected after escape decoding, including `"a"` alongside
`"\u0061"`. Array elements cannot contain a bare `object` or `number` symbol, so the tags are distinct
from ordinary arrays. The recursive `json.value` datatype supports these forms in typed clients.

Numbers are not passed through the Shen reader or silently rounded to doubles. Huge integers,
exponents, negative zero and trailing fractional zeros remain lossless tokens. `json.number Text`
validates a complete number token and constructs that value. `json.integer Value` explicitly converts
an ordinary decimal integer token to an exact fixnum, including its smallest negative value. Fractional
or exponent forms and out-of-range integers raise; `-0` converts to integer zero. It also accepts an
existing native fixnum. Approximate real conversion is a separate application choice.

```shen
(let Exact (json.number "123456789012345678901234567890.00e+99")
     Small (json.integer (json.number "42"))
  [(json.stringify Exact []) Small])
```

This returns the original number spelling and integer 42. The encoder also accepts native Shen numbers
for convenient application construction. It validates their printed number syntax and rejects NaN and
infinities. A native real already has the precision of its stored value; use a token when its original
text matters.

## Encoding and limits

`json.encode Value Options` produces owned managed wire bytes. `json.stringify Value Options` returns
an independent string containing those bytes. The encoder preserves object order and number-token
spelling, emits compact separators, escapes quotes, backslashes and controls, and keeps valid UTF-8 text.
Malformed values, improper lists, bad object members, duplicate keys and invalid UTF-8 strings raise.

```shen
(json.stringify [object ["message" "hello c#34;Shenc#34;c#10;"]
                        ["values" [true null [number "-0"]]]] [])
```

Options are `[Name Number]` pairs:

| Option | Default | Meaning |
| --- | --- | --- |
| `byte-limit` | 1048576 | Maximum input bytes when decoding, or output bytes when encoding |
| `depth-limit` | 128 | Maximum nested containers, 0..256; scalars need no container depth |

Unknown, duplicate, malformed and negative options raise. One array/object consumes one depth level,
including an empty container. Output uses a [bounded builder](buffers.md#bounded-builders), with
geometric growth and no repeated concatenation of the serialized prefix. The byte limit bounds wire
size and builder capacity, not all memory occupied by an input/value graph or temporary string copies.
Decoded lists, strings and object dictionaries occupy additional memory proportional to the input.

Syntax errors report a byte offset in the input view's backing owner, matching the buffer scanner's
owner-relative coordinates, and what was expected there. Other invalid arguments, limits and encoding failures raise too. Results
own their strings and bytes; they survive input mutation or release after the call. A caller must keep
foreign input alive and stable during decoding. Builders and input readers belong to one task.

## Application and verification

The [SQLite HTTP example](../example-apps/sqlite-http/README.md) uses this encoder for every JSON
response and decodes bounded JSON PUT bodies, including chunked requests. Its integer field has an
explicit application range and schema rather than accepting arbitrary JSON as SQL parameters.

`make test-json` covers syntax, Unicode, exact number tokens/conversion, builder bounds, native foreign
input, typed clients, saved images and every-allocation GC. `python3 tests/json_oracle.py build/shen-jit`
checks decoding and encoding against Python's independent JSON implementation. The earlier buffer
example delegates to this library, retaining its byte-view interface. Incremental/event JSON parsing,
pretty printing and approximate numeric conversion are future additions driven by clients.
