# Grammars over bytes

[lib/grammar.shen](../lib/grammar.shen) adds `defgrammar`, Shen-YACC's notation for parsers that read
[byte views](buffers.md) instead of lists. Each definition compiles to an ordinary function over a buffer, a
position and an end, which reads bytes with the same inline primitives a scanner written by hand would use, and
allocates nothing but the values its rules build. Load it after `buffer.shen`, under `(tc -)`, and before the
grammars, which must be in a file read after it:

```shen
(defgrammar <letter> B where (and (>= B 97) (<= B 122));)
(defgrammar <name> (+ <letter>);)
(defgrammar <space> (* 32);)
(defgrammar <names>
  (text <name>) <space> "," <space> <names> := [<name> | <names>];
  (text <name>) := [<name>];)
(defgrammar <list>
  "[" <space> (require <names> <space> "]" "expected names, then ]") := <names>;)
```

```sh
shen-jit eval -l lib/buffer.shen -l lib/grammar.shen -l names.shen \
  -e '(grammar.parse <list> (buffer.from-string "[ab, cd ]") (/. At Message [error At Message]))' \
  -e '(grammar.parse <list> (buffer.from-string "[ab,]") (/. At Message [error At Message]))'
```

The first gives `["ab" "cd"]`, and the second `[error 1 "expected names, then ]"]`.

## Rules

A definition names a rule, which must be a symbol in angle brackets, perhaps after a prefix, as
`http.<token>` is. Its alternatives end with `;`, and each is a sequence of items, then perhaps `:=`
and a value, then perhaps `where` and a guard:

```shen
(defgrammar <digit> B := (- B 48) where (and (>= B 48) (<= B 57));)
```

| Item | Matches |
| --- | --- |
| `13`, a number from 0 to 255 | That byte |
| `"HTTP/"`, a string | Its bytes in order, as UTF-8 |
| `B`, a variable | Any byte, bound to B for what follows |
| `_` | Any byte |
| `<rule>` | That rule |
| `(<rule> Arguments...)` | That rule, given arguments for its parameters |
| `<e>` | Nothing: an empty alternative |
| `<end>` | Nothing, at the end of the input |
| `(* Item)`, `(+ Item)` | Item as many times as it matches, or at least once |
| `(? Item)` | Item, or nothing |
| `(text <rule>)`, `(span <rule>)` | The rule, whose name then stands for the string, or the view, of the bytes it matched |
| `(require Items... Message)` | The items, or the parse stops with Message |
| `(where Guard)` | Nothing, when Guard is true |
| `(at P)` | Nothing, binding P to the position, so that a guard can bound a length |
| `(u16-be N)`, `(u32-be N)` | Two or four bytes, bound to N as an unsigned big-endian number |

Alternatives are tried in order, and the first that matches wins: a later failure never comes back to
try the next one. `(*` and `(+` take as many as they can, and never give any back, so `(* <letter>) <letter>`
never matches. They take one item each: to repeat a sequence, give it a rule of its own. A repetition
runs as a loop, in constant stack, however long the input, and stops at an item that matches nothing.

A rule can take parameters, named after it in parentheses. They can be used in guards, values, messages and the
arguments of other calls, so a grammar can carry a limit or a byte it found:

```shen
(defgrammar (<list> Depth)
  "[" (require (where (< Depth 64)) "nesting too deep") (* (<list> (+ Depth 1))) "]";)
(defgrammar (<not> Q) B where (not (= B Q));)
(defgrammar <quoted> Q (* (<not> Q)) Q2 := Q where (= Q Q2);)
```

The rule's value is named by its name, as for any other, and an entry point gives the first arguments, as in
`(grammar.match? (<list> 0) View)`.

## Values

A rule with `:=` has a value, which its caller names by the rule's name, and a variable in the syntax
names the byte it matched:

```shen
(defgrammar <digits> (+ <digit>);)
(defgrammar <decimal> (text <digits>) "." <digit> := [<digits> <digit>];)
```

`<decimal>` gives `["12" 3]` for `12.3`.

A rule matched twice in one alternative is named for the later match. A rule without `:=` has no value:
naming it is refused when the grammar is defined, and so is naming a rule matched only inside a
repetition. Repetitions build no lists: a list is a recursive rule, as `<names>` is above.

Values cost what they build and nothing more. Rules pass positions, not values, so matching allocates
nothing, and a rule's value is read only where its caller names it. `(text <rule>)` copies the bytes into
a string, and `(span <rule>)` makes a view that shares them, once the alternative has matched, unless a
later item in it names them: an alternative that fails after a capture does not build it.

## Errors

