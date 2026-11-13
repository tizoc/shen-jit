"""Ordered batch answers against an independent BFS and the existing CLI walk."""
import random
import source_deps as ref


def check_high_workers(program, source, output, directory):
    queries = directory / 'high worker queries.ndjson'
    ref.write(source, ref.fixture())
    ref.write(queries, [dict(mode='reach', file='a.c', name='main', definition_byte=0)] * 67)
    ref.run([program, source, output, '--batch', queries])
    expected = output.read_bytes()
    for workers in [32, 64]:
        ref.run([program, source, output, '--batch', queries, '--workers', workers])
        assert output.read_bytes() == expected, workers
    return 2


def check(program, source, output, directory):
    query_file = directory / 'batch queries.ndjson'
    rng = random.Random(90217)
    fixtures = [ref.fixture(), ref.linkage_fixture(), [ref.file('empty.c')]]
    for case in range(4):
        names = [f'f{i}' for i in range(19)]
        records = [ref.file('graph.c', version=2)]
        records += [ref.definition('graph.c', name, i * 10) for i, name in enumerate(names)]
        records += [ref.call('graph.c', rng.choice(names[:-1]), names[i % 18], (i % 18) * 10,
                             1000 + i * 20) for i in range(45 + case * 8)]
        fixtures.append(records)
    checks = 0
    for records in fixtures:
        oracle = ref.expected(records)
        nodes = sorted(oracle['nodes'])
        queries = [dict(mode=mode, file=f, name=n, definition_byte=b)
                   for f, n, b in nodes for mode in ['reach', 'impact']]
        # Repeated roots and uneven shards; an empty graph exercises all-empty shards.
        queries = queries[:35] + queries[:2]
        ref.write(source, records)
        for subset in [queries, queries[:1]]:
            ref.write(query_file, subset)
            original = None
            for workers in [0, 1, 2, 3, 4, 5]:
                ref.run([program, source, output, '--batch', query_file, '--workers', workers])
                rows = ref.read(output)
                ref.check_report(rows, records)
                assert [r['query_index'] for r in rows if r['kind'] == 'query'] == list(range(len(subset)))
                for i, q in enumerate(subset):
                    edges = oracle['edges']
                    if q['mode'] == 'impact':
                        edges = {(b, a) for a, b in edges}
                    want = ref.reachable(edges, (q['file'], q['name'], q['definition_byte']))
                    got = [ref.function(r['function']) for r in rows
                           if r['kind'] == q['mode'] and r['query_index'] == i]
                    assert len(got) == len(want) and set(got) == want, (q, got, want)
                if original is None:
                    original = output.read_bytes()
                assert output.read_bytes() == original, f'ordered results differ with {workers} workers'
                checks += 1
        # The old Datalog traversal remains an independent implementation control.
        for q in queries[:2]:
            ref.run([program, source, output, '--' + q['mode'], q['file'], q['name'], q['definition_byte']])
            edges = oracle['edges'] if q['mode'] == 'reach' else {(b, a) for a, b in oracle['edges']}
            assert {ref.function(r['function']) for r in ref.read(output) if r['kind'] == q['mode']} == (
                ref.reachable(edges, (q['file'], q['name'], q['definition_byte'])))
            checks += 1
    checks += check_high_workers(program, source, output, directory)
    ref.write(source, ref.fixture())
    ref.write(query_file, [])
    ref.run([program, source, output, '--batch', query_file])
    original = output.read_bytes()
    for text in ['{', '{}\n', '{"mode":"oops","file":"a.c","name":"main"}\n',
                 '{"mode":"reach","file":"missing","name":"main"}\n',
                 '{"mode":"reach","file":"a.c","name":"main","extra":1}\n',
                 ' ' * 1048577]:
        query_file.write_text(text)
        ref.run([program, source, output, '--batch', query_file, '--workers', 4], success=False)
        assert output.read_bytes() == original
        assert not any(p.name.startswith('.shen-') for p in directory.iterdir())
        checks += 1
    ref.write(query_file, [])
    for options in [['--workers', '65'], ['--workers', '-1'], ['--workers', '3.5'],
                    ['--workers', '2', '--worker-image', program]]:
        ref.run([program, source, output, '--batch', query_file, *options], success=False)
        assert output.read_bytes() == original
        checks += 1
    print(f'{checks} passed, 0 failed (batch graph, ordered 0..5/32/64 isolates, BFS/Datalog controls)', flush=True)
