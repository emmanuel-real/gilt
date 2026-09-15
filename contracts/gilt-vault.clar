;; gilt-vault -- fixed-rate notes on stSTX.
;;
;; A holder locks stSTX until the series matures and is promised a fixed
;; STX-denominated return, set when they deposit. The vault takes the floating
;; side: it keeps whatever stSTX earns above the promise and covers any
;; shortfall from a reserve.
;;
;; WHY DEPOSITS ARE PRICED AT THE LIVE RATE
;;
;; An earlier version sent every deposit through gilt-series split, which only
;; accepts a split while the live stSTX rate still equals the series start
;; rate. StackingDAO updates that rate roughly every 70 Bitcoin blocks (about
;; 12 hours), so on mainnet deposits would have stopped within hours of launch.
;; The split window exists to keep yield tokens fair between strangers. This
;; vault holds every position itself, so it does not need one: each note
;; records its own entry rate instead.
;;
;; THE NUMBERS FOR ONE NOTE (integer arithmetic, all floored)
;;
;;   premium = amount * rate-bps * blocks-remaining / (10000 * term-blocks)
;;             the promised return, pro-rated to time actually locked, so a
;;             late deposit cannot collect a full term's premium from reserve
;;   promise = (amount + premium) * entry-rate / denom           (micro-STX)
;;   payout  = (amount + premium) * entry-rate / max(Rm, entry-rate)
;;             paid in stSTX, where Rm is the settlement rate
;;
;; SOLVENCY IS STRUCTURAL
;;
;; If Rm >= entry-rate the payout is worth exactly the promise and is at most
;; amount + premium stSTX. If the rate dipped below entry, the payout is clamped
;; to amount + premium stSTX. Either way a note takes at most amount + premium
;; out of the vault, having brought amount in. So reserve is only needed for
;; premiums, counted in stSTX with no rate valuation at all:
;;
;;   sum(premium of open notes) <= reserve          checked on every deposit
;;
;; No oracle, no liquidation, no margin call. Redemption can never be paused,
;; and reserve can only be withdrawn once no notes are outstanding.

(use-trait ft-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)
(use-trait rate-source-trait .rate-source-trait.rate-source-trait)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant BPS u10000)
(define-constant MAX_RATE_BPS u2000)     ;; 20% for a full term, hard ceiling
(define-constant MIN_DEPOSIT u1000000)   ;; 1 stSTX

(define-constant ERR_NOT_OWNER (err u300))
(define-constant ERR_ALREADY_INITIALIZED (err u301))
(define-constant ERR_NOT_INITIALIZED (err u302))
(define-constant ERR_BAD_TOKEN (err u303))
(define-constant ERR_RATE_TOO_HIGH (err u304))
(define-constant ERR_TOO_SMALL (err u305))
(define-constant ERR_CAPACITY (err u306))
(define-constant ERR_NO_NOTE (err u307))
(define-constant ERR_NOT_SETTLED (err u308))
(define-constant ERR_ALREADY_REDEEMED (err u309))
(define-constant ERR_CLOSED (err u310))
(define-constant ERR_NOTES_OUTSTANDING (err u311))
(define-constant ERR_ZERO (err u312))
(define-constant ERR_BAD_SOURCE (err u313))
(define-constant ERR_BAD_SCHEDULE (err u314))
(define-constant ERR_DEPOSITS_ENDED (err u315))
(define-constant ERR_NOT_MATURED (err u316))
(define-constant ERR_ALREADY_SETTLED (err u317))
(define-constant ERR_NOT_NOTE_OWNER (err u318))
(define-constant ERR_BAD_DENOM (err u319))
(define-constant ERR_ZERO_RATE (err u320))
(define-constant ERR_INSUFFICIENT_BALANCE (err u321))

(define-data-var initialized bool false)
(define-data-var closed bool false)
(define-data-var ststx-principal (optional principal) none)
(define-data-var source-principal (optional principal) none)
(define-data-var denom uint u1000000)
(define-data-var rate-bps uint u0)
(define-data-var start-height uint u0)
(define-data-var deposit-end uint u0)
(define-data-var maturity uint u0)
(define-data-var settled bool false)
(define-data-var settlement-rate uint u0)
(define-data-var reserve uint u0)             ;; stSTX backing open premiums
(define-data-var committed uint u0)           ;; sum of premiums on open notes
(define-data-var notes-outstanding uint u0)
(define-data-var next-note-id uint u1)

(define-map notes
  uint
  { owner: principal, amount: uint, premium: uint, entry-rate: uint, redeemed: bool })

;;-------------------------------------
;; Guards
;;-------------------------------------

