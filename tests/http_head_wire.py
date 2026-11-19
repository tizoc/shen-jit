#!/usr/bin/env python3
"""Optional independent TCP fixtures for head capture, limits and slow-peer deadlines."""
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LIBRARIES = ["io/file", "tools/http-head-capture.shenmod"]


def exercise(executable, destination, limit, duration, slow=False):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    program = f'''(let L (socket.listen "127.0.0.1" {port})
                       Peer (socket.closing-on-error L (freeze (socket.accept L)))
                       _ (socket.close L)
                       Result (http-head.capture (io.socket Peer "wire peer") {limit} {duration})
                    (if (result.ok? Result)
                        (io.write-file "{destination.as_posix()}" (fixture.success Result))
                        (let Error (fixture.failure Result)
                          (output "failure: ~A ~A~%" (io.error-domain Error)
                                                    (io.error-progress Error)))))'''
    command = [str(executable), "eval"]
    for library in LIBRARIES:
        command += ["-m", library]
    command += ["-l", "tests/result_helpers.shen", "-e", program]
    output_log = tempfile.TemporaryFile()
    error_log = tempfile.TemporaryFile()
    process = subprocess.Popen(command, cwd=ROOT, stdout=output_log, stderr=error_log)
    try:
        ready = time.monotonic() + 10
        while True:
            try:
                peer = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                if process.poll() is not None or time.monotonic() >= ready:
                    raise AssertionError("head capture did not become ready")
                time.sleep(0.02)
        head = b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        with peer:
            peer.settimeout(3)
            try:
                if slow:
                    for byte in head:
                        peer.sendall(bytes([byte]))
                        time.sleep(0.02)
                else:
                    peer.sendall(head + b"body")
                peer.shutdown(socket.SHUT_WR)
                while peer.recv(1024):
                    pass
            except OSError:
                # Rejection may close with unread native input and reset the connection.
                pass
        process.wait(timeout=5)
        output_log.seek(0)
        error_log.seek(0)
        output, errors = output_log.read(), error_log.read()
        assert process.returncode == 0, errors.decode(errors="replace")
        if slow:
            assert b"failure: timeout " in output, output[-1000:]
            assert not destination.exists()
        elif limit < len(head):
            assert f"failure: library {limit}".encode() in output, output[-1000:]
            assert not destination.exists()
        else:
            assert destination.read_bytes() == head
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        if process.returncode:
            output_log.seek(0)
            error_log.seek(0)
            sys.stderr.buffer.write(output_log.read() + error_log.read())
        output_log.close()
        error_log.close()


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/shen-jit").resolve()
    with tempfile.TemporaryDirectory() as directory:
        destination = Path(directory)
        exercise(executable, destination / "normal", 4096, 2000)
        exercise(executable, destination / "over-limit", 16, 2000)
        exercise(executable, destination / "slow", 4096, 100, slow=True)
    print("3 independent HTTP head cases passed")


if __name__ == "__main__":
    main()
