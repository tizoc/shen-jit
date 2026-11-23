#!/bin/sh
# Closed executables (docs/modules.md): what they hold and print, against the sealed executable of the
# same module, and what is refused. Usage: tests/closed.sh path/to/shen-jit [path/to/ffi_test]
SHEN=$1
ffi=$2
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
if command -v cygpath > /dev/null; then dir=$(cygpath -m "$dir") ffi=$(cygpath -m "$ffi"); fi
pass=0
fail=0
source='(sources tc- "closed.shen")'

passed() { pass=$((pass + 1)); }
failed() { # name, why, file
    fail=$((fail + 1))
    echo "FAIL $1: $2"
    sed 's/^/    /' "$3"
}

module() { # name, main, and what else its descriptor holds
    printf '(shen.module (version 1) (name %s) (main %s) %s)\n' "$1" "$2" "$3" > "$dir/$1.shenmod"
}

# The closed executable runs as the sealed one, and prints the expected line. One sealed executable has
# every main of closed.shen, named by its argument. With TEST_GC_STRESS=1 (make test-kernel-stress) the
# closed one runs again with a collection at every allocation.
runs() { # name, expected line, main, options
    name=$1 expected=$2 main=$3
    shift 3
    module "$name" "$main" "${parts:-$source}"
    sealed=$dir/every.sealed
    if [ -n "$parts" ]; then
        sealed=$dir/$name.sealed
        "$SHEN" build "$dir/$name.shenmod" -o "$sealed" > "$dir/$name.out" 2>&1 < /dev/null
    fi
    if ! "$SHEN" build "$dir/$name.shenmod" --closed "$@" -o "$dir/$name.closed" > "$dir/$name.out" 2>&1 < /dev/null; then
        failed "$name" "not built" "$dir/$name.out"
        return
    fi
    run "$sealed" "$dir/$name.sealed.out"
    run "$dir/$name.closed" "$dir/$name.closed.out"
    if [ "${TEST_GC_STRESS:-}" = 1 ]; then
        run "$dir/$name.closed" "$dir/$name.stress.out" 1
    else
        cp "$dir/$name.closed.out" "$dir/$name.stress.out"
    fi
    if ! grep -qxF -- "$expected" "$dir/$name.closed.out"; then
        failed "$name" "no line \"$expected\" in:" "$dir/$name.closed.out"
    elif [ -z "$differs" ] && ! cmp -s "$dir/$name.sealed.out" "$dir/$name.closed.out"; then
        failed "$name" "not as the sealed executable:" "$dir/$name.sealed.out"
    elif ! cmp -s "$dir/$name.stress.out" "$dir/$name.closed.out"; then
        failed "$name" "not the same under GC stress:" "$dir/$name.stress.out"
    else
        passed
    fi
}

run() { # executable, output, SHEN_JIT_GC_STRESS
    SHEN_JIT_GC_STRESS=$3 "$1" "$main" two > "$2" 2>&1 < /dev/null
    echo "status $?" >> "$2"
}

# No executable is written, and one line says why.
refused() { # name, text it must hold, main, options
    name=$1 text=$2 main=$3
    shift 3
    module "$name" "$main" "${parts:-$source}"
    if "$SHEN" build "$dir/$name.shenmod" --closed "$@" -o "$dir/$name.closed" > "$dir/$name.out" 2>&1 < /dev/null; then
        failed "$name" "built" "$dir/$name.out"
    elif [ -f "$dir/$name.closed" ] || [ "$(grep -c 'shen-jit:' "$dir/$name.out")" != 1 ] ||
         ! grep -qF -- "$text" "$dir/$name.out"; then
        failed "$name" "not one line with \"$text\":" "$dir/$name.out"
    else
        passed
    fi
}

cat > "$dir/closed.shen" <<'EOF'
(define double X -> (* 2 X))
(define triple X -> (* 3 X))
(define pair-up X Y -> [X Y])
(define evaluates -> (eval [+ 1 2]))
(define evaluates-kl -> (eval-kl [+ 1 2]))
(define installs -> (shen-jit.install []))

