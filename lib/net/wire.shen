\\ The packet formats, drawn as their RFCs draw them: one 32-bit row to a line, most significant
\\ bit first. Each layout defines typed accessors that inline where they are called, so
\\ (wire.ipv4.protocol B I) is the read of byte I+9 that one would write by hand. See lib/layout.shen.
(shen.x.namespace net-wire
  (use buffer)
  (import layout deflayout)

\\ RFC 791.
(deflayout ipv4
  (version 4) (header-length 4) (service 8) (total-length 16)
  (identification 16) (reserved 1) (dont-fragment 1) (more-fragments 1) (fragment-offset 13)
  (time-to-live 8) (protocol 8) (checksum 16)
  (source 32)
  (destination 32))

\\ RFC 8200.
(deflayout ipv6
  (version 4) (traffic-class 8) (flow-label 20)
  (payload-length 16) (next-header 8) (hop-limit 8)
  (source 128)
  (destination 128))

\\ An IPv6 address as four 32-bit words, as net-ipv6 keeps it.
(deflayout ipv6-address
  (a 32)
  (b 32)
  (c 32)
  (d 32))

\\ RFC 768.
(deflayout udp
  (source-port 16) (destination-port 16)
  (length 16) (checksum 16))

\\ RFC 9293. The flags are CWR, ECE, URG, ACK, PSH, RST, SYN and FIN, most significant first.
(deflayout tcp
  (source-port 16) (destination-port 16)
  (sequence 32)
  (acknowledgement 32)
  (data-offset 4) (reserved 4) (flags 8) (window 16)
  (checksum 16) (urgent 16))

\\ RFC 792 and RFC 4443: the common part, and an echo's or a neighbor message's next word.
(deflayout icmp
  (type 8) (code 8) (checksum 16)
  (rest 32))

\\ IEEE 802.3.
(deflayout ethernet
  (destination 48)
  (source 48)
  (ethertype 16))

\\ RFC 826, for IPv4 over Ethernet.
(deflayout arp
  (hardware-type 16) (protocol-type 16)
  (hardware-length 8) (protocol-length 8) (operation 16)
  (sender-hardware 48) (sender-protocol 32)
  (target-hardware 48) (target-protocol 32))
)
