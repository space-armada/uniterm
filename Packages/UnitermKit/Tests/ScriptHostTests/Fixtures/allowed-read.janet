# Reads the file named by the first script argument, and prints its size.
(def path (get (dyn :args) 1))

(print (length (slurp path)))
