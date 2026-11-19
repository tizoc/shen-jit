\\ Untyped code over fields.shen's struct: its reads, and those of a typed definition inlined into it,
\\ keep their checks.
(define spot-x-untyped P -> (spot.x P))

(define spot-sum-untyped P -> (spot-sum P))

(declare spot-x-declared [spot --> fixnum])
(define spot-x-declared P -> (spot.x P))
