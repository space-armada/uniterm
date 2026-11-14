(import uniterm)

# Asks for one buffer far past any cap. Janet's own integer check refuses 1e12, so the request is
# the largest size a 32-bit integer holds.
(uniterm/post-status :info "allocating")

(buffer/new 2000000000)
