;; ScholarFi Application Manager Contract
;; Handles student applications, evaluation, and distribution management

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u200))
(define-constant ERR-APPLICATION-NOT-FOUND (err u201))
(define-constant ERR-APPLICATION-EXISTS (err u202))
(define-constant ERR-INVALID-STATUS (err u203))
(define-constant ERR-UNAUTHORIZED (err u204))
(define-constant ERR-APPLICATION-CLOSED (err u205))
(define-constant ERR-INVALID-SCORE (err u206))
(define-constant ERR-MINIMUM-SCORE-NOT-MET (err u207))
(define-constant ERR-ALREADY-PROCESSED (err u208))

;; Application statuses
(define-constant STATUS-PENDING "pending")
(define-constant STATUS-UNDER-REVIEW "reviewing")
(define-constant STATUS-APPROVED "approved")
(define-constant STATUS-REJECTED "rejected")
(define-constant STATUS-FUNDED "funded")

;; Data Variables
(define-data-var application-counter uint u0)
(define-data-var applications-open bool true)
(define-data-var minimum-score uint u70) ;; Minimum score of 70 out of 100
(define-data-var auto-approve-threshold uint u90) ;; Auto-approve applications with score 90+
(define-data-var max-applications-per-round uint u100)

;; Data Maps
(define-map applications uint {
  applicant: principal,
  academic-score: uint,
  financial-need-score: uint,
  essay-score: uint,
  total-score: uint,
  status: (string-ascii 20),
  submitted-at: uint,
  reviewed-at: (optional uint),
  reviewer: (optional principal)
})

(define-map applicant-to-id principal uint)
(define-map application-documents uint {
  academic-records: (string-ascii 200),
  financial-documents: (string-ascii 200),
  essay: (string-ascii 500),
  recommendation: (string-ascii 200)
})

(define-map authorized-reviewers principal bool)
(define-map reviewer-stats principal {
  applications-reviewed: uint,
  last-review: uint
})

;; Application round management
(define-map application-rounds uint {
  start-block: uint,
  end-block: uint,
  max-applications: uint,
  applications-count: uint,
  round-active: bool
})

(define-data-var current-round uint u0)

;; Public Functions

;; Submit scholarship application
(define-public (submit-application 
  (academic-records (string-ascii 200))
  (financial-documents (string-ascii 200))
  (essay (string-ascii 500))
  (recommendation (string-ascii 200)))
  (let (
    (applicant tx-sender)
    (existing-app (map-get? applicant-to-id applicant))
    (current-counter (var-get application-counter))
    (new-counter (+ current-counter u1))
    (round-id (var-get current-round))
    (round-info (map-get? application-rounds round-id))
  )
    (asserts! (var-get applications-open) ERR-APPLICATION-CLOSED)
    (asserts! (is-none existing-app) ERR-APPLICATION-EXISTS)
    
    ;; Check round limits if active round exists
    (match round-info
      round-data (asserts! (and 
                    (get round-active round-data)
                    (< (get applications-count round-data) (get max-applications round-data))
                    (>= stacks-block-height (get start-block round-data))
                    (<= stacks-block-height (get end-block round-data))) ERR-APPLICATION-CLOSED)
      true ;; No active round, proceed normally
    )
    
    ;; Create application with initial scores of 0
    (map-set applications new-counter {
      applicant: applicant,
      academic-score: u0,
      financial-need-score: u0,
      essay-score: u0,
      total-score: u0,
      status: STATUS-PENDING,
      submitted-at: stacks-block-height,
      reviewed-at: none,
      reviewer: none
    })
    
    ;; Store documents
    (map-set application-documents new-counter {
      academic-records: academic-records,
      financial-documents: financial-documents,
      essay: essay,
      recommendation: recommendation
    })
    
    ;; Map applicant to application ID
    (map-set applicant-to-id applicant new-counter)
    
    ;; Update counter
    (var-set application-counter new-counter)
    
    ;; Update round count if active
    (match round-info
      round-data (map-set application-rounds round-id 
                   (merge round-data {applications-count: (+ (get applications-count round-data) u1)}))
      true
    )
    
    (print {event: "application-submitted", applicant: applicant, application-id: new-counter})
    (ok new-counter)
  )
)

