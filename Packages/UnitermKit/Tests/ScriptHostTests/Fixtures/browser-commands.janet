# Calls the browser's commands and prints how each one ended. A call the controller holds the
# power for returns the app's reply. A call it does not hold the power for fails as refused, and
# the script goes on.
(import uniterm)

(def pane {:window 7 :pane 1})
(def tab {:window 7 :pane 1 :tab 3})

(defn attempt [label target command arguments]
  (def [ok result] (protect (uniterm/send-command target :browser 0 command arguments)))
  (print label " " (if ok "ok" (string (result :kind)))))

(attempt "open" pane :open {:url "https://example.com/"})
(attempt "navigate" tab :navigate {:url "https://example.com/next"})
(attempt "reload" tab :reload {})
(attempt "read" tab :read {})
