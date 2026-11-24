#!/usr/bin/env python3
"""Fuzzes the checker for native code written by hand (lib/native.shen).

    python3 tests/native_fuzz.py [CASES [SEED]]

Mutates valid code objects at random, and runs whatever shen-jit.install-code
accepts. Refusing is fine, and so is an error when the code runs; a crash means
that code the checker accepted broke something the JIT relies on."""
import os, random, re, subprocess, sys, tempfile

BIN = os.environ.get('SHEN_JIT', 'build/shen-jit')
BATCH = 100

BASES = [
    # A loop over a list, overwriting its parameters.
    "(code fuzz.f 2 7 (0) ((prim 4 cons? 2) (jump-if-false 4 0) (prim 5 hd 2) (prim 3 + 3 5) (prim 2 tl 2)"
    " (tail-call 0 fuzz.f 2) (label 0) (return 3)) ())",
    # Tests that leave known pairs, and hd and tl of them.
    "(code fuzz.f 2 8 (foo) ((prim 4 cons? 2) (jump-if-false 4 0) (prim 5 hd 2) (prim 6 tl 2) (prim 7 cons 5 6)"
    " (return 7) (label 0) (prim 5 = 2 (const 0)) (jump-if-false 5 1) (return 3) (label 1) (return 2)) ())",
    # Calls, with windows above the slots that live across them.
    "(code fuzz.f 2 10 (1 (1 2)) ((const 6 1) (call 4 4 reverse 1) (move 7 2) (call 5 5 fuzz.g 1)"
    " (prim 6 cons 4 5) (return 6)) ())",
    # A call of a value, and a tail call of one.
    "(code fuzz.f 2 9 (1) ((closure 4 0 2) (move 6 3) (move 7 4) (call-value 5 5 1) (tail-call-value 5 0)) "
    "((code freeze 0 4 () ((capture 2 0) (return 2)) ())))",
    # Handlers: nested, quiet and reading the exception.
    "(code fuzz.f 2 8 (\"e\") ((push-handler 0) (push-handler 1) (prim 4 hd 2) (pop-handler) (jump 2) (label 1)"
    " (prim 4 simple-error (const 0)) (label 2) (prim 5 tl 2) (pop-handler) (return 5) (label 0) (exception 6)"
    " (prim 7 error-to-string 6) (return 7)) ())",
    # Closures and captures.
    "(code fuzz.f 2 6 () ((closure 4 0 2 3) (return 4)) "
    "((code lambda 1 7 () ((capture 3 0) (capture 4 1) (prim 5 cons 3 4) (prim 6 cons 2 5) (return 6)) ())))",
    # An entry for two arguments, whose label a jump also reaches.
    "(code fuzz.f 1 6 (1) ((entry 2 0) (prim 4 cons? 2) (jump-if-false 4 1) (const 3 0) (jump 0) (label 1)"
    " (return 2) (label 0) (prim 5 hd 2) (return 5)) ())",
    # Allocation in a loop, with a vector and a string.
    "(code fuzz.f 2 8 (0 1 2) ((prim 4 = 2 (const 0)) (jump-if-false 4 0) (return 3) (label 0)"
    " (prim 5 absvector (const 2)) (prim 5 address-> 5 (const 0) 2) (prim 6 str 2) (prim 5 address-> 5 (const 1) 6)"
    " (prim 3 cons 5 3) (prim 2 - 2 (const 1)) (tail-call 0 fuzz.f 2)) ())",
    # Float registers: a loop, what it keeps round it, and each kind of instruction.
    "(code fuzz.f 2 8 (0 1.5) ((float-number 0 (const 1)) (float-number 1 (const 0)) (loop 1) (prim 4 cons? 2)"
    " (jump-if-false 4 0) (prim 5 hd 2) (float-number 2 5) (float+ 1 1 2) (float* 2 1 0) (float-sqrt 2 2) (prim 2 tl 2)"
    " (again 1) (label 0) (float-box 6 1) (return 6)) ())",
    # Float registers on memory: a store, a load, a comparison.
    "(code fuzz.f 2 8 (8 1.5 16) ((prim 4 shen-jit.bytes (const 2)) (float-number 0 (const 1)) (float-store 4 (const 0) 0)"
    " (float-load 1 4 (const 0)) (float-unless< 0 1 0) (float-box 5 1) (return 5) (label 0) (float-neg 2 0) (float-box 5 2)"
    " (return 5)) ())",
    # Word registers: a hash over memory in a loop, every kind of access, and what comes back.
    "(code fuzz.f 2 8 (0 8 1099511628211) ((prim 4 shen-jit.bytes (const 1)) (word-number 0 (const 0))"
    " (word-number 1 (const 2)) (word-move 2 (const 0)) (loop 1) (word-unless-u< 2 (const 1) 0) (word-load8 3 4 2)"
    " (word-xor 0 0 3) (word* 0 0 1) (word-store8 4 2 0) (word+ 2 2 (const 1)) (again 1)"
    " (label 0) (word-shr 0 0 (const 8)) (word-box 5 0) (return 5)) ())",
    # A loop within a loop, with slots that go round them.
    "(code fuzz.f 2 9 (0 3) ((prim 4 + 2 (const 1)) (loop 1) (prim 5 >= 4 (const 1)) (jump-if-false 5 0) (return 4)"
    " (label 0) (word-move 0 (const 0)) (loop 2) (word-unless< 0 (const 1) 3) (word+ 0 0 (const 1)) (prim 3 + 3 4)"
    " (again 2) (label 3) (prim 4 + 4 (const 1)) (again 1)) ())",
    # Words as indices of floats, and each way between the two kinds.
    "(code fuzz.f 2 8 (16 1.5 8) ((prim 4 shen-jit.bytes (const 0)) (float-number 0 (const 1)) (word-number 0 (const 2))"
    " (float-store-at 4 0 0) (float-load-at 1 4 0) (word-from-float 1 1) (float-from-word 2 1) (word-box 5 1) (float-box 6 2)"
    " (prim 7 cons 5 6) (return 7)) ())",
    # Vectors: loads and stores at a word index, each bytewise operation, the mask and the counts, in a loop.
    "(code fuzz.f 2 8 (32 7 3) ((prim 4 shen-jit.bytes (const 0)) (word-number 0 (const 2)) (word-number 1 (const 1))"
    " (vec-splat 0 0) (loop 1) (vec-load 1 4 1) (vec= 2 1 0) (vec-and 3 2 1) (vec-or 3 3 2) (vec-xor 3 3 0)"
    " (vec-move 4 3) (vec-shr 4 4 (const 2)) (vec-lookup 4 3 4) (vec-max 3 3 4) (vec-min 4 4 2) (vec+ 2 3 4)"
    " (vec- 4 2 4) (vec-andnot 3 4 3) (vec-store 4 1 4) (vec-mask 2 2) (word-ctz 3 2)"
    " (word-clz 2 2) (word+ 1 1 (const 2))"
    " (word-unless-u< 1 (const 0) 0) (again 1) (label 0) (word-box 5 3) (return 5)) ())",
]
ATOMS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, -1] + ['foo', 'fuzz.g', 'fuzz.f', 'reverse', 'hd', 'tl', 'cons', 'cons?', '+', '=', 'str']
INSNS = ["(move 4 2)", "(const 4 0)", "(prim 4 cons? 2)", "(jump-if-false 4 0)", "(jump 0)", "(label 9)",
         "(pop-handler)", "(push-handler 0)", "(exception 4)", "(capture 4 0)", "(return 2)", "(return (const 0))",
         "(call 4 4 fuzz.g 1)", "(call-value 4 4 0)", "(tail-call 0 fuzz.f 2)", "(tail-call 4 fuzz.g 1)", "(closure 4 0 2)",
         "(prim 4 hd 2)", "(prim 2 tl 2)", "(move 2 4)", "(prim 4 cons (const 0) 2)", "(jump-unless-entry 2 2 0)",
         "(float-number 0 2)", "(float-number 1 (const 0))", "(float+ 0 0 1)", "(float-move 1 0)", "(float-box 4 0)",
         "(float-load 0 2 3)", "(float-store 2 3 0)", "(float-unless< 0 1 0)", "(loop 7)", "(again 7)", "(again 1)", "(word-number 0 2)",
         "(word-move 1 (const 0))", "(word+ 0 0 1)", "(word-shl 0 0 1)", "(word-box 4 0)", "(word-load8 0 2 1)",
         "(word-load64 0 2 1)", "(word-store8 2 1 0)", "(word-store64 2 1 0)", "(float-load-at 0 2 1)",
         "(float-store-at 2 1 0)", "(word-unless< 0 1 0)", "(word-unless-u>= 0 (const 0) 0)", "(word-from-float 0 0)",
         "(float-from-word 0 0)", "(vec-load 0 2 1)", "(vec-store 2 1 0)", "(vec-splat 1 0)", "(vec= 0 0 1)",
         "(vec-xor 1 0 1)", "(vec-move 1 0)", "(vec-mask 0 1)", "(word-ctz 0 1)", "(word-clz 1 0)",
         "(vec-shr 0 1 (const 1))", "(vec-lookup 1 0 1)", "(vec-max 0 1 0)", "(vec- 1 0 1)", "(vec-andnot 0 0 1)"]


