;; yt-token -- Gilt Yield Token
;;
;; 1 YT = the stacking yield earned by 1 micro-stSTX of deposit from the
;; series' start rate to maturity. Freely transferable SIP-010 (buying YT =
;; going long stacking APY). Mint/burn is gated to a single minter (the
;; series contract), set once by the deployer.

(impl-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

(define-fungible-token yt)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_OWNER (err u930))
(define-constant ERR_NOT_TOKEN_OWNER (err u931))
(define-constant ERR_NOT_MINTER (err u932))
(define-constant ERR_MINTER_ALREADY_SET (err u933))

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
    (ft-mint? yt amount recipient)
  )
)

(define-public (burn (amount uint) (owner principal))
  (begin
    (asserts! (is-eq (some contract-caller) (var-get minter)) ERR_NOT_MINTER)
    (ft-burn? yt amount owner)
  )
)

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR_NOT_TOKEN_OWNER)
    (try! (ft-transfer? yt amount sender recipient))
    (match memo to-print (print to-print) 0x)
    (ok true)
  )
)

(define-read-only (get-minter)
  (var-get minter))

(define-read-only (get-name)
  (ok "Gilt Yield stSTX"))

(define-read-only (get-symbol)
  (ok "YT-stSTX"))

(define-read-only (get-decimals)
  (ok u6))

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance yt who)))

(define-read-only (get-total-supply)
  (ok (ft-get-supply yt)))

(define-read-only (get-token-uri)
  (ok none))
