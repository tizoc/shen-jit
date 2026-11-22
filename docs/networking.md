# Networking

The `net` modules, in [lib/net/](../lib/net/), are a networking stack in typed Shen. An interface on one link,
in memory or a Linux TUN or TAP device, serves TCP, UDP and ICMP over IPv4 and IPv6, with neighbor discovery,
fragment reassembly and multicast, and DHCP and DNS clients. Each module allocates its packet rings, tables and
buffers when it is set up, and once it runs it allocates nothing on the Shen heap.

| Module | What it is | Page |
| --- | --- | --- |
| `net/link` | A link: two sides, each with bounded rings of packets in and out, and a clock the caller gives | [In-memory IPv4 and UDP](net-udp.md) |
| `net/udp` | UDP endpoints and inboxes over IPv4 and IPv6 | [In-memory IPv4 and UDP](net-udp.md) |
| `net/tcp` | TCP connections, and tables of them shared by listeners and outbound connections | [In-memory TCP](net-tcp.md) |
| `net/interface` | One link's IPv4 and IPv6, ICMP, TCP and UDP, driven by one poll | [Linux TUN and TAP](net-tun.md#shared-interface) |
| `net/tun` | A Linux TUN or TAP device on one side of a link | [Linux TUN and TAP](net-tun.md) |
| `net/ethernet` | Ethernet frames, ARP and IPv4 routes, between a TAP device and an interface | [Linux TUN and TAP](net-tun.md#ethernet-and-tap) |
| `net/dhcp`, `net/dns`, `net/stream` | An address lease, A lookups, and application streams over TCP | [Linux TUN and TAP](net-tun.md#dhcp-dns-and-outbound-streams) |

Supporting protocol layers loaded automatically by those modules live beside them: `net/wire`, `net/seq`,
`net/marks`, `net/ipv4`, `net/ipv6`, `net/ipv6-headers`, `net/fragments`, `net/fragments6`, `net/ndp`,
`net/multicast` and `net/routes`.

## Driving it

Every call does a bounded amount of work, and only the device's wait blocks. A program over TUN repeats:

- `net-tun.pump Device Budget`, which moves at most `Budget` packets each way between the device and the link;
- `net-interface.poll Interface Budget`, which takes in at most `Budget` packets and then does what is due;
- `net-tun.wait Device Millis`, which waits until the device can be read or written, or `Millis` milliseconds pass.

`net-interface.next-deadline` says how long to wait: an absolute time in milliseconds of the link's clock, or
`-1` when only the device can make progress. `net-tun.wait` takes milliseconds from now, up to 2,147,483,647,
so a program waits for the deadline less the time, and for a bound of its own when there is none. Over TAP,
`net-ethernet.pump` runs between the device and the interface, and the wait is bounded too by
`net-ethernet.next-deadline`, and by `net-dhcp.client.deadline` and `net-dns.resolver.deadline` while a
lease or a lookup runs. [tests/net_host.shen](../tests/net_host.shen) drives TUN and TAP so.

## What it does not do

- **TCP** has no timestamps, no keepalive and no delayed acknowledgments, and declines ECN. A segment with
  URG set is dropped, so a peer that sends urgent data stalls.
- **IPv4** drops a packet with options, but IGMP's, and fragments nothing it sends.
- **IPv6** takes one prefix and one router from advertisements, and processes no routing header with segments
  left.
- **DNS** asks for A records over UDP, with no fallback to TCP, and gives up after four tries, 1, 2, 4 and 8
  seconds apart.
- **DHCP** sends no RELEASE or DECLINE, and a client whose lease expired stays expired: a new one asks again.

## How it is written

The code says what its RFCs say, with notations that expand, as they are read, into the code one would
write by hand.

**Packet formats** are declared in [lib/net/wire.shen](../lib/net/wire.shen) as [layouts](layout.md), one
32-bit row to a line, as the RFCs draw them:

```shen
\\ RFC 791.
(deflayout ipv4
  (version 4) (header-length 4) (service 8) (total-length 16)
  (identification 16) (reserved 1) (dont-fragment 1) (more-fragments 1) (fragment-offset 13)
  (time-to-live 8) (protocol 8) (checksum 16)
  (source 32)
  (destination 32))
```

Code reads `(wire.ipv4.protocol B I)` and writes a header whole with `write-layout`, whose constants fold into
the stores. The stack's headers, and most of its options, are declared there. TCP's control bits are named with `defflags`, and `(flag-bits control syn ack)` is a constant, which a
pattern can match.

**Options** are typed [grammars](grammar.md), parsed in place with `.parse-at` and a parse state each table
keeps. Each alternative stores what its option offers in a record as it matches, so a segment's options are
read once. TCP's match one option a round, so that the list is a loop:

```shen
(defgrammar (<advance-option> Seg) {segment ==> boolean}
  1 := true;
  Kind (where (fx>= Kind 2)) Length (<option-body> Seg Kind Length) := <option-body>;)

(defgrammar (<options> Seg) {segment ==> boolean}
  <end> := true;
  0 (* _) := true;
  (* (<advance-option> Seg)) <options-end> := true;)
```

IPv6's hop-by-hop and destination options, DHCP's options and neighbor discovery's are grammars too.

**Dispatch** is rules. A TCP segment is read once into a record, and answered by rules on the connection's
state and the segment's flags, as RFC 9293 lists the cases:

```shen
(define opening
  {phase --> fixnum --> peer --> segment --> fixnum --> boolean}
  syn-sent Flags P Seg _ -> (stop-peer P reset)
    where (and (flag? Flags (flag-bits control rst)) (flag? Flags (flag-bits control ack))
               (acknowledge? P (segment.acknowledgement Seg)))
  listen-state (flag-bits control syn) P Seg _ ->
    (do (accept-syn P Seg true)
        (peer.phase-> P syn-received)
        (queue-control P (flag-bits control syn ack)))
    where (= (segment.length Seg) 0)
  ...
  _ _ _ _ _ -> false)
```

A table of protocol numbers is a function with literal patterns, as IPv6's next headers are, and rules on its
answer walk the extension headers as RFC 8200 4.1 orders them.

**Types** check what the protocols mean. TCP's sequence numbers are a type of their own, `seq`, which wraps at
32 bits: the type checker refuses `fx<` on two of them, and `(shen-jit.represent seq fixnum)` keeps them in
registers as fixnums. A family of symbols, such as TCP's states, is a datatype that admits only its members, so
a misspelt state is a type error.

**Bounds** are set at setup. TCP's table of connections has a fixed number of slots, and a map of those in
use, a bit each, which its scans pass over a run at a time. Which of a window's bytes were received out of
order, selectively acknowledged or repaired are such maps too, in [lib/net/marks.shen](../lib/net/marks.shen).

## Writing code like it

- **Read fields through a layout, and write a layout whole.** A layout's readers are the reads one would write,
  and a typed caller takes them in. A word written field by field is a read, a mask and a store for each field
  narrower than a byte; `write-layout` stores it once.
- **Parse a range with a kept state.** `<rule>.parse-at` and `<rule>.end-at` parse part of a view with a state
  the caller made once, and allocate nothing but the values the rules build.
- **Commit early in a grammar.** A guard at the end of an alternative runs after the rest of it has matched,
  and when it fails, the next alternative parses that again. Test what decides an alternative with a
  `(where Guard)` item where it is known, or make the rest a `require`.
- **Match one item a round.** A repetition of a rule that matches one item is a loop. So is a rule that ends
  in a match of itself, giving that match's value, with no guard, and has after that alternative only ones
  that match the end or nothing.
- **Bind fixnums as fixnums.** A literal bound by `let` is a `number`; `(fixnum 1)` is a fixnum at no cost.
- **Name what numbers stand for.** A definition of no arguments that gives a constant, a set of flags, or a
  function from numbers to symbols costs nothing in typed code, and a symbol's datatype catches a misspelling.
- **Look at what runs.** `(shen-jit.code F)` shows what F's definition compiles to by itself. A program built
  with `shen-jit build` is sealed; to see the same code from `eval`, set `SHEN_JIT_SEAL=1`.
