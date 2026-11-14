(import uniterm)

# Tells the app it is running, then never yields. The post comes first so a test knows the script
# is past every reply. Only an interrupt, or the app closing the connection, ends it.
(uniterm/post-status :info "spinning")

(while true)
