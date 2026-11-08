#!/usr/bin/env python3
"""Independent name-matching/BFS oracle and real CLI checks for source-deps."""
from collections import defaultdict
import json
import os
from pathlib import Path
import random
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def string(value):
    return '"' + ''.join(chr(b) if 32 <= b < 127 and b not in [34, 99] else f'c#{b};'
                         for b in str(value).encode()) + '"'


def run(args, *, success=True, **kwargs):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, encoding='utf-8', errors='backslashreplace', timeout=120,
                            env={**os.environ, **kwargs.pop('env', {})}, **kwargs)
    if success:
        assert result.returncode == 0 and 'uncaught error' not in result.stderr, (
            result.stdout[-2000:], result.stderr[-2000:])
    else:
        assert result.returncode == 2, (result.stdout[-2000:], result.stderr[-2000:])
    return result


def file(path, bad=False, *, version=1):
    record = dict(kind='file', path=path, byte_count=10000, syntax_error=bad)
    if version != 1:
        record['schema_version'] = version
    return record


def site(kind, path, name, owner, at, bad=False):
    return dict(kind=kind, path=path, name=name, container=owner, start_byte=at,
                end_byte=at + len(name.encode()), row=0, column=at, syntax_error=bad)


def definition(path, name, at, linkage='external'):
    return {**site('definition', path, name, name, at), 'container_byte': at, 'linkage': linkage}


def call(path, name, owner, owner_byte, at):
    return {**site('call', path, name, owner, at), 'container_byte': owner_byte}


def linkage_fixture():
    return [file('a.c', version=2), file('b.c', version=2), file('c.c', version=2), file('legacy.c'),
            definition('a.c', 'twice', 0), definition('a.c', 'twice', 20),
            definition('a.c', 'private', 40, 'internal'), definition('a.c', 'shared', 60, 'internal'),
            definition('a.c', 'nested', 80, 'unknown'), definition('b.c', 'private', 0, 'internal'),
            definition('b.c', 'shared', 20), definition('c.c', 'entry', 0),
            site('definition', 'legacy.c', 'old', 'old', 0),
            call('a.c', 'private', 'twice', 0, 100), call('a.c', 'shared', 'twice', 20, 120),
            call('a.c', 'nested', 'twice', 0, 140), call('c.c', 'private', 'entry', 0, 100),
            call('c.c', 'shared', 'entry', 0, 120), call('c.c', 'nested', 'entry', 0, 140),
            call('c.c', 'twice', 'entry', 0, 160), call('c.c', 'old', 'entry', 0, 180),
            call('c.c', 'shared', '', None, 200), site('call', 'legacy.c', 'shared', 'old', 100)]


def fixture():
    headers = [file(p, p == 'bad.c') for p in ['a.c', 'b.c', 'café λ.c', 'd.c', 'bad.c']]
    definitions = [('a.c', 'main', 0), ('a.c', 'helper', 10), ('b.c', 'helper', 0), ('b.c', 'leaf', 10),
                   ('café λ.c', 'entry', 0), ('café λ.c', 'twice', 10), ('café λ.c', 'twice', 20),
                   ('d.c', 'unused', 0), ('bad.c', 'bad', 0)]
    calls = [('a.c', 'main', 'helper'), ('a.c', 'main', 'helper'), ('a.c', 'helper', 'leaf'),
             ('b.c', 'leaf', 'main'), ('b.c', 'helper', 'helper'), ('café λ.c', 'entry', 'helper'),
             ('café λ.c', 'entry', 'external'), ('café λ.c', 'entry', 'bad'),
             ('café λ.c', 'entry', 'twice'), ('café λ.c', 'twice', 'main'),
             ('café λ.c', '', 'main'), ('d.c', 'unknown-owner', 'main'), ('bad.c', 'bad', 'leaf')]
    return headers + [site('definition', f, n, n, at, f == 'bad.c') for f, n, at in definitions] + [
        site('call', f, n, owner, 100 + i * 20, f == 'bad.c') for i, (f, owner, n) in enumerate(calls)]


def function(value):
    return value['file'], value['name'], value['definition_byte']


def location(value):
    return value['file'], value['start_byte'], value['end_byte'], value['row'], value['column']


