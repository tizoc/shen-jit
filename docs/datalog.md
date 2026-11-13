# Datalog

`lib/datalog.shen` evaluates relations, facts and recursive rules bottom up, to a fixed point. It is not in the
image. It needs `lib/native.shen`, and a macro applies only to files read after it, so load them first:

```shen
\\ deps.shen
(defdatalog dependencies
  (relation imports [symbol symbol])
  (relation depends [symbol symbol])
  (relation cyclic [symbol])
  (rule (depends X Y) <-- (imports X Y))
  (rule (depends X Z) <-- (imports X Y) (depends Y Z))
  (rule (cyclic X) <-- (depends X X)))

(let Db (datalog.run dependencies [[imports a b] [imports b c] [imports x y] [imports y x]])
  (do (output "~R~%" (datalog.sorted Db depends))
      (output "~R~%" (datalog.ask Db (depends a X)))
      (output "~R~%" (datalog.sorted Db cyclic))
      (output "~A~%" (datalog.holds? Db [depends c a]))))
```

```bash
shen-jit eval -l lib/native.shen -l lib/datalog.shen -l deps.shen
```

[Source facts in Datalog](../example-apps/source-deps/README.md) is a complete application over
Tree-sitter's C source export: bounded NDJSON input/output through our I/O, exact caller identity,
linkage-aware name matching, explicit ambiguity/exclusion diagnostics, and single-root reachability
and reverse impact queries.
Configured translation-unit exports also require a preceding external declaration for cross-unit
matches and keep build configurations separate.

```text
((a b) (a c) (b c) (x x) (x y) (y x) (y y))
((a b) (a c))
((x) (y))
false
```

| Form | Meaning |
| --- | --- |
| `(defdatalog Name Item ...)` | Defines a program, checked now. An item is `(relation Name [Types])`, with `equivalence`, `min`, `max`, `choice` or `(lattice F)` after it for such a relation, `(type Name [Constructor Types] ...)` or `(rule Head <-- Body ...)`, or `(rule Head)` for one that always holds |
| `(datalog.run Name Facts)` | A database from facts such as `[imports a b]` |
| `(datalog.add Db Facts)` | The database with these facts added and what follows from them, changed in place and given back |
| `(datalog.remove Db Facts)` | The same with these facts removed, and what no longer follows; a fact it does not have is no change |
| `(datalog.tuples Db Relation)`, `(datalog.sorted Db Relation)` | Its tuples as lists, in no particular order or sorted |
| `(datalog.read-facts Name Relation Path)` | The facts of a relation in a file, a line each, its fields apart by tabs, or by commas if the path ends in `.csv` |
| `(datalog.write-facts Db Relation Path)` | Writes a relation's tuples so, in no particular order, and gives how many |
| `(datalog.bytes->facts Name Relation Bytes Format)`, `(datalog.relation->bytes Db Relation Format)` | The same from and to the bytes of such a file, a byte buffer, `Format` being `tsv` or `csv`: for a program that reads and writes its files itself, as with the [I/O library](io.md) |
| `(datalog.count Db Relation)` | How many tuples it has |
| `(datalog.holds? Db [Relation Value ...])` | Whether a tuple is there |
| `(datalog.explain Db [Relation Value ...])` | Why it is: `[Tuple fact]`, `[Tuple Rule Proof ...]` with a proof of each tuple the rule's atoms read, `[Tuple equivalence]`, or `[Tuple lattice]` for a value joined from others; `[]` if it is not there |
| `(datalog.ask Db (Relation Term ...))` | The tuples that match, in no particular order, with variables, constants and `_`, found by an index on the columns of the constants, which the first such question makes and the database keeps |
| `(datalog.query Name Facts (Relation Term ...))` | The same tuples as asking a run of these facts, computing only what the query needs |
| `(datalog.demand-db Name Facts)` | A database that answers `datalog.ask` and `datalog.match` by demand, keeping what earlier queries derived, and that `datalog.add` and `datalog.remove` change as they change any |
| `(datalog.define Name Items)`, `(datalog.match Db Pattern)`, `(datalog.solve Name Facts Pattern)` | The same as `defdatalog`, `datalog.ask` and `datalog.query` with the program as data, where a variable is `[var "X"]` and `_` is `[any]`. `ask` and `query` read their pattern as written, so a Shen variable in it is a Datalog one: to ask about a value a function holds, build the pattern, as `[depends F [var "X"]]` |
| `(datalog.plans Name)`, `(datalog.code Name)` | Each rule's order of joins with no sizes to go by, and the code that gives: each kernel as written for `lib/native.shen`, and the KL that calls it |
| `(datalog.stats Db)` | The rounds, how many plans were made, and each relation's tuples, the derivations that made them and its indexes |
| `(datalog.run-naive Name Facts)` | The same result by the plain definition, slowly: what the rest is tested against |
| `(datalog.share Name)`, `(datalog.use Shared)` | A program prepared and shared, for isolates (below), and taken up in one, which gives its name |
| `(datalog.run-parallel N Name Facts)` | The same as `datalog.run`, in at most `N` isolates: for a program that runs in parts (below), each runs the rules for some of the keys, and it gives a database of the parts, which answers `count`, `holds?`, `ask`, `match`, `tuples` and `sorted`; for one whose joins run in isolates (below), they share each round of its recursive rules, and it gives a database as `datalog.run` does |
| `(datalog.partition Name)` | `[parts KeyType DerivedRelations]` if the program runs in parts, `[joins Reason]` if its joins run in isolates, with why it does not run in parts, or `[sequential Reason]` |

