#!/usr/bin/env python3
"""Exercise the optional client against an independent loopback HTTP/TLS server."""
import http.server
import json
import os
import re
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
BINARY = bytes(range(256))*4


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path == '/sink-hold':
            self.server.sink_blocked.set()
            assert self.server.sink_release.wait(15)
        if self.path.startswith('/bulk/') or self.path == '/backpressure':
            held = self.path == '/backpressure'
            total = 67108864 if held else int(self.path.removeprefix('/bulk/'))
            if held:
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8192)
            self.send_response(200)
            self.send_header('Content-Length', str(total))
            self.end_headers()
            block = bytes(range(256))*64
            try:
                for at in range(0, total, len(block)):
                    self.wfile.write(block[:min(len(block), total-at)])
                    if held:
                        self.server.produced = at + min(len(block), total-at)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path == '/hold':
            self.server.hold_started.set()
            assert self.server.hold_release.wait(15)
        if self.path == '/await-hold':
            assert self.server.hold_started.wait(5)
        if self.path == '/release-hold':
            self.server.hold_release.set()
        if self.path in ['/slow', '/slow-echo']:
            time.sleep(.3)
        if self.path == '/partial':
            self.send_response(200)
            self.send_header('Content-Length', '1024')
            self.end_headers()
            self.wfile.write(b'abc')
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path == '/stall-body':
            self.send_response(200)
            self.send_header('Content-Length', '1024')
            self.end_headers()
            self.wfile.write(b'abc')
            self.wfile.flush()
            time.sleep(.3)
            self.close_connection = True
            return
        if self.path == '/interim':
            self.wfile.write(b'HTTP/1.1 100 Continue\r\nX-Phase: interim\r\n\r\n')
        if self.path == '/chunked':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.send_header('Trailer', 'X-Trail')
            self.end_headers()
            self.wfile.write(b'3\r\nabc\r\n2\r\nde\r\n0\r\nX-Trail: yes\r\n\r\n')
            return
        size = int(self.headers.get('Content-Length', '0'))
        incoming = self.rfile.read(size) if size else b''
        body = incoming if self.path in ['/echo', '/slow-echo'] else b'missing' if self.path == '/error' else BINARY
        if self.path == '/json':
            body = b'{"ok":true}'
        status = 404 if self.path == '/error' else 302 if self.path in ['/redirect', '/loop', '/downgrade'] else 200
        if status == 302:
            body = b'redirect-body'
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Client-Port', str(self.client_address[1]))
        self.send_header('Set-Cookie', 'a=1')
        self.send_header('Set-Cookie', 'b=2')
        self.send_header('X-Method', self.command)
        self.send_header('X-Content-Type', self.headers.get('Content-Type', 'missing'))
        self.send_header('X-Reset-Value', self.headers.get('X-Reset', 'missing'))
        self.send_header('X-Empty-Value', 'empty' if self.headers.get('X-Empty') == '' else 'missing')
        self.send_header('X-Phase', 'final')
        if status == 302:
            self.send_header('Location', self.server.downgrade if self.path == '/downgrade'
                             else '/loop' if self.path == '/loop' else '/binary')
            self.send_header('X-Hop', 'intermediate')
        self.end_headers()
        if self.command != 'HEAD':
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    do_POST = do_GET
    do_PUT = do_GET
    do_PATCH = do_GET
    do_DELETE = do_GET


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def shen_string(value):
    return '"'+str(value).replace('c#', 'c#99;#').replace('"', 'c#34;')+'"'


def command(executable, adapter):
    return [str(executable), 'eval', '-l', 'lib/ffi.shen', '-l', 'lib/buffer.shen', '-l', 'lib/io.shen',
            '-s', 'curl.*adapter-files*', '['+shen_string(adapter)+']', '-l', 'lib/curl.shen']


def run(cmd, **kwargs):
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=120, **kwargs)
    assert result.returncode == 0 and 'uncaught error' not in result.stderr, (result.stdout[-4000:], result.stderr)
    return result


def check_lines(result, expected):
    lines = [line for line in result.stdout.splitlines() if re.fullmatch(r'[0-9]+ passed, 0 failed', line)]
    assert len(lines) == expected and 'FAIL ' not in result.stdout, result.stdout[-5000:]
    for line in lines:
        print(line, flush=True)


