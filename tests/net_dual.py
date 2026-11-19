#!/usr/bin/env python3
"""Linux dual-stack TCP, UDP and ICMP on a single device, with SLAAC on TAP."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import os
import select
import socket
import struct
import subprocess
import sys


PORT = 7777
HOST_MAC = bytes.fromhex("020000000021")
SHEN_MAC = bytes.fromhex("020000000020")
PAYLOAD = b"outbound IPv6 stream"
OFFLINK = "2001:db8:61::1"


def command(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def ipv6(address):
    return socket.inet_pton(socket.AF_INET6, address)


def router_advertisement():
    source, destination = ipv6("fe80::1"), ipv6("ff02::1")
    advertisement = struct.pack("!BBHBBHII", 134, 0, 0, 64, 0, 60, 0, 0)
    link_option = bytes((1, 1)) + HOST_MAC
    prefix_option = struct.pack("!BBBBIII16s", 3, 4, 64, 192, 120, 60, 0, ipv6("2001:db8:60::"))
    message = advertisement + link_option + prefix_option
    pseudo = source + destination + struct.pack("!I3xB", len(message), 58)
    message = message[:2] + struct.pack("!H", checksum(pseudo + message)) + message[4:]
    header = struct.pack("!IHBB16s16s", 0x60000000, len(message), 58, 255, source, destination)
    return bytes.fromhex("333300000001") + HOST_MAC + b"\x86\xdd" + header + message


def observe_nd(frames, host, guest):
    expected = {ipv6("fe80::20"), ipv6(guest)}
    probes = set()
    saw_shen_ns = False
    saw_linux_ns = False
    saw_rs = False
    while not (probes == expected and saw_shen_ns and saw_linux_ns and saw_rs):
        frame = frames.recv(2048)
        if len(frame) < 62 or frame[12:14] != b"\x86\xdd" or frame[20:22] != b"\x3a\xff":
            continue
        mac, src = frame[6:12], frame[22:38]
        kind, code = frame[54:56]
        if code:
            continue
        if kind == 133 and mac == SHEN_MAC and src == ipv6("fe80::20"):
            if ipv6("fe80::20") not in probes:
                raise RuntimeError("router solicitation preceded link-local duplicate detection")
            if frame[62:70] != bytes((1, 1)) + SHEN_MAC:
                raise RuntimeError("router solicitation omitted its link address")
            frames.send(router_advertisement())
            saw_rs = True
        if kind != 135 or len(frame) < 78:
            continue
        target = frame[62:78]
        if mac == SHEN_MAC and src == bytes(16) and target in expected:
            if frame[18:20] != b"\x00\x18":
                raise RuntimeError("duplicate address probe carried a source link address")
            probes.add(target)
        elif mac == SHEN_MAC and target == ipv6(host):
            saw_shen_ns = True
        elif mac == HOST_MAC and target == ipv6(guest):
            saw_linux_ns = True
    print("TAP observed both duplicate-address probes, router solicitation, and neighbor resolution in both directions")


def net_socket(resources, family, kind, protocol=0):
    sock = resources.enter_context(socket.socket(family, kind, protocol))
    sock.settimeout(12)
    return sock


def exact(sock, length):
    result = bytearray()
    while len(result) < length:
        block = sock.recv(length - len(result))
        if not block:
            raise RuntimeError(f"short TCP echo, {len(result)} of {length} bytes")
        result.extend(block)
    return bytes(result)


def outbound(listener, guest):
    stream, peer = listener.accept()
    with stream:
        stream.settimeout(12)
        if peer[0] != guest or exact(stream, len(PAYLOAD)) != PAYLOAD:
            raise RuntimeError(f"unexpected outbound IPv6 TCP peer {peer}")
        stream.sendall(PAYLOAD)
        stream.shutdown(socket.SHUT_WR)
        if stream.recv(1):
            raise RuntimeError("extra outbound data")


def tcp_echo(client, payload):
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    if exact(client, len(payload)) != payload or client.recv(1):
        raise RuntimeError("inbound TCP echo differed")
    return len(payload)


def udp_echo(sock, guest, packets):
    for payload in packets:
        sock.sendto(payload, (guest, PORT))
        content, sender = sock.recvfrom(1500)
        if sender[:2] != (guest, PORT) or content != payload:
            raise RuntimeError(f"UDP echo differed from {sender}")


def router_echo(sock, guest):
    data, sender = sock.recvfrom(1500)
    if sender[:2] != (guest, PORT) or data != PAYLOAD:
        raise RuntimeError(f"unexpected IPv6 gateway test datagram from {sender}")
    sock.sendto(data, sender)
    print("TAP exchanged off-link IPv6 UDP through the advertised router")


def expect_line(process, expected):
    ready, _, _ = select.select([process.stdout], [], [], 10)
    line = process.stdout.readline().strip() if ready else "timed out"
    if line != expected:
        raise RuntimeError(f"expected {expected!r}, got {line!r}")


def exchange(binary, mode, interface, host4, guest4, host6, guest6):
    families = [(socket.AF_INET, host4, guest4), (socket.AF_INET6, host6, guest6)]
    with ExitStack() as resources, ThreadPoolExecutor(max_workers=4) as pool:
        listener = net_socket(resources, socket.AF_INET6, socket.SOCK_STREAM)
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind((host6, 7778))
        listener.listen()
        opened = pool.submit(outbound, listener, guest6)
        discovery = None
        routed = None
        if mode == "tap":
            gateway = net_socket(resources, socket.AF_INET6, socket.SOCK_DGRAM)
            gateway.bind((OFFLINK, 7779))
            routed = pool.submit(router_echo, gateway, guest6)
            frames = net_socket(resources, socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
            frames.bind((interface, 0))
            discovery = pool.submit(observe_nd, frames, host6, guest6)
        with subprocess.Popen([binary, interface, mode], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True) as process:
            try:
                expect_line(process, "TUN ready")
                expect_line(process, "IPv6 ready")
                opened.result()
                command("ping", "-4", "-n", "-c", "1", "-W", "2", guest4)
                command("ping", "-6", "-n", "-c", "1", "-W", "2", guest6)
                if mode == "tap":
                    command("ping", "-6", "-n", "-c", "1", "-W", "2", f"fe80::20%{interface}")
                streams = []
                for i, (family, host, guest) in enumerate(families):
                    stream = net_socket(resources, family, socket.SOCK_STREAM)
                    stream.bind((host, 0))
                    stream.connect((guest, PORT))
                    payload = bytes((p + i) % 251 for p in range(16003 + i * 7013))
                    streams.append((stream, payload))
                running = [pool.submit(tcp_echo, stream, payload) for stream, payload in streams]
                for i, (family, host, guest) in enumerate(families):
                    datagrams = net_socket(resources, family, socket.SOCK_DGRAM)
                    datagrams.bind((host, 0))
                    udp_echo(datagrams, guest, (b"", bytes(range(256)) * (i + 4)))
                count = sum(future.result() for future in running)
                if discovery:
                    discovery.result()
                    routed.result()
                output, _ = process.communicate(timeout=10)
                expected = f"Dual stack echoed {count} TCP bytes and four UDP datagrams, 0 Shen heap words (control 5)"
                if process.returncode or expected not in output:
                    raise RuntimeError(output.strip())
                print(f"{mode.upper()} {expected}")
            except BaseException:
                if process.poll() is None:
                    process.kill()
                output, _ = process.communicate()
                if output:
                    print(output, end="", file=sys.stderr)
                raise


def main():
    binary, mode = sys.argv[1:]
    if mode not in ("tun", "tap"):
        raise ValueError(f"unknown mode {mode!r}")
    interface = f"sd{mode}{os.getpid()}"
    host4, guest4 = ("192.0.2.17", "192.0.2.18") if mode == "tun" else ("192.0.2.33", "192.0.2.34")
    prefix = "2001:db8:50::" if mode == "tun" else "2001:db8:60::"
    host6, guest6 = prefix + "1", prefix + "20"
    command("ip", "tuntap", "add", "dev", interface, "mode", mode)
    try:
        command("ip", "link", "set", "dev", interface, "addrgenmode", "none")
        if mode == "tap":
            command("ip", "link", "set", "dev", interface, "address", HOST_MAC.hex(":"))
            command("ip", "addr", "add", host4 + "/29", "dev", interface)
        else:
            command("ip", "addr", "add", host4, "peer", guest4, "dev", interface)
        command("ip", "link", "set", "dev", interface, "mtu", "1500", "up")
        command("ip", "-6", "addr", "add", "fe80::1/64", "dev", interface, "nodad")
        command("ip", "-6", "addr", "add", host6 + "/64", "dev", interface, "nodad")
        if mode == "tap":
            command("ip", "-6", "addr", "add", OFFLINK + "/128", "dev", interface, "nodad")
        exchange(binary, mode, interface, host4, guest4, host6, guest6)
    finally:
        command("ip", "tuntap", "del", "dev", interface, "mode", mode)


if __name__ == "__main__":
    main()