def parse(text):
    tokens = re.findall(r'\(|\)|"[^"]*"|[^\s()]+', text)

    def form(i):
        if tokens[i] == '(':
            out, i = [], i + 1
            while tokens[i] != ')':
                x, i = form(i)
                out.append(x)
            return out, i + 1
        t = tokens[i]
        return (int(t) if re.fullmatch(r'-?\d+', t) else t), i + 1
    return form(0)[0]


def show(x):
    return '[' + ' '.join(show(y) for y in x) + ']' if isinstance(x, list) else str(x)


def places(x, out):
    """Every list and index holding a number or a name."""
    for i, y in enumerate(x):
        if isinstance(y, list):
            places(y, out)
        else:
            out.append((x, i))
    return out


def mutate(code, r):
    for _ in range(r.choice([1, 1, 1, 2, 3])):
        insns = code[5]
        kind = r.random()
        if kind < 0.65:  # change an operand; rarely the code object's own numbers
            where = r.choice(places(insns, []) if r.random() < 0.9 else places(code[:4], []))
            where[0][where[1]] = r.choice(ATOMS)
        elif kind < 0.75 and len(insns) > 1:
            del insns[r.randrange(len(insns))]
        elif kind < 0.85 and len(insns) > 1:
            i, j = r.randrange(len(insns)), r.randrange(len(insns))
            insns[i], insns[j] = insns[j], insns[i]
        else:
            insns.insert(r.randrange(len(insns) + 1), parse(r.choice(INSNS)))
    return code