def main():
    # The fixture must stay local even when the host configures a proxy for other traffic.
    os.environ['NO_PROXY'] = os.environ['no_proxy'] = '127.0.0.1,localhost'
    executable = Path(sys.argv[1]).resolve()
    adapter = Path(sys.argv[2]).resolve()
    server = Server(('127.0.0.1', 0), Handler)
    server.hold_started = threading.Event()
    server.hold_release = threading.Event()
    server.sink_blocked = threading.Event()
    server.sink_release = threading.Event()
    server.produced = 0
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    base = f'http://127.0.0.1:{server.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='shen-curl-') as directory:
            directory = Path(directory)
            cert, key = directory/'ca.pem', directory/'key.pem'
            run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),
                 '-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1'])
            tls = Server(('127.0.0.1', 0), Handler)
            tls.downgrade = base+'/binary'
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            tls.socket = context.wrap_socket(tls.socket, server_side=True)
            tls_worker = threading.Thread(target=tls.serve_forever,daemon=True)
            tls_worker.start()
            try:
                args = command(executable, adapter)
                base_args = ['-s','curl-test.base',shen_string(base)]
                tls_args = ['-s','curl-test.tls',shen_string(f'https://127.0.0.1:{tls.server_port}/binary'),
                            '-s','curl-test.ca',shen_string(cert),
                            '-s','curl-test.wrong-host',shen_string(f'https://localhost:{tls.server_port}/binary'),
                            '-s','curl-test.downgrade',shen_string(f'https://127.0.0.1:{tls.server_port}/downgrade')]
                check_lines(run(args+base_args+['-l','tests/curl.shen','-l','tests/curl_stream.shen']
                                +tls_args+['-l','tests/curl_tls.shen']),3)
                typed = '(do (output "~A~%" (if (curl-typed.run '+shen_string(base)+') "3 passed, 0 failed" "0 passed, 1 failed")) true)'
                check_lines(run(args+['-e','(tc +)','-l','tests/curl_typed.shen','-e',typed]),1)
                # A blocked sink cannot cause the server's entire response to be drained/queued.
                pressure = subprocess.Popen(args+base_args+['-l','tests/curl_stream_pressure.shen'],
                    cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                    env={**os.environ,'SHEN_JIT_SEMISPACE':'4M','SHEN_JIT_MAX_HEAP':'16M','SHEN_JIT_STATS':'1'})
                try:
                    assert server.sink_blocked.wait(10), 'stream never reached the sink'
                    time.sleep(.2)
                    produced = server.produced
                    assert produced < 67108864//4, f'slow sink allowed {produced} bytes to be produced'
                finally:
                    server.sink_release.set()
                    out,err = pressure.communicate(timeout=40)
                assert pressure.returncode == 0 and 'stream pressure ok' in out and 'uncaught error' not in err,(out[-1000:],err)
                assert 'C roots still registered' not in err,err
                print(f'curl backpressure: {produced} of 67108864 bytes produced while the sink was blocked',flush=True)
                print('2 passed, 0 failed',flush=True)
                for size in [8388608,67108864]:
                    memory = run(args+base_args+['-s','curl-memory.size',str(size),'-l','tests/curl_stream_memory.shen'],
                        env={**os.environ,'SHEN_JIT_SEMISPACE':'4M','SHEN_JIT_MAX_HEAP':'16M','SHEN_JIT_STATS':'1'})
                    assert f'stream memory ok {size} ' in memory.stdout,memory.stdout[-1000:]
                    assert 'C roots still registered' not in memory.stderr,memory.stderr
                    live = re.search(r'live heap (\d+) KB',memory.stderr).group(1)
                    assert int(re.search(r'semispace (\d+) KB',memory.stderr).group(1)) <= 16384,memory.stderr
                    print(f'curl stream: {size} bytes with a 16 MiB heap cap; live heap {live} KiB',flush=True)
                print('2 passed, 0 failed',flush=True)
                reference = ROOT/'docs/curl.md'
                if reference.exists():
                    examples = directory/'client.shen'
                    examples.write_text('\n'.join(re.findall(r'```shen\n(.*?)```', reference.read_text(), re.S)))
                    verify = '(if (and (= (web.status (web.get '+shen_string(base+'/binary')+')) 200) '
                    verify += '(= (web.decode-json (web.get '+shen_string(base+'/json')+')) [object ["ok" true]]) '
                    verify += '(= (web.decode-json (web.post-json '+shen_string(base+'/echo')+' [object ["ok" true]])) [object ["ok" true]])) '
                    verify += '(do (output "3 passed, 0 failed~%") true) (error "documentation examples failed"))'
                    example_file = directory/'example.bin'
                    saved = '(let Result (web.save '+shen_string(base+'/binary')+' '+shen_string(example_file)+') '
                    saved += 'R (hd (tl Result)) (if (and (= (hd Result) ok) (= (curl.body-length R) 1024)) '
                    saved += '(do (output "1 passed, 0 failed~%") true) (error "stream example failed")))'
                    streamed = '(let Sink (io.output-buffer (buffer.new 1024)) Result (web.stream '+shen_string(base+'/binary')+' Sink) '
                    streamed += '_ (io.close Sink) R (hd (tl Result)) (if (and (= (hd Result) ok) (= (curl.body-length R) 1024)) '
                    streamed += '(do (output "1 passed, 0 failed~%") true) (error "borrowed stream example failed")))'
                    check_lines(run(args+['-l','lib/io-file.shen','-l','lib/grammar.shen','-l','lib/json.shen','-l',str(examples),'-e',verify,'-e',saved,'-e',streamed]),3)
                    assert example_file.read_bytes()==BINARY
                server.hold_started.clear()
                server.hold_release.clear()
                check_lines(run(args+base_args+['-l','tests/curl_wait.shen','-l','tests/curl_stream_thread.shen']),1)
                check_lines(run(args+base_args+['-l','tests/curl_wait.shen','-l','tests/curl_thread.shen']),1)
                image = directory/'curl.img'
                save = [str(executable),'--save',str(image)]+args[1:]+base_args+['-l','tests/curl_wait.shen','-l','tests/curl_thread.shen',
                    '-e','(set curl-image.client (curl.open))',
                    '-e','(set curl-image.streamed (let Sink (io.output-buffer (buffer.new 5)) '
                         'Result (curl.get-to (cn (value curl-test.base) "/chunked") Sink [[proxy ""]]) '
                         '_ (io.close Sink) (hd (tl Result))))',
                    '-e','(set curl-image.response (hd (tl (curl.get (cn (value curl-test.base) "/binary") [[proxy ""]]))))']
                server.hold_started.clear()
                server.hold_release.clear()
                run(save)
                env = {**os.environ,'SHEN_JIT_IMAGE':str(image)}
                restored = run([str(executable),'eval','-e',
                    '(output "saved: ~A ~A ~A ~A ~A~%" (buffer.length (curl.body (value curl-image.response))) '
                    '(trap-error (do (curl.request (value curl-image.client) "GET" (value curl-test.base) [] (buffer.new 0) []) false) (/. X true)) '
                    '(curl.streamed? (value curl-image.streamed)) (curl.body-length (value curl-image.streamed)) '
                    '(= (curl.trailers (value curl-image.streamed)) [["x-trail" "yes"]]))'],env=env)
                assert 'saved: 1024 true true 5 true' in restored.stdout,restored.stdout[-1000:]
                stress = os.environ.get('TEST_GC_STRESS') == '1' # a collection at every allocation: make test-lib-stress
                if stress:
                    gc = run([str(executable),'eval','-l','tests/curl_gc.shen'],
                             env={**env,'SHEN_JIT_GC_STRESS':'1'})
                    assert 'curl gc ok' in gc.stdout and 'curl stream gc ok' in gc.stdout,gc.stdout[-1000:]
                print(f'{7 + stress} passed, 0 failed',flush=True)
                destination = directory/'download.bin'
                for path,success in [('/bulk/20971520',True),('/binary',True),('/error',False),('/redirect',False),('/partial',False)]:
                    argv='['+' '.join(map(shen_string,['tools/curl-fetch.shen',base+path,destination]))+']'
                    completed=subprocess.run(args+['-s','*argv*',argv,'-l','tools/curl-fetch.shen'],
                        cwd=ROOT,capture_output=True,text=True,timeout=30,
                        env={**os.environ,'SHEN_JIT_SEMISPACE':'4M','SHEN_JIT_MAX_HEAP':'16M'})
                    assert (completed.returncode==0 and 'uncaught error' not in completed.stderr)==success,completed.stderr
                    expected = BINARY*20480 if path.startswith('/bulk/') else b'abc' if path=='/partial' else BINARY
                    assert destination.read_bytes()==expected,'downloaded bytes or partial failure differ'
                print('5 passed, 0 failed',flush=True)
            finally:
                tls.shutdown();tls.server_close();tls_worker.join()
    finally:
        server.shutdown();server.server_close();worker.join()


if __name__ == '__main__':
    main()