- **Columns** are `symbol`, `string`, `integer` or a declared type, and a value of another type raises when it is given. An integer
  is 32 bits, signed: from -2147483648 to 2147483647.
- **Rules:** a body has atoms, negated atoms and comparisons: `<`, `>`, `<=` and `>=` on integers, and `=` and `!=` on values of one
  type. A variable in a head, a comparison or a negated atom must appear in an atom of the body, or be bound by `=`, and each `_` is a variable of its own.
- **Records:** `(type shape [circle point integer] [rect point point] [blank])` declares a type and its constructors, each with the
  types of its fields, which may be the type itself. A value of it is a list headed by a constructor, as `[rect [pt 1 2] [pt 4 6]]`
  or `[blank]`; a record is a type of one constructor, as `point` here. In a rule, brackets are a record: in an atom of the body it
  matches, so `(drawn S [rect [pt X _] _])` binds `X`, and in a head, or on one side of `=`, it is made, from what is bound.
  Records are equal when their constructors and fields are, and are compared only with `=` and `!=`. A record in a negated atom
  cannot hold `_`, and `=` makes a record but does not take one apart. As with arithmetic, a recursive rule that makes records
  makes new values, so it should bound them, as `(<= N 4)` does here:

```shen
(defdatalog routes
  (type path [nil] [cons symbol path])
  (relation edge [symbol symbol])
  (relation start [symbol])
  (relation route [symbol path integer])
  (rule (route X [cons X [nil]] 1) <-- (start X))
  (rule (route Y [cons Y P] N) <-- (route X P M) (edge X Y) (= N (+ M 1)) (<= N 4)))
```

  With `a` a start and edges from `a` to `b` and `b` to `c`, `route` holds `[c [cons c [cons b [cons a [nil]]]] 3]`, among
  others. `datalog.sorted` orders records after other values, by constructor name and then by fields.
- **Functions:** on integers, `(+ A B)`, `(- A B)`, `(* A B)`, `(/ A B)` and `(% A B)`, which truncate toward zero as C does,
  `(band A B)`, `(bor A B)` and `(bxor A B)`, and `(bshl A B)` and `(bshr A B)`, A times or divided by 2 to the B, rounded down;
  on strings, `(cat S T)`, `(strlen S)`, `(substr S Start Length)`, which keeps what of that range `S` has, `(to-number S)` and
  `(to-string N)`, counting characters as `pos` does. They nest as deep as wanted and stand on either side of a comparison.
  `(= D (+ D0 W))` binds `D` when nothing else has, and compares otherwise; a binding can use what another binds, in any order.
  An integer operation whose result is not 32 bits raises. Division by zero, and `to-number` of text that is not an integer, give
  no value, so the rule does not hold there, whatever the order of its conditions. Rules that divide, take a `mean`, work on strings
  or shift by other than a constant from 0 to 31 run as KL rather than native kernels, which is slower. Functions make new values, so
  a recursive rule that uses them should bound them, as `(<= D 10)` does here, or it does not end:

```shen
(defdatalog distances
  (relation edge [symbol symbol integer])
  (relation start [symbol])
  (relation dist [symbol integer])
  (rule (dist X 0) <-- (start X))
  (rule (dist Y D) <-- (dist X D0) (edge X Y W) (= D (+ D0 W)) (<= D 10)))
```

- **Aggregates:** `(= N (count (edge X _)))` counts the tuples an atom matches, and `(sum W Atom)`, `(min W Atom)`, `(max W Atom)`
  and `(mean W Atom)`, which truncates toward zero, read an integer variable of the atom. A variable of the atom that appears elsewhere in the body is a key, which the rest of the body
  binds, as `X` here; the others belong to the aggregate. Over no tuples, `count` and `sum` give 0, and `min`, `max` and `mean` give nothing, so the
  rule does not hold. If `N` is bound already, the aggregate compares instead. As with negation, a relation cannot depend on an aggregate of one
  that depends on it.

```shen
(defdatalog degrees
  (relation node [symbol])
  (relation edge [symbol symbol])
  (relation cost [symbol integer])
  (relation degree [symbol integer])
  (relation dearest [symbol integer])
  (rule (degree X N) <-- (node X) (= N (count (edge X _))))
  (rule (dearest X M) <-- (node X) (= M (max C (cost X C)))))
```

With nodes `a` and `b`, an edge from `a` to `b` and costs 3 and 5 for `a`, `degree` is `((a 1) (b 0))` and `dearest` is `((a 5))`.
- **Negation:** `(not (edge X _))` holds when no tuple matches: here, when `X` has no edge out. A relation cannot depend on the negation of
  one that depends on it, as there would be no single answer, and defining such a program raises. So each relation it negates is complete
  before a rule reads it, and a program is evaluated in strata.

```shen
(defdatalog reachable
  (relation edge [symbol symbol])
  (relation start [symbol])
  (relation node [symbol])
  (relation reached [symbol])
  (relation unreached [symbol])
  (rule (reached X) <-- (start X))
  (rule (reached Y) <-- (reached X) (edge X Y))
  (rule (unreached X) <-- (node X) (not (reached X))))
```
- **Equivalences:** `(relation same [symbol symbol] equivalence)` holds what is put in it, by facts or rules, and all that follows
  from that being an equivalence: `[same a b]` gives `[same b a]`, `[same a a]` and `[same b b]`, and with `[same b c]` all nine pairs
  of `a`, `b` and `c`. A rule can read and add to it in the same recursion, as congruence closure does with
  `(rule (same A B) <-- (same X Y) (f X A) (f Y B))`. Classes are joined by union-find as pairs arrive, and kept as classes, not as
  their pairs: a class of thousands of values takes room in proportion to its values, and rules read its pairs from it.
- **One tuple a key:** `(relation dist [symbol integer] min)` keeps, for each value of the columns before the last, the tuple
  whose last column is least, `max` the greatest, and `choice` the first derived, whichever that is. A tuple that is not better
  than its key's is not added, so a shortest path needs no bound to end on a graph with cycles:

```shen
(defdatalog shortest
  (relation edge [symbol symbol integer])
  (relation start [symbol])
  (relation dist [symbol integer] min)
  (rule (dist X 0) <-- (start X))
  (rule (dist Y D) <-- (dist X D0) (edge X Y W) (= D (+ D0 W))))
```

  `(lattice F)` keeps, for each key, the least upper bound of all the values derived for it, by `F`, a Shen function of two
  integers that is commutative, associative and idempotent, and whose values reach a top in finitely many steps, or evaluation
  does not end; `min` and `max` are two such. `(lattice bor)` and `(lattice band)` are the union and the intersection of bit
  sets, joined natively: `bor` gives for each node which of up to 32 starts reach it, and `band` what every way into it carries.
  With a function of your own, such as a flat lattice, a constant or a value for many, for constant propagation, rules that
  add to it run as KL, which calls `F`.

  While its own recursion runs, a rule may still read a tuple that a better one has since replaced, so another relation in the
  same recursion may hold what follows from it; relations evaluated after it see only the best. `datalog.add` evaluates again
  what reads such a relation, once it has changed.