PRELUDE = r'''
(define fuzz.g X -> [X])
(set fuzz.*accepted* 0)
(define fuzz.try
  Code -> (trap-error
            (do (shen-jit.install-code [defun fuzz.f Code])
                (set fuzz.*accepted* (+ 1 (value fuzz.*accepted*)))
                (map (/. Args (trap-error (eval-kl [fuzz.f | (fuzz.take (nth 3 Code) Args)]) (/. E skip)))
                     [[[cons 1 [cons 2 []]] 0] [0 [cons 1 2]] ["s" [cons 3 []]] [[lambda x x] 4]]))
            (/. E skip)))
(define fuzz.take
  0 _ -> []
  N [X | Xs] -> [X | (fuzz.take (- N 1) Xs)]
  _ _ -> [])
'''


def run(binary, cases, stress):
    """Returns the process's status, and how many cases the checker accepted."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, 'cases.shen')
        with open(path, 'w') as f:
            for c in cases:
                f.write(f'(fuzz.try {show(c)})\n')
            f.write('(output "accepted ~A~%" (value fuzz.*accepted*))\n')
        env = dict(os.environ, SHEN_JIT_GC_STRESS=str(stress), SHEN_JIT_MAX_HEAP='256M') # mutated code may allocate without end
        try:
            p = subprocess.run([binary, 'eval', '-l', path], env=env, capture_output=True, text=True,
                               timeout=1 + len(cases) // 25)
        except subprocess.TimeoutExpired:
            return 'hang', 0
    m = re.search(r'accepted (\d+)', p.stdout)
    return p.returncode, int(m.group(1)) if m else 0


def search(binary, cases, stress, found):
    """Halves a batch that failed, down to the cases that crash or do not end."""
    status, accepted = run(binary, cases, stress)
    if status == 0:
        found['accepted'] += accepted
    elif len(cases) > 1:
        search(binary, cases[:len(cases) // 2], stress, found)
        search(binary, cases[len(cases) // 2:], stress, found)
    elif status == 'hang':
        found['hangs'] += 1
    else:
        found['crashes'] += 1
        print(f'status {status}, stress {stress}: {show(cases[0])}', flush=True)


def main():
    total = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    r = random.Random(seed)
    found = {'accepted': 0, 'hangs': 0, 'crashes': 0}
    with tempfile.TemporaryDirectory() as d:
        # Loading native.shen under GC stress would take most of the time.
        binary = os.path.join(d, 'fuzz')
        with open(os.path.join(d, 'prelude.shen'), 'w') as f:
            f.write(PRELUDE + f'(shen-jit.save-executable "{binary}" [])\n')
        subprocess.run([BIN, 'eval', '-m', 'native', '-l', os.path.join(d, 'prelude.shen')],
                       check=True, capture_output=True)
        for start in range(0, total, BATCH):
            cases = [mutate(parse(r.choice(BASES)), r) for _ in range(min(BATCH, total - start))]
            search(binary, cases, r.choice([0, 0, 200]), found)
    print(f'{total} cases: {found["accepted"]} accepted, {found["hangs"]} did not end, {found["crashes"]} crashed')
    sys.exit(1 if found['crashes'] else 0)


main()