def expected(records):
    excluded = {r['path'] for r in records if r['kind'] == 'file' and r['syntax_error']}
    versions = {r['path']: r.get('schema_version', 1) for r in records if r['kind'] == 'file'}
    by_local, visible, linkage = defaultdict(list), defaultdict(list), {}
    for r in records:
        if r['kind'] == 'definition' and r['path'] not in excluded:
            fn = r['path'], r['name'], r['start_byte']
            if fn not in linkage:
                linkage[fn] = r.get('linkage', 'legacy')
                by_local[r['path'], r['name']].append(fn)
                if linkage[fn] in ['external', 'legacy']:
                    visible[r['name']].append(fn)
    nodes = set(linkage)
    resolved, unresolved, ambiguous, unowned = set(), set(), set(), set()
    for r in records:
        if r['kind'] != 'call' or r['path'] in excluded:
            continue
        loc = r['path'], r['start_byte'], r['end_byte'], r['row'], r['column']
        owners = by_local[r['path'], r['container']]
        if versions[r['path']] == 2:
            owners = [fn for fn in owners if fn[2] == r['container_byte']]
        if len(owners) != 1:
            unowned.add((loc, r['container'], r['name'], len(owners)))
            continue
        local = by_local[r['path'], r['name']]
        candidates = local or visible[r['name']]
        if len(candidates) == 1 and linkage[candidates[0]] != 'unknown':
            resolved.add((loc, owners[0], candidates[0]))
        elif len(candidates) > 1:
            ambiguous.add((loc, owners[0], r['name'], len(candidates), 'local' if local else 'global'))
        else:
            unresolved.add((loc, owners[0], r['name']))
    return dict(excluded=excluded, nodes=nodes, resolved=resolved, unresolved=unresolved,
                ambiguous=ambiguous, unowned=unowned, edges={(a, b) for _, a, b in resolved})


def check_report(rows, records):
    oracle = expected(records)
    summary = rows[0]
    assert summary['kind'] == 'summary' and summary['matching'] == 'caller-id-local-then-visible-name'
    assert summary['syntax_errors'] == 'exclude-files'
    assert summary['files'] == sum(r['kind'] == 'file' for r in records)
    assert summary['legacy_files'] == sum(r['kind'] == 'file' and 'schema_version' not in r for r in records)
    assert summary['functions'] == len(oracle['nodes'])
    assert summary['calls'] == sum(r['kind'] == 'call' and not r['syntax_error'] for r in records)
    assert summary['calls'] == sum(summary[k] for k in ['resolved_calls', 'unresolved_calls', 'ambiguous_calls', 'unowned_calls'])
    assert {r['file'] for r in rows if r['kind'] == 'excluded_file'} == oracle['excluded']
    assert {function(r['function']) for r in rows if r['kind'] == 'function'} == oracle['nodes']
    assert {function(r['function']): r['linkage'] for r in rows if r['kind'] == 'function'} == {
        (r['path'], r['name'], r['start_byte']): r.get('linkage', 'legacy') for r in records
        if r['kind'] == 'definition' and r['path'] not in oracle['excluded']}
    assert {(function(r['from']), function(r['to'])) for r in rows if r['kind'] == 'edge'} == oracle['edges']
    assert {(r['from'], r['to']) for r in rows if r['kind'] == 'file_edge'} == {
        (a[0], b[0]) for a, b in oracle['edges'] if a[0] != b[0]}
    assert {(location(r['site']), function(r['from']), function(r['to'])) for r in rows
            if r['kind'] == 'resolved_call'} == oracle['resolved']
    assert {(location(r['site']), function(r['from']), r['target']) for r in rows
            if r['kind'] == 'unresolved_call'} == oracle['unresolved']
    assert {(location(r['site']), function(r['from']), r['target'], r['candidates'], r['scope']) for r in rows
            if r['kind'] == 'ambiguous_call'} == oracle['ambiguous']
    assert {(location(r['site']), r['container'], r['target'], r['owner_candidates']) for r in rows
            if r['kind'] == 'unowned_call'} == oracle['unowned']
    return oracle


def write(path, records):
    path.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in records), encoding='utf-8')


def read(path):
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]


def reachable(edges, root):
    todo = [b for a, b in edges if a == root]
    seen = set()
    while todo:
        node = todo.pop()
        if node not in seen:
            seen.add(node)
            todo.extend(b for a, b in edges if a == node)
    return seen


