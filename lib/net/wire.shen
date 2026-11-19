\\ The packet formats, drawn as their RFCs draw them: one 32-bit row to a line, most significant
\\ bit first. Each layout defines typed accessors that inline where they are called, so
\\ (wire.ipv4.protocol B I) is the read of byte I+9 that one would write by hand. See lib/layout.shen.
(shen.x.namespace net-wire
  (use buffer)
  (use grammar)
  (import layout deflayout)
  (externals [defgrammar <e>])

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

\\ RFC 1191: "fragmentation needed", with the next hop's MTU.
(deflayout icmp-too-big
  (type 8) (code 8) (checksum 16)
  (_ 16) (next-hop-mtu 16))

\\ RFC 4443: "packet too big".
(deflayout icmp6-too-big
  (type 8) (code 8) (checksum 16)
  (mtu 32))

\\ RFC 4861, neighbor discovery: the messages after ICMPv6's first word, then their options.
(deflayout ndp-router-solicitation
  (type 8) (code 8) (checksum 16)
  (_ 32))

(deflayout ndp-router-advertisement
  (type 8) (code 8) (checksum 16)
  (current-hop-limit 8) (managed 1) (other 1) (_ 6) (router-lifetime 16)
  (reachable-time 32)
  (retransmit-timer 32))

(deflayout ndp-neighbor-solicitation
  (type 8) (code 8) (checksum 16)
  (_ 32)
  (target 128))

(deflayout ndp-neighbor-advertisement
  (type 8) (code 8) (checksum 16)
  (router 1) (solicited 1) (override 1) (_ 29)
  (target 128))

\\ Every option starts so; its length counts 8-byte units.
(deflayout ndp-option
  (type 8) (length 8))

\\ Source (1) or target (2) link-layer address, over Ethernet.
(deflayout ndp-link-address
  (type 8) (length 8) (address 48))

(deflayout ndp-prefix
  (type 8) (length 8) (prefix-length 8) (on-link 1) (autonomous 1) (_ 6)
  (valid-lifetime 32)
  (preferred-lifetime 32)
  (_ 32)
  (prefix 128))

\\ RFC 2131: BOOTP's fixed part, with DHCP's options after the magic cookie. The client's hardware
\\ address field is 16 bytes, of which Ethernet uses the first 6.
(deflayout dhcp
  (op 8) (hardware-type 8) (hardware-length 8) (hops 8)
  (transaction-id 32)
  (seconds 16) (broadcast 1) (_ 15)
  (client-address 32)
  (your-address 32)
  (server-address 32)
  (relay-address 32)
  (client-hardware 48) (_ 80)
  (server-name 512)
  (boot-file 1024)
  (magic-cookie 32))

\\ RFC 1035: a message's header; then each question's name and these, and each record's name and these.
(deflayout dns
  (id 16) (response 1) (opcode 4) (authoritative 1) (truncated 1) (recursion-desired 1)
      (recursion-available 1) (_ 3) (rcode 4)
  (questions 16) (answers 16)
  (authorities 16) (additionals 16))

(deflayout dns-question
  (type 16) (class 16))

(deflayout dns-record
  (type 16) (class 16)
  (ttl 32)
  (length 16))

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

\\ N bytes of anything: the rest of an option, or a label, whose length came before it.
(defgrammar (<bytes> N) {fixnum ==> fixnum}
  (where (= N 0)) := 0;
  (where (fx> N 0)) _ (<bytes> (fx- N 1)) := 0;)

(grammar.finish)
)
