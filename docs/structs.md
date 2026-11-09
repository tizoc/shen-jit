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
does not install the complete API. Pattern matching, defaults, inheritance and native/unboxed layouts are
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
a struct that untyped code declared. Labelled construction typechecks as the call it becomes.

A field's type is any closed type, such as `(list number)` or another struct, and resolves in a namespace
as a signature's does. Type variables are refused, and so is a declaration that types some fields and not
others. Under `(tc +)`, a struct whose fields have no types is refused: give them types or load it under
`(tc -)`. The types are part of the layout: reloading with another type is an incompatible redefinition.

Typed and untyped structs make the same code, and cost the same.

## Labelled construction

The shared `struct.make` macro accepts a literal struct type followed by labelled fields, in any order:

```shen
(struct.make entry
  value <- 42;
  key <- "answer";)
```

Every field must appear exactly once, with `;` after each expression. Unknown, duplicate and missing
fields raise while reading. Each expression is evaluated once, in the order written, before the
constructor is called with the values in declaration order. The declaration must precede construction
in source order. Unknown types and positional arguments to `struct.make` raise while reading.
The generated `entry.make` remains an ordinary positional function, including when passed with `fn`.

## Namespaces and images

A namespace qualifies the type and its generated operations. Field labels remain literal even when
they have the same spelling as a system function or imported alias; initializer expressions resolve
in the caller's scope normally. Generated bodies cannot capture the caller's shadowed primitives.
Import the declaration keyword from `struct` and use its prefix for labelled construction.
Export the type name as well as the operations clients need: `struct.make` resolves its type through
the same imports and export checks as ordinary references.

```shen
(shen.x.namespace catalog
  (import struct defstruct)
  (export entry entry.make entry? entry.key entry.value entry.value->)

  (defstruct entry key (mutable value)))

(shen.x.namespace application
  (use struct)
  (use catalog => c)
  (export answer)

  (define answer
    -> (let E (struct.make c.entry
                value <- 42;
                key <- "answer";)
         (c.entry.value E))))

(application.answer)    \\ 42
```

Identical declarations can be reloaded. They reuse the original private tag, so existing records remain
valid. Changing field order, field names or mutability raises before any generated function is replaced;
start a fresh process to experiment with a different layout. Schemas, syntax registrations and
records survive saved images. A tag is a fresh symbol, separate from every public operation, bound
only to the record's printer.

The kernel's namespace annotator protects field descriptors and construction labels before name
resolution. A separate declaration callback checks generated names against imports. Both are registered
once for the syntax, independently of individual schemas; Shen/JIT does not replace the namespace walker.
The struct expander consumes protection only in literal field positions, preserving initializer expressions.
`<-` and `;` are system punctuation and need no protection.

With the older `package` form, include `defstruct` and `struct.make` in its external-symbol list when used.

## Cost

A constructor allocates one vector with one tag slot plus one slot per field. Its values are ordinary
managed Shen values, and construction can trigger GC. Readers and setters use constant slot indices;
they allocate nothing on success and consult no schema or field-name table. The predicate uses the
runtime's tagged-vector primitive, with no handler. Labelled syntax adds local bindings to preserve
evaluation order and builds no runtime field list.

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
