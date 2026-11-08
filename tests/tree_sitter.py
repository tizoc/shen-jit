#!/usr/bin/env python3
"""Independent C API, coordinate and application oracles for the optional binding."""
import os
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = '// café λ\r\nint sum(int a) { return helper(a); }\r\nint empty(void) {}\r\n'.encode()
QUERY = ('(function_definition declarator: (function_declarator declarator: (identifier) @definition))\n'
         '(call_expression function: (identifier) @call)')


def string(value):
    return '"' + ''.join(chr(b) if 32 <= b < 127 and b not in [34, 99] else f'c#{b};'
                         for b in str(value).encode()) + '"'


def run(args, **kwargs):
    env = {**os.environ, **kwargs.pop('env', {})}
    result = subprocess.run(list(map(str, args)), cwd=ROOT, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, errors='backslashreplace', timeout=120,
                            env=env, **kwargs)
    assert result.returncode == 0 and 'uncaught error' not in result.stderr, (result.stdout[-4000:], result.stderr[-4000:])
    return result


def checks(result):
    lines = re.findall(r'^\d+ passed, 0 failed$', result.stdout, re.M)
    assert lines and 'FAIL ' not in result.stdout, result.stdout[-6000:]
    for line in dict.fromkeys(lines):
        print(line, flush=True)


def oracle(args, executable, root, source_bytes=SOURCE, query_text=QUERY):
    source, query = root / 'input.c', root / 'query.scm'
    source.write_bytes(source_bytes)
    query.write_text(query_text, encoding='utf-8')
    reference = run([executable, source, query]).stdout.splitlines()
    expression = '(ts-test.dump (ts-test.ok (treesitter.query (value ts-test.language) '
    # Length-counted Shen escapes preserve CRLF, NUL and malformed source independently of files.
    encoded = '"' + ''.join(f'c#{b};' for b in source_bytes) + '"'
    expression += '(buffer.from-string ' + encoded + ') ' + string(query_text) + ' [])))'
    actual = run(args + ['-e', expression]).stdout.splitlines()
    expected = [line for line in reference if line.startswith(('N\t', 'C\t'))]
    observed = [line for line in actual if line.startswith(('N\t', 'C\t'))]
    assert observed == expected, (observed, expected)
    nodes = [line.split('\t') for line in observed if line.startswith('N\t')]
    for row in nodes:
        start, end, sr, sc, er, ec = map(int, row[6:])
        for at, r, c in [(start, sr, sc), (end, er, ec)]:
            prefix = source_bytes[:at]
            assert r == prefix.count(b'\n') and c == len(prefix.rsplit(b'\n', 1)[-1])
    # Verify links using independently reconstructed children, not the adapter's DFS.
    links = {int(row[1]): [] for row in nodes}
    for row in nodes:
        if parent := int(row[2]):
            links[parent].append(int(row[1]))
    expressions = []
    for parent, children in links.items():
        expressions.append(f'(= (treesitter.children T {parent}) [{" ".join(map(str, children))}])')
        for i, child in enumerate(children):
            sibling = children[i + 1] if i + 1 < len(children) else 0
            expressions.append(f'(= (treesitter.next-sibling T {child}) {sibling})')
    construct = '(ts-test.ok (treesitter.query (value ts-test.language) (buffer.from-string '
    construct += encoded + ') ' + string(query_text) + ' []))'
    check = '(let T ' + construct + ' (if (and ' + ' '.join(expressions) + ') true (error "tree links differ")))'
    run(args + ['-e', check])
    print('3 passed, 0 failed (independent C API, byte coordinates and traversal links)', flush=True)


def documentation(args, grammar, root):
    reference = ROOT / 'docs/tree-sitter.md'
    if not reference.is_file():
        return
    examples = root / 'examples.shen'
    examples.write_text('\n'.join(re.findall(r'```shen\n(.*?)```', reference.read_text(encoding='utf-8'), re.S)),
                        encoding='utf-8')
    expression = '(let Language (ts-test.ok (example.language [' + string(grammar) + '])) '
    expression += 'T (ts-test.ok (example.parse Language)) '
    expression += 'Q (ts-test.ok (example.definitions Language (treesitter.source T))) '
    expression += '(if (and (= (treesitter.kind T 1) "translation_unit") '
    expression += '(= (hd (example.first-capture Q)) "definition")) '
    expression += '(output "3 passed, 0 failed~%") (error "reference examples failed")))'
    checks(run(args + ['-l', examples, '-e', expression]))


