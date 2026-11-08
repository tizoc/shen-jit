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

```text
((a b) (a c) (b c) (x x) (x y) (y x) (y y))
((a b) (a c))
((x) (y))
false
```

| Form | Meaning |
| --- | --- |
| `(defdatalog Name Item ...)` | Defines a program, checked now. An item is `(relation Name [Types])`, `(type Name [Constructor Types] ...)` or `(rule Head <-- Body ...)`, or `(rule Head)` for one that always holds |
| `(datalog.run Name Facts)` | A database from facts such as `[imports a b]` |
| `(datalog.add Db Facts)` | The database with these facts added and what follows from them, changed in place and given back |
| `(datalog.remove Db Facts)` | The same with these facts removed, and what no longer follows; a fact it does not have is no change |
| `(datalog.tuples Db Relation)`, `(datalog.sorted Db Relation)` | Its tuples as lists, in no particular order or sorted |
| `(datalog.count Db Relation)` | How many tuples it has |
| `(datalog.holds? Db [Relation Value ...])` | Whether a tuple is there |
| `(datalog.ask Db (Relation Term ...))` | The tuples that match, in no particular order, with variables, constants and `_` |
| `(datalog.query Name Facts (Relation Term ...))` | The same tuples as asking a run of these facts, computing only what the query needs |
| `(datalog.define Name Items)`, `(datalog.match Db Pattern)`, `(datalog.solve Name Facts Pattern)` | The same as `defdatalog`, `datalog.ask` and `datalog.query` with the program as data, where a variable is `[var "X"]` and `_` is `[any]` |
| `(datalog.plans Name)`, `(datalog.code Name)` | Each rule's order of joins with no sizes to go by, and the code that gives: each kernel as written for `lib/native.shen`, and the KL that calls it |
| `(datalog.stats Db)` | The rounds, how many plans were made, and each relation's tuples, the derivations that made them and its indexes |
| `(datalog.run-naive Name Facts)` | The same result by the plain definition, slowly: what the rest is tested against |

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
- **Arithmetic:** `(+ A B)`, `(- A B)` and `(* A B)` on integers, nested as deep as wanted, can stand on either side of a comparison.
  `(= D (+ D0 W))` binds `D` when nothing else has, and compares otherwise; a binding can use what another binds, in any order.
  An operation whose result is not 32 bits raises. Arithmetic makes new values, so a recursive rule that uses it should bound them,
  as `(<= D 10)` does here, or it does not end:

```shen
(defdatalog distances
  (relation edge [symbol symbol integer])
  (relation start [symbol])
  (relation dist [symbol integer])
  (rule (dist X 0) <-- (start X))
  (rule (dist Y D) <-- (dist X D0) (edge X Y W) (= D (+ D0 W)) (<= D 10)))
```

- **Aggregates:** `(= N (count (edge X _)))` counts the tuples an atom matches, and `(sum W Atom)`, `(min W Atom)` and `(max W Atom)`
  read an integer variable of the atom. A variable of the atom that appears elsewhere in the body is a key, which the rest of the body
  binds, as `X` here; the others belong to the aggregate. Over no tuples, `count` and `sum` give 0, and `min` and `max` give nothing, so the
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
- **Results** are sets, and the order of rules, atoms and facts does not change them.
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
  `(path X c)` is when nearly every node reaches `c`. Each query runs on its facts afresh: for many queries over the same
  facts, a run and `datalog.ask` may cost less.
- **Saving:** a program saved with `--save` runs in the saved image.