\\ Data, closures and arguments. Quoting eval is not calling it, and evaluates is not reached.
(set c.*data* [a "b" 1.5 -3 1e20 (@p a b) (/. X (+ X 1)) (@v 1 2 <>)])
(define apply-to F X -> (F X))
(define data
  -> (output "~S ~S ~S ~A ~A~%" (tl (value *argv*)) (value c.*data*) (apply-to (nth 7 (value c.*data*)) 41) eval
             (trap-error (value c.*none*) (/. E (error-to-string E)))))
(define texts
  -> (output "~A ~S ~R ~A ~A ~A ~A~%" (@p 1 "x") (@v 1 2 <>) [1 "a" b] (absvector 2) (shen.dict 9) (fail) (concat a b)))
(define raises -> (hd 5))
(define partial-f 1 -> 2)
(define partial -> (output "~A~%" (trap-error (partial-f 3) (/. E (error-to-string E)))))
(define arities -> (output "~A ~A~%" (arity evaluates) (arity pair-up)))

\\ Names: called by fn and through parameters, a closure, a branch and a handler.
(define call-named F X -> ((fn F) X))
(define call-later F X -> (freeze (trap-error (if (= X 0) (simple-error "0") (call-named F X)) (/. E (call-named F 1)))))
(define names
  -> (output "~A ~A ~A ~A~%" (call-named double 4) (thaw (call-later triple 4)) (thaw (call-later double 0))
             ((fn pair-up) 1 2)))
(set c.*names* [double triple])
(define computed -> (output "~A~%" (map (/. F (call-named F 10)) (value c.*names*))))
(define inlined-call F -> ((shen-jit.function F) 10))
(define inlined -> (output "~A~%" (map (/. F (inlined-call F)) (value c.*names*))))
(define chosen -> (output "~A~%" (shen-jit.apply (hd (value c.*names*)) [21])))
(define form F -> (fn F))
(define same-form -> (output "~A~%" (= (form double) (form double))))
(define global-of N -> (value N))
(define globals -> (output "~A ~A~%" (global-of c.*names*) (trap-error (global-of c.*none*) (/. E none))))
(define computed-global -> (output "~A~%" (value (hd (value c.*globals*)))))
(set c.*globals* [c.*names*])

\\ Properties. The subject can be computed, but not the property.
(put colours red 1)
(put colours blue 2)
(put shapes blue 3)
(put lost evaluator (fn evaluates))
(unput nothing at-all)
(define blue-of S -> (trap-error (get S blue) (/. E (error-to-string E))))
(define properties
  -> (let Before (map (/. S (blue-of S)) [colours shapes])
          _ (put colours red 5)
          _ (put new blue 6)
          _ (unput shapes blue)
       (output "~A ~A ~A ~A~%" Before (get colours red) (map (/. S (blue-of S)) [colours shapes new]) (blue-of "text"))))
(define no-property
  -> (output "~A~%" [(trap-error (get nothing at-all) (/. E (error-to-string E)))
                     (trap-error (get unknown at-all) (/. E (error-to-string E)))]))
(define computed-property -> (output "~A~%" (get colours (hd (value c.*properties*)))))
(set c.*properties* [red])
(define raw-properties -> (output "~A~%" (shen.dict-count (value *property-vector*))))
(define new-properties -> (do (set *property-vector* []) (output "done~%")))

\\ Vectors are printed by the functions their first elements name.
(defstruct point x y)
(defstruct shown-point value (printer show-point))
(define show-point V -> (cn "shown " (str (<-address V 1))))
(defstruct unsafe-point value (printer show-unsafely))
(define show-unsafely V -> (eval [cn "unsafe" "ly"]))
(define show-vector V -> (cn "vector " (str (<-address V 1))))
(define tagged Tag X -> (address-> (address-> (absvector 2) 0 Tag) 1 X))
(set c.*vector* (tagged show-vector 1))
(define printers
  -> (output "~S ~S ~A ~A ~A~%" (point.make 1 [2 "x"]) (shown-point.make 7) (value c.*vector*) (tagged show-vector 2)
             (tagged unprinted 3)))
(define unsafe-printer -> (output "~A~%" (unsafe-point.make 1)))

