(import uniterm)

# Pane 6 closes as soon as it takes its file. The next call finds it gone.
(uniterm/send {:window 7 :pane 6} "gone.txt" "first")
(uniterm/send {:window 7 :pane 1} "kept.txt" "second")
