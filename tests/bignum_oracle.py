#!/usr/bin/env python3
"""lib/bignum.shen against Python's integers.

Run: python3 tests/bignum_oracle.py build/shen-jit [CASES [SEED]]
"""
import math
from pathlib import Path
import random
import subprocess
import sys
import tempfile

if hasattr(sys, 'set_int_max_str_digits'):
    sys.set_int_max_str_digits(0)

EDGES = [s * (2 ** p + d) for p in (0, 31, 32, 53, 59, 60, 61, 62, 63, 64, 65, 127, 128, 129)
         for d in (-2, -1, 0, 1, 2) for s in (1, -1)] + [0]


def integer(r, bits=4096):
    k = r.random()
    if k < 0.25:
        return r.choice(EDGES)
    if k < 0.45:
        return r.randint(-1000, 1000)
    n = r.getrandbits(r.choice([61, 64, 128, 200, r.randint(1, bits)]))
    if k < 0.5:  # runs of ones and zeros, as carries cross limbs
        n = (1 << r.randint(1, bits)) - (1 << r.randint(0, 64))
    return n if r.random() < 0.5 else -n


def truncated(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def isprime(n):
    if n < 2:
        return False
    small = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]
    for p in small:
        if n % p == 0:
            return n == p
    d, s = n - 1, 0
    while d % 2 == 0:
        d, s = d // 2, s + 1
    for a in small:  # a proof below 3.3e24, and far likelier than not above
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def nextprime(n):
    n = max(n + 1, 2)
    while not isprime(n):
        n += 1
    return n


