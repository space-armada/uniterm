(import uniterm)

(def panes (uniterm/list-panes {:window 7}))

(assert (= (length panes) 2) "the window has two panes")

(def first-pane (panes 0))

(assert (= (first-pane :pane) 1) "the pane ID arrives")
(assert (= (first-pane :applet) "terminal") "the applet type arrives")
(assert (= (first-pane :directory) "/synthetic/work") "the directory arrives")
(assert (first-pane :focused) "the first pane is focused")
(assert (= (length (first-pane :tabs)) 2) "the pane has two tabs")
(assert (= (((first-pane :tabs) 1) :tab) 2) "the tab number arrives")
(assert (nil? ((panes 1) :directory)) "a pane that reports no directory has none")

# A pane reference names its window too, and a table is as good as a struct.
(assert (= (length (uniterm/list-panes first-pane)) 2) "a pane reference names a window")
(assert (= (length (uniterm/list-panes @{:window 7})) 2) "a table names a window")

# A window that is not open answers nil, and the edge of the range is still a valid ID.
(assert (nil? (uniterm/list-panes {:window 8})) "a closed window has no panes")
(assert (nil? (uniterm/list-panes {:window 9007199254740991})) "the largest ID is accepted")
