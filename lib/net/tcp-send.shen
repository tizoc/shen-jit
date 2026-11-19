\\ TCP's sending: options and segments written, timers, congestion control, SACK repair and output.
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

(define receive-marked?
  {peer --> fixnum --> fixnum --> boolean}
  P Tail Offset -> (marked? (peer.rx-present P) (wrap-offset (fx+ Tail Offset) (peer.capacity P))))

(define sack-run-start
  {peer --> fixnum --> fixnum --> fixnum}
  P Tail I ->
    (if (and (fx> I 0) (receive-marked? P Tail (fx- I 1)))
        (sack-run-start P Tail (fx- I 1)) I))

(define sack-run-end
  {peer --> fixnum --> fixnum --> fixnum --> fixnum}
  P Tail I Limit ->
    (if (and (fx< I Limit) (receive-marked? P Tail I))
        (sack-run-end P Tail (fx+ I 1) Limit) I))

(define write-sack-block
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> buffer.view}
  P B At Left Right ->
    (let Next (peer.recv-next P)
      (write-layout wire.tcp-sack-block B At
        (left (seq-number (seq-add Next Left))) (right (seq-number (seq-add Next Right))))))

(define write-sack-runs
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  P B At Tail I Limit Skip Used Max ->
    (cases (or (fx>= I Limit) (= Used Max)) Used
           (not (receive-marked? P Tail I))
             (write-sack-runs P B At Tail (fx+ I 1) Limit Skip Used Max)
           true
             (let End (sack-run-end P Tail (fx+ I 1) Limit)
               (if (= I Skip) (write-sack-runs P B At Tail End Limit Skip Used Max)
                   (do (write-sack-block P B (fx+ At (fx* Used (wire.tcp-sack-block.size))) I End)
                       (write-sack-runs P B At Tail End Limit Skip (fx+ Used 1) Max))))))

(define write-sack
  {peer --> buffer.view --> fixnum --> fixnum}
  P B At ->
    (let Tail (receive-tail P)
         Limit (receive-limit P (window P))
         Max (smaller 4 (fxquotient (fx- (peer.path-mtu P) (fx+ (minimum-header P) (wire.tcp-sack-option.size)))
                                    (wire.tcp-sack-block.size)))
         Recent (seq-distance (seq-of (peer.rx-sack-recent P)) (peer.recv-next P))
         First (if (and (fx>= (peer.rx-sack-recent P) 0)
                        (fx< Recent Limit) (receive-marked? P Tail Recent))
                   (sack-run-start P Tail Recent) (fixnum -1))
         Blocks (fx+ At (wire.tcp-sack-option.size))
         Used (if (fx>= First 0)
                  (do (write-sack-block P B Blocks First (sack-run-end P Tail (fx+ First 1) Limit))
                      (fixnum 1))
                  (fixnum 0))
         N (write-sack-runs P B Blocks Tail 0 Limit First Used Max)
         Size (fx* N (wire.tcp-sack-block.size))
      (if (= N 0) 0
          (do (write-layout wire.tcp-sack-option B At (no-ops 257) (kind 5) (length (fx+ Size 2)))
              (fx+ Size (wire.tcp-sack-option.size))))))

(define wants-sack?
  {peer --> boolean}
  P -> (and (peer.sack-enabled P) (fx> (peer.rx-pending P) 0) (not (peer.recv-eof P))))

(define sack-capable?
  {peer --> boolean}
  P -> (fx>= (peer.path-mtu P) (fx+ (minimum-header P) 12)))

