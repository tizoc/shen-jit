# Linux TUN and TAP packet I/O

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

Load `net/interface` to serve multiple TCP and UDP ports on a single IPv4 address. It owns
ingress for one side of a packet link. The other side can be a TUN adapter, an Ethernet
adapter, or an in-memory peer. Call only `net-interface.poll` to drive this side of the link.

| Operation | Meaning |
| --- | --- |
| `net-interface.make Device IP TcpPort TcpSlots InitialSequence UdpPort UdpSlots` | Preallocate the TCP listener and a UDP receive queue. Each UDP slot holds one packet of up to the link MTU. |
| `net-interface.make-host Device IP TcpPorts TcpSlots Key0 Key1 UdpPorts UdpSlots` | Set up listener and UDP bindings from lists of port fixnums. All TCP connections share `TcpSlots`. UDP uses `UdpSlots` per port. Supply two independently randomized unsigned 32-bit key words at setup. |
| `net-interface.make-host-sized Device IP TcpPorts TcpSlots Key0 Key1 UdpPorts UdpSlots Bytes` | Choose 1 through 1,048,576 bytes per TCP send and receive buffer. Setup also reserves the appropriate presence and SACK bitmaps. |
| `net-interface.make-host-limits Device IP TcpPorts TcpSlots Key0 Key1 UdpPorts UdpSlots Bytes WaitSlots` | Also choose 0 through 1,024 detached TCP TIME-WAIT records. The other constructors reserve 16. At zero, TIME-WAIT connections hold their stream slot until expiry. |
| `net-interface.connect Interface RemoteIP RemotePort` | Claim a TCP slot, pick an unused ephemeral port, and start an active open. Returns a token, or zero when no slot or port is free. |
| `net-interface.next-deadline Interface` | Give the earliest ingress or TCP deadline in absolute monotonic milliseconds, or `-1` while waiting for external I/O. |
| `net-interface.udp-binding Interface Port` | Get an inbox for `udp.inbox-recv-into`, `udp.inbox-ready?`, or `udp.send` with `udp.inbox.peer`. |
| `net-interface.poll Interface Budget` | Process at most `Budget` ingress packets and return the number examined. Drive TCP timers and output even with a zero ingress budget. |
| `net-interface.interface.listener Interface` | Get the listener for `tcp.accept` and the [connection operations](net-tcp.md#bounded-listeners). |
| `net-interface.udp-send Interface IP Port View Count` | Send from the bound port. Returns `udp.sent`, `udp.would-block`, or `udp.too-large`. |
| `net-interface.udp-recv-into Interface Out Info` | Read the next queued datagram with reusable `udp.recv-info`. Returns `udp.received`, `udp.empty`, or `udp.too-small`. A short output leaves the datagram queued. |
| `net-interface.udp-dropped Interface` | Count valid datagrams dropped because this port's receive queue was full. |

A full UDP queue drops the newest datagram, preserving the queued datagrams and allowing TCP and ICMP
to continue. ICMP handles echo requests plus protocol and UDP port unreachable replies. A valid
fragmentation-needed message quoting outstanding TCP data can reduce its segment size. Two
preallocated IPv4 assembly slots each hold up to one link-MTU datagram. They accept fragments
out of order, reject overlaps, and expire after 30 seconds. [ICMP echo format](https://www.rfc-editor.org/rfc/rfc792.html)

## Linux kernel integration test

Run `make test-net-tun` in a disposable Linux network namespace with `/dev/net/tun`, network administration
and raw packet capabilities, `iproute2`, `ping`, and Python 3. For example, a Linux test container can use Docker's
`--network none`, `--cap-add NET_ADMIN`, `--cap-add NET_RAW`, and `--device /dev/net/tun` options.

The test fills a two-slot UDP queue, overflows it, and keeps it full through the first wave of four
Linux TCP streams. While all four are open, a fifth connection attempt times out and Linux `ping`
gets a reply. After the first wave closes, both retained UDP datagrams echo in order and a new
one verifies recovery. The second TCP wave reuses the same slots. The test checks 131,124 TCP
bytes and EOF on all eight sockets. A test-only probe checks the Shen heap across 16 runs each
of simulated reordering, timeout recovery, fast retransmit, adaptive timing, congestion
control, and SACK recovery with two and five losses in a window. It also covers the
entire TUN workload and uses a freshly allocated view as a positive control. A second
test drops the first HTTP request data segment on TUN and delivers the response segments
out of order. Shen initiates this connection to a Linux server.

## Ethernet and TAP

Use `net-tun.attach-tap` with a packet link sized to the IPv4 MTU plus 14 bytes.
Connect that link to `net-ethernet.make` and give the Ethernet adapter the device
at the other end of the interface's IPv4 link. Pass the local MAC and IPv4
addresses, a list of static routes from `net-routes.make`, and the neighbor
capacity. Route lookup chooses the longest prefix. A zero gateway marks a
directly connected route.

Call `net-tun.pump`, `net-ethernet.pump`, and `net-interface.poll` to move frames
between Linux and the Shen interface. Each unresolved neighbor can queue four
packets while ARP retries. The pending entries expire after three seconds and
learned addresses expire after 60 seconds. The Ethernet adapter exposes its
next deadline in monotonic milliseconds.

Run `make test-net-tap` under the same Linux requirements as the TUN check. The
test uses a separate subnet and measures the Ethernet, ARP, and IPv4 echo path
with the same direct Shen heap probe.

## DHCP, DNS, and outbound streams

With TAP, initialize `net-ethernet.make` with the local MAC, IPv4 address zero,
and an empty route list. During address acquisition, alternate Ethernet and device pumps
with `net-dhcp.poll` on the IPv4 link. Create the DHCP client with a setup-time
transaction ID. When it returns `net-dhcp.bound`, read `net-dhcp.client.address`,
`net-dhcp.client.mask`, `net-dhcp.client.gateway`, and `net-dhcp.client.dns`.
Configure the Ethernet adapter and create the shared IPv4 interface with those
settings. To maintain the lease, bind UDP port 68 at setup and call
`net-dhcp.maintain` with that inbox after polling the interface. The client handles
renewal, rebinding, and lease expiry. Stop using the interface when the lease
expires and reacquire an address before configuring it again.

`net-dns.make` reserves storage for one lookup. Pass it a dedicated UDP inbox
and the maximum size of the response buffer. `net-dns.start` takes a resolver IP,
an unsigned 16-bit transaction ID, and a buffer containing a DNS wire-format
name. For instance, `"c#4;testc#0;"` encodes the name `test`. Pass the
monotonic clock to `net-dns.poll` until it reports a result. The UDP resolver
follows bounded CNAME chains and exposes the IPv4 address and TTL on success.
A truncated reply reports failure. Choose the source port and a fresh transaction
ID at the application boundary.

Allocate a `net-stream.make` handle for each application stream. Open it with
`net-stream.connect` or attach an accepted connection with `net-stream.accept`.
The read and write calls work with offsets and partial counts in existing
buffer views. Continue polling the interface while the stream is live, then
release the terminal connection. [The outbound HTTP example and allocation fixture](../tests/net_host.shen)
uses this API to send a request, check the reply, and perform a clean shutdown.
The TAP test runs it with a DHCP lease and a DNS server on a different subnet
so both DNS and HTTP exercise gateway resolution. [DHCP](https://www.rfc-editor.org/rfc/rfc2131.html), [DNS](https://www.rfc-editor.org/rfc/rfc1035.html)

The TAP test uses four 128 KiB TCP slots. Each slot reserves 311,296 bytes for the
send and receive buffers and three bitmaps, plus fixed metadata. The two links
reserve 48,224 packet bytes and the four ARP pending queues reserve 24,000 more.


## Dual-stack interfaces

IPv6 uses the same packet link, TCP table, listener ports, and UDP bindings as IPv4.
During setup, use `net-ndp.make Device Mac IdHigh IdLow Slots` to create the IPv6 host.
The two ID words form a 64-bit interface identifier. Supply a stable, locally unique
identifier. Use MAC zero and zero neighbor slots for TUN. Use the Ethernet adapter's
MAC and a positive number of neighbor slots for TAP.

For a static address, configure the address using `net-ndp.configure-static Host Address`
before polling. The Ethernet adapter treats that address's /64 as on link. For SLAAC,
the host solicits router advertisements and uses one advertised autonomous /64
prefix and one default router. Both the link-local and global addresses pass duplicate
address detection before use. The host tracks preferred and valid address lifetimes
and removes expired addresses from transport use. [IPv6 Neighbor Discovery](https://www.rfc-editor.org/rfc/rfc4861.html), [IPv6 address autoconfiguration](https://www.rfc-editor.org/rfc/rfc4862.html)

Call `net-interface.enable-ipv6 Interface Host` once during setup. For TAP, also call
`net-ethernet.enable-ipv6 Ethernet Host` with the same host. Afterwards use the usual
poll operations and deadlines. Neighbor entries reserve four pending packets each
and stop retrying after three seconds. Ethernet sends IPv6 multicast using the
destination's corresponding Ethernet multicast address.

| Operation | Meaning |
| --- | --- |
| `net-ipv6.make-address A B C D` | Construct an address from four unsigned 32-bit words, in network order. |
| `net-ndp.host.link-local Host`, `net-ndp.host.global Host` | Borrow the host's address records. Check `net-ndp.local-ready?` or `net-ndp.global-ready?` before using them. Copy an address if it must survive host reconfiguration. |
| `net-interface.connect6 Interface IP Port`, `net-stream.connect6 Stream IP Port` | Open TCP using a usable source address selected for the destination's scope. Existing TCP accept, read, write, and shutdown operations work for both families. |
| `net-interface.udp-send6 Interface LocalPort IP Port Payload Count` | Send unicast IPv6 over the selected binding. Returns `net-interface.no-address` while no usable address is available for the destination's scope. |
| `udp.recv-info.family Info`, `udp.recv-info.source6 Info`, `udp.recv-info.destination6 Info` | Read the family (4 or 6) and the reusable source and destination address records for an IPv6 datagram. Consume or copy these records before reusing `Info`. |

IPv6 uses a minimum link MTU of 1,280 bytes. TCP, UDP, and ICMPv6 receive through
Hop-by-Hop Options, Destination Options, Routing headers with zero segments left,
and Fragment headers. The walker limits each chain to eight headers and 256 bytes
of extensions. It processes option actions in order and ignores trailing bytes
after No Next Header. Unsupported routing, ESP, and AH receive no transport
processing. ICMPv6 handles echo, neighbor discovery, UDP port errors, and TCP
Packet Too Big feedback. [IPv6 specification](https://www.rfc-editor.org/rfc/rfc8200.html),
[ICMPv6](https://www.rfc-editor.org/rfc/rfc4443.html)

### IPv6 reassembly

`net-interface.enable-ipv6 Interface Host` reserves two reassembly slots of
4,096 bytes each. Call `net-interface.enable-ipv6-sized Interface Host Slots Bytes`
at setup to choose 1 through 16 slots of 1,500 through 65,575 bytes each. The size
counts the IPv6 header and payload together. UDP inbox slots grow at setup so
they can receive reassembled datagrams larger than the link MTU. The transmit
path still segments TCP and bounds UDP to the link MTU.

Each datagram has 60 seconds from its first received fragment. Offset zero must
contain the full header chain through its transport header. An overlap discards
the slot's contents and that datagram's remaining fragments are ignored until the
slot expires. A full table drops new assemblies. Atomic fragments bypass the table.
Neighbor Discovery messages carrying a Fragment header are ignored, including
atomic fragments. [IPv6 reassembly](https://www.rfc-editor.org/rfc/rfc8200.html#section-4.5),
[Atomic fragments](https://www.rfc-editor.org/rfc/rfc6946.html),
[Neighbor Discovery and fragmentation](https://www.rfc-editor.org/rfc/rfc6980.html)

The Linux integration tests run IPv4 and IPv6 TCP, UDP, and ping through each device.
They also open an outbound IPv6 TCP stream. The TAP fixture sends a router
advertisement, observes neighbor solicitations in both directions, and uses the
advertised router for an off-link UDP exchange. On both devices, Linux sends TCP
with Destination Options, ICMPv6 behind an options header, and an IPv6 UDP datagram
whose 2,189-byte payload arrives in three reordered fragments. The fixture checks
every reassembled payload byte and rejects an overlapping datagram. Allocation
measurement starts before duplicate address detection and ends after the streams
and datagrams finish.


## IPv4 and IPv6 multicast

Call `net-interface.enable-multicast Interface Slots Seed` during setup to reserve
1 through 64 group slots shared by IPv4 and IPv6. Supply an unsigned 32-bit seed
for report jitter. Enable IPv6 before joining IPv6 groups.

Use `net-interface.join4 Interface IP` or `net-interface.join6 Interface IP` to
receive UDP for a group on the interface's bound ports. Joins return true if the
group is already joined or a slot was available. Use `leave4` and `leave6` to
stop accepting new datagrams for that group. Datagrams already in an inbox can
still be read. A leaving slot is released once its control reports have drained.
Use `joined4?` and `joined6?` to inspect current membership. The normal interface
poll and deadline operations drive pending reports.

`udp.recv-info.destination` gives the IPv4 destination of a received datagram.
For IPv6, use `udp.recv-info.destination6`. Send multicast datagrams with
`udp.send`, `udp.send6`, or the corresponding interface operation. The IPv4 TTL
and IPv6 Hop Limit are 1 on multicast sends. On TAP, the Ethernet adapter maps
multicast IP destinations to multicast MAC addresses.

Membership is interface-wide. The any-source group API uses IGMPv3 and MLDv2
state-change reports and answers general and group-specific queries. An older
querier selects IGMPv1, IGMPv2, or MLDv1 reports for those memberships until its
timer expires. External routers handle multicast forwarding.
[IGMPv3](https://www.rfc-editor.org/rfc/rfc9776.html),
[MLDv2](https://www.rfc-editor.org/rfc/rfc9777.html)

### Source-specific multicast

Use `net-interface.enable-multicast-sized Interface Slots Sources Seed` during
setup to reserve 0 through 64 source slots per group. The device MTU must fit
the largest IPv4 report for that capacity. Ordinary `enable-multicast` reserves
up to eight sources per group, capped by the MTU.

Use `join-source4 Interface Group Source` or `join-source6 Interface Group Source`
to accept UDP from a unicast source in an IPv4 `232/8` or IPv6 `ff3x::/32`
group. IPv6 requires an enabled IPv6 interface, an MTU of at least 1280 bytes,
and a group scope from 2 through 14. Joins return true for a new or existing
subscription and false for an invalid address or a full table. Multiple
subscriptions to the same group form an INCLUDE list.

`leave-source4` and `leave-source6` take the same arguments and stop accepting
new datagrams from that source immediately. The removed source holds its slot
until the last leave report is sent. Rejoining that source can reuse its slot
before the reports finish. A group's slot is released once its last source has
left and the reports have drained. Datagrams already in an inbox remain readable.

IGMPv3 and MLDv2 use ALLOW_NEW_SOURCES and BLOCK_OLD_SOURCES for changes. Reports
to group-and-source-specific queries include the intersection with the
subscribed sources. Source-specific memberships continue to use these report
versions when older queriers are present.
[SSM host requirements](https://www.rfc-editor.org/rfc/rfc4604.html)

The Linux tests capture both families' join and leave reports, including
Router Alert, query Linux-to-Shen, and verify multicast UDP in both directions.
They replace a subscribed source in each family, check the reports against
queries that name both sources, and verify delivery from the selected source.
The heap probe covers group and source changes, queries, and multicast delivery
from the first join through completion.
