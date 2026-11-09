(import uniterm)

(defn refuses [label needle f]
  (def [ok message] (protect (f)))
  (assert (not ok) (string label " was accepted"))
  (assert (string/find needle (string message)) (string label " failed with: " message)))

(def pane {:window 7 :pane 1})
(def gone {:window 7 :pane 404})
(def busy {:window 7 :pane 403})

(refuses "an unknown kind" "kind is not known" (fn [] (uniterm/open-pane :bogus pane)))
(refuses "a closed pane" "not open" (fn [] (uniterm/open-pane :terminal gone)))
(refuses "a pane with no room" "no room" (fn [] (uniterm/open-pane :terminal busy)))
(refuses "a tab in a closed pane" "not open" (fn [] (uniterm/open-tab gone)))
(refuses "a tab in a pane that has none" "no tabs" (fn [] (uniterm/open-tab busy)))
(refuses "a send to a closed pane" "not open" (fn [] (uniterm/send gone "a.txt" "x")))
(refuses "a send to a terminal" "owns this pane's input" (fn [] (uniterm/send busy "a.txt" "x")))

# The script survives every refusal, and the app still answers.
(assert (= (length (uniterm/list-windows)) 2) "the app still answers")