;; Review and score application (authorized reviewers only)
(define-public (review-application 
  (application-id uint)
  (academic-score uint)
  (financial-need-score uint)
  (essay-score uint))
  (let (
    (app-info (unwrap! (map-get? applications application-id) ERR-APPLICATION-NOT-FOUND))
    (reviewer tx-sender)
    (total-score (+ academic-score (+ financial-need-score essay-score)))
    (reviewer-authorized (or (is-eq reviewer CONTRACT-OWNER)
                           (default-to false (map-get? authorized-reviewers reviewer))))
  )
    (asserts! reviewer-authorized ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status app-info) STATUS-PENDING) ERR-ALREADY-PROCESSED)
    (asserts! (and (<= academic-score u40) (<= financial-need-score u30) (<= essay-score u30)) ERR-INVALID-SCORE)
    
    ;; Update application with scores and review info
    (map-set applications application-id 
      (merge app-info {
        academic-score: academic-score,
        financial-need-score: financial-need-score,
        essay-score: essay-score,
        total-score: total-score,
        status: (if (>= total-score (var-get auto-approve-threshold)) STATUS-APPROVED STATUS-UNDER-REVIEW),
        reviewed-at: (some stacks-block-height),
        reviewer: (some reviewer)
      })
    )
    
    ;; Update reviewer stats
    (let ((reviewer-data (default-to {applications-reviewed: u0, last-review: u0} 
                                   (map-get? reviewer-stats reviewer))))
      (map-set reviewer-stats reviewer {
        applications-reviewed: (+ (get applications-reviewed reviewer-data) u1),
        last-review: stacks-block-height
      })
    )
    
    (print {event: "application-reviewed", application-id: application-id, reviewer: reviewer, score: total-score})
    (ok true)
  )
)

;; Approve application manually (owner/authorized reviewers)
(define-public (approve-application (application-id uint))
  (let (
    (app-info (unwrap! (map-get? applications application-id) ERR-APPLICATION-NOT-FOUND))
    (reviewer tx-sender)
  )
    (asserts! (or (is-eq reviewer CONTRACT-OWNER)
                  (default-to false (map-get? authorized-reviewers reviewer))) ERR-UNAUTHORIZED)
    (asserts! (>= (get total-score app-info) (var-get minimum-score)) ERR-MINIMUM-SCORE-NOT-MET)
    (asserts! (not (is-eq (get status app-info) STATUS-APPROVED)) ERR-ALREADY-PROCESSED)
    
    (map-set applications application-id (merge app-info {status: STATUS-APPROVED}))
    
    (print {event: "application-approved", application-id: application-id, applicant: (get applicant app-info)})
    (ok true)
  )
)

;; Reject application (owner/authorized reviewers)
(define-public (reject-application (application-id uint) (reason (string-ascii 200)))
  (let (
    (app-info (unwrap! (map-get? applications application-id) ERR-APPLICATION-NOT-FOUND))
    (reviewer tx-sender)
  )
    (asserts! (or (is-eq reviewer CONTRACT-OWNER)
                  (default-to false (map-get? authorized-reviewers reviewer))) ERR-UNAUTHORIZED)
    (asserts! (not (is-eq (get status app-info) STATUS-REJECTED)) ERR-ALREADY-PROCESSED)
    
    (map-set applications application-id (merge app-info {status: STATUS-REJECTED}))
    
    (print {event: "application-rejected", application-id: application-id, reason: reason})
    (ok true)
  )
)

