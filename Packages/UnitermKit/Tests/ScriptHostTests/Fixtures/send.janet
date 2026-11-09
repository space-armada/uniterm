(import uniterm)

(assert (nil? (uniterm/send {:window 7 :pane 1} "report.csv" "a,b\n1,2\n")) "a send returns nothing")

(uniterm/send {:window 7 :pane 1} "notes.txt" @"buffer content")
(uniterm/send {:window 7 :pane 1} "empty.txt" "")
