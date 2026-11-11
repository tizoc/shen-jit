"""Optional value transport beside the application's byte CLI and independent BFS."""
import os
import source_deps as ref


def check(executable, adapter, directory, byte_program):
    program = directory / ('source-values.exe' if os.name == 'nt' else 'source-values')
    base = [executable, 'eval', '-s', 'fs.*adapter-files*', '[' + ref.string(adapter) + ']',
            '-l', 'example-apps/source-deps/load.shen', '-l', 'lib/parallel-map.shen',
            '-l', 'example-apps/source-deps/batch-values.shen', '-l', 'tests/source_deps_values.shen']
    pure = ref.run(base + ['-e', '(svt.pure)', '-e',
                          '(shen-jit.save-executable ' + ref.string(program) + ' svt.main)'])
    assert '11 passed, 0 failed' in pure.stdout
    print('11 passed, 0 failed (value reply validation)', flush=True)
    source, queries_file = directory / 'value facts.ndjson', directory / 'value queries.ndjson'
    output, original = directory / 'value report.ndjson', directory / 'byte report.ndjson'
    checks = 0
    for records in [ref.fixture(), ref.linkage_fixture(), [ref.file('empty.c')]]:
        oracle = ref.expected(records)
        queries = [dict(mode=mode, file=f, name=n, definition_byte=b)
                   for f, n, b in sorted(oracle['nodes']) for mode in ['reach', 'impact']]
        queries += queries[:3]
        ref.write(source, records)
        for subset in [queries, queries[:1], []]:
            ref.write(queries_file, subset)
            ref.run([byte_program, source, original, '--batch', queries_file])
            expected = original.read_bytes()
            for workers in [1, 2, 3, 4, 5]:
                ref.run([program, source, output, queries_file, workers])
                assert output.read_bytes() == expected, (workers, subset)
                ref.check_report(ref.read(output), records)
                checks += 1
    # Reloaded images, worker collections, owned results surviving join and host GC.
    ref.write(source, ref.fixture())
    ref.write(queries_file, [dict(mode='reach', file='a.c', name='main', definition_byte=0)])
    ref.run([byte_program, source, original, '--batch', queries_file])
    for workers in [1, 4]:
        ref.run([program, source, output, queries_file, workers],
                env={'SHEN_JIT_GC_STRESS': '100'})
        assert output.read_bytes() == original.read_bytes()
        checks += 1
    ref.write(queries_file, [dict(mode='reach', file='a.c', name='main', definition_byte=0)] * 67)
    ref.run([byte_program, source, original, '--batch', queries_file])
    for workers in [32, 64]:
        ref.run([program, source, output, queries_file, workers])
        assert output.read_bytes() == original.read_bytes(), workers
        checks += 1
    print(f'{checks} passed, 0 failed (optional value transport, byte reports, join/GC)', flush=True)
