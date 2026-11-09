(import uniterm)

(uniterm/send {:window 7 :pane 1} "largest.bin" (string/repeat "x" 1048576))
