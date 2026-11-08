\* Writes each generated program as Prolog with every relation tabled, which SWI-Prolog then
   evaluates by an algorithm of its own, and writes what lib/datalog.shen makes of it. See
   tests/datalog-swipl.sh, which compares them. *\

(define swi.atom
  S -> (cn "'" (cn (swi.escape (str S)) "'")))

(define swi.escape
  "" -> ""
  (@s "'" Rest) -> (cn "\'" (swi.escape Rest))
  (@s "\" Rest) -> (cn "\\" (swi.escape Rest))
  (@s C Rest) -> (cn C (swi.escape Rest)))

(define swi.term
  [var V] -> (cn "V" V)
  [any] -> "_"
  [C | Args] -> (swi.atom-form [C | Args])
  X -> (str X) where (number? X)
  X -> (swi.atom X))

(define swi.join
  [] _ -> ""
  [X] _ -> X
  [X | Xs] Sep -> (cn X (cn Sep (swi.join Xs Sep))))

(define swi.atom-form
  [Rel] -> (swi.atom Rel)
  [Rel | Terms] -> (cn (swi.atom Rel) (cn "(" (cn (swi.join (map (function swi.term) Terms) ",") ")"))))

\* Conditions go after the atoms, where their variables are bound. A negated relation is complete
   by then, as its table is, so plain negation is enough. *\
(define swi.comparison
  [not Atom] -> (cn "\+ " (swi.atom-form Atom))
  [Op A B] -> (cn (swi.guards [A B]) (cn (swi.expr A) (cn (swi.arith-op Op) (swi.expr B))))
              where (or (datalog.expression? A) (datalog.expression? B))
  [Op A B] -> (cn (swi.term A) (cn (swi.op Op) (swi.term B))))

\* What binds a variable is is, after the atoms and before what reads it. Generated programs bind
   only from what the atoms bind. *\
(define swi.binding
  [= [var V] E] -> (cn (swi.guards [E]) (cn "V" (cn V (cn " is " (swi.expr E))))))

\* A division by zero has no value, so the rule fails there, as Prolog's would raise. *\
(define swi.guards
  [] -> ""
  [[Op A B] | Es] -> (cn (swi.guards [A B]) (cn (swi.expr B) (cn " =\= 0, " (swi.guards Es)))) where (element? Op [/ %])
  [[Op A B] | Es] -> (swi.guards [A B | Es]) where (datalog.arithmetic? Op)
  [_ | Es] -> (swi.guards Es))

(define swi.binding?
  [= [var "K"] _] -> true
  _ -> false)

(define swi.expr
  [Op A B] -> (cn "(" (cn (swi.expr A) (cn (cn " " (cn (swi.operator Op) " ")) (cn (swi.expr B) ")"))))
              where (datalog.arithmetic? Op)
  T -> (swi.term T))

\* SWI-Prolog's // truncates toward zero and rem takes the dividend's sign, as / and % do. *\
(define swi.operator
  / -> "//"
  % -> "rem"
  band -> "/\"
  bor -> "\/"
  bxor -> "xor"
  bshl -> "<<"
  bshr -> ">>"
  Op -> (str Op))

(define swi.arith-op
  = -> " =:= "
  != -> " =\= "
  Op -> (swi.op Op))

(define swi.op
  < -> " < "
  > -> " > "
  <= -> " =< "
  >= -> " >= "
  = -> " == "
  != -> " \== ")

(define swi.body
  Body -> (let Conditions (datalog.conditions Body)
            (swi.join (append (map (function swi.atom-form) (datalog.atoms Body))
                              (map (function swi.aggregate) (swi.filter (function datalog.aggregate-condition?) Conditions))
                              (map (function swi.binding) (swi.filter (function swi.binding?) Conditions))
                              (map (function swi.comparison)
                                   (swi.filter (/. C (not (or (swi.binding? C) (datalog.aggregate-condition? C)))) Conditions)))
                      ", ")))

\* An aggregate is aggregate_all, which does not group by its free variables, after the atoms
   that bind its keys: a tabled relation's answers are a set, so each tuple counts once. *\
(define swi.aggregate
  [= [var V] [count Atom]] -> (make-string "aggregate_all(count, ~A, V~A)" (swi.atom-form Atom) V)
  [= [var V] [mean [var W] Atom]]
  -> (make-string "aggregate_all(count, ~A, V~Ac), V~Ac > 0, aggregate_all(sum(V~A), ~A, V~As), V~A is V~As // V~Ac"
                  (swi.atom-form Atom) V V W (swi.atom-form Atom) V V V V)
  [= [var V] [Op [var W] Atom]] -> (make-string "aggregate_all(~A(V~A), ~A, V~A)" Op W (swi.atom-form Atom) V))

