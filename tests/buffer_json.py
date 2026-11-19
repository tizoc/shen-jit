#!/usr/bin/env python3
"""Optional JSON example oracle, using Python's independent decoder.

Run: python3 tests/buffer_json.py build/shen-jit
Not required for C-only release-tarball testing.
"""
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile


class Number(str):
    pass


def shen_string(text):
    return '"' + ''.join(f'c#{b};' for b in text.encode('utf-8')) + '"'


def shen_value(value):
    if isinstance(value, Number):
        return f'[number {shen_string(value)}]'
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, str):
        return shen_string(value)
    if isinstance(value, list):
        return '[' + ' '.join(map(shen_value, value)) + ']'
    if isinstance(value, dict):
        return '[object ' + ' '.join(
            f'[{shen_string(k)} {shen_value(v)}]' for k, v in value.items()) + ']'
    raise TypeError(type(value))


rng = random.Random(193)
strings = ['', 'plain', 'éλ😀', '"\\\n\t', '\0', 'c#34;', 'a b',
           '\u0080\u07ff\u0800\ud7ff\ue000\uffff\U00010000\U0010ffff']


def generate(depth=0):
    kind = rng.randrange(6 if depth < 4 else 4)
    if kind == 0:
        return rng.choice([None, True, False])
    if kind == 1:
        return rng.choice(strings)
    if kind == 2:
        return rng.randrange(-10**20, 10**20)
    if kind == 3:
        return rng.choice([-0.0, 1.5, -2.25, 1e-30, 1.234e20])
    if kind == 4:
        return [generate(depth + 1) for _ in range(rng.randrange(5))]
    return {key: generate(depth + 1) for key in rng.sample(strings, rng.randrange(5))}


root = Path(__file__).resolve().parent.parent
executable = Path(sys.argv[1]).resolve()
forms = []
for n in range(256):
    text = json.dumps(strings if n == 0 else generate(), ensure_ascii=bool(n % 2), allow_nan=False,
                      indent=2 if n % 3 == 0 else None)
    expected = json.loads(text, parse_int=Number, parse_float=Number)
    forms.append(
        f'(if (= (buffer-example.json (buffer.from-string {shen_string(text)})) '
        f'{shen_value(expected)}) true (error "JSON oracle case {n}"))')
forms.append('(output "256 independent JSON cases passed~%")')
with tempfile.TemporaryDirectory(prefix='shen-buffer-json-') as name:
    fixture = Path(name) / 'oracle.shen'
    fixture.write_text('\n'.join(forms) + '\n')
    result = subprocess.run(
        [str(executable), 'eval', '-m', 'tools/buffer-parsers.shenmod', '-l', str(fixture)], cwd=root,
        capture_output=True, text=True, timeout=30)
    if result.returncode or '256 independent JSON cases passed' not in result.stdout:
        print(result.stdout[-4000:])
        print(result.stderr)
        raise SystemExit(1)
print('256 independent JSON cases passed (seed 193)')
