# In-memory IPv4 and UDP

The optional `net/udp` module, [lib/net/udp.shen](../lib/net/udp.shen), connects two typed Shen peers over
an in-memory packet link. A peer receives unfragmented unicast IPv4 with a 20-byte header on one bound UDP
port, and sends to a unicast or multicast IPv4 address; `udp.send6` sends over IPv6. The shared interface
receives IPv6 and multicast datagrams. It writes and checks IPv4 and UDP checksums and accepts a zero UDP checksum as permitted for IPv4.
The sender sets the IPv4 Don't Fragment flag and uses ID zero for these datagrams. The link and application
buffers work on static builds. [UDP checksum format](https://www.rfc-editor.org/rfc/rfc768.html) ·
[IPv4 identification field](https://www.rfc-editor.org/rfc/rfc6864.html#section-4.1)

To receive UDP alongside TCP and ICMP on one link, use [the shared interface](net-tun.md#shared-interface).

```sh
shen-jit eval -m tools/udp-echo.shenmod -e '(udp-echo.run "hello")'
```

This prints `hello`. The example uses a zero-delay link. Tests use a mutable fake clock to check when packets
become readable, without waiting for wall-clock time.

## Setup and ownership

| Operation | Meaning |
| --- | --- |
| `udp.make-link Slots Mtu Delay Clock` | Allocate `Slots` packets of up to `Mtu` bytes in each direction. `Clock` is a frozen computation returning a fixnum in milliseconds. |
| `udp.left L`, `udp.right L` | Create the two device handles for `L`. |
| `udp.ipv4 A B C D` | Pack four octets in network byte order into a fixnum. |
| `udp.bind Device IP Port` | Set the peer's local unicast IPv4 address and UDP port, from 1 through 65535. |
| `udp.make-recv-info` | Allocate reusable receive metadata. Its readers are `udp.recv-info.source`, `udp.recv-info.port` and `udp.recv-info.length`. |

Use one isolate to own and drive both device handles. The clock must return nonnegative, nondecreasing values
and must not call back into the link. The delay is a nonnegative fixnum. A send schedules delivery at the clock
reading plus the delay. Each receive or echo call samples once and can consume packets due at or before that
reading. An invalid clock reading raises. All packet operations return immediately.

Each direction has a preallocated byte arena and a ring of lengths and delivery times. `Slots` must be positive and
`Mtu` must be in 28 through 65535. The maximum UDP payload is `Mtu - 28` bytes. A successful send copies the
payload into the queue slot, so the caller can reuse its buffer. A receive copies bytes into the caller's buffer.
The typed send, receive and echo paths use the preallocated storage and immediate return values. A caller can
keep the entire loop allocation-free by reusing buffers and metadata and using a non-allocating clock.

## Datagram and packet operations

| Operation | Outcomes |
| --- | --- |
| `udp.send Peer IP Port Payload Count` | `udp.sent`, `udp.would-block` if the queue is full, or `udp.too-large` if the packet exceeds the MTU. |
| `udp.recv-into Peer Out Info Budget` | `udp.received`, `udp.empty` when no packet is ready, `udp.budget-exhausted`, or `udp.too-small` if the next valid datagram will not fit. |
| `udp.echo-step Peer Budget` | Number of incoming packets consumed, including invalid packets discarded. An eligible request stays at the head of the queue while the reply queue is full. |
| `udp.packet-send Device Packet Count` | Copy a whole packet into the link. Returns the same statuses as `udp.send`. |
| `udp.packet-recv-into Device Out` | Copy the next eligible whole packet and return its length. Returns `-1` if none is ready or `-2` if the output is too small. |

`Count` selects a prefix of the supplied buffer view. `Budget` bounds how many incoming packets a UDP receive or
echo call examines, including malformed packets and packets for other destinations. A receive delivers at most one
datagram. Output and metadata are written only on `udp.received`, and a packet that does not fit can be retried with
a larger output. Zero-length datagrams are valid. A zero budget consumes nothing. An echo reply takes the request's
source as its destination and copies its payload directly to the outgoing queue slot.

Use the API from typed code. `make test-net-udp` builds a typed executable and checks independent wire fixtures,
delivery and queue bounds, echo backpressure, and a warmed 10,000-cycle run under allocation stress. The allocation
check compares collection counts with an otherwise identical warmup-only run and checks a positive control that
allocates a fresh view each cycle.