\\ Isolates, with what they run in a lambda, through a scope, or computed.
(define square [Out N] -> (channel.send Out (* N N)))
(define show-in-isolate Out -> (channel.send Out (make-string "~S ~A" (point.make 1 2) (language))))
(define isolates
  -> (let Ch (channel.new 4)
          _ (map (/. N (isolate.spawn square [(channel.sender Ch) (if (> N 2) N 2)])) [1 2 3])
          Sum (+ (channel.receive Ch) (+ (channel.receive Ch) (channel.receive Ch)))
          Scoped (isolate.scope (/. S (do (isolate.spawn-in S show-in-isolate (channel.sender Ch)) (channel.receive Ch))))
       (output "~A ~A ~A~%" Sum Scoped Ch)))
(define ending -> (output "ended~%"))
(define ends Out -> (do (shen-jit.at-end ending) (channel.send Out done)))
(define at-end
  -> (let Ch (channel.new 1)
          I (isolate.spawn ends (channel.sender Ch))
       (do (channel.receive (isolate.monitor I)) (output "~A~%" (channel.receive Ch)))))
(define computed-worker
  -> (let Ch (channel.new 1)
       (do (isolate.spawn (hd (value c.*workers*)) [(channel.sender Ch) 5]) (output "~A~%" (channel.receive Ch)))))
(set c.*workers* [square])

\\ Prolog, a grammar and reading.
(defprolog parent a b <--; b c <--;)
(defprolog ancestor X Y <-- (parent X Y); X Y <-- (parent X Z) (ancestor Z Y);)
(defcc <sum> N + <sum> := (+ N <sum>) where (number? N); N := N where (number? N);)
(define parses
  -> (output "~A ~A ~A~%" (prolog? (ancestor a X) (is Y (+ 1 2)) (return [X Y])) (compile (/. X (<sum> X)) [1 + 2 + 3])
             (read-from-string-unprocessed "[1 foo (bar x)]")))
(define reads -> (output "~A~%" (read-from-string "[1]")))

\\ A closed program asks as an isolate does whether it can compile, and what a library leaves for later
\\ is done before it is saved.
(define asks -> (output "~A~%" (if (shen-jit.builder?) (eval [+ 1 2]) (if (not (shen-jit.builder?)) told lost))))
(define late -> (if (shen-jit.builder?) 1 (shen-jit.unprepared "late")))
(set c.*made* [])
(define make -> (set c.*made* [made | (value c.*made*)]))
(shen-jit.before-save make)
(define made -> (output "~A~%" (value c.*made*)))
(define every -> (shen-jit.apply (intern (hd (tl (value *argv*)))) []))
EOF
module every every "$source"
"$SHEN" build "$dir/every.shenmod" -o "$dir/every.sealed" > "$dir/every.out" 2>&1 < /dev/null || failed every "not built" "$dir/every.out"

runs data '["data" "two"] [a "b" 1.5 -3 1e20 (@p a b) #<procedure> <1 2>] 42 eval c.*none* has no value' data
runs texts '(@p 1 "x") <1 2> (1 "a" b) <<... ...>> (dict ...) ... ab' texts
runs raises 'shen-jit: uncaught error: hd: 5 is not a pair' raises
differs=yes
runs partial 'partial function partial-f' partial
differs=
differs=yes
runs asks 'told' asks
differs=
refused late 'late -> requires what was not prepared before it was saved' late
runs made '[made]' made
runs arities '0 2' arities
runs names '8 12 2 [1 2]' names
runs same-form 'true' same-form
runs globals '[double triple] none' globals
runs computed '[20 30]' computed --dispatch computed double --dispatch computed triple
runs inlined '[20 30]' inlined --dispatch inlined-call double --dispatch inlined-call triple
runs chosen '42' chosen --dispatch chosen double
runs properties '[2 3] 5 [2 attribute blue not found for shapes' properties
runs no-property '[attribute at-all not found for nothing' no-property
runs printers '#<point x: 1 y: [2 "x"]> shown 7 vector 1 vector 2 <<unprinted 3>>' printers
runs isolates '17 #<point x: 1 y: 2> native <receive endpoint 0>' isolates
runs at-end 'ended' at-end
runs computed-worker '25' computed-worker --dispatch computed-worker square
runs parses '[b 3] 6 [[cons 1 [cons foo [cons [bar x] []]]]]' parses

