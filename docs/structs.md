# Managed structs

`defstruct` declares a fixed layout over one managed `absvector`. It is available in the default image;
no library needs loading. Put declarations in a source file and load that file with `load` or `-l`:

```shen
(defstruct entry
  key
  (mutable value))

(let E (entry.make "answer" 41)
  (do (entry.value-> E 42)
      [(entry? E) (entry.key E) (entry.value E)]))
```

The result is `[true "answer" 42]`. Bare fields are read-only through the generated API; `(mutable Field)`
also generates a setter. A setter takes the record followed by its new value and returns the same record.
Other references to that record see the update.

This first version supports declarations in source files. A declaration expands to several top-level
definitions, so entering one through the REPL or `eval -e`, which takes only the first expanded form,
does not install the complete API. Defaults, inheritance and native/unboxed layouts are
outside this version.

## Generated operations

For the declaration above:

| Operation | Meaning |
| --- | --- |
| `(entry.make Key Value)` | Construct a record; arguments follow declaration order |
| `(entry? X)` | Test the record's nominal tag; other ordinary values return false |
| `(entry.key E)` | Read `key` |
| `(entry.value E)` | Read `value` |
| `(entry.value-> E Value)` | Update `value`, returning E |

These are ordinary functions, including the positional constructor, so they can be passed with `fn`.
There is no `entry.key->`. Field names must be literal symbols and unique; `make` and names beginning with
`%` are reserved. A declaration that would generate colliding operation names, or replace an existing
function on its first definition, raises.

The predicate distinguishes records from different declarations even when their fields agree. Readers
and setters assume a record of the declared type; they do not validate its tag on each operation. Use
the predicate at boundaries. The representation is private: manually forging an absvector or changing
its tag/slots with `address->` bypasses these contracts and read-only fields.

## Printing

A record prints with its type and fields, each value as `~S` shows it:

```shen
(entry.make "answer" 42)    \\ #<entry key: "answer" value: 42>
```

`(printer F)`, anywhere in the declaration, prints with F instead: F takes the record and returns a
string. F is a function name or any expression that gives a function, and resolves where the declaration is, as any
other reference does. Use it for records that hold closures, buffers or large values:

```shen
(define show-entry E -> (make-string "#<entry ~A>" (entry.key E)))

(defstruct entry
  (printer show-entry)
  key
  (mutable value))
```

The printer is not part of the layout: a reload may change it, and records made before take the new one.
A declaration has one printer at most.

## Types

Fields may have types, all of them or none:

```shen
(defstruct point
  (x : number)
  (mutable y : number))
```

Then the operations have types: `point.make` is `number --> number --> point`, `point.x` is
`point --> number`, `point.y->` is `point --> number --> point` and `point?` is `A --> boolean`. `point`
is a type of its own, whose only values are what `point.make` returns. Under `(tc +)` the declaration is
typechecked as the definitions it makes; under `(tc -)` it declares the same types, so typed code can use
a struct that untyped code declared. Labelled construction typechecks as the call it becomes, and
a pattern as the record it matches: in `{point --> number}`, `(:point x <- X ...) -> X` checks, and
a pattern of another struct, or a field pattern of the wrong type, is a type error.

A field's type is any closed type, such as `(list number)` or another struct, and resolves in a namespace
as a signature's does. Type variables are refused, and so is a declaration that types some fields and not
others. Under `(tc +)`, a struct whose fields have no types is refused: give them types or load it under
`(tc -)`. The types are part of the layout: reloading with another type is an incompatible redefinition.

Typed and untyped structs make the same code, and cost the same.

## Labelled construction and matching

`:` followed by a struct type and labelled fields, in any order, constructs a record:

```shen
(:entry value <- 42 key <- "answer")
```

Every field must appear exactly once. Each value is one form, so fields need no separator: they
follow one another, on one line or several. Unknown, duplicate and missing fields
raise while reading. Each value is evaluated once, in the order written, before the record is made with
the values in declaration order. The declaration must precede its use in source order. `struct.make`
is a longer name for the same thing: `(struct.make entry value <- 42 key <- "answer")`. The reader
reads `:entry` as `:` and `entry`, so `(: entry ...)` is the same form.

The same form is a pattern in `define`:

```shen
(define describe
  (:entry key <- K value <- V) -> (make-string "~A is ~A" K V)
  _ -> "not an entry")

(define key-of
  (:entry key <- K ...) -> K)
```

A pattern tests that the value is a record of that struct, then matches each named field against its
own pattern, which may be any pattern: a variable, `_`, a literal, a list, or another struct's. A final
`...` leaves the other fields out; without it, every field must be named. A pattern reads only the fields
it names: `key-of` compiles to `(entry? V)` and `(entry.key V)`. Nothing else is a struct pattern: the
positional `entry.make` is not one.

`...` has no meaning in a construction: there, the fields it leaves out are free variables, an error
when the definition is compiled.

Both expand to a call of `entry.%make`, an internal constructor that is never written by hand: as a
construction it makes the record, and as a pattern a handler of the kernel's pattern-matching extension
compiles it.

## Several structs as one type

Every record carries its struct's tag, so a function can match several structs, one clause each:

```shen
(defstruct circle radius)
(defstruct rect width height)

(define area
  (:circle radius <- R) -> (* 3.14159 (* R R))
  (:rect width <- W height <- H) -> (* W H))
```

The set stays open: a struct declared later needs no change to the others, and functions read after
its declaration can match it too. A value that matches no clause falls through to Shen's partial
function error, as with any `define`; nothing checks that every struct is covered. Tags are nominal:
two declarations with the same fields are two types, and their predicates tell them apart.

In typed code, `struct.union` makes the set a type. Each struct named must have field types:

```shen
(defstruct circle (radius : number))
(defstruct rect (width : number) (height : number))
(struct.union shape circle rect)

(define area
  {shape --> number}
  (:circle radius <- R) -> (* 3.14159 (* R R))
  (:rect width <- W height <- H) -> (* W H))
```

A circle is then a `shape`, and a `shape` matched by a circle's pattern gives that circle's fields their
types. A `shape` is not a circle otherwise: `(circle.radius S)` on a `shape` is a type error. The union
stays open as well: a later declaration, in this file or another, adds to it.

```shen
(defstruct square (side : number))
(struct.union shape square)
```

In a namespace, `struct.union` is the `struct` namespace's `union`, used through its prefix or imported.

With `...`, a pattern names only the fields it uses, so adding a field to a struct leaves such
patterns as they are.

## Namespaces and images

A namespace qualifies the type and its generated operations. Field labels remain literal even when
they have the same spelling as a system function or imported alias; initializer expressions resolve
in the caller's scope normally. Generated bodies cannot capture the caller's shadowed primitives.
Import the declaration keyword from `struct`. `:` needs no import; `struct.make` is used through the
`struct` prefix. Export the type name as well as the operations clients need: a construction or a
pattern resolves its type through the same imports and export checks as ordinary references.

```shen
(shen.x.namespace catalog
  (import struct defstruct)
  (export entry entry.make entry? entry.key entry.value entry.value->)

  (defstruct entry key (mutable value)))

(shen.x.namespace application
  (use catalog => c)
  (export answer)

  (define answer
    -> (let E (:c.entry value <- 42 key <- "answer")
         (value-of E)))

  (define value-of
    (:c.entry value <- V ...) -> V))

(application.answer)    \\ 42
```

Identical declarations can be reloaded. They reuse the original private tag, so existing records remain
valid. Changing field order, field names or mutability raises before any generated function is replaced;
start a fresh process to experiment with a different layout. Schemas, syntax registrations, the
pattern handler and records survive saved images. A tag is a fresh symbol, separate from every public operation, bound
only to the record's printer.

The kernel's namespace annotator protects field descriptors and construction labels before name
resolution. A separate declaration callback checks generated names against imports. Both are registered
once for the syntax, independently of individual schemas; Shen/JIT does not replace the namespace walker.
The struct expander consumes protection only in literal field positions, preserving initializer expressions.
`<-` is system punctuation and needs no protection.

With the older `package` form, include `defstruct` and `struct.make` in its external-symbol list when used.
`:` needs nothing there.

## Cost

A constructor allocates one vector with one tag slot plus one slot per field. Its values are ordinary
managed Shen values, and construction can trigger GC. Readers and setters use constant slot indices;
they allocate nothing on success and consult no schema or field-name table. The predicate uses the
runtime's tagged-vector primitive, with no handler. Labelled construction binds only the values that
may have effects, to keep their order, and passes the rest straight to the constructor: it compiles to
what the positional call does, and builds no runtime field list.

Readers, setters, the predicate and a constructor of up to nine fields are inlined, and then cost what
the `<-address`, `address->` and `absvector` they replace do. Two things differ from a vector written by
hand:

- Code compiled before a declaration calls its operations instead of inlining them, since they did not
  exist yet. Declare a struct before the definitions that use it.
- A record that had no tag gains a word. For one made in great numbers that shows: Datalog's union-find
  cells stay vectors for that reason.

A struct's name resolves as any other name in a namespace: one that is already a global function, such as
stlib's `index`, needs `(shadow index)` for the struct to be the namespace's own.

This is for builders, cursors, connection state and other fixed records otherwise written as numbered
`absvector` accesses. It does not have the allocation/GC contract of the native authoring DSL.

## In the libraries

The libraries' fixed records are structs: byte views, cursors and builders, I/O endpoints, readers and
writers, framers and deadlines, subprocess options, children and reports, HTTP requests, responses, body
readers and server state, curl clients and responses, filesystem metadata and traversal state,
Tree-sitter languages and snapshots, and Datalog's classes, indexes and demand stores. They print as
`#<view 0..5>`, `#<endpoint "stdin" open>` or `#<child 1234 exited 0>`, and their public API and errors
are unchanged. Libraries that read another's records use its exported readers, such as
`buffer.view.start` and `io.endpoint.state`.

Some stay vectors: what a C adapter reads by position (subprocess spawn requests, curl and Tree-sitter
configurations) or returns, records that generated or native code reads by slot (a grammar's parse
state), one-slot counters, and a handle's record, which the runtime's pointer guard holds.
