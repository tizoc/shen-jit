\\ Walk receive-side IPv6 headers, RFC 8200 4, without copying the packet or allocating a result.
(shen.x.namespace net-ipv6-headers
  (use buffer)
  (use shen-jit)
  (use grammar)
  (use net-wire => wire)
  (import struct defstruct)
  (externals [defgrammar <end> <e> skip at u16-be])
  (export cursor make parse after-fragment can-report?
          cursor.protocol cursor.at cursor.next-field cursor.problem
          cursor.multicast-error cursor.router-alert
          upper fragment problem incomplete ignored outcome
          parameter-problem erroneous-field unrecognized-next-header unrecognized-option incomplete-chain)

\\ Where a walk ends: at an upper-layer header, at a fragment header, at a problem to report, in a
\\ header cut short, or at a packet dropped without a report.
(datatype outcomes
  if (element? Outcome [upper fragment problem incomplete ignored])
  _________________________________________________________________
  Outcome : outcome;)

\\ RFC 4443 3.4: what a parameter problem points at: a field in error, a next header or an option not
\\ recognized, or a first fragment without the whole header chain.
(datatype parameter-problems
  if (element? Problem [erroneous-field unrecognized-next-header unrecognized-option incomplete-chain])
  __________________________________________________________________________________________________
  Problem : parameter-problem;)

\\ What a next header is to this receiver.
(datatype kinds
  if (element? Kind [upper hop-by-hop routing fragment destination none unknown])
  _______________________________________________________________________________
  Kind : kind;)

\\ Where a walk stopped: the upper-layer header or fragment header found, at At, and the next-header
\\ field that named it, or a problem's offset and code, and the value of a router alert in a hop-by-hop
\\ header, or -1. The packet's bounds, the headers it may still have and whether a fragment header may
\\ come are the walk's own.
(defstruct cursor
  (mutable protocol : fixnum)
  (mutable at : fixnum)
  (mutable next-field : fixnum)
  (mutable left : fixnum)
  (mutable problem : parameter-problem)
  (mutable multicast-error : boolean)
  (mutable router-alert : fixnum)
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
      problem <- erroneous-field
      multicast-error <- false
      router-alert <- -1
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
  {cursor --> fixnum --> fixnum --> fixnum --> outcome --> outcome}
  C Protocol At Next Result ->
    (do (cursor.protocol-> C Protocol)
        (cursor.at-> C At)
        (cursor.next-field-> C Next)
        Result))

(define fail-at
  {cursor --> fixnum --> parameter-problem --> boolean --> outcome}
  C At Problem Multicast ->
    (do (cursor.at-> C At)
        (cursor.problem-> C Problem)
        (cursor.multicast-error-> C Multicast)
        problem))

(define truncated
  {cursor --> fixnum --> outcome}
  C Pointer -> (do (fail-at C Pointer erroneous-field false) incomplete))

\\ What each next header is to this receiver. ESP's and AH's payloads are not read, so neither is
\\ anything after them.
(define header
  {fixnum --> kind}
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
\\ router alert, RFC 2711, which has 2 bytes in a hop-by-hop header, and whose value is kept.
\\ The common case consumes one option. The final rule handles the end and terminal options.
(defgrammar (<advance-option> C Hop) {cursor --> boolean ==> boolean}
  0 := true;
  5 2 (where Hop) (u16-be Value) := (do (cursor.router-alert-> C Value) true);
  Kind Length (where (and (= (action Kind) 0) (not (and Hop (= Kind 5))))) (skip Length) := true;)

(defgrammar (<terminal-body> C Hop At Kind Length)
  {cursor --> boolean --> fixnum --> fixnum --> fixnum ==> outcome}
  (where (and Hop (= Kind 5) (not (= Length 2)))) := (fail-at C (fx+ At 1) erroneous-field false);
  (skip Length) := (if (= (action Kind) 1) ignored (fail-at C At unrecognized-option (= (action Kind) 2)));
  <e> := (fail-at C (fx+ At 1) erroneous-field false);)

(defgrammar (<terminal-option> C Hop) {cursor --> boolean ==> outcome}
  <end> := upper;
  (at At) Kind Length (<terminal-body> C Hop At Kind Length) (* _) := <terminal-body>;
  (at At) _ := (fail-at C At erroneous-field false);)

(defgrammar (<options> C Hop) {cursor --> boolean ==> outcome}
  (* (<advance-option> C Hop)) (<terminal-option> C Hop) := <terminal-option>;)

(grammar.finish)

\\ Most packets have no extension headers, and need no walk.
(define parse
  {cursor --> buffer.view --> fixnum --> fixnum --> outcome}
  C B I N ->
    (if (fx< N (wire.ipv6.size)) ignored
        (let Protocol (wire.ipv6.next-header B I)
             At (fx+ I (wire.ipv6.size))
             Next (wire.ipv6.next-header-at I)
             _ (cursor.router-alert-> C -1)
          (if (= (header Protocol) upper) (found C Protocol At Next upper)
              (walk (start C I N 8 true) B At Next Protocol)))))

\\ The chain after a fragment header that parse found, in a datagram that is not in pieces.
(define after-fragment
  {cursor --> buffer.view --> fixnum --> fixnum --> outcome}
  C B I N ->
    (let At (cursor.at C)
      (walk (start C I N (cursor.left C) false) B (fx+ At (wire.ipv6-fragment.size)) At
            (wire.ipv6-fragment.next-header B At))))

\\ The header at At, which the next-header field at Next names.
(define walk
  {cursor --> buffer.view --> fixnum --> fixnum --> fixnum --> outcome}
  C B At Next Protocol -> (follow (header Protocol) C B At Next Protocol))

\\ RFC 8200 4.1: a chain holds up to 8 headers in 296 bytes, with the hop-by-hop header first if at all.
\\ Past those bounds, or after a header not read here, the packet is dropped without a report.
(define follow
  {kind --> cursor --> buffer.view --> fixnum --> fixnum --> fixnum --> outcome}
  upper C _ At Next Protocol -> (found C Protocol At Next upper)
  none _ _ _ _ _ -> ignored
  unknown C _ _ Next _ -> (fail-at C Next unrecognized-next-header false)
  _ C _ At _ _ -> ignored where (or (= (cursor.left C) 0) (fx> (fx- At (cursor.base C)) 296))
  hop-by-hop C _ At Next _ -> (fail-at C Next unrecognized-next-header false)
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
  {kind --> cursor --> buffer.view --> fixnum --> fixnum --> outcome}
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
  {kind --> cursor --> buffer.view --> fixnum --> fixnum --> outcome}
  routing C B At _ -> (if (= (wire.ipv6-routing.segments-left B At) 0) upper
                          (fail-at C (wire.ipv6-routing.routing-type-at At) erroneous-field false))
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
  {kind --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
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
