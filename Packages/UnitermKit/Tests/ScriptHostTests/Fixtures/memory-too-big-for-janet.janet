# One trillion bytes is past what Janet's own integer check accepts, so this is an error the script
# sees, not a memory limit.
(buffer/new 1e12)
