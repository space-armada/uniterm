(import uniterm)

# Grows a buffer without limit.
(uniterm/post-status :info "growing")

(def pile @"")

(while true
  (buffer/push pile (string/repeat "x" 1000000)))