- **Results** are sets, and the order of rules, atoms and facts does not change them, except under `choice`.
- **Recursion** can be through several atoms of a rule, as in `(rule (path X Z) <-- (path X Y) (path Y Z))`: each combination
  of tuples is derived once, in the round after the last of them was.
- **The order of a rule's atoms** need not be tuned. A run chooses the order of joins from the sizes of the relations, and again when one has doubled.
- **Adding facts** with `datalog.add` gives what a run of all of them would. It goes on from what grew where it can, and
  evaluates again only what negates or aggregates something that changed, or reads what was evaluated again. The database
  changes, so a value from before the add sees the new tuples too.
- **Removing facts** with `datalog.remove` evaluates again whatever holds a relation that lost a fact, or reads something evaluated
  again, and keeps the rest. That costs about a full run of what it reaches, and nothing for the parts of a program a removal
  does not reach. It removes facts given, not tuples derived: a tuple that still follows from what is left stays.
- **Queries by demand:** `(datalog.query dependencies Facts (depends a X))` gives what asking a run would, but derives only
  what bears on `a`: the program is rewritten for the query's pattern of constants, by magic sets, once for each pattern,
  and kept with the program. A relation read under a negation or an aggregate is still computed whole, with all it depends
  on. It gains most when the constants select a small part, and little when what they reach is most of a relation, as
  `(path X c)` is when nearly every node reaches `c`. Each query runs on its facts afresh. A database from
  `(datalog.demand-db dependencies Facts)` keeps what its queries derive, for each pattern of constants and variables: a later
  query computes only what it reaches that those before it did not, and adds and removals change only what they reach of
  that. Other questions, such as `datalog.count`, need a run.
- **Explanations:** `(datalog.explain Db [depends a c])` gives
  `[[depends a c] [[depends X Z] <-- [imports X Y] [depends Y Z]] [[imports a b] fact] [[depends b c] ...]]`: a rule as written
  and a proof of each tuple its atoms read, down to the facts given; negations, comparisons and aggregates hold in it but have no
  proof of their own. A proof never goes round in a circle, and costs nothing until asked for, as nothing is recorded per tuple;
  finding one reads the relations it touches, which on a relation of a million tuples takes tens of milliseconds.
- **Fact files:** each field is read as its column's type says, an integer, a symbol, a string as it is or a record as Shen reads it,
  `[pt 1 2]`, and one that does not fit raises, naming the file and line. A `.csv` file quotes a field as RFC 4180 does, so it can
  hold commas, quotes and line breaks; a tab-separated one cannot hold a tab or a line break, and writing one raises before
  the file is touched. Blank lines are skipped, and a line may end in a carriage return. `datalog.read-facts` and
  `datalog.write-facts` use Shen's own files; with the I/O library, a program handles each failure as a value:

```shen
\\ imports.shen, after deps.shen
(define save-imports
  Db Path -> (io.write-file Path (buffer.wrap (datalog.relation->bytes Db imports tsv))))

(define load-imports
  Path -> (let Read (io.read-file Path 100000000)
            (if (= (hd Read) ok)
                (datalog.bytes->facts dependencies imports (buffer.bytes (hd (tl Read))) tsv)
                (error "cannot read ~A: ~A" Path (io.error-message (hd (tl Read)))))))

(let Db (datalog.run dependencies [[imports a b] [imports b c]])
  (do (output "~R~%" (save-imports Db "imports.tsv"))
      (output "~R~%" (load-imports "imports.tsv"))))
```

```bash
shen-jit eval -l lib/native.shen -l lib/datalog.shen -l lib/ffi.shen -l lib/buffer.shen -l lib/io.shen \
  -l lib/io-file.shen -l deps.shen -l imports.shen
```

  After what `deps.shen` prints, this prints `(ok 8)`, the bytes written, and the facts read back, in no particular order.
