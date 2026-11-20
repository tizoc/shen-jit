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

\\ RFC 8200 4.3 to 4.6: an extension header's first 8 bytes, with its length in 8-byte units after
\\ them; a hop-by-hop or destination options header's options start after the length. A routing
\\ header's first word, and a fragment header, whose offset counts 8-byte units.
(deflayout ipv6-extension
  (next-header 8) (length 8) (options 16)
  (_ 32))

(deflayout ipv6-routing
  (next-header 8) (length 8) (routing-type 8) (segments-left 8))

(deflayout ipv6-fragment
  (next-header 8) (_ 8) (offset 13) (_ 2) (more 1)
  (identification 32))

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

\\ TCP's options as this stack writes them, each a word: RFC 9293's maximum segment size, RFC 7323's
\\ window scale, followed by the end of the list, and RFC 2018's SACK permitted and SACK blocks, which
\\ two no-ops (1 and 1, together 257) pad.
(deflayout tcp-mss-option
  (kind 8) (length 8) (segment-size 16))

(deflayout tcp-scale-option
  (kind 8) (length 8) (shift 8) (_ 8))

(deflayout tcp-sack-permitted-option
  (kind 8) (length 8) (no-ops 16))

(deflayout tcp-sack-option
  (no-ops 16) (kind 8) (length 8))

(deflayout tcp-sack-block
  (left 32)
  (right 32))

\\ RFC 792 and RFC 4443: the common part, and an echo's or a neighbor message's next word.
(deflayout icmp
  (type 8) (code 8) (checksum 16)
  (rest 32))

\\ RFC 2236 and RFC 3376: IGMP's messages, a version 3 query, whose sources follow it, and a
\\ version 3 report's group records, whose sources follow each.
(deflayout igmp
  (type 8) (max-response 8) (checksum 16)
  (group 32))

(deflayout igmp3-query
  (type 8) (max-response 8) (checksum 16)
  (group 32)
  (_ 4) (suppress 1) (robustness 3) (interval 8) (sources 16))

(deflayout igmp3-record
  (record-type 8) (aux-length 8) (sources 16)
  (group 32))

\\ RFC 2710 and RFC 3810: MLD's messages, as IGMP's.
(deflayout mld
  (type 8) (code 8) (checksum 16)
  (max-response 16) (_ 16)
  (group 128))

(deflayout mld2-query
  (type 8) (code 8) (checksum 16)
  (max-response 16) (_ 16)
  (group 128)
  (_ 4) (suppress 1) (robustness 3) (interval 8) (sources 16))

(deflayout mld2-record
  (record-type 8) (aux-length 8) (sources 16)
  (group 128))

\\ IGMPv3's and MLDv2's reports start alike, and their records follow.
(deflayout membership-report
  (type 8) (_ 8) (checksum 16)
  (_ 16) (records 16))

\\ An IPv4 address in a list of them, as a query's or a record's sources are.
(deflayout ipv4-address
  (address 32))

\\ RFC 2113 and RFC 2711: a router alert, as an IPv4 option, and as the one option of a hop-by-hop
\\ header, which PadN fills to 8 bytes.
(deflayout ipv4-router-alert
  (type 8) (length 8) (value 16))

(deflayout ipv6-router-alert
  (next-header 8) (length 8) (type 8) (option-length 8)
  (value 16) (pad 8) (pad-length 8))

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

\\ RFC 2132 9.6 and 9.8: a request's message type, and the list of what it asks for: the mask, the
\\ router, DNS servers, the lease, and the renewal and rebinding times.
(deflayout dhcp-request-options
  (type-code 8) (type-length 8) (message-type 8)
  (list-code 8) (list-length 8) (mask 8) (router 8) (dns 8) (lease 8) (renewal 8) (rebinding 8))

\\ RFC 2132 9.1 and 9.7: an address option, the address a client asks for or the server's identifier.
(deflayout dhcp-address-option
  (code 8) (length 8) (address 32))

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

\\ RFC 1035 4.1.4: a pointer to a name earlier in the message, its top two bits set.
(deflayout dns-pointer
  (marker 2) (offset 14))

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

\\ What the fields hold. IANA's protocol numbers, which IPv4's protocol field and IPv6's next header
\\ give, and the ether types of IEEE 802.3.
(define icmp-protocol {--> fixnum} -> 1)
(define igmp-protocol {--> fixnum} -> 2)
(define tcp-protocol {--> fixnum} -> 6)
(define udp-protocol {--> fixnum} -> 17)
(define icmp6-protocol {--> fixnum} -> 58)
(define no-next-header {--> fixnum} -> 59)                              \\ RFC 8200 4.7.

(define ipv4-type {--> fixnum} -> 2048)
(define arp-type {--> fixnum} -> 2054)
(define ipv6-type {--> fixnum} -> 34525)
)
