# Conditions, proved

[lib/refine.shen](../lib/refine.shen) lets typed code say what must hold of what it is given: that an index is inside
its buffer, that a list is sorted or has an element, that a mode is one of two. It proves it of code that the kernel has
typechecked, with [`smt`](smt.md). Its module is `refine`.

It is experimental. Its names, and what it accepts, may change from one release to the next, and it may prove what is not
so. So conditions are tested as the program runs, though they were proved, until [`(refine.test -)`](#contracts) says not
to. They cost nothing then.

```shen
(refine.type octet N where (and (fx<= 0 N) (fx<= N 255)))

(define-checked byte-at
  {B : buffer.storage --> I : fixnum --> octet}
  {requires (fx<= 0 I) (fx< I (shen-jit.bytes-length B))}
  B I -> (shen-jit.u8 B I))

\\ How long the record at I is: a tag, a byte that says how many follow, and those. -1 if it is cut short.
(define-checked record-length
  {B : buffer.storage --> I : fixnum --> R : fixnum}
  {requires (fx<= 0 I)}
  {ensures (or (fx= R -1) (and (fx<= 2 R) (fx<= (fx+ I R) (shen-jit.bytes-length B))))}
  B I -> (if (fx> (fx+ I 2) (shen-jit.bytes-length B))
             -1
             (let N (fx+ 2 (byte-at B (fx+ I 1)))
               (if (fx> (fx+ I N) (shen-jit.bytes-length B)) -1 N))))

(define-checked count-records
  {B : buffer.storage --> I : fixnum --> fixnum --> fixnum}
  {requires (fx<= 0 I) (fx<= I (shen-jit.bytes-length B))}
  B I Count -> (if (fx= I (shen-jit.bytes-length B))
                   Count
                   (let N (record-length B I)
                     (if (fx= N -1)
                         (error "the record at ~A is cut short" I)
                         (count-records B (fx+ I N) (fx+ Count 1))))))

(define records
  {buffer.storage --> fixnum}
  B -> (count-records B 0 0))
```

```sh
shen-jit eval -m refine -e '(tc +)' -l records.shen
```

Every read there is inside its buffer, and every step stays within it. Were the first test of `record-length` to
read `(fx+ I 1)`, the file would not load:

```text
type error in rule 1 of record-length: byte-at needs (fx< (fx+ I 1) (shen-jit.bytes-length B)), which may not be so,
as if I is 0 and (shen-jit.bytes-length B) is 1
```

There are more programs under [Examples](#examples).

## Contracts

```shen
(define-checked F
  {X : T --> Y : U --> Result : V}
  {requires Condition ...}
  {ensures Promise ...}
  Clauses)
```

`define-checked` is `define` with a contract, either part of which can be left out, or both. The signature names the
arguments and the result: `X : T` is an argument X of type T, and a type alone an argument that no condition is of.
Conditions and promises are Boolean expressions over those names, the result's in promises alone, and bind nothing: a
`let` or a lambda in one is an error. Each must hold.

- **A condition is what a call must meet.** A direct call in typed code, with all its arguments, must prove it, or is a
  type error. Any other call, from untyped code, a macro or a side condition, through `(fn F)` or `(F X)` with some of its
  arguments, or checked before F had the condition, tests it as it runs, and raises `F: not so: ` and what is not so,
  where an argument with no name is `Argument%` and its place.
- **A promise is what a call then gives,** if it gives something: nothing proves that a function ends. Each value that
  the clauses can give must prove it, but for `error`, and `(fail)` in a `<-` clause, and whoever calls F knows it.
- **The clauses know the condition,** and their own calls of F must meet it as any other must.
- **A condition may call a function with one,** which what is before it must prove, as in
  `{requires (fx< 1 (shen-jit.bytes-length B)) (fx= 7 (byte-at B 0))}`.

A call that was proved calls F, which tests the condition again. One that is not so is an error then, and not believed,
whether `refine` proved what it should not have, what is trusted is not so, or a function was defined again.
`(refine.test -)` ends this for what is checked after it in the same module, or, where there is none, in the REPL and in
files that are no module's, and `(refine.test +)` brings it back. F is then two functions, what tests its condition and
its body, which does not, and whose name, as `F.%body` and a number, no program has, though errors and `track` show it.
A call that was proved in such code goes to the body, if F was defined in such code too, and a loop is the code it would
be without conditions. Each contract that F has had has a body of its own, so what was proved to meet one never runs
what needs another. Promises are not tested. Under `(tc -)`, nothing is proved: a `define-checked` tests its condition,
and its promise is taken as said. What was proved of its contract before calls it then.

A contract is as its function was last defined. Another `define-checked` changes it, and a `define` takes it away. The
definitions of a file are checked by its contracts, as by its types, wherever they are in it, and what it evaluates
between them by those of what is defined by then. So, as with types, a definition that is called before what it calls is
defined may be given something else. A file that does not read changes none, nor does a definition that is refused, which
leaves the function as it was. What was proved is not proved again, as what was typechecked is not: not when a function
that is called, or that a condition calls, is defined again, and not by a new `refine.type` of a name. Those,
`refine.contract`, `refine.trust` and `refine.pure` are in effect as they are read.

## What is known

In typed code each expression knows what its place says, in a `define` as in a `define-checked`, and what `input+` reads
too:

| Place | What is known there |
| --- | --- |
| A clause | The condition, its own guard, what its patterns are, and that the clauses before it did not match |
| `(if P A B)` | P in A, and that it is false in B |
| `(and P Q)`, `(or P Q)` | P in Q, or that it is false there |
| `(let X E Body)`, `(do A B)` | What E is, in Body, and what the calls that were made promise, there and after them |
| An argument, a field, a call | What its refined type says, and for a call what it promises, once it has been made |

What is known in a part that may not run, as a branch of an `if`, is known after it as far as that did. Arguments are
known no more than was before them, in whichever order they run.

That an earlier clause did not match is known where its patterns are variables, integers and other constants, `[]`,
lists, pairs, and structs. A pattern matches what is equal to it, as 0 matches 0.0: of a number so matched, only what `=`
and the comparisons say is known. A pattern written again in the action, or what is equal to it, as `[2.5e1 | Xs]` is to
`[25 | Xs]`, is what it matched, as the kernel takes it, unless it has a wildcard, or a `let` or a lambda binds one of its
names or constants. Nothing but its type is known where the patterns have a variable twice, or the same pattern. An action
`(where G E)` of a `->` clause is E with the guard G, and a `where` anywhere else is an error.

A definition is compiled without `protect`, so `(protect X)` is the value of X where X is bound. A `let` or a lambda may
bind a constant, which is then its value wherever that is written, and one that binds a form is an error. A `cond` that a
rule of one's own types is read as `if`s.

A pattern's variable is read from what was matched, again wherever it is written. In what may change, the element of a
vector, a mutable field, or what a pattern of one's own takes apart, it is something else each time, and of a field what
its reader says is known each time: of `(:account balance <- B)`, with a mutable balance, a guard of B says nothing of B
in the action. A `let` reads it once, as in `(let N B (if (fx> N 0) (pay-out N) 0))`.

Nothing is known of a lambda's argument, as in `(map (/. N (at N)) Ns)`. A function with a signature in its place knows
what its type says. The types are those that the kernel has checked, as far as signatures, structs, patterns of lists
and pairs, and what calls are given tell them: what a datatype's rule says of a pattern's variable is not read, nor is a
variable's type from its uses. A Boolean is true or false, a list empty or a cons, and a pair a pair: a datatype that
gives one of those types to other values breaks that.

## What can be said

| Of | What is read |
| --- | --- |
| Fixnums | `fx<`, `fx<=`, `fx>`, `fx>=`, `fx=` and `=`, of terms made with `fx+`, `fx-` and `fx*` by a constant, and of quotients, remainders, shifts and masks by one |
| Numbers and floats | `<`, `<=`, `>`, `>=`, `fl<` and the rest, and `=`, by their order |
| Symbols and strings | `=`, with each other and with constants, which are all different |
| Any that `=` is read of | `element?` of a list that is written, as in `(element? Mode [read write])`, and `=` of lists and pairs that are |
| Bytes and buffers | The length of what is made, sliced, copied into or written, and the [layout](layout.md) sizes, as `(header.size)` |
| Lists | `empty?`, `cons?` and `(= Xs [])`, and the `length` of one, of `append`, `reverse`, `map` and `tail` |
| Pairs and structs | What `fst` and `snd`, and the reader of a field that does not change, give of one that was made |
| Anything | What a pure function gives, as itself: a Boolean one is true or false, the same each time |

`and`, `or`, `not` and `if` combine them, a Boolean variable is one, and `=` of two Booleans is too. Any other term, such
as a product of two variables, is something unknown. What cannot be read proves nothing.

- **A predicate needs no meaning.** `(refine.pure sorted?)` says that `sorted?` gives the same for the same list. A
  test of it, or a promise, then proves a condition that asks for it, of the same list. A function that a pure one is
  given is the same if it is pure itself, and so is one with some of its arguments that are the same each time, as in
  `(all? (fx< 3) Ns)`. A function that is an argument, or a lambda, may not be, and `(= V)` of what may change is not, so
  a pure function that is given one of them may give something else.
- **A promise that equates names a condition.** With `{ensures (= R (and (fx<= 0 I) (fx< I N)))}`, a call
  `(in-range? I N)` is read as what it equals, in tests, in other conditions and in types. A fixnum can be named so
  too, by `(fx= R (fx+ I N))`. Functions whose promises name each other in a circle are not read so.
- **Fixnums are integers here,** as an operation whose result is no fixnum raises: one that a program has is the
  integer that the proof was about. So are numbers that are always integers, as a `length` is.
- **Bits are arithmetic.** A shift to the right by a constant of up to 32 is a quotient rounded down, a mask of up to
  32 ones is the remainder that goes with it, and a shift to the left is a product where what is shifted fits in 24
  bits. Of `shen-jit.bit-or` and `shen-jit.bit-xor`, what is known is that they are no more than the sum, for numbers
  from 0, and have 8, 16 or 32 bits where both do.
- **Other numbers have only their order.** Float arithmetic rounds, so `(+ X 1)` is some number and no more. And a
  float may be no number, for which every comparison is false: that `(< X 0)` is false says that X is at least 0 or is
  no number, so a guard that leaves only numbers from 0 to the clauses after it is `(not (>= X 0))`.
- **What changes is never the same.** The elements of a vector, mutable fields and calls that are not pure give
  something else each time they are written, and so does `=` of two vectors, or of two values of a type that may have
  what changes, as one that is not known; a `let` names what was given once. Where a condition fails for that, the error
  says which function is not declared pure.

```shen
(define sorted?
  {(list number) --> boolean}
  [X Y | Zs] -> (and (<= X Y) (sorted? [Y | Zs]))
  _ -> true)

(refine.pure sorted?)

(define-checked least
  {Xs : (list number) --> number}
  {requires (sorted? Xs) (not (empty? Xs))}
  [X | _] -> X)

(define-checked least-or-0
  {(list number) --> number}
  [] -> 0
  Xs -> (if (sorted? Xs) (least Xs) 0))
```

## Refined types

```shen
(refine.type octet N where (and (fx<= 0 N) (fx<= N 255)))
(refine.type probability X : number where (and (>= X 0) (<= X 1)))
(refine.type (nonempty A) Xs : (list A) where (not (empty? Xs)))
```

Each is a name for a base type, `fixnum` if none is named, and for a condition on what is given that type in a signature
or as a struct's field:

- **An argument's is a condition,** which calls must prove and F tests, in a `define` as in a `define-checked`, but for a
  `define` under `(tc -)`, which `refine` does not see.
- **A result's is a promise,** which each value must prove. With `(define below {octet --> octet} N -> (fx- N 1))`, it is

  ```text
  type error in rule 1 of below: below promises (fx<= 0 (fx- N 1)), which may not be so, as if N is 0
  ```

- **A field's** is a condition on calls of the constructor, and of what changes the field, and known of what is read, as
  its type was when the struct was declared. Those functions do not test it, so they are only for direct calls: `(fn
  account.make)` is an error. What untyped code or `eval` makes of a struct is believed all the same, as its type is.
- **`(type E octet)`** must be proved of E.

A type may be over another, as `(refine.type digit N : octet where (fx<= N 9))`, which says what that says too. The
kernel takes each for its base, so what it makes of one, as a list, is of the base: a refined type is for a whole
argument, result or field, and an error in a signature that has it in another, as `(list octet)`. In a datatype's rule
it is its base, and so is it in a synonym, so that `(synonyms byte octet)` says nothing of a byte. Declare it before the
structs that have fields of it.

The condition must be a Boolean of a value of the base type, which is checked with the next typed form, as it may call
what is defined after it. Type variables of the base must be parameters, and the name one that no type of the kernel's,
and no struct, union, datatype or synonym, has.

## What is trusted

| Declaration | Says |
| --- | --- |
| `(refine.trust (F X Y) --> Result where Promise)` | What a call of F gives, for a function that `refine` does not check |
| `(refine.pure F ...)` | The same arguments give the same result, whenever it is called |

Nothing checks either. What `refine.trust` says must hold whatever the arguments are, as a condition can name a call
that would raise: say for which, as in `(or (empty? L) (= (length R) (- (length L) 1)))`. Only functions of what does
not change are pure, and not those of a vector's elements, nor of mutable fields. `refine` declares the arithmetic, the
comparisons, the functions of lists and pairs above, the type predicates, `limit` and `fxlimit`, the divisions and the bit
operations, `shen-jit.bytes-length` and `buffer.length`, and says what `fxquotient`, `fxremainder`, the bit operations,
`shen-jit.u8` and the other reads, and the lengths, can give, and how long what `shen-jit.bytes`, `buffer.new`,
`buffer.slice` and the functions that write to a buffer give is. What it says of `buffer`'s functions is known once that
is loaded, and of no function that a program defines in their place. That bytes keep their length is not so of those that
`memory.free` gives back, which have none. A struct's constructor, its test and the readers of its fields that do not
change are pure, for as long as they are those that `defstruct` made.

## Functions made elsewhere

```shen
(refine.contract (buffer.u8 V I) --> R
  requires (fx<= 0 I) (fx< I (buffer.length V))
  trusts (fx<= 0 R) (fx<= R 255))
```

`refine.contract` gives a contract to a function that is there already, with `requires`, `trusts`, or both. The names
are of its arguments, in order, as many as it takes, and of its result, `--> R`, which only what is trusted can be of.
Conditions are checked to be Booleans of the types the function has, if it has any by then. A form that `refine` reads
itself, as `if` or `let`, has none.

- **`requires` must be proved by each direct call in typed code,** as a condition is. The function that runs is the
  same, and tests what it did: a contract makes a program say before it runs what would have raised. It is for a
  function that is safe by itself, and costs nothing as the program runs.
- **`trusts` is taken as said,** as the body is not read again. It is known once the call has been made.
- **It binds who asks for it.** A contract in a module is for that module's sources and for those of modules whose
  `requires` names it. A module that requires one of these is not bound, nor is a library, whatever was loaded before.
  In the REPL and in files that are no module's, what has been loaded is for all. Of several modules' contracts of a
  function, each that is for a module holds there. The functions that a [layout](layout.md) makes test what they are
  given, and need no proof.

So contracts go in modules of their own, and a library need not require `refine` to have them. The module
`buffer/contracts` has those of [buffers](buffers.md): that an index is in its view, that a slice and a copy fit, and
that a stored value fits its width.

```shen
(shen.module
  (version 1)
  (name sums)
  (requires buffer buffer/contracts)
  (sources tc+ "sums.shen"))
```

```shen
(define-checked sum-from
  {V : buffer.view --> I : fixnum --> fixnum --> fixnum}
  {requires (fx<= 0 I)}
  V I Sum -> (if (fx>= I (buffer.length V)) Sum (sum-from V (fx+ I 1) (fx+ Sum (buffer.u8 V I)))))
```

## Rules of one's own

`(refine.proves? Hyps Condition)` is for the side condition of a datatype rule, where `ctxt` gives the hypotheses. The
rule's variables are the program's terms. The rule is what types the function, which is defined under `(tc -)`, before the
rule is used:

```shen
(define slice-of B I N -> (shen-jit.copy-bytes (shen-jit.bytes N) 0 B I N))

(datatype slice-of
  ctxt Hyps
  if (refine.proves? Hyps [and [fx<= 0 I] [and [fx<= 0 N] [fx<= [fx+ I N] [shen-jit.bytes-length B]]]])
  B : buffer.storage; I : fixnum; N : fixnum;
  __________________________________________
  (slice-of B I N) : buffer.storage;)
```

A condition that is not proved there fails as any premise does, and the type checker looks for another proof. Only
guards are known there, as the type checker knows nothing else of a place, and a guard of a variable that a pattern
reads from what may change is believed all the same.

## Examples

### A search that stays in its table

```shen
\\ The key at I of a table of 16-bit keys.
(define-checked key-at
  {Table : buffer.storage --> I : fixnum --> fixnum}
  {requires (fx<= 0 I) (fx<= (fx* 2 (fx+ I 1)) (shen-jit.bytes-length Table))}
  Table I -> (fx+ (fx* 256 (shen-jit.u8 Table (fx* 2 I))) (shen-jit.u8 Table (fx+ 1 (fx* 2 I)))))

\\ Where a key is, from Low and before High, or -1.
(define-checked search
  {Table : buffer.storage --> Key : fixnum --> Low : fixnum --> High : fixnum --> R : fixnum}
  {requires (fx<= 0 Low) (fx<= Low High) (fx<= (fx* 2 High) (shen-jit.bytes-length Table))}
  {ensures (fx<= -1 R) (fx< R High)}
  Table Key Low High
  -> (if (fx= Low High)
         -1
         (let Middle (fxquotient (fx+ Low High) 2)
              Found (key-at Table Middle)
           (if (fx= Found Key)
               Middle
               (if (fx< Found Key)
                   (search Table Key (fx+ Middle 1) High)
                   (search Table Key Low Middle))))))

(define index-of
  {buffer.storage --> fixnum --> fixnum}
  Table Key -> (search Table Key 0 (fxquotient (shen-jit.bytes-length Table) 2)))
```

A key is read only where there is one, as Middle is at least Low and less than High. That the table is sorted is not
said: one that is not may give the wrong answer, and never reads outside it. Were `index-of` to take the table's length
in bytes for the number of its keys:

```text
type error in rule 1 of index-of: search needs (fx<= (fx* 2 (shen-jit.bytes-length Table)) (shen-jit.bytes-length Table)),
which may not be so, as if (shen-jit.bytes-length Table) is 1
```

### A date that exists

```shen
(refine.type month M where (and (fx<= 1 M) (fx<= M 12)))

(define leap?
  {fixnum --> boolean}
  Y -> (or (fx= 0 (fxremainder Y 400)) (and (fx= 0 (fxremainder Y 4)) (not (fx= 0 (fxremainder Y 100))))))

(define days-in
  {fixnum --> month --> fixnum}
  Y 2 -> (if (leap? Y) 29 28)
  _ M -> (if (element? M [4 6 9 11]) 30 31))

(refine.pure days-in)

(defstruct date (year : fixnum) (month : month) (day : fixnum))

(define-checked day
  {Y : fixnum --> M : month --> D : fixnum --> date}
  {requires (fx<= 1 D) (fx<= D (days-in Y M))}
  Y M D -> (date.make Y M D))

(define read-date
  {fixnum --> fixnum --> fixnum --> date}
  Y M D -> (if (and (fx<= 1 M) (fx<= M 12) (fx<= 1 D) (fx<= D (days-in Y M)))
               (day Y M D)
               (error "there is no ~A-~A-~A" Y M D)))
```

Whoever makes a date with `day` has asked how long its month is. Without `(refine.pure days-in)`, what `read-date` tests
would say nothing of what `day` needs:

```text
type error in rule 1 of read-date: day needs (fx<= D (days-in Y M)), which may not be so, as if D is 1 and
(days-in Y M) is 0. days-in is not declared pure, so (days-in Y M) may be another each time
```

With the month and the day the wrong way round, it is `day needs (fx<= D 12)`.

### Money that is neither made nor lost

```shen
(refine.type money N where (fx<= 0 N))

(defstruct account (owner : symbol) (balance : money))

(define-checked withdraw
  {A : account --> N : money --> R : account}
  {requires (fx<= N (account.balance A))}
  {ensures (fx= (account.balance R) (fx- (account.balance A) N))}
  A N -> (account.make (account.owner A) (fx- (account.balance A) N)))

(define-checked deposit
  {A : account --> N : money --> R : account}
  {ensures (fx= (account.balance R) (fx+ (account.balance A) N))}
  A N -> (account.make (account.owner A) (fx+ (account.balance A) N)))

(define-checked transfer
  {A : account --> B : account --> N : money --> R : (account * account)}
  {requires (fx<= N (account.balance A))}
  {ensures (fx= (fx+ (account.balance (fst R)) (account.balance (snd R)))
                (fx+ (account.balance A) (account.balance B)))}
  A B N -> (@p (withdraw A N) (deposit B N)))

(define pay
  {account --> account --> fixnum --> (account * account)}
  A B N -> (if (and (fx<= 0 N) (fx<= N (account.balance A))) (transfer A B N) (error "~A cannot pay ~A" A N)))
```

A balance is never below 0, and the two after a transfer come to what they did before. Were `transfer` to forget the
deposit, it would not keep that promise, and were `pay` not to ask whether N is from 0:

```text
type error in rule 1 of pay: transfer needs (fx<= 0 N), which may not be so, as if N is -1
```

### A link that is not used once closed

```shen
(defstruct link (state : symbol) (sent : fixnum))

(define-checked open-link
  {--> R : link}
  {ensures (= (link.state R) up)}
  -> (link.make up 0))

(define-checked send
  {L : link --> N : fixnum --> R : link}
  {requires (= (link.state L) up)}
  {ensures (= (link.state R) up)}
  L N -> (link.make up (fx+ (link.sent L) N)))

(define-checked close-link
  {L : link --> R : link}
  {requires (= (link.state L) up)}
  {ensures (= (link.state R) down)}
  L -> (link.make down (link.sent L)))

(define greet
  {--> link}
  -> (let L (send (open-link) 5)
       (close-link (send L 2))))
```

Each step says what state it leaves, so that the next need not test it. To send after closing:

```text
type error in rule 1 of greet: send needs (= (link.state (close-link L)) up), which may not be so, as if
(link.state (close-link L)) is down
```

### A mean of something

```shen
(define total
  {(list number) --> number}
  [] -> 0
  [X | Xs] -> (+ X (total Xs)))

(define-checked mean
  {Xs : (list number) --> number}
  {requires (not (empty? Xs))}
  Xs -> (/ (total Xs) (length Xs)))

(define summary
  {(list number) --> string}
  [] -> "nothing"
  Xs -> (make-string "~A" (mean Xs)))
```

Without the clause for `[]`:

```text
type error in rule 1 of summary: mean needs (not (empty? Xs)), which may not be so, as if (empty? Xs) is true
```

## What it costs

As the program runs, the tests of its conditions, so that one that walks a list walks it at each call, and nothing after
`(refine.test -)`. The type checker is given what was written, and takes the inferences that it would without `refine`,
but for a few where the datatypes of `smt` are tried, after which each definition is walked once, and each condition
asked of `smt`. A closed program keeps nothing of `refine` or `smt`.

In a namespace, `(import refine define-checked)` gives the name, and `(use refine => r)` gives `r.define-checked`,
`r.contract`, `r.type`, `r.trust`, `r.pure` and `r.test`.
