#!/usr/bin/env python3
"""Configured C extraction checked against compiler preprocessing and executable behavior."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

import source_deps as oracle

ROOT = Path(__file__).resolve().parent.parent


def run(args, cwd=ROOT, success=True):
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True, text=True,
                            encoding='utf-8', errors='backslashreplace', timeout=120)
    assert (result.returncode == 0) == success, (result.stdout[-2000:], result.stderr[-2000:])
    return result


def main():
    executable, adapter, grammar, fs_adapter, process_adapter = map(lambda p: Path(p).resolve(), sys.argv[1:6])
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    assert len(compiler) == 1, 'configured extraction expects a compiler executable, without wrapper arguments'
    with tempfile.TemporaryDirectory(prefix='shen-source-context-') as directory:
        root = Path(directory)
        (root / 'include').mkdir()
        (root / 'include/api.h').write_text(
            '#if FAST\n#define NEXT fast\n#else\n#define NEXT slow\n#endif\n'
            'int (NEXT)(void);\nextern int (*indirect)(void);\n'
            'static inline int helper(void) { return NEXT(); }\n', encoding='utf-8')
        (root / 'a.c').write_text('#include "api.h"\nint start(void) { return helper(); }\n', encoding='utf-8')
        (root / 'b.c').write_text('#if FAST\nint fast(void) { return 10; }\n'
                                 '#else\nint slow(void) { return 20; }\n#endif\n'
                                 'int unexported(void) { return 30; }\n', encoding='utf-8')
        (root / 'c.c').write_text('int unexported(void);\nint other(void) { return unexported(); }\n', encoding='utf-8')
        (root / 'check.c').write_text('int start(void); int other(void);\n'
                                     'int main(void) { return start() == EXPECTED && other() == 30 ? 0 : 1; }\n',
                                     encoding='utf-8')
        database, facts, report = root / 'compile_commands.json', root / 'facts.ndjson', root / 'report.ndjson'
        base = [executable, 'eval', '-s', 'treesitter.*adapter-files*', '[' + oracle.string(adapter) + ']',
                '-s', 'fs.*adapter-files*', '[' + oracle.string(fs_adapter) + ']',
                '-s', 'process.*adapter-files*', '[' + oracle.string(process_adapter) + ']']

        def extract(label, success=True):
            argv = '[' + ' '.join(map(oracle.string, ['source-facts', grammar, '--compile-commands',
                                                     database, label, facts])) + ']'
            return run(base + ['-s', '*argv*', argv, '-l', 'example-apps/source-facts/main.shen'], success=success)

        def analyze(success=True):
            argv = '[' + ' '.join(map(oracle.string, ['source-deps', facts, report])) + ']'
            return run(base + ['-s', '*argv*', argv, '-l', 'example-apps/source-deps/main.shen'], success=success)

        checks = 0
        for mode in [0, 1]:
            commands = []
            for file in ['a.c', 'b.c', 'c.c']:
                output, dependency = file + '.o', file + '.d'
                (root / output).write_text('preserve object', encoding='utf-8')
                (root / dependency).write_text('preserve dependency', encoding='utf-8')
                args = compiler + ['-std=c11', '-O0', '-I', 'include', f'-DFAST={mode}', '-DLABEL="spaces ; $()"',
                                   '-MMD', '-MF', dependency, '-MT', output, '-c', file, '-o', output]
                commands.append(dict(directory=str(root), file=file, arguments=args))
            database.write_text(json.dumps(commands), encoding='utf-8')
            extract(f'mode-{mode}')
            records = oracle.read(facts)
            assert all(r['schema_version'] == 3 and r['coordinates'] == 'preprocessed' and
                       r['configuration'] == f'mode-{mode}' for r in records if r['kind'] == 'file')
            for command in commands:
                file = command['file']
                assert (root / (file + '.o')).read_text(encoding='utf-8') == 'preserve object'
                assert (root / (file + '.d')).read_text(encoding='utf-8') == 'preserve dependency'
                # Independently ask the compiler for the exact bytes, retaining no application flags parser.
                preprocessed = subprocess.check_output(compiler + ['-std=c11', '-O0', '-I', 'include',
                                                       f'-DFAST={mode}', '-DLABEL="spaces ; $()"', '-E', '-P', '-x', 'c', file], cwd=root)
                path = next(r['path'] for r in records if r['kind'] == 'file' and Path(r['path']).name == file)
                for record in records:
                    if record['path'] == path and record['kind'] != 'file':
                        assert preprocessed[record['start_byte']:record['end_byte']].decode() == record['name']
                run(command['arguments'], cwd=root)
            program = root / ('check.exe' if os.name == 'nt' else 'check')
            run(compiler + ['check.c', 'a.c.o', 'b.c.o', 'c.c.o', f'-DEXPECTED={10 if mode else 20}', '-o', program], cwd=root)
            run([program], cwd=root)
            analyze()
            rows = oracle.read(report)
            oracle.check_report(rows, records)
            summary = rows[0]
            assert summary['configured_units'] == 3 and summary['excluded_files'] == 0
            assert summary['functions'] == 5 and summary['edges'] == 3 and summary['resolved_calls'] == 3
            declarations = {r['name'] for r in records if r['kind'] == 'declaration'}
            assert declarations == {'fast' if mode else 'slow', 'unexported'}, declarations
            assert {r['name'] for r in records if r['kind'] == 'definition'} == {
                'helper', 'start', 'fast' if mode else 'slow', 'unexported', 'other'}
            assert {r['configuration'] for r in rows if r['kind'] == 'context'} == {f'mode-{mode}'}
            checks += 5

        original_facts, original_report = facts.read_bytes(), report.read_bytes()
        valid = json.loads(database.read_text(encoding='utf-8'))
        for broken in [[valid[0], valid[0]],
                       [{**valid[0], 'arguments': ['cc', '@response', '-c', 'a.c']}],
                       [{k: v for k, v in valid[0].items() if k != 'arguments'}],
                       [{**valid[0], 'arguments': compiler + ['-E', 'missing.c']}],
                       [{**valid[0], 'arguments': compiler + ['-x', 'c++', '-c', 'a.c']}],
                       [{**valid[0], 'arguments': compiler + ['-I', 'absent', '-c', 'a.c']}],
                       [valid[0], {**valid[1], 'arguments': compiler + ['-include', 'missing.h', '-c', 'b.c']}]]:
            database.write_text(json.dumps(broken), encoding='utf-8')
            extract('broken', success=False)
            assert facts.read_bytes() == original_facts
            assert not any(p.name.startswith('.shen-') for p in root.iterdir())
            checks += 1
        (root / 'large.c').write_bytes(b'int repeated;\n' * 650000)
        database.write_text(json.dumps([dict(directory=str(root), file='large.c',
                                              arguments=compiler + ['-c', 'large.c'])]), encoding='utf-8')
        failed = extract('oversize', success=False)
        assert 'limit' in failed.stderr and facts.read_bytes() == original_facts
        assert not any(p.name.startswith('.shen-') for p in root.iterdir())
        checks += 1
        records = oracle.read(facts)
        for mutate in ['configuration', 'coordinates', 'raw']:
            changed = [dict(r) for r in records]
            header = next(r for r in changed if r['kind'] == 'file')
            if mutate == 'raw':
                header['schema_version'] = 2
                for key in ['configuration', 'coordinates', 'directory', 'arguments']:
                    del header[key]
            else:
                header[mutate] = 'wrong'
            oracle.write(facts, changed)
            analyze(success=False)
            assert report.read_bytes() == original_report
            checks += 1
        records = [r for r in map(json.loads, original_facts.decode().splitlines())
                   if r['kind'] != 'declaration' or r['name'] != 'fast']
        oracle.write(facts, records)
        analyze()
        rows = oracle.read(report)
        oracle.check_report(rows, records)
        assert rows[0]['edges'] == 2
        assert [r['reason'] for r in rows if r['kind'] == 'unresolved_call'] == ['missing-external-declaration']
        checks += 1
        print(f'{checks} passed, 0 failed (configured compiler bytes/behavior, declarations and safe failures)', flush=True)


if __name__ == '__main__':
    main()