refused evaluates 'evaluates -> requires eval' evaluates
refused evaluates-kl 'evaluates-kl -> requires shen-jit.eval-kl' evaluates-kl
refused kept-eval 'evaluates -> requires eval' data --keep evaluates
refused installs 'installs -> requires shen-jit.install' installs
refused reads 'reads -> read-from-string' reads
refused undeclared 'computed -> lambda -> call-named -> requires a computed function name in fn (declare it with --dispatch call-named FUNCTION)' computed
refused other-caller 'requires a computed function name' computed --dispatch data double
refused undeclared-inlined '(declare it with --dispatch inlined-call FUNCTION)' inlined
refused undeclared-worker 'requires a computed function name in shen-jit.isolate' computed-worker
refused no-function 'closed build: --keep nowhere: there is no such function' data --keep nowhere
refused no-caller 'closed build: --dispatch nowhere: there is no such function' data --dispatch nowhere double
refused no-target 'closed build: --dispatch nowhere: there is no such function' data --dispatch data nowhere
refused computed-global 'requires a computed global name in value' computed-global
refused computed-property 'requires a computed property of *property-vector*' computed-property
refused raw-properties 'shen.dict-count -> requires *property-vector* other than through get, put and unput' raw-properties
refused new-properties 'requires a change to *property-vector*' new-properties
refused unsafe-printer 'show-unsafely -> requires eval' unsafe-printer

# A function that a source calls before another defines it.
printf '(define main -> (output "~A ~A~%%" (later 3) (two 3 4)))\n' > "$dir/first.shen"
printf '(define later X -> (+ X 1))\n(define two X Y -> [X Y])\n' > "$dir/second.shen"
parts='(sources tc- "first.shen" "second.shen")'
runs forward '4 [3 4]' main
parts=

# A program's own definition of what closed programs replace.
cat > "$dir/override.shen" <<'EOF'
(shen-jit.sealing shen.f-error)
(define shen.f-error F -> (cn "replaced " (str F)))
(define partial 1 -> 2)
(define main -> (output "~A ~A~%" (shen-jit.apply shen.f-error [f]) (partial 2)))
EOF
parts='(sources tc- "override.shen")'
runs override 'replaced f replaced partial' main
parts=

# Plain C functions are kept, and C written for Shen if it is asked for.
if [ -n "$ffi" ] && "$SHEN" eval -e '(element? shen-jit/ffi (shen.x.features.current))' < /dev/null | grep -qx true; then
    cat > "$dir/foreign.shen" <<EOF
(shen-jit.library c-library ["$ffi"])
(define-foreign add64 c-library "add64" (int64 int64) --> int64)
(define-foreign-procedure sum-list c-library "sum_list" 1)
(define plain -> (output "~A~%" (add64 2 3)))
(define procedure -> (output "~A~%" (sum-list [1 2 3])))
EOF
    parts='(requires ffi) (sources tc- "foreign.shen")'
    runs plain '5' plain
    runs procedure '6' procedure --keep sum-list
    refused unkept-procedure 'a C procedure, which may look names up (--keep it, and those): sum-list' procedure
    # A server whose handler, named with an argument, runs in each connection's isolate, and its client.
    cat > "$dir/serves.shen" <<'EOF'
(define handle Tag Request
  -> (do (if (= (http.target Request) "/stop") (http.stop (http.current-server)) true)
         (http.response 200 [] (buffer.from-string (make-string "~A ~A" Tag (http.target Request))))))
(define fetch
  Port Target -> (let C (socket.connect "127.0.0.1" Port)
                      _ (socket.send C (make-string "GET ~A HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;Connection: closec#13;c#10;c#13;c#10;" Target))
                   (body (io.with-endpoint (io.socket C "client") (/. Peer (io.read-all (io.reader Peer []) 4096))))))
(define body
  (:result.ok V) -> (last-line (buffer.string V) "")
  (:result.err E) -> (io.error-message E))
(define last-line
  "" Line -> Line
  (@s "c#10;" S) _ -> (last-line S "")
  (@s C S) Line -> (last-line S (cn Line C)))
(define client [Port Out] -> (channel.send Out (map (fetch Port) ["/a" "/b" "/stop"])))
(define main
  -> (let S (http.listen "127.0.0.1" 0 [handle "tag"] [])
          R (channel.new 1)
          _ (isolate.spawn client [(http.port S) (channel.sender R)])
          Result (http.run S)
       (output "~S ~S~%" Result (channel.receive R))))
