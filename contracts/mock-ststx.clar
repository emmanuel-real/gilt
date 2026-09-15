;; mock-ststx
;;
;; Test/testnet stand-in for SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.ststx-token,
;; implementing the same canonical SIP-010 trait. Deployer-mintable so tests
;; can fund wallets. Never part of a mainnet deployment plan; on mainnet the
;; series is initialized with the real ststx-token.

(impl-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

(define-fungible-token mock-ststx)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_OWNER (err u910))
(define-constant ERR_NOT_TOKEN_OWNER (err u911))

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR_NOT_TOKEN_OWNER)
    (try! (ft-transfer? mock-ststx amount sender recipient))
    (match memo to-print (print to-print) 0x)
    (ok true)
  )
)

(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (ft-mint? mock-ststx amount recipient)
  )
)

(define-read-only (get-name)
  (ok "Mock Stacked STX"))

(define-read-only (get-symbol)
  (ok "stSTX"))

(define-read-only (get-decimals)
  (ok u6))

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance mock-ststx who)))

(define-read-only (get-total-supply)
  (ok (ft-get-supply mock-ststx)))

(define-read-only (get-token-uri)
  (ok none))