def application(args, grammar, fs_adapter, root):
    directory = root / 'source-λ'
    directory.mkdir()
    one = directory / 'one.c'
    one.write_bytes(SOURCE)
    pointer = directory / 'pointer.h'
    pointer.write_text('const char *pointer(void) { return target(); }\n')
    broken = directory / 'broken.c'
    broken.write_text('int broken(void) { return 1 }\n')
    (directory / 'ignored.txt').write_text('not C')
    (directory / 'build').mkdir()
    (directory / 'build' / 'ignored.c').write_text('int omitted(void) {}')
    output = root / 'facts.ndjson'
    argv = '[' + ' '.join(map(string, ['example-apps/source-facts/main.shen', grammar, directory, output])) + ']'
    adapter_files = args[args.index('treesitter.*adapter-files*') + 1]
    call = args[:2] + ['-s', 'treesitter.*adapter-files*', adapter_files,
                      '-s', 'fs.*adapter-files*', '[' + string(fs_adapter) + ']',
                      '-s', '*argv*', argv, '-l', 'example-apps/source-facts/main.shen']
    result = run(call, env={'SHEN_JIT_SEMISPACE': '4M', 'SHEN_JIT_MAX_HEAP': '16M'})
    assert 'Extracted 9 records from 3 files' in result.stdout, result.stdout[-1000:]
    facts = [json.loads(line) for line in output.read_text(encoding='utf-8').splitlines()]
    assert len(facts) == 9
    names = {(f['kind'], f.get('name'), f.get('container')) for f in facts}
    assert ('definition', 'sum', 'sum') in names and ('call', 'helper', 'sum') in names
    assert ('definition', 'pointer', 'pointer') in names and ('call', 'target', 'pointer') in names
    assert any(f['kind'] == 'file' and f['syntax_error'] for f in facts)
    for fact in facts:
        if 'name' not in fact:
            continue
        data = Path(fact['path']).read_bytes()
        assert data[fact['start_byte']:fact['end_byte']].decode() == fact['name']
    before = output.read_bytes()
    with (directory / 'oversize.c').open('wb') as f:
        f.truncate(8388609)
    failed = subprocess.run(list(map(str, call)), cwd=ROOT, capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, timeout=120)
    assert failed.returncode != 0 and 'limit' in failed.stderr, failed.stderr[-1000:]
    assert output.read_bytes() == before, 'failed extraction replaced its destination'
    assert not any(p.name.startswith('.shen-') for p in root.iterdir())
    (directory / 'oversize.c').unlink()
    print('5 passed, 0 failed (source facts, coordinates, Unicode paths and safe replacement)', flush=True)

    for i in range(100):
        (directory / f'file-{i:03}.c').write_bytes(SOURCE)
    result = run(call + ['-e', '(shen-jit.collect)'],
                 env={'SHEN_JIT_SEMISPACE': '4M', 'SHEN_JIT_MAX_HEAP': '16M', 'SHEN_JIT_STATS': '1'})
    assert 'Extracted 409 records from 103 files' in result.stdout, result.stdout[-1000:]
    live = re.findall(r'live heap (\d+) KB', result.stderr)
    assert live, result.stderr[-1000:]
    print(f'tree-sitter facts: 103 files under a 16 MiB heap cap; live heap {live[-1]} KiB', flush=True)
    print('1 passed, 0 failed', flush=True)


def images(executable, args, root):
    image = root / 'tree-sitter.img'
    run([executable, '--save', image] + args[1:] + ['-l', 'tests/tree_sitter_gc.shen'])
    restored = [executable, 'eval', '-e',
                '(do (if (= (treesitter.text (value ts-test.snapshot) '
                '(treesitter.capture-node (value ts-test.snapshot) 1)) "sum") true (error "snapshot changed")) '
                '(ts-gc.run (value ts-test.language)) (output "tree-sitter image gc ok~%"))']
    result = run(restored, env={'SHEN_JIT_IMAGE': str(image), 'SHEN_JIT_GC_STRESS': '1'})
    assert 'tree-sitter image gc ok' in result.stdout
    print('3 passed, 0 failed (saved language, snapshot and concurrent GC)', flush=True)


def timeout(args, root):
    source = root / 'long.c'
    source.write_bytes(b'int value;\n' * 100000)
    expression = '(let Input (hd (tl (io.read-file ' + string(source) + ' 2097152))) '
    expression += 'R (treesitter.parse (value ts-test.language) Input '
    expression += '[[timeout 1] [node-limit 4194304] [result-limit 536870912]]) '
    expression += '(if (= (ts-test.error-domain R) timeout) '
    expression += '(output "1 passed, 0 failed~%") (error "native parse deadline failed")))'
    checks(run(args + ['-l', 'lib/io.shen', '-l', 'lib/io-file.shen', '-e', expression]))