\\ A SYN's options, a word each: SACK permitted, the size, and the window scale. A path with room for
\\ SACK has room for all three.
(define write-syn-options
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum}
  P B At Flags ->
    (let Room (fx- (peer.path-mtu P) (minimum-header P))
         Sack (and (sack-capable? P) (or (= Flags (flag-bits control syn)) (peer.sack-enabled P)))
         Scale (and (sack-capable? P)
                    (if (= Flags (flag-bits control syn)) (fx> (peer.window-scale P) 0)
                        (fx>= (peer.remote-scale P) 0)))
         M (if Sack (fx+ At (wire.tcp-sack-permitted-option.size)) At)
         End (if Scale (fx+ M 8) (fx+ M 4))
      (if (fx< Room (wire.tcp-mss-option.size)) 0
          (do (if Sack (write-layout wire.tcp-sack-permitted-option B At (kind 4) (length 2) (no-ops 257)) B)
              (write-layout wire.tcp-mss-option B M (kind 2) (length 4) (segment-size (smaller (peer.capacity P) Room)))
              (if Scale
                  (write-layout wire.tcp-scale-option B (fx+ M (wire.tcp-mss-option.size))
                    (kind 3) (length 3) (shift (peer.window-scale P)))
                  B)
              (fx- End At)))))

(define write-options
  {peer --> buffer.view --> fixnum --> fixnum --> fixnum}
  P B I Flags ->
    (cases (flag? Flags (flag-bits control syn)) (write-syn-options P B (fx+ I (wire.tcp.size)) Flags)
           (and (= Flags (flag-bits control ack)) (wants-sack? P)) (write-sack P B (fx+ I (wire.tcp.size)))
           true 0))

(define advertised-window
  {peer --> fixnum --> fixnum}
  P Flags ->
    (let Space (window P)
         Shift (if (or (flag? Flags (flag-bits control syn)) (fx< (peer.remote-scale P) 0))
                   (fixnum 0) (peer.window-scale P))
      (smaller 65535 (shen-jit.shift-right Space Shift))))

(define write-segment
  {peer --> buffer.view --> fixnum --> fixnum --> seq --> fixnum --> fixnum --> fixnum --> buffer.view}
  P B T Flags Seq At Count Options ->
    (let Header (fx+ (wire.tcp.size) Options)
      (do (write-layout wire.tcp B T
            (source-port (peer.local-port P)) (destination-port (peer.remote-port P))
            (sequence (seq-number Seq))
            (acknowledgement (if (flag? Flags (flag-bits control ack)) (seq-number (peer.recv-next P)) 0))
            (data-offset (shen-jit.shift-right Header 2)) (flags Flags) (window (advertised-window P Flags)))
          (if (= Count 0) B
              (copy-from-ring B (fx+ T Header) (peer.tx P) At (peer.capacity P) Count)))))

(define emit-segment
  {peer --> net-link.ring --> fixnum --> fixnum --> seq --> fixnum --> fixnum --> boolean}
  P R Now Flags Seq At Count ->
    (let Delivery (net-link.delivery (peer.device P) Now)
         B (net-link.ring.data R)
         I (net-link.tail-offset R)
         IpBytes (peer.ip-header P)
         T (fx+ I IpBytes)
         Options (write-options P B T Flags)
         TcpBytes (fx+ (fx+ Count (wire.tcp.size)) Options)
         Size (fx+ TcpBytes IpBytes)
      (do (write-ip-header B I Size IpBytes (peer.local-address P) (peer.remote-address P))
          (write-segment P B T Flags Seq At Count Options)
          (wire.tcp.checksum-> B T (transport-checksum B I IpBytes TcpBytes))
          (net-link.publish R Size Delivery)
          (if (and (flag? Flags (flag-bits control ack)) (or (= Flags (flag-bits control ack)) (not (wants-sack? P))))
              (peer.ack-needed-> P false) P)
          true)))

(define emit-ack
  {peer --> net-link.ring --> fixnum --> boolean}
  P R Now ->
    (let Pending (peer.rx-duplicate-acks P)
      (do (if (and (not (peer.ack-needed P)) (fx> Pending 0))
              (peer.rx-duplicate-acks-> P (fx- Pending 1)) P)
          (emit-segment P R Now 16 (peer.send-next P) 0 0))))

