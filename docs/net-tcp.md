# In-memory TCP

The optional `net/tcp` module, [lib/net/tcp.shen](../lib/net/tcp.shen), provides individual TCP peers and a
bounded TCP listener over the [packet link](net-udp.md). Each connection keeps one segment in flight in
each direction and uses a fixed initial retransmission timeout. The stack emits 20-byte IPv4 and TCP
headers, honors the MSS option in incoming SYNs, and skips unnegotiated options. TCP runs entirely in
managed Shen/JIT. [Linux TUN](net-tun.md) connects the link to kernel TCP sockets. To share a link
with UDP and ICMP, use [the shared IPv4 interface](net-tun.md#shared-ipv4-interface).

```sh
shen-jit eval -m tools/tcp-echo.shenmod -e '(tcp-echo.run "hello")'
```

This prints `hello`. The example sends up to 536 bytes in one stream write. The library supports repeated
writes and partial reads with the same preallocated buffers.

## Setup and progress

| Operation | Meaning |
| --- | --- |
| `net-link.make Slots Mtu Delay Clock` | Allocate a packet queue in each direction. `Clock` is a frozen computation returning a nonnegative, nondecreasing fixnum in milliseconds. `Delay` is the one-way delivery delay. |
| `net-link.left Link`, `net-link.right Link` | Create the device handles. One isolate owns the link and both peers. |
| `net-ipv4.address A B C D` | Pack four octets into the address passed to `tcp.make-peer`. |
| `tcp.make-peer Device LocalIP LocalPort RemoteIP RemotePort` | Allocate a reusable peer and its stream buffers. Its state starts at `tcp.closed`. Both ports must be in 1 through 65535. |
| `tcp.listen Peer Sequence`, `tcp.connect Peer Sequence` | Arm a passive or active open from `tcp.closed`. Each returns true if it started. Use an initial sequence fixnum in 0 through 4294967295. |
| `tcp.poll Peer Budget` | Check the clock, consume at most `Budget` queued packets and send at most one segment. Returns the number of incoming packets consumed. Poll both peers to drive the connection. |
| `tcp.state Peer` | Inspect the connection state, such as `tcp.established`, `tcp.close-wait`, `tcp.time-wait`, `tcp.closed`, `tcp.timed-out`, or `tcp.reset`. |

The MTU must be at least 41. Each peer reserves a send buffer and receive buffer of `min(536, Mtu - 40)` bytes
each. The link reserves `Slots × Mtu` packet bytes in each direction, plus fixed queue metadata. Reuse device
handles, peer state, application buffers and a non-allocating clock for an allocation-free typed loop.

The peers start a retransmission timer when a segment is queued onto the link. The timeout starts at one second,
doubles on each retry up to 60 seconds, and the peer enters `tcp.timed-out` when the sixth retry expires.
A received segment is acknowledged according to the next expected byte, including across 32-bit sequence
wraparound. The peer keeps the unacknowledged bytes in its send buffer and can resend them without reading from
the application again. A single queued byte can probe a zero window and recover a lost window update. The
clock makes these transitions reproducible. [TCP sequence numbers and windows](https://www.rfc-editor.org/rfc/rfc9293.html#section-3.4) ·
[Retransmission timer](https://www.rfc-editor.org/rfc/rfc6298.html)

## Byte stream

| Operation | Outcomes |
| --- | --- |
| `tcp.send Peer Payload Count` | Accept up to `Count` bytes from the view's prefix into the send buffer. Returns the accepted count, which may be zero while a previous segment awaits acknowledgment. |
| `tcp.recv-into Peer Out Count` | Copy up to `Count` bytes into the view's prefix. Returns the copied count, zero when no bytes are available, or `-1` on a nonempty read after the peer's FIN and the last buffered byte. |
| `tcp.shutdown-write Peer` | Queue FIN after all accepted bytes have been acknowledged. Returns true if queued. Continue calling `tcp.poll` to drive shutdown and read remaining bytes in the other direction. |

An active close leaves the peer in TIME-WAIT for two minutes of link time, during which it acknowledges a repeated
FIN. A closed peer with its receive buffer drained can be initialized again with a fresh sequence number.

## Bounded listeners

A listener owns one side of a packet link. It accepts connections to one local IPv4 address and port and
matches each segment to a connection by its remote address and port. Setup allocates the connection table
and both stream buffers for every slot. Admission, polling, and slot reuse use that storage.

| Operation | Meaning |
| --- | --- |
| `tcp.make-listener Device LocalIP LocalPort Slots InitialSequence` | Allocate `Slots` connection records and buffers. `InitialSequence` is the first initial sequence number, in 0 through 4294967295. |
| `tcp.listener-poll Listener Budget` | Consume at most `Budget` incoming packets and return the number examined. Check timers and allow up to one outgoing segment per slot. The output rotation advances after a segment is queued. |
| `tcp.accept Listener` | Return the next established connection's fixnum token, or `0` if none is ready. |
| `tcp.connection-index Listener Token` | Return the physical slot index in 1 through `Slots` for caller-owned preallocated buffers. |
| `tcp.connection-state Listener Token` | Return the state of an accepted connection. |
| `tcp.connection-send Listener Token Payload Count` | Accept bytes with the same return contract as `tcp.send`. |
| `tcp.connection-recv-into Listener Token Out Count` | Receive bytes with the same return contract as `tcp.recv-into`. |
| `tcp.connection-shutdown-write Listener Token` | Queue FIN with the same return contract as `tcp.shutdown-write`. |
| `tcp.release Listener Token` | Recycle a terminal connection, discarding any unread data. Returns false while the connection is live, including TIME-WAIT. |

Half-open handshakes take up slots and are reclaimed on timeout. A full listener drops new SYNs, allowing
clients to retry. An accepted connection retains its slot until released. Tokens are scoped to the listener,
and reuse of a slot gives the next connection a fresh token. Access through a released token raises.

`make test-net-tcp` builds a typed executable and compares the SYN bytes with an independently generated fixture.
It drops a data segment and a standalone ACK in separate connections, verifies timer boundaries and exactly-once
byte delivery, and exercises stream backpressure, a lost window update, and FIN retransmission after a lost
final ACK. Listener checks cover capacity, slot reuse, half-open expiration, and output rotation under
backpressure. The allocation regression runs 2,000 typed connections under allocation stress, with a
warmup-only baseline and a positive control that allocates a fresh buffer view each iteration.