EOF
    parts='(requires http/listener buffer io socket) (sources tc- "serves.shen")'
    runs serves '#<result.ok []> ["tag /a" "tag /b" "tag /stop"]' main
    parts=
fi

# Libraries, typed code among them. A name that a library sends to an isolate needs no declaration, and
# what it compiles when that is first used is compiled before the program is saved.
cat > "$dir/maps.shen" <<'EOF'
(define main -> (output "~A ~A~%" (parallel.map 2 double [1 2 3]) (parallel.map 2 [add 10] [1 2 3])))
(define double X -> (* 2 X))
(define add N X -> (+ N X))
EOF
parts='(requires parallel) (sources tc- "maps.shen")'
runs maps '[2 4 6] [11 12 13]' main
cat > "$dir/grammars.shen" <<'EOF'
(defgrammar <g.digit> B where (and (>= B 48) (<= B 57));)
(defgrammar <g.number> (+ <g.digit>);)
(defgrammar <g.more> 44 <g.number>;)
(defgrammar <g.list> <g.number> (* <g.more>);)
(define main
  -> (do (grammar.finish)
         (output "~A ~A~%" (grammar.match? <g.list> (buffer.from-string "1,22,3"))
                 (grammar.match? <g.list> (buffer.from-string "1,x")))))
EOF
parts='(requires grammar buffer) (sources tc- "grammars.shen")'
runs grammars 'true false' main
cat > "$dir/json-main.shen" <<'EOF'
(define main
  -> (let R (io.reader (io.input-buffer (buffer.from-string "[1] {}")) [])
          First (json.read R [])
          Second (json.read R [])
       (output "~S ~S ~S~%" (json.decode (buffer.from-string "[1, 2.5, true, null, {}]") []) First Second)))
EOF
parts='(requires json io) (sources tc- "json-main.shen")'
runs json-app '[[number "1"] [number "2.5"] true null [object]] #<result.ok [[[number "1"]]]> #<result.ok [[object]]>' main
parts=
cp tests/typed/app*.shen "$dir"
parts='(requires numbers buffer) (typed) (sources tc+ "app.shen" tc- "app-main.shen")'
runs typed '2.5 55 annotated true true false true' app-main
parts=

# The executable is a program: its arguments are its own, its image too, and it is far smaller. A
# refused build leaves the one that is there.
SHEN_JIT_IMAGE="$dir/none.img" "$dir/data.closed" --stage1 a b > "$dir/own.out" 2>&1
if grep -qF '["--stage1" "a" "b"]' "$dir/own.out"; then passed; else failed own "not its own" "$dir/own.out"; fi
SHEN_JIT_IMAGE="$dir/none.img" "$dir/every.sealed" --stage1 a b > "$dir/own.out" 2>&1
if grep -qF 'undefined function --stage1' "$dir/own.out"; then passed; else failed own-sealed "not its own" "$dir/own.out"; fi
if [ $((4 * $(wc -c < "$dir/data.closed"))) -lt $((3 * $(wc -c < "$dir/every.sealed"))) ]; then passed; else
    ls -l "$dir" > "$dir/sizes"; failed size "data.closed is not much smaller than every.sealed" "$dir/sizes"; fi
module data evaluates "$source"
"$SHEN" build "$dir/data.shenmod" --closed -o "$dir/data.closed" > /dev/null 2>&1
main=data
run "$dir/data.closed" "$dir/data.out"
if cmp -s "$dir/data.out" "$dir/data.closed.out"; then passed; else failed kept "the executable changed" "$dir/data.out"; fi
if ls "$dir"/*.tmp > "$dir/left" 2> /dev/null; then failed left "a file was left" "$dir/left"; else passed; fi
for options in "--closed --open" "--keep double" "--dispatch double double" "--closed --keep" "--closed --dispatch double"; do
    if "$SHEN" build "$dir/data.shenmod" $options -o "$dir/options" > "$dir/options.out" 2>&1 || [ -f "$dir/options" ] ||
       ! grep -qF 'build: ' "$dir/options.out"; then
        failed "options $options" "not refused" "$dir/options.out"
    else
        passed
    fi
done

echo "closed executables: $pass passed, $fail failed"
[ "$fail" = 0 ]
