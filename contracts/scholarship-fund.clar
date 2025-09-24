;; ScholarFi Scholarship Fund Contract
;; Manages donations, fund pooling, and basic scholarship operations

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-INSUFFICIENT-FUNDS (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-RECIPIENT-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-FUNDED (err u104))
(define-constant ERR-FUND-NOT-ACTIVE (err u105))
(define-constant ERR-UNAUTHORIZED (err u106))

;; Data Variables
(define-data-var total-fund-pool uint u0)
(define-data-var total-donations uint u0)
(define-data-var fund-active bool true)
(define-data-var minimum-donation uint u1000000) ;; 1 STX in microSTX
(define-data-var scholarship-amount uint u5000000) ;; 5 STX in microSTX

;; Data Maps
(define-map donors principal uint)
(define-map donation-history uint {donor: principal, amount: uint, block-height: uint})
(define-map scholarship-recipients principal {amount: uint, funded-at: uint, status: (string-ascii 20)})
(define-map authorized-distributors principal bool)

;; Donation counter
(define-data-var donation-counter uint u0)

;; Public Functions

;; Donate to the scholarship fund
(define-public (donate (amount uint))
  (let (
    (donor tx-sender)
    (current-donation (default-to u0 (map-get? donors donor)))
    (new-donation (+ current-donation amount))
    (current-counter (var-get donation-counter))
    (new-counter (+ current-counter u1))
  )
    (asserts! (var-get fund-active) ERR-FUND-NOT-ACTIVE)
    (asserts! (>= amount (var-get minimum-donation)) ERR-INVALID-AMOUNT)
    (try! (stx-transfer? amount donor (as-contract tx-sender)))
    
    ;; Update donor records
    (map-set donors donor new-donation)
    
    ;; Record donation history
    (map-set donation-history new-counter {
      donor: donor,
      amount: amount,
      block-height: stacks-block-height
    })
    
    ;; Update counters and totals
    (var-set donation-counter new-counter)
    (var-set total-fund-pool (+ (var-get total-fund-pool) amount))
    (var-set total-donations (+ (var-get total-donations) amount))
    
    (print {event: "donation", donor: donor, amount: amount, total-pool: (var-get total-fund-pool)})
    (ok true)
  )
)

;; Distribute scholarship to approved recipient
(define-public (distribute-scholarship (recipient principal))
  (let (
    (scholarship-amt (var-get scholarship-amount))
    (current-pool (var-get total-fund-pool))
    (existing-recipient (map-get? scholarship-recipients recipient))
  )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) 
                  (default-to false (map-get? authorized-distributors tx-sender))) ERR-UNAUTHORIZED)
    (asserts! (var-get fund-active) ERR-FUND-NOT-ACTIVE)
    (asserts! (>= current-pool scholarship-amt) ERR-INSUFFICIENT-FUNDS)
    (asserts! (is-none existing-recipient) ERR-ALREADY-FUNDED)
    
    ;; Transfer scholarship amount
    (try! (as-contract (stx-transfer? scholarship-amt tx-sender recipient)))
    
    ;; Record recipient
    (map-set scholarship-recipients recipient {
      amount: scholarship-amt,
      funded-at: stacks-block-height,
      status: "funded"
    })
    
    ;; Update fund pool
    (var-set total-fund-pool (- current-pool scholarship-amt))
    
    (print {event: "scholarship-distributed", recipient: recipient, amount: scholarship-amt})
    (ok true)
  )
)

;; Add authorized distributor (owner only)
(define-public (add-distributor (distributor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (map-set authorized-distributors distributor true)
    (print {event: "distributor-added", distributor: distributor})
    (ok true)
  )
)

;; Remove authorized distributor (owner only)
(define-public (remove-distributor (distributor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (map-delete authorized-distributors distributor)
    (print {event: "distributor-removed", distributor: distributor})
    (ok true)
  )
)

;; Set scholarship amount (owner only)
(define-public (set-scholarship-amount (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (var-set scholarship-amount amount)
    (print {event: "scholarship-amount-updated", amount: amount})
    (ok true)
  )
)

;; Set minimum donation (owner only)
(define-public (set-minimum-donation (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (var-set minimum-donation amount)
    (print {event: "minimum-donation-updated", amount: amount})
    (ok true)
  )
)

;; Toggle fund active status (owner only)
(define-public (toggle-fund-status)
  (let ((current-status (var-get fund-active)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (var-set fund-active (not current-status))
    (print {event: "fund-status-toggled", active: (not current-status)})
    (ok (not current-status))
  )
)

;; Emergency withdrawal (owner only)
(define-public (emergency-withdraw (amount uint))
  (let ((current-pool (var-get total-fund-pool)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (<= amount current-pool) ERR-INSUFFICIENT-FUNDS)
    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT-OWNER)))
    (var-set total-fund-pool (- current-pool amount))
    (print {event: "emergency-withdrawal", amount: amount, remaining: (- current-pool amount)})
    (ok true)
  )
)

;; Read-only functions

;; Get total fund pool
(define-read-only (get-fund-pool)
  (var-get total-fund-pool)
)

;; Get total donations ever made
(define-read-only (get-total-donations)
  (var-get total-donations)
)

;; Get donor contribution
(define-read-only (get-donor-contribution (donor principal))
  (default-to u0 (map-get? donors donor))
)

;; Get donation history by ID
(define-read-only (get-donation-history (donation-id uint))
  (map-get? donation-history donation-id)
)

;; Get scholarship recipient info
(define-read-only (get-recipient-info (recipient principal))
  (map-get? scholarship-recipients recipient)
)

;; Check if address is authorized distributor
(define-read-only (is-authorized-distributor (address principal))
  (default-to false (map-get? authorized-distributors address))
)

;; Get fund status
(define-read-only (is-fund-active)
  (var-get fund-active)
)

;; Get scholarship amount
(define-read-only (get-scholarship-amount)
  (var-get scholarship-amount)
)

;; Get minimum donation amount
(define-read-only (get-minimum-donation)
  (var-get minimum-donation)
)

;; Get current donation counter
(define-read-only (get-donation-counter)
  (var-get donation-counter)
)

;; Get contract owner
(define-read-only (get-contract-owner)
  CONTRACT-OWNER
)

;; Check available scholarships based on current pool
(define-read-only (get-available-scholarships)
  (/ (var-get total-fund-pool) (var-get scholarship-amount))
)

;; Get fund statistics
(define-read-only (get-fund-stats)
  {
    total-pool: (var-get total-fund-pool),
    total-donations: (var-get total-donations),
    scholarship-amount: (var-get scholarship-amount),
    available-scholarships: (/ (var-get total-fund-pool) (var-get scholarship-amount)),
    fund-active: (var-get fund-active),
    donation-count: (var-get donation-counter)
  }
)


