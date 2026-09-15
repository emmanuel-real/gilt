;; gilt-series -- fixed-term yield splitting for stSTX
;;
;; Deposit stSTX, receive two SIP-010 tokens:
;;   PT (principal): redeems at maturity for stSTX worth a fixed amount of
;;       STX -- the principal value at deposit time.
;;   YT (yield): redeems at maturity for the stacking yield the deposit
;;       earned over the term.
;;
;; Accounting (rates are 6-decimal fixed point, u1000000 = 1.0):
;;   R0 = stSTX->STX rate captured at series init (start rate)
;;   Rm = rate captured at settlement, clamped to >= R0
;;   split(a):      PT out = a * R0 / 1e6        YT out = a
;;   merge(a):      burn ceil(a * R0 / 1e6) PT + a YT -> a stSTX back
;;   redeem-pt(p):  p * 1e6 / Rm stSTX   (worth exactly p STX)
;;   redeem-yt(y):  y * (Rm - R0) / Rm stSTX  (the accrued yield)
;;
;; Splits are only accepted while the live rate still equals R0. The stSTX
;; rate is stepwise (it moves when StackingDAO processes cycle rewards), so
;; each series has a natural mint window: deposits are open until the first
;; rate step after init, then close automatically. This makes every YT in a
;; series carry identical yield entitlement -- the late-deposit dilution
;; exploit that continuous-mint designs must solve with per-holder interest
;; indexes cannot occur here.
;;
;; Solvency is structural: custody = sum of net deposits; PT payouts total
;; sum * R0/Rm and YT payouts total sum * (Rm-R0)/Rm, which sum to custody.
;; All divisions floor, so rounding dust accrues to the contract, never
;; against it. No price oracle exists anywhere: the rate derives from
;; StackingDAO reserve totals and token supply, not a spot market, so it
;; cannot be moved with a flash loan.

