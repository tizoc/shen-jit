#!/usr/bin/env python3
"""Independent Linux fixtures for outbound HTTP, DHCP and DNS over TUN/TAP."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import os
import socket
import struct
import subprocess
import sys


TUN_HOST, TUN_GUEST = "198.51.100.1", "198.51.100.2"
TAP_HOST, TAP_GUEST = "198.51.100.129", "198.51.100.130"
SERVICE = "203.0.113.53"
TAP_MAC = bytes.fromhex("020000000011")
REQUEST = b"GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n"
REPLY = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"


def ip(*args):
    subprocess.run(["ip", *args], check=True)


def checksum(data):
    word_sum = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while word_sum >> 16:
        word_sum = (word_sum & 65535) + (word_sum >> 16)
    return (~word_sum) & 65535


def dhcp_option(kind, value):
    return bytes((kind, len(value))) + value


def dhcp_options(payload):
    if payload[236:240] != b"\x63\x82\x53\x63":
        raise ValueError("invalid DHCP cookie")
    options = {}
    offset = 240
    while offset < len(payload):
        kind = payload[offset]
        offset += 1
        if kind == 255:
            return options
        if kind == 0:
            continue
        length = payload[offset]
        offset += 1
        if offset + length > len(payload):
            raise ValueError("truncated DHCP option")
        options[kind] = payload[offset:offset + length]
        offset += length
    raise ValueError("missing DHCP END option")


def dhcp_reply(request, reply_kind):
    ip_server, ip_guest = map(socket.inet_aton, (TAP_HOST, TAP_GUEST))
    body = bytearray(240)
    body[:4] = b"\x02\x01\x06\x00"
    body[4:8] = request[4:8]
    body[16:20] = ip_guest
    body[28:34] = request[28:34]
    body[236:240] = request[236:240]
    options = (
        dhcp_option(53, bytes((reply_kind,))) + dhcp_option(54, ip_server)
        + dhcp_option(1, socket.inet_aton("255.255.255.128")) + dhcp_option(3, ip_server)
        + dhcp_option(6, socket.inet_aton(SERVICE)) + dhcp_option(51, struct.pack("!I", 8))
        + dhcp_option(58, struct.pack("!I", 1)) + dhcp_option(59, struct.pack("!I", 7))
    )
    payload = bytes(body) + options + b"\xff"
    # Respond to acquisition via limited broadcast and renewal via unicast.
    dst_ip = ip_guest if request[12:16] == ip_guest else b"\xff" * 4
    dst_mac = request[28:34] if dst_ip == ip_guest else b"\xff" * 6
    udp = struct.pack("!HHHH", 67, 68, 8 + len(payload), 0) + payload
    header = struct.pack("!BBHHHBBH4s4s", 69, 0, 20 + len(udp), 0, 16384, 64, 17, 0, ip_server, dst_ip)
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    return dst_mac + TAP_MAC + b"\x08\x00" + header + udp


def dhcp(socket_):
    phases = (1, 3, 3)
    for phase, expected in enumerate(phases):
        while True:
            frame = socket_.recv(2048)
            if (len(frame) >= 283 and frame[12:14] == b"\x08\x00" and frame[14] == 69
                    and frame[23] == 17 and frame[34:38] == b"\x00D\x00C"):
                request = frame[42:]
                options = dhcp_options(request)
                if options.get(53) != bytes((expected,)):
                    continue
                if phase == 2 and request[12:16] != socket.inet_aton(TAP_GUEST):
                    continue
                if phase == 1 and (options.get(50) != socket.inet_aton(TAP_GUEST)
                                   or options.get(54) != socket.inet_aton(TAP_HOST)):
                    raise ValueError("DHCP REQUEST omitted selected offer")
                if options.get(55) != bytes((1, 3, 6, 51, 58, 59)):
                    raise ValueError("unexpected DHCP parameter request list")
                socket_.send(dhcp_reply(request, 2 if phase == 0 else 5))
                break


def dns(datagrams):
    request, source = datagrams.recvfrom(512)
    if request[12:] != b"\x04test\x00\x00\x01\x00\x01" or source != (TAP_GUEST, 53333):
        raise ValueError(f"unexpected DNS request {request!r} from {source}")
    header = request[:2] + struct.pack("!HHHHH", 0x8180, 1, 2, 0, 0)
    question = request[12:]
    alias = b"\x04edge\xc0\x0c"
    cname = b"\xc0\x0c" + struct.pack("!HHIH", 5, 1, 42, len(alias)) + alias
    alias_offset = len(header) + len(question) + 12
    address = struct.pack("!HHHIH", 0xC000 | alias_offset, 1, 1, 60, 4) + socket.inet_aton(SERVICE)
    response = header + question + cname + address
    datagrams.sendto(b"\x00\x00" + response[2:], source)
    datagrams.sendto(response, source)


def http(listener, guest, mode):
    connection, source = listener.accept()
    with connection:
        connection.settimeout(15)
        if source[0] != guest:
            raise ValueError(f"unexpected HTTP source {source}")
        request = b""
        while not request.endswith(b"\r\n\r\n"):
            data = connection.recv(512)
            if not data or len(request) + len(data) > 512:
                raise ValueError(f"incomplete HTTP request: {request!r}")
            request += data
        if request != REQUEST:
            raise ValueError(f"unexpected HTTP request {request!r}")
        if mode == "tun":
            connection.sendall(REPLY.replace(b"Length: 5", b"Length: 2200")[:-5] + b"x" * 2200)
        else:
            connection.sendall(REPLY)
        connection.shutdown(socket.SHUT_WR)
        if connection.recv(1):
            raise ValueError("extra data on closed HTTP connection")


def use_socket(resources, family, kind, protocol=0):
    sock = resources.enter_context(socket.socket(family, kind, protocol))
    sock.settimeout(15)
    return sock


def run(binary, mode, interface):
    with ExitStack() as resources, ThreadPoolExecutor(max_workers=3) as pool:
        listener = use_socket(resources, socket.AF_INET, socket.SOCK_STREAM)
        host, guest = (TUN_HOST, TUN_GUEST) if mode == "tun" else (SERVICE, TAP_GUEST)
        listener.bind((host, 8080))
        listener.listen()
        checks = [pool.submit(http, listener, guest, mode)]
        if mode == "tap":
            dhcp_frames = use_socket(resources, socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
            dhcp_frames.bind((interface, 0))
            # The raw fixture sees bootstrap and renew. A bound socket prevents an
            # ICMP response from the kernel to the fixture's unicast renewal.
            dhcp_port = use_socket(resources, socket.AF_INET, socket.SOCK_DGRAM)
            dhcp_port.bind((TAP_HOST, 67))
            dns_socket = use_socket(resources, socket.AF_INET, socket.SOCK_DGRAM)
            dns_socket.bind((SERVICE, 53))
            checks.extend((pool.submit(dhcp, dhcp_frames), pool.submit(dns, dns_socket)))
        result = subprocess.run([binary, interface, mode], capture_output=True, text=True, timeout=20)
        output = result.stdout
        print(output, end="")
        if result.returncode:
            raise RuntimeError(result.stderr)
        for check in checks:
            check.result()
        expected = (
            ["TUN outbound HTTP with TCP loss and reordering"] if mode == "tun" else
            ["TAP DHCP acquisition", "TAP gateway DNS, outbound HTTP, and DHCP renewal"]
        )
        if any(f"{label} used 0 Shen heap words (control 5)" not in output for label in expected):
            raise RuntimeError("missing heap check for an outbound host path")


def main():
    binary, mode = sys.argv[1:]
    if mode not in ("tun", "tap"):
        raise ValueError(f"unknown mode {mode!r}")
    interface = f"sh{mode}{os.getpid()}"
    ip("tuntap", "add", "dev", interface, "mode", mode)
    try:
        if mode == "tun":
            ip("addr", "add", TUN_HOST, "peer", TUN_GUEST, "dev", interface)
        else:
            ip("link", "set", "dev", interface, "address", TAP_MAC.hex(":"))
            ip("addr", "add", TAP_HOST + "/25", "dev", interface)
            ip("addr", "add", SERVICE + "/32", "dev", interface)
        ip("link", "set", "dev", interface, "mtu", "1500", "up")
        run(binary, mode, interface)
    finally:
        ip("tuntap", "del", "dev", interface, "mode", mode)


if __name__ == "__main__":
    main()
