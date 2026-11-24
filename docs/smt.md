# Formulas over the integers

[lib/smt.shen](../lib/smt.shen) tells whether formulas over the integers can hold together: it gives values for
which they do, or a proof that there are none. Its module is `smt`, and it is Shen alone. [`refine`](refine.md)
checks typed code with it.

```sh
shen-jit eval -m smt -l program.shen
```

```repl
(0-) (smt.check [[<= 0 i] [< i n] [< n 3]])
#<smt.sat model: [[i 0] [n 1]]>

(1-) (smt.check [[<= 0 i] [< i n] [< n 1]])
#<smt.unsat proof: #<smt.refutation steps: [(@p 1 [(@p 2 1) (@p 1 1)]) (@p 1 [(@p 3 1) (@p -1 1)])]>>

(2-) (smt.valid? [[<= [+ start count] length] [<= 0 count]] [<= start length])
true
```

## Formulas

A formula is Shen data:

| Formula | Holds when |
| --- | --- |
| `true`, `false` | Always, never |
| A symbol or a string | The proposition of that name does |
| `[not F]`, `[and F ...]`, `[or F ...]` | As they read; `[and]` always does, and `[or]` never |
| `[<= A B]`, `[< A B]`, `[>= A B]`, `[> A B]`, `[= A B]` | The integers do |

A term is a fixnum, a name, `[+ T ...]`, `[- T]`, `[- T T ...]`, or `[* A B]` where A or B is constant. A name, of an
unknown integer, is a symbol or a string, and no name is an unknown and a proposition both. Anything else raises. In a
namespace, names are qualified as any symbol is, so strings are the simpler ones there.

## Functions

| Function | What it gives |
| --- | --- |
| `(smt.check Formulas)` | What becomes of them together: a result that is one of the three below |
| `(smt.check-within N Formulas)` | The same, with a budget of N |
| `(smt.valid? Assumptions Goal)` | Whether the goal holds wherever the assumptions do: `true` only with a proof |
| `(smt.sat? R)`, `(smt.model R)` | Whether they can hold, and then a model |
| `(smt.unsat? R)`, `(smt.proof R)` | Whether they cannot, and then a proof |
| `(smt.unknown? R)`, `(smt.reason R)` | Whether neither was found, and then why, a string |
| `(smt.integer Model T)`, `(smt.truth Model F)` | What a term is in a model, and whether a formula holds in it |
| `(smt.check-model Formulas Model)` | Whether they all hold in it |
| `(smt.check-proof Formulas Proof)` | Whether it shows that they cannot hold together |
| `(smt.budget N)` | Sets how many sums a check may make and cases it may try before its answer is not known, 20,000 to start with |

In typed code, formulas are `smt.formula`, terms `smt.term`, and the rest are `smt.result`, `smt.model` and
`smt.proof`, which only these functions take apart:

```shen
(define in-range?
  {string --> fixnum --> boolean}
  X N -> (smt.valid? [[<= 0 X] [< X N]] [< X [+ N 1]]))
```

## What an answer rests on

- **A model is tried** on the formulas, as they were written, before `check` gives it.
- **A proof is checked** before `check` gives it. An `unsat` rests on that check, which is typed
  ([lib/smt-proof.shen](../lib/smt-proof.shen)), and on reading the formulas into the rows that it is about. The search,
  which is most of the module, is not trusted: were it wrong, `check` would raise, and not answer.
- **`unknown` is an answer.** The search stops when it has spent its budget, when a number does not fit a fixnum
  (`"integer overflow"`), or when rationals satisfy the formulas and the integers it tried do not
  (`"no integers found"`): it chooses each unknown once, and does not go back. So a formula whose only models are far
  apart may be missed. A budget counts sums and cases, and not time, so the same formulas get the same answer everywhere.

A proof is a `refutation` or a `split`. Each `<=` is a row, a sum of unknowns with coefficients that is at most a
bound, and `=` is two of them. A refutation is a list of steps. A step is a divisor and the lines it adds up, each with
how many times it is taken, where line 3 is the third row and line -2 the second step. A sum all of whose coefficients
the divisor divides is divided by it, its bound rounded down, as the unknowns are integers. The last step says that 0
is at most less than that. A split names an `or` and has a proof for each of its parts. A row that is false by itself,
and a proposition with its negation, need no steps.

## How it decides

Formulas are read with their negations moved to their atoms. While some `or` has no part chosen, the rows so far are
refuted if they can be, and otherwise the one with the fewest parts is split; a proof that does not use the part it
was found under does for the whole. Rows are refuted by eliminating one unknown after another: each row that
bounds it above is added to each that bounds it below, which Fourier and Motzkin described, and every sum is
divided by what its coefficients have in common, with its bound rounded down. An unknown that has no multiple in what
bounds it on one side, or in what it is equal to, goes first, as eliminating it loses no integers; of those, the one
that makes fewest rows.

That suits what programs ask, some tens of rows over some tens of unknowns. It has no products of unknowns, no arrays,
no functions and no quantifiers, and nothing is kept from one check to the next. Elimination can make many rows
from few, which the budget ends.