(define-private (check-token (token <ft-trait>))
  (ok (asserts! (is-eq (some (contract-of token)) (var-get ststx-principal)) ERR_BAD_TOKEN)))

(define-private (check-source (source <rate-source-trait>))
  (ok (asserts! (is-eq (some (contract-of source)) (var-get source-principal)) ERR_BAD_SOURCE)))

;;-------------------------------------
;; Note arithmetic
;;-------------------------------------

(define-read-only (premium-for (amount uint) (at-height uint))
  (let (
    (term (- (var-get maturity) (var-get start-height)))
    (remaining (if (> (var-get maturity) at-height) (- (var-get maturity) at-height) u0))
  )
    (if (is-eq term u0)
      u0
      (/ (* amount (var-get rate-bps) remaining) (* BPS term)))))

(define-read-only (payout-for (amount uint) (premium uint) (entry-rate uint) (settle-rate uint))
  (let ((effective (if (> settle-rate entry-rate) settle-rate entry-rate)))
    (if (is-eq effective u0)
      u0
      (/ (* (+ amount premium) entry-rate) effective))))

;;-------------------------------------
;; Admin
;;-------------------------------------

;; One series per vault. Pins the token and rate source, fixes the promised
;; rate, and opens deposits until deposit-end; the term runs to maturity.
(define-public (init
    (ststx <ft-trait>)
    (source <rate-source-trait>)
    (new-denom uint)
    (new-rate-bps uint)
    (new-deposit-end uint)
    (new-maturity uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (asserts! (not (var-get initialized)) ERR_ALREADY_INITIALIZED)
    (asserts! (<= new-rate-bps MAX_RATE_BPS) ERR_RATE_TOO_HIGH)
    (asserts! (or (is-eq new-denom u1000000) (is-eq new-denom u100000000)) ERR_BAD_DENOM)
    (asserts! (> new-deposit-end burn-block-height) ERR_BAD_SCHEDULE)
    (asserts! (> new-maturity new-deposit-end) ERR_BAD_SCHEDULE)
    (var-set ststx-principal (some (contract-of ststx)))
    (var-set source-principal (some (contract-of source)))
    (var-set denom new-denom)
    (var-set rate-bps new-rate-bps)
    (var-set start-height burn-block-height)
    (var-set deposit-end new-deposit-end)
    (var-set maturity new-maturity)
    (var-set initialized true)
    (print { action: "init", rate-bps: new-rate-bps, start-height: burn-block-height,
             deposit-end: new-deposit-end, maturity: new-maturity })
    (ok true)))

(define-public (fund-reserve (amount uint) (ststx <ft-trait>))
  (begin
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (try! (check-token ststx))
    (asserts! (> amount u0) ERR_ZERO)
    (try! (contract-call? ststx transfer amount tx-sender (as-contract tx-sender) none))
    (var-set reserve (+ (var-get reserve) amount))
    (print { action: "fund-reserve", amount: amount, reserve: (var-get reserve) })
    (ok (var-get reserve))))

;; Stops new deposits. Never blocks settlement or redemption.
(define-public (set-closed (v bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (ok (var-set closed v))))

;; Only with no notes outstanding, so backing a depositor relies on can never
;; leave. Everything held at that point is reserve, so the recorded reserve is
;; reset to what remains -- capacity can never count stSTX that has left.
(define-public (withdraw-surplus (amount uint) (ststx <ft-trait>))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (try! (check-token ststx))
    (asserts! (is-eq (var-get notes-outstanding) u0) ERR_NOTES_OUTSTANDING)
    (asserts! (> amount u0) ERR_ZERO)
    (withdraw-checked amount ststx
      (unwrap-panic (contract-call? ststx get-balance (as-contract tx-sender))))))

(define-private (withdraw-checked (amount uint) (ststx <ft-trait>) (held uint))
  (begin
    (asserts! (<= amount held) ERR_INSUFFICIENT_BALANCE)
    (try! (as-contract (contract-call? ststx transfer amount tx-sender CONTRACT_OWNER none)))
    (var-set reserve (- held amount))
    (print { action: "withdraw-surplus", amount: amount, reserve: (- held amount) })
    (ok amount)))

;;-------------------------------------
;; Deposit
;;-------------------------------------

(define-public (deposit (amount uint) (ststx <ft-trait>) (source <rate-source-trait>))
  (begin
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (asserts! (not (var-get closed)) ERR_CLOSED)
    (try! (check-token ststx))
    (try! (check-source source))
    (asserts! (< burn-block-height (var-get deposit-end)) ERR_DEPOSITS_ENDED)
    (asserts! (>= amount MIN_DEPOSIT) ERR_TOO_SMALL)
    ;; the source is only called once it is known to be the pinned one
    (deposit-checked amount ststx (try! (contract-call? source get-stx-per-ststx)))))

(define-private (deposit-checked (amount uint) (ststx <ft-trait>) (rate uint))
  (let (
    (user tx-sender)
    (premium (premium-for amount burn-block-height))
    (id (var-get next-note-id))
    (base (var-get denom))
  )
    (asserts! (> rate u0) ERR_ZERO_RATE)
    ;; The whole safety property: a note can take at most amount + premium
    ;; stSTX out, so open premiums must never exceed the reserve.
    (asserts! (<= (+ (var-get committed) premium) (var-get reserve)) ERR_CAPACITY)
    (try! (contract-call? ststx transfer amount user (as-contract tx-sender) none))
    (map-set notes id
      { owner: user, amount: amount, premium: premium, entry-rate: rate, redeemed: false })
    (var-set next-note-id (+ id u1))
    (var-set committed (+ (var-get committed) premium))
    (var-set notes-outstanding (+ (var-get notes-outstanding) u1))
    (print { action: "deposit", note-id: id, user: user, amount: amount,
             premium: premium, entry-rate: rate })
    (ok { note-id: id,
          entry-rate: rate,
          premium-ststx: premium,
          principal-stx: (/ (* amount rate) base),
          payout-stx: (/ (* (+ amount premium) rate) base) })))

;;-------------------------------------
;; Maturity
;;-------------------------------------

;; Permissionless once the term has run.
(define-public (settle (source <rate-source-trait>))
  (begin
    (asserts! (var-get initialized) ERR_NOT_INITIALIZED)
    (try! (check-source source))
    (asserts! (>= burn-block-height (var-get maturity)) ERR_NOT_MATURED)
    (asserts! (not (var-get settled)) ERR_ALREADY_SETTLED)
    (settle-checked (try! (contract-call? source get-stx-per-ststx)))))

(define-private (settle-checked (rate uint))
  (begin
    (asserts! (> rate u0) ERR_ZERO_RATE)
    (var-set settlement-rate rate)
    (var-set settled true)
    (print { action: "settle", settlement-rate: rate })
    (ok rate)))

(define-public (redeem (note-id uint) (ststx <ft-trait>))
  (let (
    (note (unwrap! (map-get? notes note-id) ERR_NO_NOTE))
    (user tx-sender)
  )
    (asserts! (var-get settled) ERR_NOT_SETTLED)
    (try! (check-token ststx))
    (asserts! (is-eq (get owner note) user) ERR_NOT_NOTE_OWNER)
    (asserts! (not (get redeemed note)) ERR_ALREADY_REDEEMED)
    (let (
      (payout (payout-for (get amount note) (get premium note)
                          (get entry-rate note) (var-get settlement-rate)))
    )
      (map-set notes note-id (merge note { redeemed: true }))
      (var-set notes-outstanding (- (var-get notes-outstanding) u1))
      (var-set committed (- (var-get committed) (get premium note)))
      (try! (as-contract (contract-call? ststx transfer payout tx-sender user none)))
      (print { action: "redeem", note-id: note-id, user: user, payout: payout })
      (ok payout))))

;;-------------------------------------
;; Read-only
;;-------------------------------------

(define-read-only (get-info)
  {
    initialized: (var-get initialized),
    closed: (var-get closed),
    ststx: (var-get ststx-principal),
    rate-source: (var-get source-principal),
    denom: (var-get denom),
    rate-bps: (var-get rate-bps),
    start-height: (var-get start-height),
    deposit-end: (var-get deposit-end),
    maturity: (var-get maturity),
    settled: (var-get settled),
    settlement-rate: (var-get settlement-rate),
    reserve: (var-get reserve),
    committed: (var-get committed),
    notes-outstanding: (var-get notes-outstanding),
    next-note-id: (var-get next-note-id)
  })

(define-read-only (get-note (note-id uint))
  (map-get? notes note-id))

(define-read-only (get-remaining-capacity)
  (if (> (var-get reserve) (var-get committed))
    (- (var-get reserve) (var-get committed))
    u0))

;; What a deposit would lock in at the current height. The live rate comes from
;; a public adapter call, which a read-only function cannot make, so the caller
;; passes it in.
(define-read-only (preview-deposit (amount uint) (rate uint))
  (let ((premium (premium-for amount burn-block-height)))
    { premium-ststx: premium,
      principal-stx: (/ (* amount rate) (var-get denom)),
      payout-stx: (/ (* (+ amount premium) rate) (var-get denom)) }))

(define-read-only (preview-redeem (note-id uint))
  (match (map-get? notes note-id)
    note (if (var-get settled)
           (some (payout-for (get amount note) (get premium note)
                             (get entry-rate note) (var-get settlement-rate)))
           none)
    none))