(define swi.filter
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (swi.filter F Xs)] (swi.filter F Xs)))

(define swi.rule
  [Head []] -> (cn (swi.atom-form Head) ".c#10;")
  [Head Body] -> (cn (swi.atom-form Head) (cn " :- " (cn (swi.body Body) ".c#10;"))))

(define swi.table
  [Rel | Types] -> (cn ":- table " (cn (swi.atom Rel) (cn "/" (cn (str (length Types)) ".c#10;")))))

(define swi.print
  [Rel | Types]
  -> (let Vars (swi.numbered Types 1)
          Goal (swi.atom-form [Rel | (map (/. V [var V]) Vars)])
       (make-string "print_tuples(~A, ~A) :- forall(~A, output(~A, ~A)).c#10;"
                    (swi.atom Rel) (swi.list Vars) Goal (swi.atom Rel) (swi.list Vars))))

\* A relation with no rules or facts would otherwise be an unknown procedure. *\
(define swi.no-clause
  [Rel | Types] -> (cn (swi.atom-form [Rel | (map (/. T [any]) Types)]) " :- fail.c#10;"))

(define swi.numbered
  [] _ -> []
  [_ | Ts] I -> [(str I) | (swi.numbered Ts (+ I 1))])

(define swi.list
  Vars -> (cn "[" (cn (swi.join (map (/. V (cn "V" V)) Vars) ",") "]")))

(define swi.run-all
  [] -> ""
  [[Rel | Types] | Rs]
  -> (cn (make-string "    print_tuples(~A, ~A),c#10;" (swi.atom Rel) (swi.list (swi.numbered Types 1)))
         (swi.run-all Rs)))

(define swi.write-all
  _ [] -> true
  S [Text | Texts] -> (do (pr Text S) (swi.write-all S Texts)))

(define swi.program
  Path Relations Rules Facts
  -> (let S (open Path out)
          _ (pr ":- style_check(-singleton).c#10;:- style_check(-discontiguous).c#10;" S)
          _ (swi.write-all S (map (function swi.table) Relations))
          _ (swi.write-all S (map (function swi.no-clause) Relations))
          _ (swi.write-all S (map (/. F (cn (swi.atom-form F) ".c#10;")) Facts))
          _ (swi.write-all S (map (function swi.rule) Rules))
          _ (swi.write-all S (map (function swi.rule) (mapcan (function datalog.equivalence-rules) (value dtg.*equivalences*))))
          _ (pr "text(T, S) :- compound(T), !, T =.. Parts, maplist(text, Parts, Texts), atomic_list_concat(Texts, ' ', In), atomic_list_concat(['[', In, ']'], S).c#10;" S)
          _ (pr "text(X, X).c#10;" S)
          _ (pr "output(Rel, Values) :- maplist(text, Values, Texts), atomic_list_concat([Rel | Texts], ' ', Line), writeln(Line).c#10;" S)
          _ (swi.write-all S (map (function swi.print) Relations))
          _ (pr "main :- (c#10;" S)
          _ (pr (swi.run-all Relations) S)
          _ (pr "    true).c#10;" S)
       (close S)))

(define swi.line
  Rel Tuple -> (swi.join (map (function swi.text) [Rel | Tuple]) " "))

\* A record as the Prolog side writes it: [one p], [pr p 2]. *\
(define swi.text
  [C | Args] -> (cn "[" (cn (swi.join (map (function swi.text) [C | Args]) " ") "]"))
  X -> (str X))

(define swi.results
  Path Db Relations
  -> (let S (open Path out)
          _ (swi.write-rels S Db Relations)
       (close S)))

(define swi.write-rels
  _ _ [] -> true
  S Db [[Rel | _] | Rs]
  -> (do (swi.write-all S (map (/. T (cn (swi.line Rel T) "c#10;")) (datalog.tuples Db Rel)))
         (swi.write-rels S Db Rs)))

(define swi.generated
  _ 0 -> ok
  Dir N
  -> (let Program (dtg.program)
          Relations (hd Program)
          Rules (hd (tl Program))
          Facts (hd (tl (tl Program)))
          Name (dtg.numbered "swi.g" N)
          _ (datalog.define Name (dtg.items Relations Rules))
          Base (cn Dir (cn "/p" (str N)))
          _ (swi.program (cn Base ".pl") Relations Rules Facts)
          _ (swi.results (cn Base ".out") (datalog.run Name Facts) Relations)
       (swi.generated Dir (- N 1))))
