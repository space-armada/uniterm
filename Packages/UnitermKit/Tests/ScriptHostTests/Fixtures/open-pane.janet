(import uniterm)

(def made (uniterm/open-pane :terminal {:window 7 :pane 1}))

(assert (= (made :window) 7) "the new pane names its window")
(assert (= (made :pane) 99) "the new pane has its own ID")

(uniterm/open-pane :data-viewer {:window 7 :pane 1 :tab 2} :axis :column :directory "/synthetic/work")
(uniterm/open-pane :browser {:window 7 :pane 1} :axis :row :directory nil)
