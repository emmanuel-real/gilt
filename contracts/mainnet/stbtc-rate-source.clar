;; stbtc-rate-source -- canonical stBTC rate (Bitcoin Staking yield), 8dp.
;;
;; For the roadmap stBTC series, not the launch series. stBTC supply reached
;; 152.5 BTC by 5 Sep 2026, but the rate stayed flat from 5 to 14 Sep while
;; Bitcoin Staking capacity is whitelisted to institutions, so there is no yield
;; to fix a rate against yet. The adapter is here so the series can open once
;; stBTC accrues.
;;
;;   SP4SZE...DVMDPBG.data-stbtc-v1 . get-sbtc-per-stbtc  ->  uint (8dp)
;;
;; Read 2026-09-01: u100117328. That value dates from the launch period, when
;; supply was close to zero, and is noise rather than yield; from 5 to 14 Sep
;; the rate was flat at about u100117340. stbtc-token is a plain 8-decimal SIP-010 with mint-for-protocol; it
;; does not rebase, so all Bitcoin Staking yield surfaces through this rate.
;; A series using this source must be initialized with denom = u100000000.

(impl-trait .rate-source-trait.rate-source-trait)

(define-constant MIN_RATE u100000000)
(define-constant MAX_RATE u300000000)

(define-constant ERR_RATE_BELOW_BAND (err u200))
(define-constant ERR_RATE_ABOVE_BAND (err u201))

(define-public (get-stx-per-ststx)
  (let (
    (rate (contract-call? 'SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.data-stbtc-v1 get-sbtc-per-stbtc))
  )
    (asserts! (>= rate MIN_RATE) ERR_RATE_BELOW_BAND)
    (asserts! (<= rate MAX_RATE) ERR_RATE_ABOVE_BAND)
    (ok rate)
  )
)
