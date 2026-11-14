(import uniterm)

(def windows (uniterm/list-windows))

(assert (= (length windows) 2) "there are two windows")
(assert (= ((windows 0) :window) 9007199254740991) "the first ID is the largest exact integer")
(assert (= ((windows 1) :window) 9007199254740990) "the second ID is exact")
(assert (= ((windows 0) :title) "Synthetic 0") "the title arrives")
(assert ((windows 0) :key) "the first window is key")
(assert (not ((windows 1) :key)) "the second window is not key")
