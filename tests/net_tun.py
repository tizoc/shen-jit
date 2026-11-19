#!/usr/bin/env python3
"""Exercise TCP, UDP, and ping on one TUN or TAP in a disposable Linux network namespace."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import os
import select
import socket
import subprocess
import sys


HOST, GUEST = "192.0.2.1", "192.0.2.2"


def configure(interface, mode):
    address = [HOST, "peer", GUEST] if mode == "tun" else [HOST + "/24"]
    subprocess.run(["ip", "addr", "add", *address, "dev", interface], check=True)
    if mode == "tap":
        subprocess.run(["ip", "link", "set", "dev", interface, "address", "02:00:00:00:00:01"], check=True)
    subprocess.run(["ip", "link", "set", "dev", interface, "mtu", "1500", "up"], check=True)
    route = subprocess.check_output(["ip", "route", "get", GUEST], text=True)
    if f"dev {interface} " not in route:
        raise RuntimeError(f"kernel route misses the {mode.upper()} device: {route.strip()}")


SLOTS, WAVES = 4, 2
PORT = 7777
QUEUED_DATAGRAMS = (b"first\x00\xff", b"")
RECOVERY_DATAGRAM = bytes(range(256)) * 5


def connect(stack, port, timeout=10):
    client = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
    client.settimeout(timeout)
    client.bind((HOST, port))
    client.connect((GUEST, PORT))
    return client


def exchange(task):
    client, payload = task
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    received = bytearray()
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        received.extend(chunk)
    if received != payload:
        raise RuntimeError(f"echo differs: received {len(received)} of {len(payload)} bytes")
    return len(payload)


def wave(pool, batch):
    with ExitStack() as sockets:
        tasks = []
        for index in range(batch * SLOTS, (batch + 1) * SLOTS):
            client = connect(sockets, 41000 + index)
            payload = bytes((i + index) % 251 for i in range(16387 + index))
            tasks.append((client, payload))
        # All four handshakes have completed before any client can start closing its connection.
        if batch == 0:
            try:
                with ExitStack() as extra:
                    connect(extra, 41999, timeout=0.25)
            except TimeoutError:
                pass
            else:
                raise RuntimeError("a fifth connection was admitted to the full listener")
            # Ping while all four streams are open and the UDP mailbox is still full.
            subprocess.run(["ping", "-n", "-c", "1", "-W", "2", "-s", "21", GUEST],
                           check=True, stdout=subprocess.DEVNULL)
        return sum(pool.map(exchange, tasks))


def expect_line(process, expected):
    readable, _, _ = select.select([process.stdout], [], [], 10)
    actual = process.stdout.readline().strip() if readable else "timed out"
    if actual != expected:
        raise RuntimeError(f"expected {expected!r}, got {actual!r}")


def expect_datagram(client, expected):
    actual, source = client.recvfrom(1500)
    if actual != expected or source != (GUEST, PORT):
        raise RuntimeError(f"bad UDP echo from {source}, expected {len(expected)} bytes, got {len(actual)}")


def echo(server, interface, mode):
    with subprocess.Popen([server, interface, mode], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True) as process:
        try:
            expect_line(process, "TUN ready")
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp, ThreadPoolExecutor(max_workers=SLOTS) as pool:
                udp.settimeout(10)
                udp.bind((HOST, 0))
                for datagram in (*QUEUED_DATAGRAMS, b"must be dropped"):
                    udp.sendto(datagram, (GUEST, PORT))
                expect_line(process, "UDP queue full")
                total = wave(pool, 0)
                for datagram in QUEUED_DATAGRAMS:
                    expect_datagram(udp, datagram)
                udp.sendto(RECOVERY_DATAGRAM, (GUEST, PORT))
                expect_datagram(udp, RECOVERY_DATAGRAM)
                total += wave(pool, 1)
            output, _ = process.communicate(timeout=10)
            expected = (f"{mode.upper()} echo {total} TCP bytes on {SLOTS * WAVES} connections (peak {SLOTS}), "
                        "UDP echoed 3 and dropped 1, 0 heap words (control ")
            if process.returncode or not output.startswith(expected):
                raise RuntimeError(f"Shen echo or heap check failed: {output.strip()}")
            print("Ping succeeded with four TCP connections open and the UDP queue full")
            print(output.strip())
        except BaseException:
            if process.poll() is None:
                process.kill()
            output, _ = process.communicate()
            if output:
                print(output.rstrip(), file=sys.stderr)
            raise


def main():
    global HOST, GUEST
    mode = sys.argv[2]
    if mode not in ("tun", "tap"):
        raise ValueError(f"unknown link mode {mode!r}")
    if mode == "tap":
        HOST, GUEST = "192.0.3.1", "192.0.3.2"
    interface = f"sj{mode}{os.getpid()}"
    subprocess.run(["ip", "tuntap", "add", "dev", interface, "mode", mode], check=True)
    try:
        configure(interface, mode)
        echo(sys.argv[1], interface, mode)
    finally:
        subprocess.run(["ip", "tuntap", "del", "dev", interface, "mode", mode], check=True)


if __name__ == "__main__":
    main()