A rule that does not match lets its caller try another alternative. `(require Items... Message)` instead
says that once the parse gets there, the items must match: if they don't, the parse stops, and reports
Message and the position where the items began. Alternatives do not retry a failed require, and
repetitions do not swallow one. The message is an expression, which can name what was matched before the
require, though not what it requires:

```shen
(defgrammar <setting>
  (text <name>) "=" (require (text <digits>) (make-string "~A wants digits" <name>)) := [<name> <digits>];)
```

For `port=x`, this reports `"port wants digits"` at position 5. `(where Guard)` puts a check on values
inside a require, as in `(require <digit> (where (<= <digit> 1)) "unsupported version")`.

A grammar parses a complete span: it does not tell input that ended early from input that is wrong. A
caller that reads in pieces collects one unit first, such as a line or a frame, and parses that. A require
that fails because the span ended reports the span's end as its position.

## Running a grammar

| Function | What it does |
| --- | --- |
| `(grammar.parse <rule> View Fail)` | The rule's value, if it matches the whole view. Otherwise `(Fail Position Message)`. The rule can be `(<rule> Arguments...)` |
| `(grammar.match? <rule> View)` | Whether the rule matches the whole view |
| `(grammar.parse-range <rule> Storage Start End Fail)` | The same as `grammar.parse`, over bytes from Start to End in a buffer's storage, for a library that has already checked them |

The message given to Fail is a require's, `"no match"` when no alternative matched and nothing was
required, or `"trailing input"` at the first byte the rule left. Positions count from the start of the
view's owner, as `buffer.offset` does. With the rule named in the call, as above, the call to it is
direct; a rule passed as a value is called through `fn`, which costs a little more. Fail can raise an
error of the caller's own, or return a value, which `grammar.parse` then returns.

A definition becomes `(define <rule> Buffer At End State -> ...)`, which returns the position after its
match, or -1 when it does not match, and -2 when a require failed. A repetition becomes a function of
its own, `<rule>/1` and so on, which loops by calling itself, and is compiled at its first call, when the
functions its file defines exist. Since a file is read whole before any of it runs, `defgrammar` records
each rule's arity as it is read, so that rules can call each other in any order.
A byte class, a rule that is only `B where Guard`, is not called by the rules read after it: they test the
byte in place, so that `(+ <tchar>)` is one loop with no call per byte, and a loop over a class is called only
if its first byte matches. When a loop first runs, it evaluates each class's guard for all 256 bytes and tests a
table from then on, so a class's guard must depend only on its byte; one that raises for some byte stays a test. Other small rules that do not name themselves are compiled in place too, up to three
deep. So define a grammar's parts before the rules that use them; a rule redefined later is not seen where an
earlier definition was compiled in place.

## Reading as input arrives

`(grammar.read <rule> Reader Fail)` parses one value from an [I/O reader](io.md) as its bytes arrive, with
`io.shen` loaded. It does not need the value framed first, and it never parses again from the start: a rule
that reaches the end of what has arrived waits for the reader to fill more, under the reader's own deadline,
and goes on where it was.

| Result | When |
| --- | --- |
| `[ok Value]` | The rule matched; its bytes are consumed, and what follows stays in the reader |
| `[eof]` | The input ended before a value began |
| `[error Error]` | The reader failed or timed out; nothing is consumed, so a later read can try again |
| `(Fail Position Message)` | A syntax error, at its position in the stream; `"input ended"` if the input ended inside a value |

The parse reads in place, in the reader's buffer, and consumes nothing until the value is complete, so a
value can be no larger than the reader's capacity: a larger one fails with `"input exceeds the limit"`.
`(grammar.read-within <rule> Reader Limit Fail)` sets a smaller limit. Views made by `span` own their bytes
here, as the reader's buffer is reused. The rule matches a prefix of the input, so a rule that should stop
only at the end says so with `<end>`.

The first `grammar.read` of a rule compiles a second version of it, and of the rules it calls, whose bounds
checks wait for input; parsing a complete view is unchanged by it. `(grammar.prepare <rule>)` compiles them
ahead, outside any deadline, as a server does when it starts listening. A task blocks while its parse
waits, as it does for any read, so each connection reads in a task of its own.

## Compared with defcc

`defgrammar` keeps `defcc`'s notation where the meaning is the same: alternatives ended by `;`, `:=`,
`where`, `<e>`, variables, `_`, and a rule named in a value standing for its value. It reads bytes, not
lists, so a number or a string is a terminal, and patterns in brackets are not. It has no `<!>` and no type
signatures, and adds parameters, repetition, captures, requires, binary fields and reading from a reader as
input arrives.
