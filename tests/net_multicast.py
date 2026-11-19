#!/usr/bin/env python3
"""Check IGMPv3 and MLDv2 listener reports and UDP on a Linux TUN or TAP."""
from contextlib import ExitStack
import ipaddress
import os
import select
import socket
import struct
import subprocess
import sys
import time


def ip(*args):
    subprocess.run(["ip", *args], check=True)


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def ipv6(address):
    return socket.inet_pton(socket.AF_INET6, address)


def pseudo6(source, destination, length):
    return source + destination + struct.pack("!I3xB", length, 58)


def group_records(body, width, group):
    records = []
    offset = 8
    count = int.from_bytes(body[6:8], "big")
    for _ in range(count):
        if offset + 4 + width > len(body):
            raise RuntimeError("truncated multicast record")
        kind, aux, sources = struct.unpack_from("!BBH", body, offset)
        start = offset + 4 + width
        end = start + width * sources
        if end + aux * 4 > len(body):
            raise RuntimeError("truncated multicast source list")
        if body[offset + 4:start] == group:
            records.append((kind, tuple(sorted(body[p:p + width] for p in range(start, end, width)))))
        offset = end + aux * 4
    if offset != len(body):
        raise RuntimeError("extra bytes after multicast records")
    return sorted(records)


def capture_reports(frames, addresses, expected4, expected6, repeats):
    _, guest4, group4, group6 = addresses
    wanted4, wanted6 = socket.inet_aton(group4), ipv6(group6)
    counts = {4: 0, 6: 0}
    while min(counts.values()) < repeats:
        packet = frames.recv(2048)
        if not packet:
            continue
        version = packet[0] >> 4
        if version == 4 and len(packet) >= 40:
            if packet[12:16] != socket.inet_aton(guest4) or packet[9] != 2:
                continue
            size = (packet[0] & 15) * 4
            length = int.from_bytes(packet[2:4], "big")
            body = packet[size:length]
            if len(body) < 16 or body[0] != 34:
                continue
            if (packet[8] != 1 or packet[16:20] != socket.inet_aton("224.0.0.22")
                    or packet[20:24] != b"\x94\x04\0\0" or checksum(packet[:size]) or checksum(body)):
                raise RuntimeError("bad IGMPv3 report envelope")
            records, expected = group_records(body, 4, wanted4), expected4
        elif version == 6 and len(packet) >= 76:
            if packet[8:24] != ipv6("fe80::20") or packet[6] != 0:
                continue
            body = packet[48:]
            if body[0] != 143:
                continue
            if (packet[7] != 1 or packet[24:40] != ipv6("ff02::16")
                    or packet[40:48] != b"\x3a\0\x05\x02\0\0\x01\0"
                    or checksum(pseudo6(packet[8:24], packet[24:40], len(body)) + body)):
                raise RuntimeError("bad MLDv2 report envelope")
            records, expected = group_records(body, 16, wanted6), expected6
        else:
            continue
        if records == expected:
            counts[version] += 1


def capture_asm(frames, addresses, record, repeats):
    capture_reports(frames, addresses, [(record, ())], [(record, ())], repeats)


def query4(sock, host, group="0.0.0.0", sources=()):
    destination = "224.0.0.1" if group == "0.0.0.0" else group
    body = struct.pack("!BBH4sBBH", 17, 1, 0, socket.inet_aton(group), 2, 125, len(sources))
    body += b"".join(socket.inet_aton(address) for address in sources)
    body = body[:2] + struct.pack("!H", checksum(body)) + body[4:]
    header = struct.pack("!BBHHHBBH4s4s4s", 70, 0, 24 + len(body), 0, 0, 1, 2, 0,
                         socket.inet_aton(host), socket.inet_aton(destination), b"\x94\x04\0\0")
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    sock.sendto(header + body, (destination, 0))


def query6(sock, index, group="::", sources=()):
    destination = "ff02::1" if group == "::" else group
    source, target = ipv6("fe80::1"), ipv6(destination)
    body = struct.pack("!BBHHH16sBBH", 130, 0, 0, 100, 0, ipv6(group), 2, 125, len(sources))
    body += b"".join(ipv6(address) for address in sources)
    verify = checksum(pseudo6(source, target, len(body)) + body)
    body = body[:2] + struct.pack("!H", verify) + body[4:]
    header = struct.pack("!IHBB16s16s", 0x60000000, 8 + len(body), 0, 1, source, target)
    sock.sendto(header + b"\x3a\0\x05\x02\0\0\x01\0" + body, (destination, 0, 0, index))