(define stop-peer
  {peer --> phase --> boolean}
  P Phase -> (do (peer.phase-> P Phase)
                 (peer.tx-flags-> P 0)
                 (peer.tx-length-> P 0)
                 (peer.tx-flight-> P 0)
                 (peer.tx-replay-> P -1)
                 (peer.tx-due-> P -1)
                 (peer.rtt-sample-at-> P -1)
                 (clear-duplicate-acks P)
                 (clear-sack-recovery P)
                 (peer.recovery-bytes-> P 0)
                 (peer.ack-needed-> P false)
                 (peer.rx-duplicate-acks-> P 0)
                 true))

\\ RFC 6298 2.4 and 2.5: a retransmission timeout is at least a second and at most a minute.
(define min-rto
  {--> fixnum}
  -> 1000)

(define max-rto
  {--> fixnum}
  -> 60000)

(define backoff
  {peer --> fixnum --> boolean}
  P Now ->
    (let Rto (smaller (max-rto) (fx* 2 (peer.tx-rto P)))
      (do (peer.tx-rto-> P Rto)
          (peer.tx-due-> P (fx+ Now Rto))
          (peer.tx-retries-> P (fx+ (peer.tx-retries P) 1))
          true)))

(define start-rtt-sample
  {peer --> fixnum --> seq --> boolean}
  P Now End ->
    (if (and (fx< (peer.rtt-sample-at P) 0) (= (peer.rtt-blocked-bytes P) 0))
        (do (peer.rtt-sample-end-> P End)
            (peer.rtt-sample-at-> P Now)
            true)
        false))

(define send-control
  {peer --> net-link.ring --> fixnum --> boolean}
  P R Now ->
    (let Flags (peer.tx-flags P)
         First (fx< (peer.tx-due P) 0)
         Next (peer.send-next P)
      (do (emit-segment P R Now Flags (if First Next (seq-add Next -1)) 0 0)
          (if First
              (let End (seq-add Next 1)
                (do (peer.send-next-> P End)
                    (peer.tx-due-> P (fx+ Now (peer.tx-rto P)))
                    (if (flag? Flags (flag-bits control syn)) (start-rtt-sample P Now End) true)
                    true))
              (do (peer.rtt-sample-at-> P -1)
                  (backoff P Now))))))

\\ Queued bytes are split into an in-flight prefix and a never-sent suffix.
\\ Replay uses offsets within that prefix relative to tx-head.
(define emit-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset Count ->
    (let Seq (seq-add (peer.send-next P) (fx- Offset (peer.tx-flight P)))
         At (wrap-offset (fx+ (peer.tx-head P) Offset) (peer.capacity P))
      (emit-segment P R Now 24 Seq At Count)))

\\ A cumulative ACK across a retransmitted flight cannot give a clean sample.
(define retransmit-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset Count ->
    (do (peer.rtt-sample-at-> P -1)
        (peer.rtt-blocked-bytes-> P (peer.tx-flight P))
        (emit-data P R Now Offset Count)))

(define loss-threshold
  {peer --> fixnum --> fixnum}
  P Flight -> (larger (fx* (peer.send-mss P) 2) (fxquotient Flight 2)))

(define congestion-timeout
  {peer --> fixnum --> boolean}
  P Flight ->
    (do (if (= (peer.tx-retries P) 0) (peer.ssthresh-> P (loss-threshold P Flight)) P)
        (peer.cwnd-> P (peer.send-mss P))
        (peer.ca-acked-> P 0)
        (peer.recovery-bytes-> P 0)
        true))

(define congestion-fast-loss
  {peer --> fixnum --> boolean}
  P Flight ->
    (if (= (peer.recovery-bytes P) 0)
        (let Threshold (loss-threshold P Flight)
          (do (peer.ssthresh-> P Threshold)
              (peer.cwnd-> P (smaller (peer.cwnd P) Threshold))
              (peer.ca-acked-> P 0)
              (peer.recovery-bytes-> P Flight)
              true))
        true))

