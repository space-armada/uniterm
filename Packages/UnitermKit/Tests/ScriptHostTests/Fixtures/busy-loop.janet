(import uniterm)

# Tells the app it is running, then marks the file named by the first argument, so the test knows
# the script is past every reply. After that the script never yields, and only the helper's
# watchdog can end it.
(uniterm/post-status :info "looping")
(spit (get (dyn :args) 1) "looping")

(while true)
