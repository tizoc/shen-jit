# Linux TUN packet I/O

The optional `net/tun` module attaches a Linux TUN descriptor to one side of a `net/link` packet queue.
A protocol peer or a shared IPv4 interface uses the other side. TUN carries whole IP packets between Shen
and the Linux kernel. The native adapter opens and polls the descriptor and reads or writes bytes.
IPv4, TCP, UDP, and ICMP echo run in Shen. [Linux TUN/TAP documentation](https://docs.kernel.org/networking/tuntap.html)

Build the adapter with `make tun` on Linux. Use a Shen/JIT build that can load shared libraries. Configure
a named TUN interface, addresses, and routes in Linux. Set the same MTU on the interface and on the Shen
link. Attach needs permission to open `/dev/net/tun` and use the interface. The integration test creates
and removes its own device inside a disposable namespace.

## Typed API

| Operation | Meaning |
| --- | --- |
| `net-tun.monotonic Origin` | Return integer monotonic milliseconds since `Origin`. Pass 0 for the system clock reading, or use an earlier reading as the origin. |
| `net-tun.attach Device Name` | Open the named TUN device in nonblocking mode and allocate its fixed ingress scratch buffer. The caller owns the returned adapter. |
| `net-tun.pump Adapter Budget` | Attempt up to `Budget` packets per direction and return the number handled. Oversize ingress counts against the budget and is discarded. A blocked write keeps the outgoing packet queued. |
| `net-tun.wait Adapter Millis` | Wait for a readable descriptor when the incoming queue has space, or for a writable descriptor when a packet is ready to send. Returns true on readiness or false on timeout or interruption. |
| `net-tun.close Adapter` | Release the descriptor. Returns false for a closed or stale adapter. |

Use `net-link.make` with a frozen `(net-tun.monotonic 0)` clock for a live link. One isolate owns the link,
its protocol state, and the TUN adapter. Alternate `net-tun.pump` and the interface's poll operation. Bound
any idle wait by the next time the protocol needs to run. Closing the adapter retires its descriptor, and
a saved adapter reloads stale. Native failures raise with the Linux errno.

The link preallocates both packet rings. TUN ingress uses one MTU-sized buffer plus one byte to detect
truncation. Egress writes directly from the outgoing ring and consumes a slot only after the full write.
The typed packet path reuses this storage and returns immediate values.

## Shared IPv4 interface

Load `net/interface` to put one TCP listener, one bound UDP port, and an ICMP echo responder on a
single IPv4 address. It owns ingress for one side of a packet link. The other side can be a TUN
adapter or an in-memory peer. Call only `net-interface.poll` to drive this side of the link.

| Operation | Meaning |
| --- | --- |
| `net-interface.make Device IP TcpPort TcpSlots InitialSequence UdpPort UdpSlots` | Preallocate the TCP listener and a UDP receive queue. Each UDP slot holds one packet of up to the link MTU. |
| `net-interface.poll Interface Budget` | Process at most `Budget` ingress packets and return the number examined. Drive TCP timers and output even with a zero ingress budget. |
| `net-interface.interface.listener Interface` | Get the listener for `tcp.accept` and the [connection operations](net-tcp.md#bounded-listeners). |
| `net-interface.udp-send Interface IP Port View Count` | Send from the bound port. Returns `udp.sent`, `udp.would-block`, or `udp.too-large`. |
| `net-interface.udp-recv-into Interface Out Info` | Read the next queued datagram with reusable `udp.recv-info`. Returns `udp.received`, `udp.empty`, or `udp.too-small`. A short output leaves the datagram queued. |
| `net-interface.udp-dropped Interface` | Count valid datagrams dropped because this port's receive queue was full. |

A full UDP queue drops the newest datagram, preserving the queued datagrams and allowing TCP and ICMP
to continue. The ICMP responder handles IPv4 Echo Requests addressed to the interface. It writes
replies directly into the transmit queue when space is available. [ICMP echo format](https://www.rfc-editor.org/rfc/rfc792.html)

## Linux kernel integration test

Run `make test-net-tun` in a disposable Linux network namespace with `/dev/net/tun`, network administration
capability, `iproute2`, `ping`, and Python 3. For example, a Linux test container can use Docker's
`--network none`, `--cap-add NET_ADMIN`, `--cap-add NET_RAW`, and `--device /dev/net/tun` options.

The test fills a two-slot UDP queue, overflows it, and keeps it full through the first wave of four
Linux TCP streams. While all four are open, a fifth connection attempt times out and Linux `ping`
gets a reply. After the first wave closes, both retained UDP datagrams echo in order and a new
one verifies recovery. The second TCP wave reuses the same slots. The test checks 131,124 TCP
bytes and EOF on all eight sockets. A test-only probe checks the Shen heap across 16 runs each
of simulated reordering, timeout recovery, and fast retransmit with a lost retry. It also
covers the entire TUN workload and uses a freshly allocated view as a positive control.