(define replay-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean --> boolean}
  P R Now Offset End Retry ->
    \\ The replay cursor tracks the retransmitted prefix still awaiting an ACK.
    (let Limit (smaller End (peer.cwnd P))
         N (smaller (peer.send-mss P) (fx- Limit Offset))
         Next (fx+ Offset N)
      (do (retransmit-data P R Now Offset N)
          (peer.tx-replay-> P (if (fx< Next (peer.tx-flight P)) Next -1))
          (if Retry
              (do (peer.tx-fast-retransmit-> P false)
                  (peer.tx-duplicate-acks-> P 3)
                  (backoff P Now))
              true))))

(define send-new-data
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flight N ->
    (let End (seq-add (peer.send-next P) N)
      (do (emit-data P R Now Flight N)
          (peer.tx-flight-> P (fx+ Flight N))
          (peer.send-next-> P End)
          (if (sack-recovering? P) (peer.sack-pipe-> P (fx+ (peer.sack-pipe P) N)) P)
          (if (fx> (peer.remote-window P) 0) (start-rtt-sample P Now End) false)
          (if (= Flight 0) (peer.tx-due-> P (fx+ Now (peer.tx-rto P))) P)
          true)))

(define send-ring-offset
  {peer --> fixnum --> fixnum}
  P I -> (wrap-offset (fx+ (peer.tx-head P) I) (peer.capacity P)))

(define sacked?
  {peer --> fixnum --> boolean}
  P I -> (marked? (peer.tx-sacked P) (send-ring-offset P I)))

(define repaired?
  {peer --> fixnum --> boolean}
  P I -> (marked? (peer.tx-repaired P) (send-ring-offset P I)))

\\ Walk back from the highest SACK. Evidence only increases to the left.
(define sack-loss-frontier
  {peer --> fixnum --> fixnum --> fixnum --> boolean --> fixnum}
  P I Bytes Runs InRun ->
    (cases (fx< I 0) 0
           (sacked? P I) (sack-loss-frontier P (fx- I 1) (fx+ Bytes 1)
                                             (if InRun Runs (fx+ Runs 1)) true)
           (or (fx>= Runs 3) (fx> Bytes (fx* (peer.send-mss P) 2))) (fx+ I 1)
           true (sack-loss-frontier P (fx- I 1) Bytes Runs false)))

\\ Count unsacked originals not inferred lost, plus unacknowledged repairs.
(define measure-sack-pipe
  {peer --> fixnum --> fixnum --> fixnum --> fixnum --> fixnum}
  P I Flight LostEnd Count ->
    (if (= I Flight) Count
        (let Next (if (sacked? P I) Count
                      (fx+ (if (fx>= I LostEnd) (fx+ Count 1) Count)
                           (if (repaired? P I) 1 0)))
          (measure-sack-pipe P (fx+ I 1) Flight LostEnd Next))))

(define find-sack-repair
  {peer --> fixnum --> fixnum --> fixnum}
  P I End ->
    (cases (fx>= I End) -1
           (or (sacked? P I) (repaired? P I)) (find-sack-repair P (fx+ I 1) End)
           true I))

(define refresh-sack-recovery
  {peer --> boolean}
  P ->
    (let LostEnd (sack-loss-frontier P (fx- (peer.tx-sack-high P) 1) 0 0 false)
      (do (peer.sack-loss-end-> P LostEnd)
          (peer.sack-next-repair-> P (find-sack-repair P 0 LostEnd))
          (peer.sack-pipe-> P (measure-sack-pipe P 0 (peer.tx-flight P) LostEnd 0))
          true)))

(define mark-repair
  {peer --> fixnum --> fixnum --> boolean}
  P Offset Count ->
    (write-sack-marks (peer.tx-repaired P) (send-ring-offset P Offset) (peer.capacity P) Count true))

(define sack-hole-end
  {peer --> fixnum --> fixnum --> fixnum}
  P I Limit ->
    (if (or (fx>= I Limit) (sacked? P I) (repaired? P I))
        I (sack-hole-end P (fx+ I 1) Limit)))

(define fast-retry-length
  {peer --> fixnum --> fixnum}
  P End ->
    (let Limit (smaller (peer.send-mss P) End)
      \\ Always retry the cumulative gap, even if the peer reneged on that byte.
      (if (fx> (peer.tx-sack-high P) 0) (sack-hole-end P 1 Limit) Limit)))

