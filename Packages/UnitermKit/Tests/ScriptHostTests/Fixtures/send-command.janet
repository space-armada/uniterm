(import uniterm)

(def pane {:window 7 :pane 1})

(def reply
  (uniterm/send-command pane :fixture-slides 0 :show-slide
                        {:index 2 :label "two\n\"quoted\"" :ratio 0.5 :below -3
                         :flags [true false nil] :nested {"inner" [1 2]} :mode :row}))

(assert (= (reply :command) "show-slide") (string "the reply named " (reply :command)))
(assert (= (reply :offset) -1.5) "a fractional, negative number did not reach the script")

(uniterm/send-command {:nearest :fixture-slides} :fixture-slides 0 "status")
(uniterm/send-command pane :fixture-slides 0 :status @{})
(uniterm/send-command pane :fixture-slides [0 0] :status)
(uniterm/send-command pane :fixture-slides @[0 0] :status)

# Every refusal from the app is a struct that names its kind, and the script goes on.
(defn fails-with [kind f]
  (def [ok failure] (protect (f)))
  (assert (not ok) (string kind " was accepted"))
  (assert (struct? failure) (string "the error is not a struct: " failure))
  (assert (= (failure :kind) kind) (string "the kind was " (failure :kind)))
  (assert (string? (failure :message)) "the error has no message"))

(fails-with :unsupported (fn [] (uniterm/send-command pane :fixture-chart 0 :status)))
(fails-with :unsupported (fn [] (uniterm/send-command pane :fixture-slides 2 :status)))
(fails-with :unsupported (fn [] (uniterm/send-command pane :fixture-slides [0 1] :status)))
(fails-with :refused (fn [] (uniterm/send-command pane :fixture-slides 0 :explode)))
(fails-with :reply-lost (fn [] (uniterm/send-command pane :fixture-slides 0 :huge-reply)))
(fails-with :not-found (fn [] (uniterm/send-command {:window 7 :pane 404} :fixture-slides 0 :status)))

(assert (= (length (uniterm/list-windows)) 2) "the app still answers")