def socket_on(stack, family, kind, name, protocol=0):
    sock = stack.enter_context(socket.socket(family, kind, protocol))
    sock.settimeout(8)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, name.encode() + b"\0")
    return sock


def expect_line(process, expected):
    ready, _, _ = select.select([process.stdout], [], [], 8)
    found = process.stdout.readline().strip() if ready else "timed out"
    if found != expected:
        raise RuntimeError(f"expected {expected!r}, got {found!r}")


def receive(sock, data, address):
    observed, sender = sock.recvfrom(1500)
    if observed != data or sender[:2] != (address, 7777):
        raise RuntimeError(f"wrong multicast UDP reply from {sender}")


def exercise_ssm(frames, addresses, raw4, raw6, first4, first6, second4, second6, index):
    host4, guest4, group4, group6 = addresses
    alt4 = second4.getsockname()[0]
    first4.sendto(b"S", (guest4, 7777))
    a4, a6 = (socket.inet_aton(host4),), (ipv6("fe80::1"),)
    b4, b6 = (socket.inet_aton(alt4),), (ipv6("fe80::9"),)
    capture_reports(frames, addresses, [(5, a4)], [(5, a6)], 2)
    query4(raw4, host4, group4, (alt4, host4))
    query6(raw6, index, group6, ("fe80::9", "fe80::1"))
    capture_reports(frames, addresses, [(1, a4)], [(1, a6)], 1)
    second4.sendto(b"b", (group4, 7777))
    second6.sendto(b"b", (group6, 7777, 0, index))
    first4.sendto(b"a", (group4, 7777))
    first6.sendto(b"a", (group6, 7777, 0, index))
    receive(first4, b"a", guest4)
    receive(first6, b"a", "fe80::20")

    first4.sendto(b"R", (guest4, 7777))
    capture_reports(frames, addresses, [(5, b4), (6, a4)], [(5, b6), (6, a6)], 2)
    # A general query and a source-specific query both advertise only the active source.
    query4(raw4, host4)
    query6(raw6, index)
    capture_reports(frames, addresses, [(1, b4)], [(1, b6)], 1)
    query4(raw4, host4, group4, (host4, alt4))
    query6(raw6, index, group6, ("fe80::1", "fe80::9"))
    capture_reports(frames, addresses, [(1, b4)], [(1, b6)], 1)
    first4.sendto(b"a", (group4, 7777))
    first6.sendto(b"a", (group6, 7777, 0, index))
    second4.sendto(b"b", (group4, 7777))
    second6.sendto(b"b", (group6, 7777, 0, index))
    receive(second4, b"b", guest4)
    receive(second6, b"b", "fe80::20")

    first4.sendto(b"D", (guest4, 7777))
    capture_reports(frames, addresses, [(6, b4)], [(6, b6)], 2)
    second4.sendto(b"b", (group4, 7777))
    second6.sendto(b"b", (group6, 7777, 0, index))


def ssm_addresses(addresses):
    host4, guest4, group4, group6 = addresses
    return host4, guest4, group4.replace("239.", "232.", 1), group6.replace("ff12:", "ff32:", 1)


def alternate4(guest4):
    return str(ipaddress.IPv4Address(guest4) + 1)


