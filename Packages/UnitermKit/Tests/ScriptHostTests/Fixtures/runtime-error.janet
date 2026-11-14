(import uniterm)

(uniterm/post-status :info "before the failure")
(error "synthetic failure")
