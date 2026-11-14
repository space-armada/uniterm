(import uniterm)

# Writes the file named by the first argument, then reads standard input, which the test never
# closes. The read is one C call that Janet's interrupt flag never reaches, so only a kill ends
# it. The test waits for the file, and then for the helper's main thread to block in the read.
(spit (get (dyn :args) 1) "ready")

(file/read stdin 1)
