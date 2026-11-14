# Starts a program. Under the sandbox the call is forbidden. With the capability it gets past the
# check and waits on the event loop, which a script run does not drive, so the script ends
# cleanly without the program's exit status.
(os/execute ["/usr/bin/true"])
