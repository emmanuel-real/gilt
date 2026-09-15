;; stackingdao-rate-source -- canonical stSTX rate, with a sanity band.
;;
;; CORRECTED 2026-09-02. An earlier version of this adapter derived the rate by
;; hand from stx-reserve-v2 and the stSTXbtc token supplies. That was wrong: it
;; produced u1168482 against the canonical u1184418, a 1.4% error, because the
;; real accounting also nets off stx-for-withdrawals and live escrow, and uses
;; the reserve's get-stx-for-ststxbtc rather than the token supply. A 1.4%
;; error is small enough to pass a sanity band and large enough to misprice
;; every series, which is precisely why derivation is the wrong approach.
;;
;; So: call StackingDAO's own published function. It is authoritative by
;; definition, it is what their UI and integrators use, and it is maintained by
;; the team that owns the accounting.
;;
;;   SP4SZE...DVMDPBG.data-stx-v2 . get-stx-per-ststx  ->  uint (6dp)
;;
;; Note the bare uint: these functions are read-only returning uint128, not a
;; response. A Clarity trait cannot express that (`define-trait` rejects it),
;; which is why this adapter exists at all -- it republishes the value behind a
;; trait Gilt can dispatch on, and is the single contract to redeploy when
;; StackingDAO next versions its data contract (data-core-v2 -> data-stx-v2
;; already happened once; reserve-v1 is still callable and still answers with a
;; wound-down, garbage value).
;;
;; The band is the guard that matters here. stSTX is value-accruing, so a rate
;; below 1.0 or implausibly high means the source has been migrated, drained,
;; or replaced. Fail closed rather than settle a series against it.

(impl-trait .rate-source-trait.rate-source-trait)

;; stSTX has only ever accrued. Below par is impossible; 3.0 is far above any
;; plausible accrual over this protocol's lifetime.
(define-constant MIN_RATE u1000000)
(define-constant MAX_RATE u3000000)

(define-constant ERR_RATE_BELOW_BAND (err u200))
(define-constant ERR_RATE_ABOVE_BAND (err u201))

(define-public (get-stx-per-ststx)
  (let (
    (rate (contract-call? 'SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.data-stx-v2 get-stx-per-ststx))
  )
    (asserts! (>= rate MIN_RATE) ERR_RATE_BELOW_BAND)
    (asserts! (<= rate MAX_RATE) ERR_RATE_ABOVE_BAND)
    (ok rate)
  )
)