def linkage_checks(program, source, output, rng):
    records = linkage_fixture()
    write(source, records)
    run([program, source, output])
    oracle = check_report(read(output), records)
    assert (('a.c', 'twice', 0), ('a.c', 'private', 40)) in oracle['edges']
    assert (('a.c', 'twice', 20), ('a.c', 'shared', 60)) in oracle['edges']
    assert (('c.c', 'entry', 0), ('b.c', 'shared', 20)) in oracle['edges']
    assert len(oracle['unresolved']) == 3 and len(oracle['unowned']) == 1
    checks = 1
    for at in [0, 20]:
        for mode in ['reach', 'impact']:
            run([program, source, output, '--' + mode, 'a.c', 'twice', at])
            rows = read(output)
            check_report(rows, records)
            edges = oracle['edges'] if mode == 'reach' else {(b, a) for a, b in oracle['edges']}
            assert {function(r['function']) for r in rows if r['kind'] == mode} == reachable(edges, ('a.c', 'twice', at))
            checks += 1
    original = output.read_bytes()
    for options in [['--reach', 'a.c', 'twice'], ['--reach', 'a.c', 'twice', '1'],
                    ['--reach', 'a.c', 'twice', '-1'], ['--reach', 'a.c', 'twice', 'null']]:
        run([program, source, output, *options], success=False)
        assert output.read_bytes() == original
        checks += 1
    header, fn, invocation = file('x.c', version=2), definition('x.c', 'f', 0), call('x.c', 'f', 'f', 0, 20)
    invalid = [[{**header, 'schema_version': version}, fn, invocation] for version in [0, 1, 3, None, True]]
    invalid += [[header, {**fn, 'container_byte': byte}, invocation] for byte in [None, -1, 1, True]]
    invalid += [[header, {**fn, 'linkage': linkage}, invocation] for linkage in ['legacy', 'static', None]]
    invalid += [[header, fn, {**invocation, 'container_byte': byte}] for byte in [None, -1, 1, 10000, True]]
    invalid += [[header, fn, {**invocation, 'container': owner}] for owner in ['', 'other']]
    invalid += [[header, fn, {k: v for k, v in invocation.items() if k != 'container_byte'}],
                [header, {k: v for k, v in fn.items() if k != 'linkage'}, invocation],
                [header, {**fn, 'syntax_error': True}, invocation],
                [{**header, 'syntax_error': True}, {**fn, 'syntax_error': True},
                 {**invocation, 'syntax_error': True, 'container_byte': 1}]]
    for broken in invalid:
        write(source, broken)
        run([program, source, output], success=False)
        assert output.read_bytes() == original
        assert not any(p.name.startswith('.shen-') for p in output.parent.iterdir())
        checks += 1
    # Vary linkage and duplicate names independently of the Datalog evaluator.
    for _ in range(6):
        headers = [file(f'f{k}.c', version=2) for k in range(4)]
        defs = [definition(f'f{k}.c', f'n{rng.randrange(5)}', 10 * j,
                           rng.choice(['internal', 'external', 'unknown'])) for k in range(4) for j in range(4)]
        calls = []
        for j in range(20):
            owner = rng.choice(defs)
            calls.append(call(owner['path'], f'n{rng.randrange(7)}', owner['name'], owner['start_byte'], 100 + j * 20))
        generated = headers + defs + calls
        write(source, generated)
        run([program, source, output])
        check_report(read(output), generated)
        checks += 1
    return checks


def memory(executable, adapter, directory):
    source, output = directory / 'chain.ndjson', directory / 'chain-report.ndjson'
    records = [dict(kind='file', path='chain.c', byte_count=1000000, syntax_error=False, schema_version=2)]
    records += [definition('chain.c', f'n{i:04}', i * 10) for i in range(1000)]
    records += [call('chain.c', f'n{i+1:04}', f'n{i:04}', i * 10, 100000 + i * 10) for i in range(999)]
    write(source, records)
    argv = '[' + ' '.join(map(string, ['source-deps', source, output, '--reach', 'chain.c', 'n0000'])) + ']'
    result = run([executable, 'eval', '-s', 'fs.*adapter-files*', '[' + string(adapter) + ']',
                  '-s', '*argv*', argv, '-l', 'example-apps/source-deps/main.shen',
                  '-e', '(shen-jit.collect)'],
                 env={'SHEN_JIT_SEMISPACE': '4M', 'SHEN_JIT_MAX_HEAP': '32M', 'SHEN_JIT_STATS': '1'})
    rows = read(output)
    assert rows[0]['functions'] == 1000 and rows[0]['edges'] == 999
    assert sum(r['kind'] == 'reach' for r in rows) == 999
    assert rows[0]['input_records'] == 2000
    live = re.findall(r'live heap (\d+) KB', result.stderr)
    assert live, result.stderr[-1000:]
    print(f'source-deps: 1000 functions/999 edges under a 32 MiB heap cap; live heap {live[-1]} KiB', flush=True)
    print('1 passed, 0 failed', flush=True)