def fibonacci(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def in_base(n, base):
    digits = '0123456789abcdefghijklmnopqrstuvwxyz'
    m, out = abs(n), ''
    while m:
        m, d = divmod(m, base)
        out = digits[d] + out
    return ('-' if n < 0 else '') + (out or '0')


def binomial(n, k):
    return math.comb(n, k) if n >= 0 else (-1) ** k * math.comb(k - n - 1, k)


ZERO = '! bignum: division by zero'
INVERSE = '! bignum.invert: no inverse modulo that'


def power(b, e, m):
    if m == 0:
        return ZERO
    m = abs(m)
    try:
        return pow(b, e, m)
    except ValueError:
        return INVERSE


def nonzero(f):
    return lambda a, b: ZERO if b == 0 else f(a, b)


def floating(a):
    try:
        return float(a)
    except OverflowError:
        return '! bignum.to-float: the integer is too large for a float'


TWO = {
    '+': lambda a, b: a + b, '-': lambda a, b: a - b, '*': lambda a, b: a * b,
    'quotient': nonzero(truncated), 'remainder': nonzero(lambda a, b: a - b * truncated(a, b)),
    'quotient-remainder': nonzero(lambda a, b: (truncated(a, b), a - b * truncated(a, b))),
    'floor-quotient': nonzero(lambda a, b: a // b), 'modulo': nonzero(lambda a, b: a % b),
    'compare': lambda a, b: (a > b) - (a < b), '=': lambda a, b: a == b, '<': lambda a, b: a < b,
    '<=': lambda a, b: a <= b, '>': lambda a, b: a > b, '>=': lambda a, b: a >= b,
    'gcd': math.gcd, 'lcm': lambda a, b: abs(a * b) // math.gcd(a, b) if a and b else 0,
    'bit-and': lambda a, b: a & b, 'bit-or': lambda a, b: a | b, 'bit-xor': lambda a, b: a ^ b,
}
ONE = {
    'sign': lambda a: (a > 0) - (a < 0), 'negate': lambda a: -a, 'abs': abs, 'even?': lambda a: a % 2 == 0,
    'odd?': lambda a: a % 2 == 1, 'bit-not': lambda a: ~a, 'bit-length': lambda a: a.bit_length(),
    'bit-count': lambda a: bin(a).count('1') if a >= 0 else '! bignum.bit-count: a negative integer',
    'sqrt': lambda a: math.isqrt(a) if a >= 0 else '! bignum.sqrt: a negative integer',
    'square?': lambda a: a >= 0 and math.isqrt(a) ** 2 == a, 'to-float': floating,
    'of-float': lambda a: int(float(a)) if not isinstance(floating(a), str) else floating(a),
    'fixnum?': lambda a: -2 ** 61 <= a < 2 ** 61,
}


def case(r):
    k = r.random()
    if k < 0.55:
        op = r.choice(list(TWO))
        a, b = integer(r), integer(r)
        if r.random() < 0.1:
            b = a
        return [op, a, b], TWO[op](a, b)
    if k < 0.75:
        op = r.choice(list(ONE))
        a = integer(r, 1200) if 'float' in op else integer(r)
        if op == 'square?' and r.random() < 0.5:
            a *= a
        return [op, a], ONE[op](a)
    op = r.choice(['expt', 'expt-mod', 'invert', 'gcd-extended', 'prime?', 'next-prime', 'factorial', 'binomial',
                   'fibonacci', 'bit-set?', 'shift-left', 'shift-right', 'to-string-base', 'of-string-base'])
    if op == 'expt':
        a, n = integer(r, 300), r.randint(0, 40)
        return [op, a, n], a ** n
    if op == 'expt-mod':
        b, e, m = integer(r, 400), integer(r, 200), integer(r, 400)
        return [op, b, e, m], power(b, e, m)
    if op == 'invert':
        a, m = integer(r, 400), integer(r, 400)
        return [op, a, m], power(a, -1, m)
    if op == 'gcd-extended':
        a, b = integer(r), integer(r)
        return [op, a, b], lambda out: (lambda g, s, t: g == math.gcd(a, b) == a * s + b * t)(*map(int, out.split()))
    if op == 'prime?':
        a = r.choice([r.randint(-10, 5000), r.getrandbits(80) | 1, nextprime(r.getrandbits(70))])
        return [op, a], isprime(a)
    if op == 'next-prime':
        a = r.choice([r.randint(-10, 5000), r.getrandbits(70)])
        return [op, a], nextprime(a)
    if op == 'factorial':
        n = r.randint(0, 400)
        return [op, n], math.factorial(n)
    if op == 'binomial':
        n, j = r.choice([r.randint(-50, 300), r.getrandbits(70)]), r.randint(0, 30)
        return [op, n, j], binomial(n, j)
    if op == 'fibonacci':
        n = r.randint(0, 2000)
        return [op, n], fibonacci(n)
    if op == 'bit-set?':
        a, i = integer(r), r.choice([r.randint(0, 130), r.randint(0, 5000)])
        return [op, a, i], bool(a >> i & 1)
    if op in ('shift-left', 'shift-right'):
        a, n = integer(r), r.choice([r.randint(0, 70), r.randint(0, 5000)])
        return [op, a, n], a << n if op == 'shift-left' else a >> n
    a, base = integer(r), r.randint(2, 36)
    return [op, a, base], in_base(a, base) if op == 'to-string-base' else a


def same(want, got):
    if callable(want):
        try:
            return want(got)
        except ValueError:
            return False
    if isinstance(want, bool):
        return got == ('true' if want else 'false')
    if isinstance(want, float):
        return got[:1] not in ('', '!') and float(got) == want
    if isinstance(want, tuple):
        return got == ' '.join(map(str, want))
    return got == str(want)


def main(shen, count=6000, seed=1):
    r = random.Random(seed)
    cases = [case(r) for _ in range(count)]
    # A few that take GMP's faster algorithms.
    for bits in (50000, 300000):
        a, b, c = r.getrandbits(bits) | 1 << bits, r.getrandbits(bits) | 1, r.getrandbits(bits // 2) | 1
        cases += [(['*', a, b], a * b), (['quotient-remainder', a, -c], TWO['quotient-remainder'](a, -c)),
                  (['gcd', a * c, b * c], math.gcd(a * c, b * c)), (['sqrt', a], math.isqrt(a)),
                  (['of-string-base', a, 10], a)]
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'cases.txt'
        path.write_bytes(''.join(' '.join(map(str, words)) + '\n' for words, _ in cases).encode())  # no CR on Windows
        here = Path(__file__).resolve().parent
        p = subprocess.run([shen, 'eval', '-m', 'bignum', '-l', str(here / 'bignum_oracle.shen'),
                            '-e', f'(bignum-oracle.run "{path.as_posix()}")'], capture_output=True, text=True)
    got = p.stdout.partition('results:\n')[2].splitlines()[:len(cases)]
    if len(got) < len(cases):
        sys.exit(f'{len(got)} of {len(cases)} results\n{p.stdout[-500:]}{p.stderr[-500:]}')
    failed = 0
    for (words, want), out in zip(cases, got):
        if not same(want, out):
            failed += 1
            if failed <= 5:
                print(f'FAIL {" ".join(map(str, words))[:200]}: got {out[:200]}, '
                      f'want {"an identity" if callable(want) else str(want)[:200]}')
    print(f'{len(cases) - failed} passed, {failed} failed (against Python)')
    sys.exit(failed > 0)


if __name__ == '__main__':
    main(sys.argv[1], *map(int, sys.argv[2:4]))
