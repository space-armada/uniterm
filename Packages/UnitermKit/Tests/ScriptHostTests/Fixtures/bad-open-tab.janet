(import uniterm)

(defn refuses [label needle f]
  (def [ok message] (protect (f)))
  (assert (not ok) (string label " was accepted"))
  (assert (string/find needle (string message)) (string label " failed with: " message)))

(def pane {:window 7 :pane 1})

(refuses "no argument" "arity" (fn [] (uniterm/open-tab)))
(refuses "a number" "must be a struct" (fn [] (uniterm/open-tab 3)))
(refuses "no window" "no :window" (fn [] (uniterm/open-tab {:pane 1})))
(refuses "no pane" "no :pane" (fn [] (uniterm/open-tab {:window 7})))
(refuses "a fractional tab" "whole number" (fn [] (uniterm/open-tab {:window 7 :pane 1 :tab 1.25})))
(refuses "a string pane" "must be a number" (fn [] (uniterm/open-tab {:window 7 :pane "1"})))
(refuses "a relative directory" "absolute path" (fn [] (uniterm/open-tab pane :directory "../up")))
(refuses "an option with no value" "needs a value" (fn [] (uniterm/open-tab pane :directory)))
(refuses "an axis" "only option" (fn [] (uniterm/open-tab pane :axis :row)))
(refuses "a repeated directory" "twice" (fn [] (uniterm/open-tab pane :directory "/a" :directory "/b")))
