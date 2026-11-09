(import uniterm)

(def [ok message] (protect (uniterm/list-windows)))

(assert (not ok) "an answer past the frame is not delivered")
(assert (string/find "too large" (string message)) (string "the failure said: " message))
