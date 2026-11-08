#!/usr/bin/env python3
"""Independent subprocess fixtures and byte oracles. No network or shell interpretation."""
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BINARY = b"a\0\r\n\x1a\xff"
ARGUMENTS = ["", "one two", "a'b\"d", "tail\\", "\\\\\"", "café λ",
             "$HOME; $(exit 9)", "line\ntwo"]


def string(value):
    return '"' + ''.join(
        chr(byte) if 32 <= byte < 127 and byte not in [34, 99] else f"c#{byte};"
        for byte in str(value).encode('utf-8')
    ) + '"'


def run(args, **kwargs):
    env = {**os.environ, 'SHEN_PROCESS_PARENT_FIXTURE': 'parent-value'}
    env.update(kwargs.pop('env', {}))
    result = subprocess.run(
        args, cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        errors='backslashreplace', timeout=120, env=env, **kwargs,
    )
    assert result.returncode == 0 and 'uncaught error' not in result.stderr, (
        result.stdout[-7000:], result.stderr,
    )
    return result


def checks(result):
    lines = re.findall(r'^\d+ passed, 0 failed$', result.stdout, re.M)
    assert lines and 'FAIL ' not in result.stdout, result.stdout[-7000:]
    for line in lines:
        print(line, flush=True)


def command(executable, adapter):
    args = [str(executable), 'eval']
    for name in ['ffi', 'socket', 'buffer', 'io', 'io-file', 'deadline', 'clock']:
        args += ['-l', f'lib/{name}.shen']
    return args + ['-s', 'process.*adapter-files*', '[' + string(adapter) + ']',
                   '-l', 'lib/process.shen', '-l', 'lib/process-io.shen']


def oracle(root, data):
    expected = struct.pack('<I', len(ARGUMENTS))
    for arg in ARGUMENTS:
        encoded = arg.encode('utf-8')
        expected += struct.pack('<I', len(encoded)) + encoded
    assert (root / 'arguments.bin').read_bytes() == expected, 'argument bytes differ'
    assert (root / 'redirect.bin').read_bytes() == BINARY, 'redirected binary bytes differ'
    prefix = bytes(i % 251 for i in range(262144))
    hash_value = 2166136261
    for byte in data:
        hash_value = ((hash_value ^ byte) * 16777619) & 0xffffffff
    assert (root / 'duplex-out.bin').read_bytes() == prefix + struct.pack('<QI', len(data), hash_value)
    assert (root / 'duplex-err.bin').read_bytes() == bytes(byte ^ 255 for byte in prefix)
    if os.name != 'nt':
        assert (root / 'raw-argument.bin').read_bytes() == struct.pack('<II', 1, 1) + b'\xff'
        pid = struct.unpack('<I', (root / 'descendant.pid').read_bytes())[0]
        if sys.platform.startswith('linux'):
            try:
                state = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1][0]
            except FileNotFoundError:
                state = ''
        else:
            state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
        assert not state or state.startswith('Z'), f'descendant still running: {pid} {state}'
    else:
        import ctypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        pid = struct.unpack('<I', (root / 'descendant.pid').read_bytes())[0]
        handle = kernel.OpenProcess(0x100000, False, pid)
        if handle:
            try:
                assert kernel.WaitForSingleObject(handle, 0) == 0, 'job descendant still running'
            finally:
                kernel.CloseHandle(handle)
    count = 5 if os.name == 'nt' else 6
    print(f'{count} passed, 0 failed (independent argv, binary transfer and descendant cleanup oracles)', flush=True)


def documentation(args, helper, root):
    reference = ROOT / 'docs/processes.md'
    if not reference.exists():
        return
    source = root / 'examples.shen'
    source.write_text('\n'.join(re.findall(r'```shen\n(.*?)```', reference.read_text(), re.S)))
    check = '(let Filter (example.filter ' + string(helper) + ' ["echo"]) '
    check += 'Pipeline (example.pipeline ' + string(helper) + ' ["echo"]) '
    check += '(if (and (example.success? Filter) '
    check += '(= (buffer.string (process.output-bytes (hd (tl Filter)))) "hello") '
    check += '(= (buffer.string (process.output-bytes (hd (tl (hd (tl Pipeline)))))) "pipeline bytes")) '
    check += '(do (output "3 passed, 0 failed~%") true) (error "process reference examples failed")))'
    checks(run(args + ['-l', str(source), '-e', check]))


