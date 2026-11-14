(import uniterm)

(unless (= (uniterm/api-version) 1)
  (error "the API version is not 1"))

(uniterm/post-status :warning "synthetic status from a script")