- **Isolates:** an [isolate](guide.md#isolates) cannot compile, and a run compiles its plans as it goes, so the builder
  prepares a program for isolates and shares it. `(datalog.share Name)` compiles the plan of every rule with no sizes to
  go by, the variants a run uses too, and what loading facts, queries, records and keyed relations call, and gives the
  program, with every plan made so far, as a shared value. An isolate passes it to `(datalog.use Shared)`, which gives the
  program's name, and the rest works there as in the builder:

  ```shen
  (define count-depends
    [Shared Facts Out] -> (let Name (datalog.use Shared)
                            (shen-jit.send Out (datalog.count (datalog.run Name Facts) depends))))

  (let Shared (datalog.share dependencies)
       R (shen-jit.channel 2)
       _ (shen-jit.spawn count-depends [Shared [[imports a b] [imports b c]] (shen-jit.sender R)])
       _ (shen-jit.spawn count-depends [Shared [[imports x y]] (shen-jit.sender R)])
       A (shen-jit.receive R)
       B (shen-jit.receive R)
    (if (< A B) [A B] [B A]))
  \\ [1 3]
  ```

  An isolate takes the order of joins the sizes choose if the builder made that plan, and otherwise the rule's order with no
  sizes to go by, or for a variant that reads only new tuples, the whole rule's: any order gives the same tuples. So run the
  program in the builder, on facts like those the isolates will have, before sharing it, and its isolates join as well as
  the builder does. A query on columns the builder never looked up by reads every tuple of the relation, and a query by demand
  the builder never asked runs the whole program. Define and share programs before spawning: the program cannot change while
  isolates run.
- **Runs in parts:** a program runs in parts when its derived relations all have a first column of one type, its key, and
  each rule gives a head whose key is a constant or a variable a body atom reads, and reads derived relations only at that
  key, with no negation, aggregate, record, equivalence or relation of one tuple a key, only relations of symbols,
  strings and integers, and none named `part-key`, which the copy uses: a transitive closure from each node, say. Then no key's tuples need another's, and `(datalog.run-parallel N Name Facts)` gives the keys to at most `N`
  isolates in turn, each running a copy of the program whose rules hold only for its keys, on every input fact and the
  derived facts of its keys, and keeps the databases they send back. Counts, membership and queries read them all, or the
  first for an input relation, which each has whole; `add`, `remove`, `explain` and `stats` raise, and `datalog.run` makes a
  database that answers them. A program with fewer than two keys runs as `datalog.run` does. The first run in parts
  defines and shares the copy, so it is made in the builder, while no other isolate runs.
- **Joins in isolates:** a program that does not run in parts, but has a recursive rule, and only relations of symbols,
  strings and integers, with no equivalence or relation of one tuple a key, and no rule that makes a string, runs its
  joins in isolates instead: a nonlinear closure, say, or a points-to analysis. Each of `N` isolates holds the whole
  database and runs every rule, and in each round of a recursive component takes only some of the new tuples, by a hash
  of the columns the rule looks the next relation up by, so that one isolate reads a key's tuples; it then sends the
  tuples it derived to every other and adds theirs, so that all start the next round with the same tuples. The first
  sends its database back, which has the tuples and rounds `datalog.run` gives, and answers everything, `add`, `remove`,
  `explain` and `stats` too; its derivations differ by a few, as a plan whose relation grows derives some again. What is
  not recursive runs in every isolate, and every isolate adds every new tuple, so the gain is in rounds that derive many
  more tuples than they keep, and each round's exchange costs more with each isolate. So `run-parallel` goes by the
  program's last run on facts, by `datalog.run` or in isolates: it runs the joins only if that run's recursive rounds,
  all that isolates share, derived four times the tuples they kept, in as many isolates as get 50,000 derivations a
  round each, at most `N`, and otherwise runs the program whole, as a call graph's closure, which keeps most of what it
  derives, is faster run. With no run to go by, it takes `N`. Each run shares the program again if the builder has made
  plans since, so run it in the builder first, on facts like these, and start it there while no other isolate runs; the
  isolates then join in the orders the sizes choose, in as many isolates as pay.
- **Any other program,** or a count `N` of 1, runs as `datalog.run` does; `N` that is not a positive integer raises.
- **Saving:** a program saved with `--save` runs in the saved image, and one saved as an executable runs on its own:
  [example-apps/depends](https://github.com/tizoc/shen-jit/blob/main/example-apps/depends/README.md) is a dependency analyser
  over Shen and KL sources, built so, which uses most of the above.
