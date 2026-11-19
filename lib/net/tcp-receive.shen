\\ TCP's receiving: segments read and checked, acknowledgements, data, and the dispatch by state.
(shen.x.namespace tcp
  (use buffer)
  (use net-link)
  (use net-ipv4)
  (use net-ipv6)
  (use shen-jit)
  (use net-wire => wire)
  (use grammar)
  (import struct defstruct)
  (import layout write-layout defflags flag-bits)
  (import net-seq seq seq-of seq-number seq-add seq-distance seq-after?)
  (externals [defgrammar u16-be <end> <e> skip at])
  (shadow listen release)

(define header-length
  {buffer.view --> fixnum --> fixnum}
  B I -> (fx* 4 (wire.tcp.data-offset B I)))

\\ TCP's options, RFC 9293 3.1: a kind, then, but for the end of the list and a no-op, a length that
\\ counts both bytes. What they offer is stored in the segment as they are matched. A known kind with
\\ the wrong length, a size of 0, or a length past the end does not match; SACK blocks of a length that
\\ is not whole blocks are passed over. Each alternative tests its kind and length before the rest of
\\ the list, so that none parses it again after another.
(defgrammar (<options> Seg) {segment ==> boolean}
  <end> := true;
  0 (* _) := true;                                                       \\ The end; padding follows.
  1 (<options> Seg) := <options>;                                        \\ No-op.
  2 4 (u16-be Size) (where (fx> Size 0)) (<options> (offer-mss Seg Size)) := <options>;
  3 3 Shift (<options> (segment.scale-> Seg (smaller 14 Shift))) := <options>;     \\ RFC 7323.
  4 2 (<options> (segment.sack-permitted-> Seg true)) := <options>;      \\ RFC 2018.
  5 Length (where (sack-length? Length)) (at At) (skip (fx- Length 2))
    (<options> (sack-blocks Seg At (fx+ At (fx- Length 2)))) := <options>;
  Kind Length (where (and (fx> Kind 4) (fx>= Length 2))) (skip (fx- Length 2)) (<options> Seg)
    := <options>;)

(define offer-mss
  {segment --> fixnum --> segment}
  Seg Size -> (let Mss (segment.mss Seg) (segment.mss-> Seg (if (fx< Mss 0) Size (smaller Mss Size)))))

\\ One to four blocks, of two edges each.
(define sack-length?
  {fixnum --> boolean}
  Length -> (and (fx>= Length 10) (fx<= Length 34) (= (fxremainder (fx- Length 2) 8) 0)))

(define sack-blocks
  {segment --> fixnum --> fixnum --> segment}
  Seg At End -> (do (segment.sack-at-> Seg At) (segment.sack-end-> Seg End)))

\\ Compile the rules' loops now, while the module loads, so that a saved program carries them.
(grammar.finish)

(define header-fits?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B T Count ->
    (and (fx>= Count (wire.tcp.size)) (fx>= (header-length B T) (wire.tcp.size)) (fx<= (header-length B T) Count)))

(define valid-tcp?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B T Count ->
    (and (header-fits? B T Count)
         (= (wire.tcp.reserved B T) 0)
         (not (flag? (wire.tcp.flags B T) (flag-bits control urg)))))                     \\ URG is refused.

(define valid-segment?
  {buffer.view --> fixnum --> fixnum --> boolean}
  B I N ->
    (let T (fx+ I (wire.ipv4.size))
         Count (fx- N (wire.ipv4.size))
      (and (net-ipv4.valid? B I N 6) (valid-tcp? B T Count)
           (= (net-ipv4.transport-checksum B I (wire.tcp-protocol) Count) 0))))

(define addressed-to?
  {buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  B I IP Port -> (and (= (wire.ipv4.destination B I) IP)
                       (= (wire.tcp.destination-port B (fx+ I (wire.ipv4.size))) Port)))

\\ ECN is declined by leaving the negotiation bits clear in replies.
(define segment-flags
  {buffer.view --> fixnum --> fixnum}
  B I -> (shen-jit.bit-and (wire.tcp.flags B I) (flag-bits control ack psh rst syn fin)))

\\ RFC 9293 3.6: TIME-WAIT lasts twice the longest a segment lives, two minutes here.
(define wait-expiry
  {fixnum --> fixnum}
  Now -> (fx+ Now 120000))

(define enter-time-wait
  {peer --> fixnum --> boolean}
  P Now -> (do (peer.wait-until-> P (wait-expiry Now))
               (peer.phase-> P time-wait)
               true))

(define acknowledge?
  {peer --> seq --> boolean}
  P Ack -> (and (not (= (peer.tx-flags P) 0))
                (fx>= (peer.tx-due P) 0)
                (= Ack (peer.send-next P))))

\\ SRTT and RTTVAR are fixed point in eighths of a millisecond. The
\\ variance uses the old smoothed RTT. Quantize the timer upward to milliseconds.
(define record-rtt
  {peer --> fixnum --> boolean}
  P Ms ->
    (let Sample (fx* (larger 1 (smaller (max-rto) Ms)) 8)
         Previous (peer.srtt P)
         Delta (fx- Previous Sample)
         Error (larger Delta (fx- 0 Delta))
         Variation (if (= Previous 0) (fxquotient Sample 2)
                       (fxquotient (fx+ (fx* (peer.rttvar P) 3) Error) 4))
         Smoothed (if (= Previous 0) Sample (fxquotient (fx+ (fx* Previous 7) Sample) 8))
         Rto (fxquotient (fx+ (fx+ Smoothed (larger 8 (fx* Variation 4))) 7) 8)
      (do (peer.srtt-> P Smoothed)
          (peer.rttvar-> P Variation)
          (peer.tx-rto-> P (larger (min-rto) (smaller (max-rto) Rto)))
          true)))

(define take-rtt-sample
  {peer --> fixnum --> boolean}
  P Now ->
    (let At (peer.rtt-sample-at P)
      (if (fx>= At 0)
          (do (peer.rtt-sample-at-> P -1)
              (record-rtt P (fx- Now At)))
          false)))

(define restart-timer
  {peer --> fixnum --> fixnum --> boolean}
  P Flight Now ->
    (do (peer.tx-due-> P (if (= Flight 0) -1 (fx+ Now (peer.tx-rto P))))
        (peer.tx-retries-> P 0)
        true))

(define finish-syn
  {peer --> fixnum --> boolean}
  P Now ->
    (let Retried (fx> (peer.tx-retries P) 0)
      (do (peer.cwnd-> P (fx* (peer.send-mss P) (if Retried 1 4)))
          (if Retried (do (peer.tx-rto-> P 3000) true) (take-rtt-sample P Now))
          (restart-timer P 0 Now))))

(define remember-window
  {peer --> seq --> seq --> fixnum --> boolean}
  P Seq Ack Window ->
    (do (peer.remote-window-> P Window)
        (peer.remote-window-seq-> P Seq)
        (peer.remote-window-ack-> P Ack)
        true))

(define update-window
  {peer --> seq --> seq --> fixnum --> boolean}
  P Seq Ack Window ->
    (let LastSeq (peer.remote-window-seq P)
         LastAck (peer.remote-window-ack P)
      (if (or (seq-after? Seq LastSeq)
              (and (= Seq LastSeq) (or (= Ack LastAck) (seq-after? Ack LastAck))))
          (remember-window P Seq Ack Window)
          false)))

(define acknowledge-control
  {peer --> seq --> seq --> fixnum --> fixnum --> boolean}
  P Seq Ack Window Now ->
    (if (acknowledge? P Ack)
        (let Phase (state P)
          (do (remember-window P Seq Ack Window)
              (peer.tx-flags-> P 0)
              (if (= Phase syn-received) (finish-syn P Now) (restart-timer P 0 Now))
              (cases (= Phase syn-received) (do (peer.phase-> P established) true)
                     (= Phase fin-wait-1) (do (peer.phase-> P fin-wait-2) true)
                     (= Phase closing) (enter-time-wait P Now)
                     (= Phase last-ack) (stop-peer P closed)
                     true true)))
        false))

(define congestion-ack
  {peer --> fixnum --> boolean}
  P N ->
    (let Cwnd (peer.cwnd P)
         Threshold (peer.ssthresh P)
         Capacity (peer.capacity P)
         Mss (peer.send-mss P)
         Recovery (peer.recovery-bytes P)
      (cases (fx> Recovery 0)
               (do (if (fx>= N Recovery) (clear-sack-recovery P) true)
                   (peer.recovery-bytes-> P (larger 0 (fx- Recovery N)))
                   true)
             (= Cwnd Capacity) true
             (fx< Cwnd Threshold)
               (do (peer.cwnd-> P (smaller Threshold (fx+ Cwnd (smaller N Mss)))) true)
             true
               (let Credit (fx+ (peer.ca-acked P) N)
                 (if (fx>= Credit Cwnd)
                     (do (peer.cwnd-> P (smaller Capacity (fx+ Cwnd Mss)))
                         (peer.ca-acked-> P (fx- Credit Cwnd))
                         true)
                     (do (peer.ca-acked-> P Credit) true))))))

(define retire-sack
  {peer --> fixnum --> boolean}
  P N ->
    (let High (peer.tx-sack-high P)
      (cases (= High 0) true
             (fx>= N High) (clear-sack P)
             true (do (write-sack-marks (peer.tx-sacked P) (peer.tx-head P) (peer.capacity P) N false)
                      (peer.tx-sack-high-> P (fx- High N))
                      true))))

(define advance-ack
  {peer --> seq --> fixnum --> fixnum --> fixnum --> boolean}
  P Ack N Flight Now ->
    (let Left (fx- Flight N)
         Replay (peer.tx-replay P)
         At (fx- Replay N)
         SampleEnd (peer.rtt-sample-end P)
         Blocked (peer.rtt-blocked-bytes P)
      (do (if (or (= Ack SampleEnd) (seq-after? Ack SampleEnd)) (take-rtt-sample P Now) false)
          (if (fx> Blocked 0) (peer.rtt-blocked-bytes-> P (larger 0 (fx- Blocked N))) P)
          (retire-sack P N)
          (if (and (sack-recovering? P) (fx< N (peer.recovery-bytes P)))
              (write-sack-marks (peer.tx-repaired P) (peer.tx-head P) (peer.capacity P) N false)
              true)
          (peer.tx-head-> P (wrap-offset (fx+ (peer.tx-head P) N) (peer.capacity P)))
          (peer.tx-length-> P (fx- (peer.tx-length P) N))
          (peer.tx-flight-> P Left)
          (peer.tx-replay-> P (cases (or (= Left 0) (fx< Replay 0)) -1 (fx< At 0) 0 true At))
          (congestion-ack P N)
          (clear-duplicate-acks P)
          (restart-timer P Left Now))))

(define count-duplicate-ack
  {peer --> boolean}
  P ->
    (let Count (peer.tx-duplicate-acks P)
      (if (fx< Count 3)
          (let Next (fx+ Count 1)
            (do (peer.tx-duplicate-acks-> P Next)
                (peer.tx-fast-retransmit-> P (= Next 3))
                true))
          false)))

(define send-una
  {peer --> seq}
  P -> (seq-add (peer.send-next P) (fx- 0 (peer.tx-flight P))))

(define queue-sack-head-repair
  {peer --> boolean}
  P -> (do (peer.tx-duplicate-acks-> P 3)
           (peer.tx-fast-retransmit-> P (not (repaired? P 0)))
           true))

(define acknowledge-data
  {peer --> seq --> seq --> fixnum --> fixnum --> boolean --> boolean}
  P Seq Ack Window Now PureAck ->
    (let Flight (peer.tx-flight P)
         Una (send-una P)
         N (seq-distance Ack Una)
         OldWindow (peer.remote-window P)
      (if (fx<= N Flight)
          (do (update-window P Seq Ack Window)
              (cases (fx> N 0) (advance-ack P Ack N Flight Now)
                     (and (fx> Flight 0) (= OldWindow 0) (fx> (peer.remote-window P) 0))
                       (if (sack-recovering? P) (queue-sack-head-repair P)
                           (do (peer.tx-replay-> P 0) true))
                     (and PureAck (fx> Flight 0) (fx> Window 0) (= Window OldWindow)
                          (fx< (peer.tx-replay P) 0)) (count-duplicate-ack P)
                     (fx< (peer.tx-duplicate-acks P) 3) (clear-duplicate-acks P)
                     (= (peer.remote-window P) 0) (do (peer.tx-fast-retransmit-> P false) true)
                     true true))
          false)))

(define acknowledge
  {peer --> seq --> seq --> fixnum --> fixnum --> boolean --> boolean}
  P Seq Ack Window Now PureAck ->
    (if (= (peer.tx-flags P) 0)
        (acknowledge-data P Seq Ack Window Now PureAck)
        (acknowledge-control P Seq Ack Window Now)))

(define read-sack-blocks
  {peer --> buffer.view --> fixnum --> fixnum --> seq --> boolean}
  _ _ I I _ -> true
  P B I End Una ->
    (let Left (seq-distance (seq-of (wire.tcp-sack-block.left B I)) Una)
         Right (seq-distance (seq-of (wire.tcp-sack-block.right B I)) Una)
         Capacity (peer.capacity P)
      (do (if (and (fx> Left 0) (fx< Left Right) (fx<= Right (peer.tx-flight P)))
              (do (write-sack-marks (peer.tx-sacked P) (wrap-offset (fx+ (peer.tx-head P) Left) Capacity)
                                    Capacity (fx- Right Left) true)
                  (peer.tx-sack-high-> P (larger (peer.tx-sack-high P) Right))
                  true)
              false)
          (read-sack-blocks P B (fx+ I (wire.tcp-sack-block.size)) End Una))))

(define accept-sack
  {peer --> segment --> seq --> seq --> boolean}
  P Seg Ack Previous ->
    (if (and (peer.sack-enabled P) (= Ack (send-una P)) (fx> (peer.tx-flight P) 0))
        (let At (segment.sack-at Seg)
             _ (if (fx>= At 0) (read-sack-blocks P (segment.data Seg) At (segment.sack-end Seg) Ack) false)
          (if (sack-recovering? P)
              (do (if (or (repaired? P 0) (and (seq-after? Ack Previous) (fx> (peer.tx-sack-high P) 0)))
                      (queue-sack-head-repair P) true)
                  (refresh-sack-recovery P))
              false))
        false))

\\ Store the first byte received at each position and count only newly marked bytes.
(define store-missing
  {buffer.view --> buffer.view --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ _ _ _ 0 Added -> Added
  Rx Map B Start At Capacity N Added ->
    (let I (shen-jit.shift-right At 3)
         Bits (buffer.u8 Map I)
         Mask (presence-mask At)
         Next (wrap-offset (fx+ At 1) Capacity)
         Fresh (= (shen-jit.bit-and Bits Mask) 0)
      (do (if Fresh
              (do (buffer.u8-> Rx At (buffer.u8 B Start))
                  (buffer.u8-> Map I (shen-jit.bit-or Bits Mask)))
              Rx)
          (store-missing Rx Map B (fx+ Start 1) Next Capacity (fx- N 1)
                         (if Fresh (fx+ Added 1) Added)))))

\\ Contiguous bytes are already at the end of the readable data in the same ring.
(define promote-contiguous
  {buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Count -> Count
  Map At Capacity Limit Count ->
    (let I (shen-jit.shift-right At 3)
         Bits (buffer.u8 Map I)
         Mask (presence-mask At)
      (if (= (shen-jit.bit-and Bits Mask) 0) Count
          (do (buffer.u8-> Map I (shen-jit.bit-xor Bits Mask))
              (promote-contiguous Map (wrap-offset (fx+ At 1) Capacity) Capacity
                                  (fx- Limit 1) (fx+ Count 1))))))

(define advance-receive
  {peer --> fixnum --> boolean}
  P N -> (do (peer.rx-length-> P (fx+ (peer.rx-length P) N))
             (peer.recv-next-> P (seq-add (peer.recv-next P) N))
             (peer.rx-duplicate-acks-> P 0)
             true))

(define receive-bytes
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P B Start Offset N Limit ->
    (let Rx (peer.rx P)
         Capacity (peer.capacity P)
         Tail (receive-tail P)
         Pending (peer.rx-pending P)
      (if (and (= Offset 0) (= Pending 0))
          (do (copy-into-ring Rx Tail Capacity B Start N)
              (advance-receive P N))
          (let Map (peer.rx-present P)
               At (wrap-offset (fx+ Tail Offset) Capacity)
               Added (store-missing Rx Map B Start At Capacity N 0)
            (if (= Offset 0)
                (let Ready (promote-contiguous Map Tail Capacity Limit 0)
                  (do (peer.rx-pending-> P (fx- (fx+ Pending Added) Ready))
                      (advance-receive P Ready)))
                (do (peer.rx-pending-> P (fx+ Pending Added)) true))))))

(define receive-fin
  {peer --> fixnum --> boolean}
  P Now ->
    (let Phase (state P)
      (do (peer.recv-eof-> P true)
          (peer.rx-fin-> P -1)
          (peer.recv-next-> P (seq-add (peer.recv-next P) 1))
          (peer.ack-needed-> P true)
          (peer.rx-duplicate-acks-> P 0)
          (cases (= Phase established) (do (peer.phase-> P close-wait) true)
                 (= Phase fin-wait-1) (do (peer.phase-> P closing) true)
                 (= Phase fin-wait-2) (enter-time-wait P Now)
                 true true))))

(define receive-text
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean --> fixnum --> fixnum --> boolean}
  P B Start Offset N Fin Window Now ->
    (let End (fx+ Offset N)
         Next (peer.recv-next P)
         _ (if (and Fin (fx< End Window) (fx< (peer.rx-fin P) 0))
               (peer.rx-fin-> P (seq-number (seq-add Next End))) P)
         Final (peer.rx-fin P)
         Limit (receive-limit P Window)
         Count (smaller N (fx- Limit Offset))
      \\ Keep up to three gap ACKs across polls even when several segments arrive together.
      (do (if (= Offset 0) (peer.ack-needed-> P true)
              (peer.rx-duplicate-acks-> P (smaller 3 (fx+ (peer.rx-duplicate-acks P) 1))))
          (if (fx> Count 0)
              (do (receive-bytes P B Start Offset Count Limit)
                  (if (and (fx> Offset 0) (peer.sack-enabled P))
                      (peer.rx-sack-recent-> P (seq-number (seq-add Next Offset))) P)
                  true)
              true)
          (if (= Final (seq-number (peer.recv-next P))) (receive-fin P Now) true))))

\\ A segment's length in sequence space: a FIN takes one.
(define span
  {segment --> fixnum}
  Seg -> (if (flag? (segment.flags Seg) (flag-bits control fin)) (fx+ (segment.length Seg) 1) (segment.length Seg)))

\\ A segment repeated, or out of the window, is acknowledged again; time-wait restarts on a FIN repeated.
\\ A FIN sent again: one whose sequence space ends where the next byte is expected.
(define repeated-fin?
  {segment --> seq --> boolean}
  Seg Next -> (and (flag? (segment.flags Seg) (flag-bits control fin))
                   (= (seq-add (segment.sequence Seg) (fx+ (segment.length Seg) 1)) Next)))

(define answer-duplicate
  {peer --> segment --> fixnum --> boolean}
  P Seg Now ->
    (let Flags (segment.flags Seg)
      (if (or (fx> (segment.length Seg) 0) (flag? Flags (flag-bits control syn fin)))
          (do (peer.ack-needed-> P true)
              (if (and (= (state P) time-wait) (repeated-fin? Seg (peer.recv-next P)))
                  (enter-time-wait P Now)
                  true))
          false)))

\\ RFC 9293's test: the segment starts where we expect, overlaps what we expect, or starts in the window.
(define acceptable?
  {peer --> segment --> boolean}
  P Seg -> (let Next (peer.recv-next P)
                Seq (segment.sequence Seg)
                Ahead (seq-distance Seq Next)
             (or (= Ahead 0) (fx< (seq-distance Next Seq) (span Seg)) (fx< Ahead (window P)))))

\\ A reset ends the connection at the sequence expected, and is acknowledged elsewhere in the window.
(define reset-received
  {peer --> segment --> boolean}
  P Seg -> (cases (= (segment.sequence Seg) (peer.recv-next P)) (stop-peer P reset)
                  (acceptable? P Seg) (do (peer.ack-needed-> P true) true)
                  true false))

\\ A segment past the handshake, RFC 9293 3.10.7.4, by the state and the flags, in order.
(define connected
  {phase --> fixnum --> peer --> segment --> fixnum --> boolean}
  time-wait Flags _ _ _ -> false where (flag? Flags (flag-bits control rst))   \\ RFC 1337.
  time-wait _ P Seg Now -> (answer-duplicate P Seg Now)
  _ Flags P Seg _ -> (reset-received P Seg) where (flag? Flags (flag-bits control rst))
  _ Flags P Seg Now -> (answer-duplicate P Seg Now) where (flag? Flags (flag-bits control syn))
  _ Flags P Seg _ -> false
    where (or (not (flag? Flags (flag-bits control ack))) (seq-after? (segment.acknowledgement Seg) (peer.send-next P)))
  _ _ P Seg Now -> (answer-duplicate P Seg Now) where (not (acceptable? P Seg))
  _ _ P Seg Now -> (take-segment P Seg Now))

\\ An acceptable segment: its acknowledgement and SACK blocks, then its data, from where we expect it.
(define take-segment
  {peer --> segment --> fixnum --> boolean}
  P Seg Now ->
    (let Previous (send-una P)
         Window (window P)
         Next (peer.recv-next P)
         Seq (segment.sequence Seg)
         Ack (segment.acknowledgement Seg)
         B (segment.data Seg)
         Start (segment.start Seg)
         N (segment.length Seg)
         Ahead (seq-distance Seq Next)
         Skip (seq-distance Next Seq)
         Fin (flag? (segment.flags Seg) (flag-bits control fin))
         Win (shen-jit.shift-left (segment.window Seg) (larger 0 (peer.remote-scale P)))
      (do (acknowledge P Seq Ack Win Now (and (= (segment.flags Seg) (flag-bits control ack)) (= N 0)))
          (if (peer.sack-enabled P) (accept-sack P Seg Ack Previous) false)
          (if (and (fx> (span Seg) 0) (not (peer.recv-eof P)))
              (if (fx< Skip (span Seg))
                  (receive-text P B (fx+ Start Skip) 0 (fx- N Skip) Fin Window Now)
                  (receive-text P B Start Ahead N Fin Window Now))
              (answer-duplicate P Seg Now)))))

\\ The handshake, RFC 9293 3.5: by the state the peer is in and the segment it receives.
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
  syn-sent (flag-bits control syn ack) P Seg Now ->
    (do (accept-syn P Seg false)
        (peer.tx-flags-> P 0)
        (finish-syn P Now)
        (peer.phase-> P established)
        (peer.ack-needed-> P true)
        true)
    where (and (= (segment.length Seg) 0) (acknowledge? P (segment.acknowledgement Seg)))
  _ _ _ _ _ -> false)

\\ A listener that sent its SYN-ACK: a reset at the sequence expected ends it, the ACK of its SYN
\\ completes it, and the SYN again is answered again.
(define half-open
  {fixnum --> peer --> segment --> fixnum --> boolean}
  Flags P Seg _ -> (stop-peer P reset)
    where (and (flag? Flags (flag-bits control rst)) (= (segment.sequence Seg) (peer.recv-next P)))
  Flags P Seg Now -> (connected syn-received Flags P Seg Now)
    where (and (= (segment.sequence Seg) (peer.recv-next P)) (flag? Flags (flag-bits control ack))
               (acknowledge? P (segment.acknowledgement Seg)))
  (flag-bits control syn) P Seg Now -> (do (peer.tx-due-> P Now) true)
    where (and (= (seq-add (segment.sequence Seg) 1) (peer.recv-next P)) (fx>= (peer.tx-due P) 0))
  _ _ _ _ -> false)

\\ What either end takes from the other's SYN: its sequence, window and size, with the default size if it
\\ offers none, and window scaling and SACK if both ends can. A listener takes a window scale whenever it
\\ can, an opener only if it offered one.
(define accept-syn
  {peer --> segment --> boolean --> peer}
  P Seg Listening ->
    (let Seq (segment.sequence Seg)
         Offered (segment.mss Seg)
         Limit (smaller (peer.mss P) (fx- (peer.path-mtu P) (minimum-header P)))
         Mss (smaller Limit (if (fx>= Offered 0) Offered (default-mss (peer.ip-header P))))
         Sacked (and (sack-capable? P) (segment.sack-permitted Seg))
      (do (peer.recv-next-> P (seq-add Seq 1))
          (remember-window P Seq (segment.acknowledgement Seg) (segment.window Seg))
          (peer.send-mss-> P Mss)
          (peer.remote-scale-> P (if (and (sack-capable? P) (or Listening (fx> (peer.window-scale P) 0)))
                                     (segment.scale Seg) (type -1 fixnum)))
          (peer.sack-enabled-> P Sacked))))

(define terminal?
  {peer --> boolean}
  P -> (let Phase (state P) (or (= Phase closed) (= Phase timed-out) (= Phase reset))))

\\ Reads the segment of Count bytes at I of B into Seg, and whether its options are well formed.
(define read-segment
  {grammar.state --> segment --> buffer.view --> fixnum --> fixnum --> boolean}
  State Seg B I Count ->
    (let H (header-length B I)
         Start (fx+ I H)
      (do (segment.data-> Seg B)
          (segment.start-> Seg Start)
          (segment.length-> Seg (fx- Count H))
          (segment.flags-> Seg (segment-flags B I))
          (segment.sequence-> Seg (seq-of (wire.tcp.sequence B I)))
          (segment.acknowledgement-> Seg (seq-of (wire.tcp.acknowledgement B I)))
          (segment.window-> Seg (wire.tcp.window B I))
          (segment.mss-> Seg -1)
          (segment.scale-> Seg -1)
          (segment.sack-permitted-> Seg false)
          (segment.sack-at-> Seg -1)
          (<options>.parse-at Seg State B (fx+ I (wire.tcp.size)) Start (/. At Message false)))))

(define receive-valid
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P B I Count Now ->
    (and (not (terminal? P))
         (read-segment (peer.options-state P) (peer.segment P) B I Count)
         (let Seg (peer.segment P)
              Phase (state P)
              Flags (segment.flags Seg)
           (cases (or (= Phase listen-state) (= Phase syn-sent)) (opening Phase Flags P Seg Now)
                  (= Phase syn-received) (half-open Flags P Seg Now)
                  true (connected Phase Flags P Seg Now)))))

(define receive-segment
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> boolean}
  P B I N Now ->
    (and (not (terminal? P))
         (fx>= N (headers4))
         (addressed-to? B I (net-ipv6.address.d (peer.local-address P)) (peer.local-port P))
         (= (wire.ipv4.source B I) (net-ipv6.address.d (peer.remote-address P)))
         (= (wire.tcp.source-port B (fx+ I (wire.ipv4.size))) (peer.remote-port P))
         (valid-segment? B I N)
         (receive-valid P B (fx+ I (wire.ipv4.size)) (fx- N (wire.ipv4.size)) Now)))

(define receive-ready
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum}
  _ _ _ 0 Done -> Done
  P R Now Budget Done ->
    (if (net-link.ready? R Now)
        (do (receive-segment P (net-link.ring.data R) (net-link.head-offset R) (net-link.head-length R) Now)
            (net-link.consume R)
            (receive-ready P R Now (fx- Budget 1) (fx+ Done 1)))
        Done))

(define drive-output
  {peer --> fixnum --> boolean}
  P Now ->
    (if (terminal? P) false
        (let Sent (flush P Now)
          (do (if (and (= (state P) time-wait) (not (peer.ack-needed P)) (fx>= Now (peer.wait-until P)))
                  (stop-peer P closed)
                  true)
              Sent))))

(define poll
  {peer --> fixnum --> fixnum}
  P Budget ->
    (let Limit (buffer.index Budget)
         D (peer.device P)
         Now (net-link.now D)
         Count (receive-ready P (net-link.device.rx D) Now Limit 0)
      (do (drive-output P Now) Count)))
)