def image(executable, base, directory):
    path = directory / 'source-deps.img'
    run([executable, '--save', path] + base[1:] + ['-l', 'tests/source_deps.shen'])
    expression = '(let A (sd-test.ok (source-deps.analyze (value sd-test.data) [reach "a.c" "main"])) '
    expression += 'Db (<-address A 2) Walk (<-address A 4) '
    expression += '(do (shen-jit.collect) '
    expression += '(if (and (= (datalog.count Db edge) 3) (= (datalog.count Walk reached) 3)) '
    expression += '(output "source-deps image gc ok~%") (error "source-deps image changed"))))'
    result = run([executable, 'eval', '-e', expression],
                 env={'SHEN_JIT_IMAGE': str(path), 'SHEN_JIT_GC_STRESS': '1', 'SHEN_JIT_SEMISPACE': '4M'})
    assert 'source-deps image gc ok' in result.stdout
    print('2 passed, 0 failed (saved facts/model and collection at every allocation)', flush=True)


def main():
    executable, adapter, directory = (Path(p).resolve() for p in sys.argv[1:4])
    directory.mkdir(exist_ok=True)
    program = directory / ('source-deps.exe' if os.name == 'nt' else 'source-deps')
    base = [executable, 'eval', '-s', 'fs.*adapter-files*', '[' + string(adapter) + ']',
            '-l', 'example-apps/source-deps/load.shen']
    run(base + ['-e', '(shen-jit.save-executable ' + string(program) + ' source-deps.entry)'])
    source, output = directory / 'facts λ.ndjson', directory / 'report λ.ndjson'
    records = fixture()
    write(source, records)
    run([program, source, output])
    oracle = check_report(read(output), records)
    checks = 1
    argv = '[' + ' '.join(map(string, ['source-deps', source, output])) + ']'
    run([executable, 'eval', '-s', 'fs.*adapter-files*', '[' + string(adapter) + ']',
         '-s', '*argv*', argv, '-l', 'example-apps/source-deps/main.shen'])
    check_report(read(output), records)
    checks += 1
    config = directory / 'script-config.img'
    run([executable, '--save', config, 'eval', '-s', 'fs.*adapter-files*', '[' + string(adapter) + ']'])
    scripted = run([executable, 'script', 'example-apps/source-deps/main.shen', source, output],
                   env={'SHEN_JIT_IMAGE': str(config)})
    assert re.fullmatch(r'Wrote \d+ dependency records\n', scripted.stdout), scripted.stdout
    check_report(read(output), records)
    checks += 1
    for root in [('a.c', 'main', 0), ('b.c', 'helper', 0), ('d.c', 'unused', 0)]:
        for mode in ['reach', 'impact']:
            run([program, source, output, '--' + mode, root[0], root[1]])
            rows = read(output)
            check_report(rows, records)
            edges = oracle['edges'] if mode == 'reach' else {(b, a) for a, b in oracle['edges']}
            assert {function(r['function']) for r in rows if r['kind'] == mode} == reachable(edges, root)
            checks += 1
    rng = random.Random(1937)
    shuffled = records[:5] + rng.sample(records[5:], len(records) - 5)
    write(source, shuffled)
    run([program, source, output])
    check_report(read(output), records)
    checks += 1
    for i in range(6):
        headers = [file(f'f{k}.c') for k in range(4)]
        defs = [site('definition', f'f{k}.c', f'n{rng.randrange(5)}', '', 10 * j)
                for k in range(4) for j in range(4)]
        for r in defs:
            r['container'] = r['name']
        calls = [site('call', f'f{rng.randrange(4)}.c', f'n{rng.randrange(7)}', f'n{rng.randrange(5)}', 100 + j * 20)
                 for j in range(20)]
        generated = headers + defs + calls
        write(source, generated)
        run([program, source, output])
        check_report(read(output), generated)
        checks += 1
    checks += linkage_checks(program, source, output, rng)
    write(source, records)
    run([program, source, output])
    original = output.read_bytes()
    for args in [['--reach', 'missing', 'main'], ['--reach', 'café λ.c', 'twice'], ['--unknown'], []]:
        run([program, source, output, *args] if args else [program], success=False)
        assert output.read_bytes() == original
        checks += 1
    for text in ['{', '[]\n', source.read_text(encoding='utf-8') + '{', source.read_text(encoding='utf-8') + json.dumps(file('a.c'))]:
        source.write_text(text, encoding='utf-8')
        run([program, source, output], success=False)
        assert output.read_bytes() == original
        assert not any(p.name.startswith('.shen-') for p in directory.iterdir())
        checks += 1
    run([program, directory / 'missing.ndjson', output], success=False)
    assert output.read_bytes() == original
    checks += 1
    print(f'{checks} passed, 0 failed (independent graph/BFS oracles, saved CLI and safe failures)', flush=True)
    memory(executable, adapter, directory)
    image(executable, base, directory)


if __name__ == '__main__':
    main()