(use-trait rate-source-trait .rate-source-trait.rate-source-trait)
(use-trait ft-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

(define-constant CONTRACT_OWNER tx-sender)

;; Underlying decimal base: u1000000 for 6-dp assets (stSTX),
;; u100000000 for 8-dp assets (stBTC). Set once at init.
(define-data-var denom uint u1000000)
(define-constant BPS u10000)
(define-constant MAX_FEE_BPS u1000)      ;; 10% hard cap on either fee
(define-constant MIN_SPLIT u100000)      ;; 0.1 stSTX dust floor

(define-constant ERR_NOT_OWNER (err u100))
(define-constant ERR_ALREADY_INITIALIZED (err u101))
(define-constant ERR_NOT_INITIALIZED (err u102))
(define-constant ERR_PAUSED (err u103))
(define-constant ERR_BAD_RATE_SOURCE (err u104))
(define-constant ERR_BAD_TOKEN (err u105))
(define-constant ERR_MATURED (err u106))
(define-constant ERR_NOT_MATURED (err u107))
(define-constant ERR_ALREADY_SETTLED (err u108))
(define-constant ERR_NOT_SETTLED (err u109))
(define-constant ERR_MINT_WINDOW_CLOSED (err u110))
(define-constant ERR_TOO_SMALL (err u111))
(define-constant ERR_FEE_TOO_HIGH (err u112))
(define-constant ERR_BAD_MATURITY (err u113))
(define-constant ERR_ZERO_RATE (err u114))
(define-constant ERR_ZERO_AMOUNT (err u115))
(define-constant ERR_BAD_DENOM (err u116))

(define-data-var initialized bool false)
(define-data-var paused bool false)
(define-data-var ststx-principal (optional principal) none)
(define-data-var rate-source-principal (optional principal) none)
(define-data-var maturity-burn-height uint u0)
(define-data-var start-rate uint u0)
(define-data-var settled bool false)
(define-data-var settlement-rate uint u0)
(define-data-var split-fee-bps uint u0)
(define-data-var yield-fee-bps uint u0)
(define-data-var fees-accrued uint u0)

;;-------------------------------------
;; Guards
;;-------------------------------------

(define-private (check-token (token <ft-trait>))
  (ok (asserts! (is-eq (some (contract-of token)) (var-get ststx-principal)) ERR_BAD_TOKEN)))

(define-private (check-rate-source (source <rate-source-trait>))
  (ok (asserts! (is-eq (some (contract-of source)) (var-get rate-source-principal)) ERR_BAD_RATE_SOURCE)))

(define-private (max-uint (a uint) (b uint))
  (if (> a b) a b))

;;-------------------------------------
;; Admin
;;-------------------------------------

;; One-shot setup. Pins the stSTX token and rate source principals for the
;; life of the series and snapshots the start rate R0. On mainnet these are
;; the canonical ststx-token and stackingdao-rate-source; in tests/testnet,
;; the mocks.
(define-public (init
    (ststx <ft-trait>)
    (source <rate-source-trait>)
    (maturity uint)
    (new-denom uint)
    (new-split-fee-bps uint)
    (new-yield-fee-bps uint))
  (let (
    (rate (try! (contract-call? source get-stx-per-ststx)))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (asserts! (not (var-get initialized)) ERR_ALREADY_INITIALIZED)
    (asserts! (> maturity burn-block-height) ERR_BAD_MATURITY)
    (asserts! (<= new-split-fee-bps MAX_FEE_BPS) ERR_FEE_TOO_HIGH)
    (asserts! (<= new-yield-fee-bps MAX_FEE_BPS) ERR_FEE_TOO_HIGH)
    (asserts! (> rate u0) ERR_ZERO_RATE)
    ;; Only the two decimal bases that exist on Stacks LSTs.
    (asserts! (or (is-eq new-denom u1000000) (is-eq new-denom u100000000)) ERR_BAD_DENOM)
    (var-set denom new-denom)
    (var-set ststx-principal (some (contract-of ststx)))
    (var-set rate-source-principal (some (contract-of source)))
    (var-set maturity-burn-height maturity)
    (var-set start-rate rate)
    (var-set split-fee-bps new-split-fee-bps)
    (var-set yield-fee-bps new-yield-fee-bps)
    (var-set initialized true)
    (print { action: "init", start-rate: rate, maturity: maturity })
    (ok rate)
  )
)

;; Pause gates deposits only. Merge and redemptions can never be paused, so
;; the operator cannot trap user funds.
(define-public (set-paused (pause bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (ok (var-set paused pause))
  )
)

(define-public (claim-fees (recipient principal) (ststx <ft-trait>))
  (let (
    (amount (var-get fees-accrued))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (try! (check-token ststx))
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (var-set fees-accrued u0)
    (try! (as-contract (contract-call? ststx transfer amount tx-sender recipient none)))
    (print { action: "claim-fees", amount: amount, recipient: recipient })
    (ok amount)
  )
)

;;-------------------------------------
;; Core: split / merge
;;-------------------------------------

(define-public (split (amount uint) (ststx <ft-trait>) (source <rate-source-trait>))
  (let (
    (rate (try! (contract-call? source get-stx-per-ststx)))
    (fee (/ (* amount (var-get split-fee-bps)) BPS))
    (net (- amount fee))
    (pt-out (/ (* net (var-get start-rate)) (var-get denom)))
    (user tx-sender)
  )
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (asserts! (not (var-get paused)) ERR_PAUSED)
    (try! (check-token ststx))
    (try! (check-rate-source source))
    (asserts! (< burn-block-height (var-get maturity-burn-height)) ERR_MATURED)
    ;; Mint window: once StackingDAO processes rewards and the rate steps
    ;; past R0, deposits close for good. Keeps all YT fungible and fair.
    (asserts! (is-eq rate (var-get start-rate)) ERR_MINT_WINDOW_CLOSED)
    (asserts! (>= amount MIN_SPLIT) ERR_TOO_SMALL)
    (try! (contract-call? ststx transfer amount user (as-contract tx-sender) none))
    (var-set fees-accrued (+ (var-get fees-accrued) fee))
    (try! (contract-call? .pt-token mint pt-out user))
    (try! (contract-call? .yt-token mint net user))
    (print { action: "split", user: user, amount: amount, fee: fee, pt: pt-out, yt: net })
    (ok { pt: pt-out, yt: net, fee: fee })
  )
)

;; Recombine PT + YT back into the underlying stSTX at any point before
;; settlement. PT required rounds up so rounding can never drain the pool.
(define-public (recombine (yt-amount uint) (ststx <ft-trait>))
  (let (
    (pt-needed (/ (+ (* yt-amount (var-get start-rate)) (- (var-get denom) u1)) (var-get denom)))
    (user tx-sender)
  )
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (asserts! (not (var-get settled)) ERR_ALREADY_SETTLED)
    (try! (check-token ststx))
    (asserts! (> yt-amount u0) ERR_ZERO_AMOUNT)
    (try! (contract-call? .pt-token burn pt-needed user))
    (try! (contract-call? .yt-token burn yt-amount user))
    (try! (as-contract (contract-call? ststx transfer yt-amount tx-sender user none)))
    (print { action: "recombine", user: user, yt: yt-amount, pt: pt-needed })
    (ok { ststx: yt-amount, pt-burned: pt-needed })
  )
)

;;-------------------------------------
;; Core: settlement / redemption
;;-------------------------------------

;; Permissionless: anyone may settle once maturity has passed. The rate is
;; clamped to >= R0; in the (by-design impossible) case of a rate decrease,
;; PT redeems the original deposit exactly and YT redeems zero.
(define-public (settle (source <rate-source-trait>))
  (let (
    (rate (try! (contract-call? source get-stx-per-ststx)))
  )
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (try! (check-rate-source source))
    (asserts! (>= burn-block-height (var-get maturity-burn-height)) ERR_NOT_MATURED)
    (asserts! (not (var-get settled)) ERR_ALREADY_SETTLED)
    (var-set settlement-rate (max-uint rate (var-get start-rate)))
    (var-set settled true)
    (print { action: "settle", settlement-rate: (var-get settlement-rate) })
    (ok (var-get settlement-rate))
  )
)

(define-public (redeem-pt (pt-amount uint) (ststx <ft-trait>))
  (begin
    (asserts! (var-get settled) ERR_NOT_SETTLED)
    (try! (check-token ststx))
    (asserts! (> pt-amount u0) ERR_ZERO_AMOUNT)
    (redeem-pt-settled pt-amount ststx)
  )
)

(define-private (redeem-pt-settled (pt-amount uint) (ststx <ft-trait>))
  (let (
    (out (/ (* pt-amount (var-get denom)) (var-get settlement-rate)))
    (user tx-sender)
  )
    (try! (contract-call? .pt-token burn pt-amount user))
    (try! (as-contract (contract-call? ststx transfer out tx-sender user none)))
    (print { action: "redeem-pt", user: user, pt: pt-amount, ststx: out })
    (ok out)
  )
)

(define-public (redeem-yt (yt-amount uint) (ststx <ft-trait>))
  (begin
    (asserts! (var-get settled) ERR_NOT_SETTLED)
    (try! (check-token ststx))
    (asserts! (> yt-amount u0) ERR_ZERO_AMOUNT)
    (redeem-yt-settled yt-amount ststx)
  )
)

(define-private (redeem-yt-settled (yt-amount uint) (ststx <ft-trait>))
  (let (
    (rm (var-get settlement-rate))
    (gross (/ (* yt-amount (- rm (var-get start-rate))) rm))
    (fee (/ (* gross (var-get yield-fee-bps)) BPS))
    (out (- gross fee))
    (user tx-sender)
  )
    (try! (contract-call? .yt-token burn yt-amount user))
    (var-set fees-accrued (+ (var-get fees-accrued) fee))
    (and (> out u0)
      (try! (as-contract (contract-call? ststx transfer out tx-sender user none))))
    (print { action: "redeem-yt", user: user, yt: yt-amount, ststx: out, fee: fee })
    (ok out)
  )
)

;;-------------------------------------
;; Read-only
;;-------------------------------------

(define-read-only (get-info)
  {
    initialized: (var-get initialized),
    paused: (var-get paused),
    ststx: (var-get ststx-principal),
    rate-source: (var-get rate-source-principal),
    maturity-burn-height: (var-get maturity-burn-height),
    denom: (var-get denom),
    start-rate: (var-get start-rate),
    settled: (var-get settled),
    settlement-rate: (var-get settlement-rate),
    split-fee-bps: (var-get split-fee-bps),
    yield-fee-bps: (var-get yield-fee-bps),
    fees-accrued: (var-get fees-accrued)
  }
)

(define-read-only (preview-split (amount uint))
  (let (
    (fee (/ (* amount (var-get split-fee-bps)) BPS))
    (net (- amount fee))
  )
    { pt: (/ (* net (var-get start-rate)) (var-get denom)), yt: net, fee: fee }
  )
)

(define-read-only (preview-redeem-pt (pt-amount uint))
  (if (var-get settled)
    (some (/ (* pt-amount (var-get denom)) (var-get settlement-rate)))
    none
  )
)

(define-read-only (preview-redeem-yt (yt-amount uint))
  (if (var-get settled)
    (let (
      (rm (var-get settlement-rate))
      (gross (/ (* yt-amount (- rm (var-get start-rate))) rm))
    )
      (some (- gross (/ (* gross (var-get yield-fee-bps)) BPS)))
    )
    none
  )
)
