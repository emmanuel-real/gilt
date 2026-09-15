;; pt-token -- Gilt Principal Token
;;
;; 1 PT = a claim on 1 micro-STX of principal at series maturity, paid in
;; stSTX at the settlement rate. Freely transferable SIP-010 so PT can trade
;; on existing DEXs (buying PT below face = earning a fixed rate on STX).
;; Mint/burn is gated to a single minter (the series contract), set once by
;; the deployer.

(impl-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

(define-fungible-token pt)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_OWNER (err u920))
(define-constant ERR_NOT_TOKEN_OWNER (err u921))
(define-constant ERR_NOT_MINTER (err u922))
(define-constant ERR_MINTER_ALREADY_SET (err u923))

(define-data-var minter (optional principal) none)

(define-public (set-minter (who principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (asserts! (is-none (var-get minter)) ERR_MINTER_ALREADY_SET)
    (ok (var-set minter (some who)))
  )
)

(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq (some contract-caller) (var-get minter)) ERR_NOT_MINTER)
    (ft-mint? pt amount recipient)
  )
)

(define-public (burn (amount uint) (owner principal))
  (begin
    (asserts! (is-eq (some contract-caller) (var-get minter)) ERR_NOT_MINTER)
    (ft-burn? pt amount owner)
  )
)

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR_NOT_TOKEN_OWNER)
    (try! (ft-transfer? pt amount sender recipient))
    (match memo to-print (print to-print) 0x)
    (ok true)
  )
)

(define-read-only (get-minter)
  (var-get minter))

(define-read-only (get-name)
  (ok "Gilt Principal STX"))

(define-read-only (get-symbol)
  (ok "PT-STX"))

(define-read-only (get-decimals)
  (ok u6))

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance pt who)))

(define-read-only (get-total-supply)
  (ok (ft-get-supply pt)))

(define-read-only (get-token-uri)
  (ok none))
