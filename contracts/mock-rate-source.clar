;; mock-rate-source
;;
;; Test/testnet stand-in for stackingdao-rate-source (StackingDAO is not
;; deployed on testnet). Deployer-settable rate, same trait, same 6-decimal
;; convention. Never part of a mainnet deployment plan.

(impl-trait .rate-source-trait.rate-source-trait)

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_OWNER (err u900))

(define-data-var rate uint u1000000)

(define-public (set-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_OWNER)
    (ok (var-set rate new-rate))
  )
)

(define-public (get-stx-per-ststx)
  (ok (var-get rate))
)