def exchange(server, mode, name, addresses):
    host4, guest4, group4, group6 = addresses
    index = socket.if_nametoindex(name)
    with ExitStack() as stack:
        frames = socket_on(stack, socket.AF_PACKET, socket.SOCK_DGRAM, name, socket.htons(3))
        frames.bind((name, 0))
        raw4 = socket_on(stack, socket.AF_INET, socket.SOCK_RAW, name, socket.IPPROTO_RAW)
        raw6 = socket_on(stack, socket.AF_INET6, socket.SOCK_RAW, name, socket.IPPROTO_RAW)
        send4 = socket_on(stack, socket.AF_INET, socket.SOCK_DGRAM, name)
        send4.bind((host4, 0))
        send4.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(host4))
        send6 = socket_on(stack, socket.AF_INET6, socket.SOCK_DGRAM, name)
        send6.bind(("fe80::1", 0, 0, index))
        send6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
        other4 = socket_on(stack, socket.AF_INET, socket.SOCK_DGRAM, name)
        other4.bind((alternate4(guest4), 0))
        other4.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(host4))
        other6 = socket_on(stack, socket.AF_INET6, socket.SOCK_DGRAM, name)
        other6.bind(("fe80::9", 0, 0, index))
        other6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
        recv4 = socket_on(stack, socket.AF_INET, socket.SOCK_DGRAM, name)
        recv4.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        recv4.bind(("", 9000))
        recv4.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                         socket.inet_aton(group4) + socket.inet_aton(host4))
        recv6 = socket_on(stack, socket.AF_INET6, socket.SOCK_DGRAM, name)
        recv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        recv6.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        recv6.bind(("::", 9000))
        recv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, ipv6(group6) + struct.pack("=I", index))

        with subprocess.Popen([server, name, mode], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True) as process:
            try:
                expect_line(process, "TUN ready")
                expect_line(process, "IPv6 ready")
                capture_asm(frames, addresses, 4, 2)
                query4(raw4, host4)
                query6(raw6, index)
                capture_asm(frames, addresses, 2, 1)
                query4(raw4, host4, group4)
                query6(raw6, index, group6)
                capture_asm(frames, addresses, 2, 1)
                send4.sendto(b"4", (group4, 7777))
                send6.sendto(b"6", (group6, 7777, 0, index))
                receive(recv4, b"Shen IPv4 multicast", guest4)
                receive(recv6, b"Shen IPv6 multicast", "fe80::20")
                send4.sendto(b"L", (guest4, 7777))
                capture_asm(frames, addresses, 3, 2)
                send4.sendto(b"4", (group4, 7777))
                send6.sendto(b"6", (group6, 7777, 0, index))
                exercise_ssm(frames, ssm_addresses(addresses), raw4, raw6,
                             send4, send6, other4, other6, index)
                time.sleep(0.05)
                send4.sendto(b"Q", (guest4, 7777))
                output, _ = process.communicate(timeout=8)
                expected = "IGMP and MLD group and source changes and UDP used 0 Shen heap words (control 5)"
                if process.returncode or expected not in output:
                    raise RuntimeError(output.strip())
                print(f"{mode.upper()} {expected}")
                print(f"{mode.upper()} verified source-specific reports, replacement, query intersections, and UDP filtering")
            except BaseException:
                if process.poll() is None:
                    process.kill()
                output, _ = process.communicate()
                if output:
                    print(output, end="", file=sys.stderr)
                raise


def main():
    server, mode = sys.argv[1:]
    if mode not in ("tun", "tap"):
        raise ValueError(f"unknown mode {mode!r}")
    name = f"sm{mode}{os.getpid()}"
    if mode == "tun":
        host4, guest4, group4, group6 = "192.0.2.49", "192.0.2.50", "239.1.2.3", "ff12::1237"
        host6 = "2001:db8:70::1"
    else:
        host4, guest4, group4, group6 = "192.0.2.65", "192.0.2.66", "239.1.2.4", "ff12::1238"
        host6 = "2001:db8:80::1"
    ip("tuntap", "add", "dev", name, "mode", mode)
    try:
        ip("link", "set", "dev", name, "addrgenmode", "none")
        if mode == "tap":
            ip("link", "set", "dev", name, "address", "02:00:00:00:00:21")
            ip("addr", "add", host4 + "/29", "dev", name)
        else:
            ip("addr", "add", host4, "peer", guest4, "dev", name)
        ip("link", "set", "dev", name, "multicast", "on", "up")
        ip("addr", "add", alternate4(guest4) + "/32", "dev", name)
        ip("route", "add", group4 + "/32", "dev", name)
        ip("route", "add", ssm_addresses((host4, guest4, group4, group6))[2] + "/32", "dev", name)
        ip("route", "add", "224.0.0.1/32", "dev", name, "metric", str(socket.if_nametoindex(name)))
        ip("-6", "addr", "add", "fe80::1/64", "dev", name, "nodad")
        ip("-6", "addr", "add", "fe80::9/64", "dev", name, "nodad")
        ip("-6", "addr", "add", host6 + "/64", "dev", name, "nodad")
        exchange(server, mode, name, (host4, guest4, group4, group6))
    finally:
        ip("tuntap", "del", "dev", name, "mode", mode)


if __name__ == "__main__":
    main()
