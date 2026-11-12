#!/usr/bin/env python3
"""Exercise the counter application with independent HTTP and SQLite clients."""
import concurrent.futures
import contextlib
import http.client
import json
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARIES = ["ffi", "socket", "sqlite", "buffer", "io", "grammar", "json", "deadline", "clock", "io-socket",
             "http-head", "http-request", "http-response", "http-server", "http-listener"]


def shen_string(text):
    return '"' + str(text).replace("c#", "c#99;#").replace('"', "c#34;") + '"'


def request(port, method, target, body=None, status=200, headers=None, chunked=False):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, target, body, {"Connection": "close", **(headers or {})}, encode_chunked=chunked)
        response = connection.getresponse()
        data = response.read()
        assert response.status == status, (target, response.status, data)
        assert response.getheader("Connection") == "close"
        assert response.getheader("Date") is not None
        if method == "HEAD" or status == 204:
            assert data == b""
            return None
        return json.loads(data) if data else None
    finally:
        connection.close()


@contextlib.contextmanager
def server(executable, database):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    # Test-only routes let this harness observe listener statistics.
    program = f'''(counter-app.initialize {shen_string(database.as_posix())})
      (define counter-test.handle
        Q -> (cases (= (http.target Q) "/__test_stop")
                     (do (http.stop (value counter-test.server)) (counter-app.json 202 [object]))
                    (= (http.target Q) "/__test_fail") (error "test application failure")
                    true (counter-app.handle {shen_string(database.as_posix())} Q)))
      (set counter-test.server
        (http.listen "127.0.0.1" {port} (function counter-test.handle)
          [[max-connections 4] [shutdown-grace 100] [head-timeout 1000]
           [body-timeout 1000] [body-limit 4096] [response-body-limit 65536]]))
      (counter-app.await (value counter-test.server))
      (output "APP-STATS ~A~%" (http.stats (value counter-test.server)))'''
    driver = database.parent / "test-driver.shen"
    driver.write_text(program)
    command = [str(executable), "eval"]
    for library in LIBRARIES:
        command += ["-l", f"lib/{library}.shen"]
    command += ["-l", "example-apps/sqlite-http/main.shen", "-l", str(driver)]
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=errors)
        try:
            deadline = time.monotonic() + 15
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        break
                except OSError:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise AssertionError("counter server did not start")
                    time.sleep(0.02)
            yield port
            request(port, "POST", "/__test_stop", status=202)
            process.wait(timeout=10)
            output.seek(0)
            errors.seek(0)
            log, error = output.read(), errors.read()
            assert process.returncode == 0, error.decode(errors="replace")
            match = re.search(rb"^APP-STATS \[([0-9 ]+)\]$", log, re.MULTILINE)
            assert match, log[-2000:]
            active, accepted, completed, failed, cancelled, peak = map(int, match[1].split())
            assert active == 0 and accepted == completed and 1 <= peak <= 4
            assert cancelled <= failed <= completed
            with socket.socket() as probe:
                assert probe.connect_ex(("127.0.0.1", port)) != 0, "listener remained open"
        except BaseException:
            output.seek(0)
            errors.seek(0)
            sys.stderr.buffer.write(output.read()[-6000:] + errors.read())
            raise
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/shen-jit").resolve()
    with tempfile.TemporaryDirectory(prefix="shen-counter-") as directory:
        database = Path(directory) / "counters.db"
        with server(executable, database) as port:
            assert request(port, "GET", "/health") == {"status": "ok"}
            assert request(port, "GET", "/counters") == []
            assert request(port, "GET", "/counters/hits", status=404) == {"error": "counter not found"}
            assert request(port, "POST", "/counters/hits") == {"value": 1}
            assert request(port, "POST", "/counters/hits") == {"value": 2}
            assert request(port, "GET", "/counters/hits") == {"value": 2}
            request(port, "HEAD", "/counters/hits")
            assert request(port, "GET", "/counters") == [{"name": "hits", "value": 2}]
            request(port, "PUT", "/counters/hits", status=415)
            assert request(port, "PUT", "/counters/hits", b'{"value":42}',
                           headers={"Content-Type": "application/json"}) == {"value": 42}
            assert request(port, "PUT", "/counters/hits", [b'{"val', b'ue":', b'7}'],
                           headers={"Content-Type": "APPLICATION/JSON; CHARSET=UTF-8"},
                           chunked=True) == {"value": 7}
            for invalid in [b'{"value":1,"value":2}', b'{"value":1.0}', b'{"value":-1}',
                            b'{"value":1000000000001}', b'{"value":1,"extra":2}', b'"\xff"']:
                request(port, "PUT", "/counters/hits", invalid, status=400,
                        headers={"Content-Type": "application/json"})
            assert request(port, "GET", "/counters/hits") == {"value": 7}
            request(port, "POST", "/counters/hits", b"not empty", status=400)
            request(port, "POST", "/counters/x%27%3BDROP%20TABLE%20counters", status=404)
            request(port, "GET", "/__test_fail", status=500)
            assert request(port, "GET", "/health") == {"status": "ok"}

            def increment(_):
                return request(port, "POST", "/counters/shared")["value"]

            started = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
                values = list(workers.map(increment, range(32)))
            elapsed = time.monotonic() - started
            assert sorted(values) == list(range(1, 33)), values
            assert request(port, "GET", "/counters/shared") == {"value": 32}
            request(port, "DELETE", "/counters/hits", status=204)
            request(port, "GET", "/counters/hits", status=404)

            # Fixed and streamed responses share one connection, including HEAD boundaries.
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                connection.request("GET", "/counters.ndjson")
                response = connection.getresponse()
                assert response.getheader("Transfer-Encoding") == "chunked"
                assert response.getheader("Content-Type") == "application/x-ndjson"
                assert response.getheader("Connection") is None
                assert [json.loads(line) for line in response.read().splitlines()] == [
                    {"name": "shared", "value": 32}]
                first_socket = connection.sock
                connection.request("HEAD", "/counters.ndjson")
                response = connection.getresponse()
                assert response.read() == b""
                connection.request("GET", "/health")
                response = connection.getresponse()
                assert json.loads(response.read()) == {"status": "ok"}
                assert connection.sock is first_socket, "client silently reconnected"
                connection.request("GET", "/health", headers={"Connection": "close"})
                assert json.loads(connection.getresponse().read()) == {"status": "ok"}
                assert connection.sock is None
            finally:
                connection.close()


        with sqlite3.connect(database) as db:
            assert db.execute("SELECT name, value FROM counters").fetchall() == [("shared", 32)]
        with server(executable, database) as port:
            assert request(port, "GET", "/counters/shared") == {"value": 32}
        check_batched_export(executable, Path(directory) / "export.db")
        check_cli_shutdown(executable, database)
        print(f"Counter API, 32 increments from concurrent clients, persistence and shutdown passed ({elapsed:.3f}s for increments)")


