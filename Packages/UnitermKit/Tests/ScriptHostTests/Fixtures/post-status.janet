(import uniterm)

(unless (= (uniterm/api-version) 0)
  (error "the API version is not 0"))

(uniterm/post-status :warning "synthetic status from a script")
