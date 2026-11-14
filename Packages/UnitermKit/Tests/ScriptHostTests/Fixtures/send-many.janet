(import uniterm)

(def pane {:window 7 :pane 1})

(for index 0 300
  (uniterm/send pane (string "part-" index ".bin") (string/repeat "x" 1048576)))