;; Mark application as funded (called after successful distribution)
(define-public (mark-as-funded (application-id uint))
  (let (
    (app-info (unwrap! (map-get? applications application-id) ERR-APPLICATION-NOT-FOUND))
  )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (default-to false (map-get? authorized-reviewers tx-sender))) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get status app-info) STATUS-APPROVED) ERR-INVALID-STATUS)
    
    (map-set applications application-id (merge app-info {status: STATUS-FUNDED}))
    
    (print {event: "application-funded", application-id: application-id})
    (ok true)
  )
)

;; Add authorized reviewer (owner only)
(define-public (add-reviewer (reviewer principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (map-set authorized-reviewers reviewer true)
    (print {event: "reviewer-added", reviewer: reviewer})
    (ok true)
  )
)

;; Remove authorized reviewer (owner only)
(define-public (remove-reviewer (reviewer principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (map-delete authorized-reviewers reviewer)
    (print {event: "reviewer-removed", reviewer: reviewer})
    (ok true)
  )
)

;; Set minimum score (owner only)
(define-public (set-minimum-score (score uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (<= score u100) ERR-INVALID-SCORE)
    (var-set minimum-score score)
    (print {event: "minimum-score-updated", score: score})
    (ok true)
  )
)

;; Toggle applications open/closed (owner only)
(define-public (toggle-applications)
  (let ((current-status (var-get applications-open)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (var-set applications-open (not current-status))
    (print {event: "applications-toggled", open: (not current-status)})
    (ok (not current-status))
  )
)

;; Start new application round (owner only)
(define-public (start-application-round (duration uint) (max-apps uint))
  (let (
    (round-id (+ (var-get current-round) u1))
    (start-block stacks-block-height)
    (end-block (+ stacks-block-height duration))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    
    (map-set application-rounds round-id {
      start-block: start-block,
      end-block: end-block,
      max-applications: max-apps,
      applications-count: u0,
      round-active: true
    })
    
    (var-set current-round round-id)
    (var-set applications-open true)
    
    (print {event: "application-round-started", round-id: round-id, duration: duration, max-apps: max-apps})
    (ok round-id)
  )
)

;; Read-only functions

;; Get application info
(define-read-only (get-application (application-id uint))
  (map-get? applications application-id)
)

;; Get application documents
(define-read-only (get-application-documents (application-id uint))
  (map-get? application-documents application-id)
)

;; Get applicant's application ID
(define-read-only (get-applicant-id (applicant principal))
  (map-get? applicant-to-id applicant)
)

;; Check if reviewer is authorized
(define-read-only (is-authorized-reviewer (reviewer principal))
  (default-to false (map-get? authorized-reviewers reviewer))
)

;; Get reviewer stats
(define-read-only (get-reviewer-stats (reviewer principal))
  (map-get? reviewer-stats reviewer)
)

;; Check if applications are open
(define-read-only (are-applications-open)
  (var-get applications-open)
)

;; Get application counter
(define-read-only (get-application-counter)
  (var-get application-counter)
)

;; Get minimum score
(define-read-only (get-minimum-score)
  (var-get minimum-score)
)

;; Get auto-approve threshold
(define-read-only (get-auto-approve-threshold)
  (var-get auto-approve-threshold)
)

;; Get current round info
(define-read-only (get-current-round)
  (let ((round-id (var-get current-round)))
    (if (> round-id u0)
      (map-get? application-rounds round-id)
      none
    )
  )
)

;; Get round info by ID
(define-read-only (get-round-info (round-id uint))
  (map-get? application-rounds round-id)
)

;; Get applications by status (simplified - returns count)
(define-read-only (get-applications-by-status (status (string-ascii 20)))
  ;; This would ideally return a list, but for simplicity we'll return a count
  ;; In a real implementation, you might use a more complex data structure
  u0 ;; Placeholder - would need additional data structures to implement efficiently
)

;; Get contract owner
(define-read-only (get-contract-owner)
  CONTRACT-OWNER
)

