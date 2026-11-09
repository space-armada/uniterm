# Listens on a free local port. Under the sandbox the call is forbidden. With the capability it
# succeeds, and the stream closes when the script ends. A connect would wait on the event loop,
# which a script run does not drive, so it could not fail here.
(def server (net/listen "127.0.0.1" "0"))

(print "listening " (not (nil? server)))
(:close server)