def filter_application(executable, args, helper, root):
    output = root / 'filtered.bin'
    output.write_bytes(b'old output')
    command_line = ['tools/process-filter.shen', root / 'large-input.bin', output, helper, 'echo']
    argv = '[' + ' '.join(map(string, command_line)) + ']'
    base = args + ['-l', 'lib/fs.shen']
    result = run(base + ['-s', '*argv*', argv, '-l', 'tools/process-filter.shen'],
                 env={'SHEN_JIT_SEMISPACE': '4M', 'SHEN_JIT_MAX_HEAP': '16M'})
    assert 'Filtered 2097152 bytes' in result.stdout, result.stdout[-3000:]
    assert output.read_bytes() == (root / 'large-input.bin').read_bytes()
    before = output.read_bytes()
    command_line = ['tools/process-filter.shen', root / 'input.bin', output, helper, 'fail-filter']
    argv = '[' + ' '.join(map(string, command_line)) + ']'
    result = subprocess.run(base + ['-s', '*argv*', argv, '-l', 'tools/process-filter.shen'],
                            cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                            errors='backslashreplace', timeout=30)
    assert 'child finished with [exited 17]' in result.stdout + result.stderr, (result.stdout[-2000:], result.stderr)
    assert output.read_bytes() == before, 'failed filter replaced the destination'
    assert not any(p.name.startswith('.shen-') for p in root.iterdir())
    print('4 passed, 0 failed (bounded filter application and safe replacement)', flush=True)


def saved_image(executable, args, root):
    image = root / 'process.img'
    run([str(executable), '--save', str(image)] + args[1:] + [
        '-l', 'tests/process_wait.shen', '-l', 'tests/process_gc_helpers.shen',
        '-e', '(do (set process-image.child (hd (tl (process.spawn (value process-test.helper) ["exit" "0"] '
              '[[stdin pipe] [stdout pipe] [stderr pipe]])))) true)',
        '-e', '(process.wait (value process-image.child) 2000)',
        '-e', '(do (set process-image.report (hd (tl (process.run (value process-test.helper) '
              '["echo"] (buffer.from-string "saved") [])))) true)',
    ])
    env = {'SHEN_JIT_IMAGE': str(image)}
    restored = run([str(executable), 'eval', '-e',
        '(output "restored: ~A ~A~%" '
        '(trap-error (do (process.poll (value process-image.child)) false) (/. X true)) '
        '(buffer.string (process.output-bytes (value process-image.report))))'], env=env)
    assert 'restored: true saved' in restored.stdout, restored.stdout[-2000:]
    stressed = run([str(executable), 'eval', '-e',
        '(do (process-gc.threaded (value process-test.helper)) (output "process gc ok~%") true)'],
        env={**env, 'SHEN_JIT_GC_STRESS': '1'})
    assert 'process gc ok' in stressed.stdout, stressed.stdout[-3000:]
    print('3 passed, 0 failed', flush=True)


def main():
    executable, adapter, helper, fs_adapter = (Path(arg).resolve() for arg in sys.argv[1:5])
    # Windows CI may put its system temporary directory on another drive.
    parent = ROOT if os.name == 'nt' else None
    with tempfile.TemporaryDirectory(prefix='shen-process-', dir=parent) as directory:
        root = Path(directory).resolve()
        (root / 'bin').mkdir()
        shutil.copy2(helper, root / 'bin' / ('process-child.exe' if os.name == 'nt' else 'process-child'))
        shutil.copy2(helper, root / ('process-λ.exe' if os.name == 'nt' else 'process-λ'))
        (root / 'input.bin').write_bytes(BINARY)
        data = bytes(range(256)) * 8192
        (root / 'large-input.bin').write_bytes(data)
        args = command(executable, adapter) + [
            '-s', 'process-test.helper', string(helper),
            '-s', 'process-test.root', string(root),
            '-s', 'fs.*adapter-files*', '[' + string(fs_adapter) + ']',
        ]
        checks(run(args + ['-l', 'tests/process.shen', '-l', 'tests/process_wait.shen', '-l', 'tests/process_stream.shen', '-l', 'tests/process_platform.shen']))
        oracle(root, data)
        typed = '(do (output "~A~%" (if (process-typed.run ' + string(helper)
        typed += ') "4 passed, 0 failed" "0 passed, 1 failed")) true)'
        checks(run(args + ['-e', '(tc +)', '-l', 'tests/process_typed.shen', '-e', typed]))
        pressure = run(args + ['-l', 'tests/process_pressure.shen'])
        matched = re.search(r'process pressure ok (\d+)', pressure.stdout)
        assert matched, pressure.stdout[-3000:]
        print('process backpressure: ' + matched[1] + ' of 8388608 bytes produced while the sink was held', flush=True)
        print('1 passed, 0 failed', flush=True)
        for size in [8 * 1024**2, 64 * 1024**2]:
            memory = run(args + ['-s', 'process-memory.size', str(size), '-l', 'tests/process_memory.shen'],
                         env={'SHEN_JIT_SEMISPACE': '4M', 'SHEN_JIT_MAX_HEAP': '16M', 'SHEN_JIT_STATS': '1'})
            chunk = re.search(rf'process stream memory ok {size} (\d+)', memory.stdout)
            assert chunk and 0 < int(chunk[1]) <= 4096, memory.stdout[-3000:]
            live = int(re.search(r'live heap (\d+) KB', memory.stderr)[1])
            assert int(re.search(r'semispace (\d+) KB', memory.stderr)[1]) <= 16384
            print(f'process stream: {size} bytes with a 16 MiB heap cap; live heap {live} KiB', flush=True)
        print('2 passed, 0 failed', flush=True)
        saved_image(executable, args, root)
        filter_application(executable, args, helper, root)
        documentation(args, helper, root)


if __name__ == '__main__':
    main()