def check_batched_export(executable, database):
    # Seed long UTF-8 names directly to exercise batch and code-point boundaries.
    with server(executable, database) as port:
        rows = [(f"{index:03d}-" + "é"*150, index) for index in range(100)]
        with sqlite3.connect(database) as db:
            db.executemany("INSERT INTO counters(name, value) VALUES (?, ?)", rows)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as peer, peer.makefile("rb") as stream:
            peer.sendall(b"GET /counters.ndjson HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            assert stream.readline().startswith(b"HTTP/1.1 200 ")
            fields = []
            while (line := stream.readline()) != b"\r\n":
                assert line
                fields.append(line.lower())
            assert b"transfer-encoding: chunked\r\n" in fields
            chunks = []
            sizes = []
            while True:
                size = int(stream.readline(), 16)
                if size == 0:
                    assert stream.readline() == b"\r\n" and stream.read() == b""
                    break
                sizes.append(size)
                assert 0 < size <= 16384
                chunks.append(stream.read(size))
                assert stream.read(2) == b"\r\n"
            decoded = [json.loads(line) for line in b"".join(chunks).splitlines()]
            assert decoded == [{"name": name, "value": value} for name, value in rows]
            assert sizes[:-1] == [16384] * (len(sizes)-1), sizes
            assert 1 < len(sizes) < len(rows), sizes


def check_cli_shutdown(executable, database):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen([str(executable), "script", "example-apps/sqlite-http/run.shen",
                                    str(database), str(port)], cwd=ROOT, stdout=output, stderr=errors)
        try:
            deadline = time.monotonic() + 15
            while True:
                try:
                    assert request(port, "GET", "/health") == {"status": "ok"}
                    break
                except ConnectionRefusedError:
                    assert process.poll() is None and time.monotonic() < deadline, "CLI did not start"
                    time.sleep(0.02)
            assert request(port, "POST", "/shutdown", status=202) == {"stopping": True}
            process.wait(timeout=8)
            errors.seek(0)
            error = errors.read()
            assert process.returncode == 0, error
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


if __name__ == "__main__":
    main()
