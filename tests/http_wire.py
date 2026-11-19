#!/usr/bin/env python3
"""Independent HTTP/1.1 clients for the one-request Shen connection driver."""
import email.utils
import http.client
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBRARIES = ["http/server"]

HANDLER = '''(define wire.handler
  Q -> (cond ((= (http.target Q) "/fixed")
              (http.response 200 [["Set-Cookie" "a=1"] ["Set-Cookie" "b=2"]]
                (buffer.from-string "hello")))
             ((= (http.target Q) "/204") (http.response 204 [] (buffer.new 0)))
             ((= (http.target Q) "/205") (http.response 205 [] (buffer.new 0)))
             ((= (http.target Q) "/304") (http.response 304 [] (buffer.new 0)))
             ((= (http.target Q) "/trailers")
               (http.response 200 [] (buffer.from-string
                 (if (= (http.trailers Q) [["x-ok" "yes"]]) "trailers-ok" "bad trailers"))))
             ((= (http.target Q) "/raise") (error "private handler failure"))
             ((= (http.target Q) "/injection")
               (http.response 200 [["X" "badc#13;c#10;Injected: yes"]] (buffer.new 0)))
             (true (http.response 200 [] (http.body Q)))))'''


def exchange(executable, request, expected_status, expected_body=b"", method="GET",
             options="[]", finish=False, expected_length=None, slow=False):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    program = f'''(let L (socket.listen "127.0.0.1" {port})
                       Peer (socket.closing-on-error L (freeze (socket.accept L)))
                       _ (socket.close L)
                    (http.serve-one (io.socket Peer "wire peer") (function wire.handler) {options}))'''
    command = [str(executable), "eval"]
    for library in LIBRARIES:
        command += ["-m", library]
    command += ["-e", HANDLER, "-e", program]
    with tempfile.TemporaryFile() as output_log, tempfile.TemporaryFile() as error_log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output_log, stderr=error_log)
        try:
            ready = time.monotonic() + 10
            while True:
                try:
                    peer = socket.create_connection(("127.0.0.1", port), timeout=2)
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() >= ready:
                        raise AssertionError("HTTP listener did not become ready")
                    time.sleep(0.02)
            with peer:
                peer.settimeout(5)
                try:
                    if slow:
                        for byte in request:
                            peer.sendall(bytes([byte]))
                            time.sleep(0.02)
                    else:
                        # Split independently of the Shen parser; include arbitrary binary bodies.
                        for start in range(0, len(request), 7):
                            peer.sendall(request[start:start + 7])
                    if finish:
                        peer.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                response = http.client.HTTPResponse(peer, method=method)
                response.begin()
                assert response.status == expected_status, response.status
                assert response.read() == expected_body
                assert response.getheader("Connection").lower() == "close"
                length = response.getheader("Content-Length")
                if expected_status in (204, 304):
                    assert length is None
                else:
                    wanted = expected_length if expected_length is not None else len(expected_body)
                    assert length == str(wanted), (length, wanted)
                date = response.getheader("Date")
                assert date is not None
                parsed = email.utils.parsedate_to_datetime(date)
                assert abs(parsed.timestamp() - time.time()) < 30
                if expected_status == 200 and b"/fixed" in request:
                    assert response.headers.get_all("Set-Cookie") == ["a=1", "b=2"]
                assert response.getheader("Injected") is None
                try:
                    assert peer.recv(1) == b"", "unexpected bytes after the final response"
                except ConnectionResetError:
                    assert expected_status >= 400
            process.wait(timeout=5)
            output_log.seek(0)
            error_log.seek(0)
            output, errors = output_log.read(), error_log.read()
            assert process.returncode == 0, errors.decode(errors="replace")
            if expected_status < 400:
                assert b"#<result.ok " in output, output[-1000:]
            else:
                assert b"#<result.err " in output, output[-1000:]
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            if process.returncode:
                output_log.seek(0)
                error_log.seek(0)
                sys.stderr.buffer.write(output_log.read() + error_log.read())


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/shen-jit").resolve()
    host = b"Host: localhost\r\n"
    cases = [
        (b"GET /fixed HTTP/1.1\r\n" + host + b"\r\n", 200, b"hello", {}),
        (b"HEAD /fixed HTTP/1.1\r\n" + host + b"\r\n", 200, b"", {"method": "HEAD", "expected_length": 5}),
        (b"POST /echo HTTP/1.1\r\n" + host + b"Content-Length: 4\r\n\r\na\0\xffz", 200, b"a\0\xffz", {}),
        (b"GET /204 HTTP/1.1\r\n" + host + b"\r\n", 204, b"", {}),
        (b"GET /205 HTTP/1.1\r\n" + host + b"\r\n", 205, b"", {}),
        (b"GET /304 HTTP/1.1\r\n" + host + b"\r\n", 304, b"", {}),
        (b"GET / HTTP/1.1\r\n\r\n", 400, b"", {}),
        (b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", 400, b"", {}),
        (b"POST / HTTP/1.1\r\n" + host + b"Content-Length: 0\r\nContent-Length: 0\r\n\r\n", 400, b"", {}),
        (b"POST / HTTP/1.1\r\n" + host + b"Content-Length: 0,0\r\n\r\n", 400, b"", {}),
        (b"POST / HTTP/1.1\r\n" + host + b"Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", 400, b"", {}),
        (b"POST / HTTP/1.1\r\n" + host + b"Transfer-Encoding: gzip, chunked\r\n\r\n", 501, b"", {}),
        (b"POST / HTTP/1.1\r\n" + host + b"Content-Length: 3\r\nExpect: 100-continue\r\n\r\n", 417, b"", {}),
        (b"POST / HTTP/1.1\r\n" + host + b"Content-Length: 3\r\n\r\nabc", 413, b"", {"options": "[[body-limit 2]]"}),
        (b"POST / HTTP/1.1\r\n" + host + b"Content-Length: 4\r\n\r\nabc", 400, b"", {"finish": True}),
        (b"GET /fixed HTTP/1.1\r\n" + host + b"\r\n", 431, b"", {"options": "[[head-limit 16]]"}),
        (b"GET /raise HTTP/1.1\r\n" + host + b"\r\n", 500, b"", {}),
        (b"GET /injection HTTP/1.1\r\n" + host + b"\r\n", 500, b"", {}),
        (b"GET / HTTP/1.1\r\n" + host + b"\r\n", 408, b"", {"slow": True, "options": "[[head-timeout 100]]"}),
    ]
    chunked = b"POST /echo HTTP/1.1\r\n" + host + b"Transfer-Encoding: chunked\r\n\r\n"
    cases += [
        (chunked + b"0\r\n\r\n", 200, b"", {}),
        (chunked + b'3;x="a;\\\"b"\r\na\0\xff\r\n1;ignored=yes\r\nz\r\n00\r\n\r\n', 200, b"a\0\xffz", {}),
        (chunked.replace(b"/echo", b"/trailers") + b"0\r\nX-Ok: yes\r\n\r\n", 200, b"trailers-ok", {}),
        (chunked + b"2\r\nab\r\n2\r\n", 413, b"", {"options": "[[body-limit 3]]"}),
        (chunked + b"0\r\nContent-Length: 0\r\n\r\n", 400, b"", {}),
        (chunked + b"1\r\naXX", 400, b"", {}),
        (chunked + b"3\r\nab", 400, b"", {"finish": True}),
        (chunked + b"ffffffffffffffffffff\r\n", 413, b"", {}),
        (chunked + b"1\r\na\r\n0\r\n\r\n", 413, b"", {"options": "[[chunk-count-limit 1]]"}),
        (chunked + b"0;oversized=yes\r\n\r\n", 413, b"", {"options": "[[chunk-line-limit 4]]"}),
        (chunked + b"0\r\nX: y\r\n\r\n", 413, b"", {"options": "[[trailer-limit 7]]"}),
        (chunked + b"1\r\na\r\n0\r\n\r\n", 408, b"", {"slow": True, "options": "[[body-timeout 100]]"}),
    ]
    payload = bytes(range(256)) * 257
    cases.append((chunked + f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n",
                  200, payload, {}))
    for request, status, body, kwargs in cases:
        exchange(executable, request, status, body, **kwargs)
    print(f"{len(cases)} independent HTTP wire cases passed")


if __name__ == "__main__":
    main()
