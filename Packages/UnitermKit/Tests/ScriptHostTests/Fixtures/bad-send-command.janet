(import uniterm)

(defn refuses [label needle f]
  (def [ok message] (protect (f)))
  (assert (not ok) (string label " was accepted"))
  (assert (string/find needle (string message)) (string label " failed with: " message)))

(def pane {:window 7 :pane 1})

(defn deep [levels] (if (= levels 0) 1 {:a (deep (- levels 1))}))

(refuses "no argument" "arity" (fn [] (uniterm/send-command)))
(refuses "too many" "arity" (fn [] (uniterm/send-command pane :fixture-slides 0 :status {} {})))
(refuses "a bad pane" "must be a struct" (fn [] (uniterm/send-command 1 :fixture-slides 0 :status)))
(refuses "a string type" "keyword" (fn [] (uniterm/send-command pane "fixture-slides" 1 :status)))
(refuses "a path type" "not a path" (fn [] (uniterm/send-command pane :a/b 1 :status)))
(refuses "a negative version" "whole number" (fn [] (uniterm/send-command pane :fixture-slides -1 :status)))
(refuses "a fractional version" "whole number" (fn [] (uniterm/send-command pane :fixture-slides 1.5 :status)))
(refuses "a negative minor" "whole number" (fn [] (uniterm/send-command pane :fixture-slides [1 -1] :status)))
(refuses "a fractional major" "whole number" (fn [] (uniterm/send-command pane :fixture-slides [1.5 0] :status)))
(refuses "a one-part tuple" "[major minor]" (fn [] (uniterm/send-command pane :fixture-slides [1] :status)))
(refuses "a three-part tuple" "[major minor]" (fn [] (uniterm/send-command pane :fixture-slides [1 0 0] :status)))
(refuses "a string minor" "must be a number" (fn [] (uniterm/send-command pane :fixture-slides [1 "0"] :status)))
(refuses "a version as a string" "must be a number" (fn [] (uniterm/send-command pane :fixture-slides "1" :status)))
(refuses "a number command" "keyword or a string" (fn [] (uniterm/send-command pane :fixture-slides 0 5)))
(refuses "an empty command" "empty" (fn [] (uniterm/send-command pane :fixture-slides 0 "")))
(refuses "array arguments" "struct or a table" (fn [] (uniterm/send-command pane :fixture-slides 0 :status [1])))
(refuses "a function value" "cannot hold" (fn [] (uniterm/send-command pane :fixture-slides 0 :status {:f print})))
(refuses "an infinite number" "not finite" (fn [] (uniterm/send-command pane :fixture-slides 0 :status {:x math/inf})))
(refuses "a number key" "keyword or a string" (fn [] (uniterm/send-command pane :fixture-slides 0 :status {1 2})))
(refuses "a repeated key" "twice" (fn [] (uniterm/send-command pane :fixture-slides 0 :status {:a 1 "a" 2})))
(refuses "deep arguments" "nest" (fn [] (uniterm/send-command pane :fixture-slides 0 :status (deep 20))))

# A too-large command gets a structured error, as the app's own failures do.
(def [ok failure] (protect (uniterm/send-command pane :fixture-slides 0 :status {:s (string/repeat "x" 40000)})))
(assert (not ok) "large arguments were accepted")
(assert (struct? failure) (string "the oversize error is not a struct: " failure))
(assert (= (failure :kind) :bad-argument) (string "the oversize kind was " (failure :kind)))
(assert (string/find "bytes as JSON" (failure :message)) (string "the oversize message was " (failure :message)))

(refuses "text that is not UTF-8" "not UTF-8" (fn [] (uniterm/send-command pane :fixture-slides 0 :status {:s "\xFF"})))
