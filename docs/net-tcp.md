# In-memory TCP

The optional `net/tcp` module, [lib/net/tcp.shen](../lib/net/tcp.shen) with its sending, receiving and listener
parts beside it, provides individual TCP peers and a bounded TCP listener over the [packet link](net-udp.md).
Each connection uses bounded send and receive windows with cumulative and selective acknowledgments. The stack
emits 20-byte IPv4 headers, advertises and honors MSS, negotiates scaled windows, and can add SACK options to
TCP headers. TCP runs entirely in managed Shen/JIT. The shared interface can use IPv4 and IPv6 together with one
connection table.
[Linux TUN](net-tun.md) connects the link to kernel TCP sockets. To share a link
with UDP and ICMP, use [the shared IPv4 interface](net-tun.md#shared-ipv4-interface).

```sh
shen-jit eval -m tools/tcp-echo.shenmod -e '(tcp-echo.run "hello")'
```

This prints `hello`. The example sends up to 536 bytes in one stream write. The library supports larger
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

The MTU must be at least 41. Each peer reserves two circular byte buffers of
`8 × min(536, Mtu - 40)` bytes each, up to 4,288 bytes for sending and 4,288 for receiving.
Three bitmaps track out-of-order data, SACKed data, and repairs. Each bitmap uses one
bit per buffer byte and three padding bytes so that a 32-bit read can start at its last
data byte. A peer with the default 4,288-byte windows reserves 10,193 bytes for its
buffers and bitmaps. With a configured buffer size `N`, the total is
`2 × N + 3 × (ceil(N / 8) + 3)` per slot, plus the peer and view metadata.
The sender limits in-flight bytes by both the advertised receive window and the congestion window.
It segments writes at the negotiated MSS. The link reserves `Slots × Mtu` packet bytes in each
direction, plus fixed queue metadata. Reuse device handles, peer state, application buffers and a
non-allocating clock for an allocation-free typed loop.

The retransmission timer starts when a segment is queued onto the link. Its initial value is
one second. Clean handshake and data ACKs supply round-trip samples from the link clock.
The timer uses the smoothed RTT plus four times its variation, clamped to one through 60
seconds. ACKs that cover retransmitted data leave the estimator and any backoff in place.
A fresh sample can replace the backed-off timeout. A retried SYN starts the data phase
with a three-second timeout. [TCP retransmission timer](https://www.rfc-editor.org/rfc/rfc6298.html)

A cumulative ACK advances the send buffer across 32-bit sequence wrap. The receiver retains
in-window bytes ahead of a gap in the same ring and keeps the ACK at the next missing byte.
An overlapping segment preserves bytes already received. When the gap closes, the entire
contiguous range becomes readable and the ACK advances across it. An early FIN takes effect
once all preceding bytes arrive.

Three duplicate pure ACKs for the oldest unacknowledged byte with an unchanged positive
advertised window schedule one fast retransmission of up to one MSS. It stays pending while
the transmit queue is full. An advancing ACK cancels it and resets the count. The receiver
keeps up to three pending gap ACKs when out-of-order packets arrive in one poll.
[TCP fast retransmit](https://www.rfc-editor.org/rfc/rfc5681.html#section-3.2)

The original deadline remains armed after a fast retry. On timeout, the sender doubles
the interval up to 60 seconds and replays outstanding bytes from the oldest unacknowledged
byte within the current window. A cumulative ACK can cancel the rest of the replay. The
peer enters `tcp.timed-out` when the sixth retry expires. One byte can probe a zero window
and recover a lost window update. The clock makes these transitions reproducible.
[TCP incoming segment processing](https://www.rfc-editor.org/rfc/rfc9293.html#section-3.10.7.4)

## Selective acknowledgments

TCP offers SACK-Permitted on SYN when the link MTU is at least 52 bytes. A listener
includes it in SYN-ACK when the caller offered it. When both peers agree, the receiver
reports up to four byte ranges on standalone ACKs, subject to the link MTU. The most
recently received range comes first, and the cumulative ACK stays at the next missing byte.
Peers without negotiated SACK use cumulative ACK recovery. [TCP SACK options](https://www.rfc-editor.org/rfc/rfc2018.html)

The sender uses one preallocated bitmap for reported bytes and another for repairs already
sent. During fast recovery, the sender can retry multiple
gaps before the first repair is acknowledged. It infers loss when a gap has at least three
separate SACKed ranges or more than two MSS of SACKed bytes above it.

The sender estimates the bytes still in flight from outstanding originals and repairs and
uses the remaining congestion window to pace additional repairs, one segment per poll.
A partial advancing ACK can also expose another missing range. Transmit storage stays
occupied until cumulatively acknowledged. Timeout clears both bitmaps so replay can cover
bytes the peer may have discarded. [SACK loss detection and pipe estimation](https://www.rfc-editor.org/rfc/rfc6675.html#section-4)

## Congestion control

A connection starts with a congestion window of four MSS, or one MSS after a retried SYN.
In slow start, each advancing ACK adds up to one MSS, bounded by the newly acknowledged bytes.
The initial slow-start threshold is the send buffer capacity. At the threshold, congestion
avoidance adds one MSS for each window's worth of newly acknowledged bytes, up to the buffer cap.

On loss, the slow-start threshold drops to half the outstanding flight, with a floor of two MSS.
A timeout drops the congestion window to one MSS and limits replay to the available congestion
window as ACKs arrive. Fast retransmit caps the window at the threshold and pauses its growth
until the affected flight is acknowledged. [TCP slow start and congestion avoidance](https://www.rfc-editor.org/rfc/rfc5681.html#section-3.1)

## Byte stream

| Operation | Outcomes |
| --- | --- |
| `tcp.send Peer Payload Count` | Accept up to `Count` bytes from the view's prefix into the send buffer. Returns the accepted count, bounded by the space left for queued and unacknowledged bytes. |
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
| `tcp.make-listener Device LocalIP LocalPort Slots InitialSequence` | Allocate `Slots` connection records and buffers and 16 TIME-WAIT records. `InitialSequence` is the first initial sequence number, in 0 through 4294967295. |
| `tcp.listener-poll Listener Budget` | Consume at most `Budget` incoming packets and return the number examined. Check timers and rotate output among streams and TIME-WAIT acknowledgments. |
| `tcp.accept Listener` | Return the next established connection's fixnum token, or `0` if none is ready. |
| `tcp.connection-index Listener Token` | Return the physical slot index in 1 through `Slots` for caller-owned preallocated buffers. |
| `tcp.accept-on Listener Port` | Accept an established stream for a particular local port. |
| `tcp.connection-readable? Listener Token`, `tcp.connection-writable? Listener Token` | Check for a read or write that can progress, including a terminal read. |
| `tcp.connection-state Listener Token` | Return the state of an accepted connection. |
| `tcp.connection-send Listener Token Payload Count` | Accept bytes with the same return contract as `tcp.send`. |
| `tcp.connection-recv-into Listener Token Out Count` | Receive bytes with the same return contract as `tcp.recv-into`. |
| `tcp.connection-shutdown-write Listener Token` | Queue FIN with the same return contract as `tcp.shutdown-write`. |
| `tcp.connection-abort Listener Token` | Abort the stream and send a reset when the transmit queue has room. An unestablished active open is canceled locally. |
| `tcp.release Listener Token` | Recycle a terminal connection or move a TIME-WAIT connection to an available TIME-WAIT record. A successful release discards any unread data and invalidates the token. |

Half-open handshakes take up slots and are reclaimed on timeout. A full listener drops new SYNs, allowing
clients to retry. An accepted connection retains its slot until released. Tokens are scoped to the listener,
and reuse of a slot gives the next connection a fresh token. Access through a released token raises.

TIME-WAIT records keep the endpoint tuple, sequence numbers, and timer without
holding send or receive buffers. A matching retransmitted FIN gets an ACK and
restarts the two-minute timer. A matching SYN receives the old connection's
ACK until expiry. On an active open, the local port stays reserved while the
record exists. If the table fills, `tcp.release` returns false and the caller
keeps its token and stream slot. Retry when a TIME-WAIT record expires or the
connection reaches `tcp.closed`. `net-stream.release` uses the same rule.
The shared interface can [set the TIME-WAIT capacity](net-tun.md#shared-ipv4-interface).
[TCP closing rules](https://www.rfc-editor.org/rfc/rfc9293.html#section-3.6)

`make test-net-tcp` builds a typed executable and checks independent SYN bytes, segmentation at
the peer's MSS, cumulative ACKs, and reordering across ring and sequence wraparound. It also
checks loss and overlapping retransmissions, clipping at the receive window edge, out-of-order
FIN, zero-window probes, and reuse of a listener slot that held staged data at reset. Its
fast-retransmit test recovers a dropped segment at 25 ms of simulated time and exercises
a lost fast retry on the same connection. The adaptive timer test varies RTT and checks
the actual retry deadlines after loss and after fresh samples. Congestion tests count
segments on the wire through slow start, partial ACKs in congestion avoidance, timeout
replay, and fast retransmit. SACK tests check negotiation, legacy peers, sequence wrap,
and two repairs sent before either is acknowledged, including a gap shorter than one
MSS. A five-loss test checks that the fifth repair waits for space in the congestion
window. A one-record TIME-WAIT fixture checks blocked ACK delivery, full-table
fallback, IPv4 and IPv6 duplicate FINs, and expiry. The allocation regression
runs 9,000 typed connections under allocation stress,
with a warmup-only baseline and an allocating positive control.

## Simulated throughput

The benchmark transfers 128 KiB in one direction over a lossless in-memory link with a fixed simulated
RTT. It reports the elapsed simulated time after setup and handshake.

```sh
shen-jit build tests/bench/tcp-window.shenmod -o /tmp/shen-tcp-window
/tmp/shen-tcp-window
```
