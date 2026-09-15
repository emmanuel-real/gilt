;; rate-source-trait
;;
;; A rate source reports the stSTX -> STX exchange rate as a 6-decimal
;; fixed-point uint (u1000000 = 1.0 STX per stSTX). gilt-series pins one
;; rate source principal at init and validates every trait argument against
;; it, mirroring how StackingDAO's own data-core validates its reserve.

(define-trait rate-source-trait
  (
    (get-stx-per-ststx () (response uint uint))
  )
)
