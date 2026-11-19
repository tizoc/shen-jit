#!/usr/bin/env python3
"""Optional independent TCP wire oracle for the Shen framed-echo application."""
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path


def receive_exact(peer, count):
    result = bytearray()
    while len(result) < count:
        chunk = peer.recv(count - len(result))
        if not chunk:
            raise AssertionError("unexpected EOF")
        result.extend(chunk)
    return bytes(result)


def main():
    root = Path(__file__).resolve().parent.parent
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else root / "build/shen-jit").resolve()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    program = f'''(let L (socket.listen "127.0.0.1" {port})
                       Peer (socket.closing-on-error L (freeze (socket.accept L)))
                       _ (socket.close L)
                    (frame-echo.serve (io.socket Peer "oracle peer") 1048576))'''
    command = [str(executable), "eval"]
    command += ["-m", "tools/frame-echo.shenmod"]
    command += ["-e", program]
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                peer = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise AssertionError("echo server did not become ready")
                time.sleep(0.02)
        with peer:
            peer.settimeout(10)
            messages = [(0x1234, bytes(range(256)) * 5), (65535, b""), (7, b'{"a":[1,true]}')]
            for tag, payload in messages:
                wire = struct.pack("!HI", tag, len(payload)) + payload
                # Split the header and payload independently of the Shen encoder.
                for start, end in [(0, 1), (1, 3), (3, 6), (6, len(wire))]:
                    peer.sendall(wire[start:end])
                echoed_tag, length = struct.unpack("!HI", receive_exact(peer, 6))
                assert (echoed_tag, length) == (tag, len(payload))
                assert receive_exact(peer, length) == payload
            peer.shutdown(socket.SHUT_WR)
            assert peer.recv(1) == b""
        output, errors = process.communicate(timeout=10)
        assert process.returncode == 0, errors.decode(errors="replace")
        assert b"#<result.ok 3>" in output, output.decode(errors="replace")
        print("3 independent wire cases passed")
    finally:
        if process.poll() is None:
            process.kill()
        output, errors = process.communicate()
        if process.returncode:
            sys.stderr.buffer.write(output + errors)


if __name__ == "__main__":
    main()
