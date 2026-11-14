(import uniterm)

(def tab (uniterm/open-tab {:window 7 :pane 1}))

(assert (= (tab :window) 7) "the tab names its window")
(assert (= (tab :pane) 1) "the tab names its pane")
(assert (= (tab :tab) 5) "the tab has its own number")

(uniterm/open-tab {:window 7 :pane 1} :directory "/synthetic/tab")
