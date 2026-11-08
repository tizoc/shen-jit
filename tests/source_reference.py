#!/usr/bin/env python3
"""Reproducible runtime-source coverage and compiler-symbol checks for source-facts."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

import source_deps as oracle

ROOT = Path(__file__).resolve().parent.parent


def run(args, cwd=ROOT):
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True, text=True,
                            encoding='utf-8', errors='backslashreplace', timeout=120)
    assert result.returncode == 0, (result.stdout[-2000:], result.stderr[-2000:])
    return result.stdout


def main():
    executable, adapter, grammar, fs_adapter, process_adapter = map(lambda p: Path(p).resolve(), sys.argv[1:6])
    if not (ROOT / 'src/runtime/heap.c').is_file() or not (ROOT / 'Makefile').is_file():
        print('source reference: skipped (runtime sources and Makefile are needed)', flush=True)
        return
    full = '--all' in sys.argv[6:]
    selected = {'heap.c', 'reader.c', 'dict.c'}
    commands = []
    for line in run(['make', '-Bn', 'build/runtime']).splitlines():
        args = shlex.split(line)
        if '-c' not in args:
            continue
        source = args[args.index('-c') + 1]
        if source.startswith('src/runtime/') and (full or Path(source).name in selected):
            commands.append(dict(directory=str(ROOT), file=source, arguments=args))
    assert len(commands) >= 3, commands
    with tempfile.TemporaryDirectory(prefix='shen-source-reference-') as directory:
        root = Path(directory)
        database, facts, report = root / 'compile_commands.json', root / 'facts.ndjson', root / 'report.ndjson'
        database.write_text(json.dumps(commands), encoding='utf-8')
        base = [executable, 'eval', '-s', 'treesitter.*adapter-files*', '[' + oracle.string(adapter) + ']',
                '-s', 'fs.*adapter-files*', '[' + oracle.string(fs_adapter) + ']',
                '-s', 'process.*adapter-files*', '[' + oracle.string(process_adapter) + ']']
        argv = '[' + ' '.join(map(oracle.string, ['source-facts', grammar, '--compile-commands', database,
                                                 'runtime-reference', facts])) + ']'
        run(base + ['-s', '*argv*', argv, '-l', 'example-apps/source-facts/main.shen'])
        records = oracle.read(facts)
        bad = [r for r in records if r['kind'] == 'file' and r['syntax_error']]
        assert not [r['path'] for r in bad if Path(r['path']).name in selected], bad[:1]
        for header in bad:
            diagnostic = header['parse']['errors'][0]
            print(f'source reference exclusion: {Path(header["path"]).name} '
                  f'{diagnostic["row"] + 1}:{diagnostic["column"] + 1} '
                  f'{diagnostic["kind"]} {diagnostic["node_kind"]}: {diagnostic["excerpt"]}', flush=True)
        argv = '[' + ' '.join(map(oracle.string, ['source-deps', facts, report])) + ']'
        run(base + ['-s', '*argv*', argv, '-l', 'example-apps/source-deps/main.shen'])
        rows = oracle.read(report)
        oracle.check_report(rows, records)
        assert rows[0]['configured_units'] == len(commands) and rows[0]['functions'] > 0 and rows[0]['edges'] > 0
        assert rows[0]['unowned_calls'] <= 1, rows[0]
        symbols = 0
        nm = shutil.which('nm')
        assert nm, 'nm is required for compiler-symbol coverage checks'
        for command in commands:
            source = command['file']
            if any(Path(r['path']).name == Path(source).name for r in bad):
                continue
            obj = root / (Path(source).stem + '.o')
            args = command['arguments'][:]
            args[args.index('-o') + 1] = str(obj)
            run(args)
            native = set()
            for line in run([nm, '-g', obj]).splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[-2] in ['T', 'W']:
                    name = parts[-1]
                    native.add(name[1:] if sys.platform == 'darwin' and name.startswith('_') else name)
            definitions = {r['name'] for r in records if r['kind'] == 'definition' and
                           Path(r['path']).name == Path(source).name and r['linkage'] == 'external'}
            assert not native - definitions, (source, sorted(native - definitions))
            symbols += len(native)
        assert symbols > 0
        print(f'source reference: {len(commands)} units, {rows[0]["functions"]} functions, '
              f'{rows[0]["edges"]} edges, {len(bad)} exclusions; {symbols} compiler symbols covered', flush=True)
        print('3 passed, 0 failed (runtime extraction, graph oracle and compiler symbols)', flush=True)


if __name__ == '__main__':
    main()
