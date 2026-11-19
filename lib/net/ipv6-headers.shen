\\ Walk receive-side IPv6 headers, RFC 8200 4, without copying the packet or allocating a result.
(shen.x.namespace net-ipv6-headers
  (use buffer)
  (use shen-jit)
  (use grammar)
  (use net-wire => wire)
  (import struct defstruct)
  (externals [defgrammar <end> skip at])
  (export cursor make parse after-fragment can-report?
          cursor.protocol cursor.at cursor.next-field cursor.problem-code
          cursor.multicast-error
          upper fragment problem incomplete ignored)

\\ Where a walk stopped: the upper-layer header or fragment header found, at At, and the next-header
\\ field that named it, or a problem's offset and code. The packet's bounds, the headers it may still
\\ have and whether a fragment header may come are the walk's own.
(defstruct cursor
  (mutable protocol : fixnum)
  (mutable at : fixnum)
  (mutable next-field : fixnum)
  (mutable left : fixnum)
  (mutable problem-code : fixnum)
  (mutable multicast-error : boolean)
  (mutable base : fixnum)
  (mutable end : fixnum)
  (mutable fragments : boolean)
  (options-state : grammar.state))

(define make
  {--> cursor}
  ->
    (:cursor
      protocol <- 59
      at <- 0
      next-field <- 0
      left <- 0
      problem-code <- 0
      multicast-error <- false
      base <- 0
      end <- 0
      fragments <- false
      options-state <- (grammar.state)))

(define start
  {cursor --> fixnum --> fixnum --> fixnum --> boolean --> cursor}
  C I N Left Fragments ->
    (do (cursor.base-> C I)
        (cursor.end-> C (fx+ I N))
        (cursor.left-> C Left)
        (cursor.fragments-> C Fragments)))

(define found
  {cursor --> fixnum --> fixnum --> fixnum --> symbol --> symbol}
  C Protocol At Next Result ->
    (do (cursor.protocol-> C Protocol)
        (cursor.at-> C At)
        (cursor.next-field-> C Next)
        Result))

(define fail-at
  {cursor --> fixnum --> fixnum --> boolean --> symbol}
  C At Code Multicast ->
    (do (cursor.at-> C At)
        (cursor.problem-code-> C Code)
        (cursor.multicast-error-> C Multicast)
        problem))

(define truncated
  {cursor --> fixnum --> symbol}
  C Pointer -> (do (fail-at C Pointer 0 false) incomplete))

\\ What each next header is to this receiver. ESP's and AH's payloads are not read, so neither is
\\ anything after them.
(define header
  {fixnum --> symbol}
  6 -> upper                                                             \\ TCP,
  17 -> upper                                                            \\ UDP,
  58 -> upper                                                            \\ ICMPv6.
  0 -> hop-by-hop
  43 -> routing
  44 -> fragment
  60 -> destination
  50 -> none                                                             \\ ESP,
  51 -> none                                                             \\ AH,
  59 -> none                                                             \\ no next header.
  _ -> unknown)

\\ An option's type says, in its two high bits, what to do with one not recognized: skip it (0), drop
\\ the packet (1), or drop it and report the option (2), unless the packet went to a multicast group (3).
(define action
  {fixnum --> fixnum}
  Type -> (shen-jit.shift-right Type 6))

\\ RFC 8200 4.2: options, each a type and a length but Pad1. All are skipped as unrecognized but the
\\ router alert, RFC 2711, which has 2 bytes in a hop-by-hop header. Each alternative takes the rest
\\ of the options too, so that a problem's alternative ends the parse.
(defgrammar (<options> C Hop) {cursor --> boolean ==> symbol}
  <end> := upper;
  0 (<options> C Hop) := <options>;                                      \\ Pad1.
  (at At) 5 Length (where (and Hop (not (= Length 2)))) (* _) := (fail-at C (fx+ At 1) 0 false);
  Type Length (where (= (action Type) 0)) (skip Length) (<options> C Hop) := <options>;
  Type Length (where (= (action Type) 1)) (skip Length) (* _) := ignored;
  (at At) Type Length (skip Length) (* _) := (fail-at C At 2 (= (action Type) 2));
  (at At) _ _ (* _) := (fail-at C (fx+ At 1) 0 false);                   \\ Past the header's end.
  (at At) _ := (fail-at C At 0 false);)                                  \\ A type and no length.

(grammar.finish)

\\ Most packets have no extension headers, and need no walk.
(define parse
  {cursor --> buffer.view --> fixnum --> fixnum --> symbol}
  C B I N ->
    (if (fx< N (wire.ipv6.size)) ignored
        (let Protocol (wire.ipv6.next-header B I)
             At (fx+ I (wire.ipv6.size))
             Next (wire.ipv6.next-header-at I)
          (if (= (header Protocol) upper) (found C Protocol At Next upper)
              (walk (start C I N 8 true) B At Next Protocol)))))

\\ The chain after a fragment header that parse found, in a datagram that is not in pieces.
(define after-fragment
  {cursor --> buffer.view --> fixnum --> fixnum --> symbol}
  C B I N ->
    (let At (cursor.at C)
      (walk (start C I N (cursor.left C) false) B (fx+ At (wire.ipv6-fragment.size)) At
            (wire.ipv6-fragment.next-header B At))))

\\ The header at At, which the next-header field at Next names.
(define walk
  {cursor --> buffer.view --> fixnum --> fixnum --> fixnum --> symbol}
  C B At Next Protocol -> (follow (header Protocol) C B At Next Protocol))

\\ RFC 8200 4.1: a chain holds up to 8 headers in 296 bytes, with the hop-by-hop header first if at all.
\\ Past those bounds, or after a header not read here, the packet is dropped without a report.
(define follow
  {symbol --> cursor --> buffer.view --> fixnum --> fixnum --> fixnum --> symbol}
  upper C _ At Next Protocol -> (found C Protocol At Next upper)
  none _ _ _ _ _ -> ignored
  unknown C _ _ Next _ -> (fail-at C Next 1 false)
  _ C _ At _ _ -> ignored where (or (= (cursor.left C) 0) (fx> (fx- At (cursor.base C)) 296))
  hop-by-hop C _ At Next _ -> (fail-at C Next 1 false)
    where (not (= At (fx+ (cursor.base C) (wire.ipv6.size))))
  _ C _ At Next _ -> (truncated C Next) where (fx> (fx+ At (wire.ipv6-extension.size)) (cursor.end C))
  fragment C _ At Next Protocol -> (do (cursor.left-> C (fx- (cursor.left C) 1))
                                       (found C Protocol At Next fragment))
    where (and (cursor.fragments C) (fx<= (fx- At (cursor.base C)) 288))
  fragment _ _ _ _ _ -> ignored
  Kind C B At _ _ -> (extension Kind C B At (extension-end B At)))

(define extension-end
  {buffer.view --> fixnum --> fixnum}
  B At -> (fx+ At (fx* 8 (fx+ (wire.ipv6-extension.length B At) 1))))

\\ A hop-by-hop, routing or destination options header, from At to Stop, then the rest of the chain.
(define extension
  {symbol --> cursor --> buffer.view --> fixnum --> fixnum --> symbol}
  Kind C B At Stop ->
    (cases (fx> Stop (cursor.end C)) (truncated C (wire.ipv6-extension.length-at At))
           (fx> (fx- Stop (cursor.base C)) 296) ignored
           true (let Result (contents Kind C B At Stop)
                  (if (= Result upper)
                      (do (cursor.left-> C (fx- (cursor.left C) 1))
                          (walk C B Stop At (wire.ipv6-extension.next-header B At)))
                      Result))))

\\ RFC 8200 4.4: no routing type is known here, so a routing header with segments left is a problem,
\\ at its type.
(define contents
  {symbol --> cursor --> buffer.view --> fixnum --> fixnum --> symbol}
  routing C B At _ -> (if (= (wire.ipv6-routing.segments-left B At) 0) upper
                          (fail-at C (wire.ipv6-routing.routing-type-at At) 0 false))
  Kind C B At Stop -> (<options>.parse-at C (= Kind hop-by-hop) (cursor.options-state C) B
                                          (wire.ipv6-extension.options-at At) Stop (/. Position Message ignored)))

\\ RFC 4443 2.4: no error is sent about an ICMPv6 error or redirect, nor about a fragment but the
\\ first. This walks the chain again, past what the first walk may have stopped at: an option or a
\\ routing header it refused.
(define can-report?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N -> (and (fx>= N (wire.ipv6.size))
                (reportable B I (fx+ I N) (fx+ I (wire.ipv6.size)) (wire.ipv6.next-header B I) 8)))

(define reportable
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  B Base End At Protocol Left -> (report? (header Protocol) B Base End At Protocol Left))

(define report?
  {symbol --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  upper B _ End At 58 _ -> (and (fx< At End) (fx>= (wire.icmp.type B At) 128)        \\ Informational,
                                (not (= (wire.icmp.type B At) 137)))                  \\ not a redirect.
  upper _ _ _ _ _ _ -> true
  none _ _ _ _ _ _ -> false
  unknown _ _ _ _ _ _ -> true
  _ _ Base End At _ Left -> false
    where (or (= Left 0) (fx> (fx+ At (wire.ipv6-extension.size)) End) (fx> (fx- At Base) 288))
  fragment B Base End At _ Left ->
    (and (= (wire.ipv6-fragment.offset B At) 0)
         (reportable B Base End (fx+ At (wire.ipv6-fragment.size)) (wire.ipv6-fragment.next-header B At)
                     (fx- Left 1)))
  _ B Base End At _ Left ->
    (let Stop (extension-end B At)
      (and (fx<= Stop End) (fx<= (fx- Stop Base) 296)
           (reportable B Base End Stop (wire.ipv6-extension.next-header B At) (fx- Left 1)))))

(preclude [cursor.%match])
)
