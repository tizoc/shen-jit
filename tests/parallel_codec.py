#!/usr/bin/env python3
"""Independent binary-codec fixtures; needs only the runtime and pure libraries."""
from dataclasses import dataclass
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HEADER = struct.pack('<II', 1347240241, 1)


@dataclass(frozen=True)
class Symbol:
    data: bytes


@dataclass(frozen=True)
class Real:
    bits: int


def encode(value):
    if value is False:
        return b'\x01'
    if value is True:
        return b'\x02'
    if isinstance(value, int):
        return b'\x03' + struct.pack('<q', value)
    if isinstance(value, Real):
        return b'\x04' + struct.pack('<Q', value.bits)
    if isinstance(value, bytes):
        return b'\x05' + struct.pack('<I', len(value)) + value
    if isinstance(value, Symbol):
        return b'\x06' + struct.pack('<I', len(value.data)) + value.data
    if isinstance(value, list):
        return b'\x00' if not value else b'\x07' + struct.pack('<I', len(value)) + b''.join(map(encode, value))
    raise TypeError(value)


def literal(data):
    return '"' + ''.join(chr(b) if 32 <= b < 127 and b not in (34, 99) else f'c#{b};'
                         for b in data) + '"'


def run(binary, packet, success):
    # A flat-list fixture exceeds Windows' command-line limit when escaped.
    with tempfile.TemporaryDirectory(prefix='shen-codec-fixture-') as directory:
        source = Path(directory) / 'roundtrip.shen'
        source.write_text('(pc.roundtrip ' + literal(packet) + ')\n', encoding='ascii')
        command = [str(binary), 'eval', '-q', '-l', 'lib/buffer.shen', '-l', 'lib/parallel.shen',
                   '-l', 'lib/parallel-map.shen', '-l', 'tests/parallel-codec.shen', '-l', str(source)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=30)
    if not success:
        assert result.returncode == 1 and b'uncaught error' in result.stderr, (result.stdout, result.stderr)
        return
    assert result.returncode == 0, (result.stdout[-1000:], result.stderr[-1000:])
    rows = [line[len(b'CODEC|'):] for line in result.stdout.splitlines() if line.startswith(b'CODEC|')]
    assert len(rows) == 1 and bytes(map(int, rows[0].split())) == packet, (packet, rows)


def main():
    binary = Path(sys.argv[1]).resolve()
    real_bits = [0, 1, 0x8000000000000000, 0x8000000000000001, 0x3ff0000000000000,
                 0x7ff0000000000000, 0xfff0000000000000, 0x7ff0000000000001,
                 0x7ff8000012345678, 0xfff8000000000071]
    values = [[], True, False, 0, -1, 2**53 + 1, -(2**61), 2**61 - 1,
              b'', bytes(range(256)), 'café λ'.encode(), b'c#0;"\\\x00',
              Symbol(b''), Symbol(b'pm.echo'), Symbol(b'a name'), Symbol('símbolo'.encode()),
              [True, [False, []], Symbol(b'data'), [1, 2, 3]], list(range(1024))]
    values += [Real(bits) for bits in real_bits]
    rng = random.Random(261109)
    atoms = values[:-1]
    def tree(depth):
        if depth == 0 or rng.randrange(3) == 0:
            return rng.choice(atoms[:17])
        return [tree(depth - 1) for _ in range(rng.randrange(5))]
    values += [tree(5) for _ in range(24)]
    packets = [HEADER + encode(v) for v in values]
    for packet in packets:
        run(binary, packet, True)
    invalid = [b'', HEADER, HEADER + b'\xff', HEADER + b'\x00\x00',
               struct.pack('<II', 0, 1) + b'\x00', struct.pack('<II', 1347240241, 2) + b'\x00',
               HEADER + b'\x03' + struct.pack('<q', 2**61),
               HEADER + b'\x05' + struct.pack('<I', 0xffffffff),
               HEADER + b'\x07' + struct.pack('<I', 262144),
               HEADER + (b'\x07\x01\x00\x00\x00' * 65) + b'\x00']
    sample = HEADER + encode([Symbol(b'tag'), 11, b'a string'])
    invalid += [sample[:cut] for cut in [1, 7, 9, 13, 18, len(sample) - 1]]
    for packet in invalid:
        run(binary, packet, False)
    print(f'{len(packets) + len(invalid)} passed, 0 failed (independent value codec, exact numeric bits)')


if __name__ == '__main__':
    main()