(define fast-retransmit
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Flight End ->
    (let Count (fast-retry-length P End)
      (do (congestion-fast-loss P Flight)
          (retransmit-data P R Now 0 Count)
          (peer.tx-fast-retransmit-> P false)
          (if (sack-recovering? P)
              (do (mark-repair P 0 Count) (refresh-sack-recovery P))
              true))))

(define send-sack-repair
  {peer --> net-link.ring --> fixnum --> fixnum --> fixnum --> fixnum --> boolean}
  P R Now Offset End Credit ->
    (let LostEnd (peer.sack-loss-end P)
         Limit (smaller (smaller End LostEnd)
                        (fx+ Offset (smaller Credit (peer.send-mss P))))
         Next (sack-hole-end P (fx+ Offset 1) Limit)
         Count (fx- Next Offset)
      (do (retransmit-data P R Now Offset Count)
          (mark-repair P Offset Count)
          (peer.sack-next-repair-> P (find-sack-repair P Next LostEnd))
          (peer.sack-pipe-> P (fx+ (peer.sack-pipe P) Count))
          true)))

(define flush-data
  {peer --> net-link.ring --> fixnum --> boolean --> boolean}
  P R Now Expired ->
    (let Flight (peer.tx-flight P)
         Replay (peer.tx-replay P)
         Window (peer.remote-window P)
         End (smaller Flight (if (= Window 0) 1 Window))
         Repair (peer.sack-next-repair P)
         Pipe (peer.sack-pipe P)
         Credit (fx- (peer.cwnd P) Pipe)
         FastEnd (if (sack-recovering? P) (smaller End Credit) End)
         Available (if (and (= Window 0) (= Flight 0)) (fixnum 1)
                       (fx- (smaller Window (peer.cwnd P)) (larger Flight Pipe)))
         N (smaller (fx- (peer.tx-length P) Flight) (smaller (peer.send-mss P) Available))
      (cases (and Expired (fx> End 0))
               (do (clear-sack P)
                   (clear-sack-recovery P)
                   (if (fx> Window 0) (congestion-timeout P Flight)
                       (do (peer.recovery-bytes-> P 0) true))
                   (replay-data P R Now 0 End true))
             (and (fx>= Replay 0) (fx< Replay (smaller End (peer.cwnd P))))
               (replay-data P R Now Replay End false)
             (and (peer.tx-fast-retransmit P) (fx> FastEnd 0) (fx> Window 0))
               (fast-retransmit P R Now Flight FastEnd)
             (and (fx>= Repair 0) (fx< Repair End) (fx> Window 0) (fx> Credit 0))
               (send-sack-repair P R Now Repair End Credit)
             (and (fx> (peer.rx-duplicate-acks P) 0) (not (peer.ack-needed P))) (emit-ack P R Now)
             (and (peer.ack-needed P) (wants-sack? P)) (emit-ack P R Now)
             (fx> N 0) (send-new-data P R Now Flight N)
             true false)))

(define flush
  {peer --> fixnum --> boolean}
  P Now ->
    (let R (net-link.device.tx (peer.device P))
         Due (peer.tx-due P)
         Expired (and (fx>= Due 0) (fx<= Due Now))
         Control (not (= (peer.tx-flags P) 0))
      (cases (and Expired (fx>= (peer.tx-retries P) 6)) (do (stop-peer P timed-out) false)
             (net-link.full? R) false
             (peer.aborting P) (do (emit-segment P R Now 20 (peer.send-next P) 0 0)
                                   (peer.aborting-> P false)
                                   (stop-peer P reset))
             (and Control (or (fx< Due 0) Expired)) (send-control P R Now)
             true (or (and (not Control) (flush-data P R Now Expired))
                      (and (or (peer.ack-needed P) (fx> (peer.rx-duplicate-acks P) 0))
                           (emit-ack P R Now))))))
)
