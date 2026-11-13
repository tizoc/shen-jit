#!/usr/bin/env python3
"""Independent HTTP/1.1 framing checks for streamed, persistent responses."""
import contextlib
import email.parser
import http.client
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBRARIES = ["ffi", "socket", "buffer", "io", "deadline", "clock", "io-socket",
             "grammar", "http-head", "http-request", "http-response", "http-server", "http-listener"]
# Each connection runs in an isolate of its own, so sources say on standard output when they close.
PROGRAM = '''
(define persistent.stream
  Target ->
    (let State (io.record [0])
      (http.stream-response 200 [] (if (= Target "/known") [length 3] [chunked])
        (http.source
          (/. Maximum D
            (let N (<-address State 0)
                 _ (address-> State 0 (+ N 1))
              (cond ((and (= Target "/early") (= N 0))
                      [error (io.error read "test source" "private early failure")])
                    ((= N 0) [chunk (buffer.from-string "abc")])
                    ((= Target "/late") [error (io.error read "test source" "private late failure")])
                    ((and (= Target "/slow") (= N 1))
                      (do (shen-jit.wait-any [(shen-jit.channel 1)] 300) [eof]))
                    (true [eof]))))
          (freeze (do (output "source closed~%") [ok]))))))
(define persistent.handle
  Q -> (cond ((= (http.target Q) "/stop")
               (do (http.stop (http.current-server)) (http.response 204 [] (buffer.new 0))))
             ((= (http.target Q) "/fixed") (http.response 200 [] (buffer.from-string "fixed")))
             ((= (http.target Q) "/close")
               (http.close-after (http.response 200 [] (buffer.from-string "closed"))))
             (true (persistent.stream (http.target Q)))))
(http.run (http.listen "127.0.0.1" PORT persistent.handle
  [[request-limit 3] [idle-timeout 200] [connection-timeout 2000]
   [write-timeout 200] [response-chunk-size 3]]))
'''


@contextlib.contextmanager
def server(executable):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    command = [str(executable), "eval"]
    for library in LIBRARIES:
        command += ["-l", f"lib/{library}.shen"]
    with tempfile.TemporaryDirectory() as directory:
        program = Path(directory) / "persistent.shen"
        program.write_text(PROGRAM.replace("PORT", str(port)))
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen(command + ["-l", str(program)], cwd=ROOT, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=1):
                            break
                    except OSError:
                        assert process.poll() is None and time.monotonic() < deadline, "server did not start"
                        time.sleep(0.02)
                yield port
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                connection.request("POST", "/stop")
                assert connection.getresponse().read() == b""
                connection.close()
                process.wait(timeout=5)
                assert process.returncode == 0
                log.seek(0)
                assert log.read().count(b"source closed\n") == 6, "sources not closed exactly once"
            except BaseException:
                log.seek(0)
                sys.stderr.buffer.write(log.read()[-4000:])
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)


def message(method, target, close=False):
    return (f"{method} {target} HTTP/1.1\r\nHost: localhost\r\n" +
            ("Connection: close\r\n" if close else "") + "\r\n").encode()


def read_response(stream, method="GET"):
    assert stream.readline().startswith(b"HTTP/1.1 200 ")
    lines = []
    while (line := stream.readline()) != b"\r\n":
        assert line, "truncated response head"
        lines.append(line)
    headers = email.parser.BytesParser().parsebytes(b"".join(lines))
    if method == "HEAD":
        return headers, b""
    if headers.get("Transfer-Encoding") == "chunked":
        chunks = []
        while True:
            line = stream.readline()
            assert line.endswith(b"\r\n"), "truncated chunk line"
            length = int(line[:-2], 16)
            if length == 0:
                assert stream.readline() == b"\r\n"
                return headers, b"".join(chunks)
            data = stream.read(length)
            assert len(data) == length and stream.read(2) == b"\r\n"
            chunks.append(data)
    length = int(headers["Content-Length"])
    data = stream.read(length)
    assert len(data) == length
    return headers, data


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/shen-jit").resolve()
    with server(executable) as port:
        # One buffered reader proves chunk terminators and HEAD boundaries leave no stray bytes.
        with socket.create_connection(("127.0.0.1", port), timeout=3) as peer, peer.makefile("rb") as stream:
            peer.sendall(message("GET", "/stream") + message("HEAD", "/stream") + message("GET", "/known"))
            headers, data = read_response(stream)
            assert data == b"abc" and headers["Connection"] is None
            headers, data = read_response(stream, "HEAD")
            assert data == b"" and headers["Transfer-Encoding"] == "chunked"
            headers, data = read_response(stream)
            assert data == b"abc" and headers["Content-Length"] == "3" and headers["Connection"] == "close"
            assert stream.read() == b"", "request cap did not close"

        # Before headers a producer failure becomes one closing 500; after headers, EOF truncates it.
        for target, status in [("/early", 500), ("/late", 200), ("/slow", 200)]:
            with socket.create_connection(("127.0.0.1", port), timeout=3) as peer:
                peer.sendall(message("GET", target) + message("GET", "/fixed"))
                response = http.client.HTTPResponse(peer)
                response.begin()
                assert response.status == status
                if status == 500:
                    assert response.read() == b"" and response.getheader("Connection") == "close"
                else:
                    try:
                        response.read()
                        raise AssertionError("failed stream had a successful terminator")
                    except http.client.IncompleteRead as error:
                        assert error.partial == b"abc"
                assert peer.recv(1) == b"", "dispatched pipeline after failed output"

        with socket.create_connection(("127.0.0.1", port), timeout=3) as peer, peer.makefile("rb") as stream:
            peer.sendall(message("GET", "/fixed"))
            assert read_response(stream)[1] == b"fixed"
            assert stream.read() == b"", "idle connection did not expire"

        with socket.create_connection(("127.0.0.1", port), timeout=3) as peer, peer.makefile("rb") as stream:
            peer.sendall(message("GET", "/close") + message("GET", "/fixed"))
            headers, data = read_response(stream)
            assert data == b"closed" and headers["Connection"] == "close" and stream.read() == b""

    print("Persistent pipeline, HEAD boundaries, request/idle limits, producer failure and cleanup passed")


if __name__ == "__main__":
    main()