def source_analysis(args, grammar, fs_adapter, root):
    directory = root / 'graph-λ'
    directory.mkdir()
    (directory / 'a.c').write_text('int main(void) { return helper(); }\nint helper(void) { return target(); }\n')
    (directory / 'b.c').write_text('int helper(void) { return 0; }\nint target(void) { return 1; }\n')
    (directory / 'bad.c').write_text('int broken(void) { return 1 }\n')
    facts, report = root / 'graph-facts.ndjson', root / 'graph-report.ndjson'
    adapter_files = args[args.index('treesitter.*adapter-files*') + 1]
    producer_argv = '[' + ' '.join(map(string, ['source-facts', grammar, directory, facts])) + ']'
    run(args[:2] + ['-s', 'treesitter.*adapter-files*', adapter_files,
                   '-s', 'fs.*adapter-files*', '[' + string(fs_adapter) + ']',
                   '-s', '*argv*', producer_argv, '-l', 'example-apps/source-facts/main.shen'])
    records = [json.loads(line) for line in facts.read_text(encoding='utf-8').splitlines()]
    paths = {Path(r['path']).name: r['path'] for r in records if r['kind'] == 'file'}
    options = [[], ['--reach', paths['a.c'], 'main'], ['--impact', paths['b.c'], 'target']]
    for query in options:
        argv = '[' + ' '.join(map(string, ['source-deps', facts, report, *query])) + ']'
        run(args[:2] + ['-s', 'fs.*adapter-files*', '[' + string(fs_adapter) + ']',
                       '-s', '*argv*', argv, '-l', 'example-apps/source-deps/main.shen'])
        rows = [json.loads(line) for line in report.read_text(encoding='utf-8').splitlines()]
        assert rows[0]['functions'] == 4 and rows[0]['resolved_calls'] == 2 and rows[0]['excluded_files'] == 1
        edges = {((r['from']['file'], r['from']['name']), (r['to']['file'], r['to']['name']))
                 for r in rows if r['kind'] == 'edge'}
        assert edges == {((paths['a.c'], 'main'), (paths['a.c'], 'helper')),
                         ((paths['a.c'], 'helper'), (paths['b.c'], 'target'))}
        if query:
            mode = query[0][2:]
            answers = {(r['function']['file'], r['function']['name']) for r in rows if r['kind'] == mode}
            expected = {(paths['a.c'], 'helper'), (paths['b.c'], 'target')} if mode == 'reach' else {
                (paths['a.c'], 'main'), (paths['a.c'], 'helper')}
            assert answers == expected
    print('4 passed, 0 failed (C source → Tree-sitter facts → Datalog reach and impact)', flush=True)


def main():
    executable, adapter, grammar, fixture, native_oracle, fs_adapter = [Path(p).resolve() for p in sys.argv[1:7]]
    args = [executable, 'eval', '-l', 'lib/ffi.shen', '-l', 'lib/buffer.shen',
            '-s', 'treesitter.*adapter-files*', '[' + string(adapter) + ']',
            '-l', 'lib/tree-sitter.shen', '-s', 'ts-test.grammar-files', '[' + string(grammar) + ']',
            '-s', 'ts-test.fixture-files', '[' + string(fixture) + ']',
            '-l', 'tests/tree_sitter_helpers.shen', '-l', 'tests/tree_sitter_setup.shen',
            '-l', 'tests/tree_sitter_dump.shen']
    checks(run(args + ['-l', 'tests/tree_sitter.shen']))
    checks(run(args + ['-e', '(tc +)', '-l', 'tests/tree_sitter_typed.shen', '-e', '(tc -)', '-e',
                       '(if (ts-typed.check (value ts-test.language) (value ts-test.snapshot)) '
                       '(output "2 passed, 0 failed~%") (error "typed Tree-sitter client failed"))']))
    with tempfile.TemporaryDirectory(prefix='shen-tree-sitter-') as directory:
        root = Path(directory)
        oracle(args, native_oracle, root)
        oracle(args, native_oracle, root, b'int f(void) { return 1 } @@@\r\n', '(_) @node')
        oracle(args, native_oracle, root, b'int x;\0int y;', '(_) @node')
        timeout(args, root)
        images(executable, args, root)
        documentation(args, grammar, root)
        application(args, grammar, fs_adapter, root)
        source_analysis(args, grammar, fs_adapter, root)


if __name__ == '__main__':
    main()
