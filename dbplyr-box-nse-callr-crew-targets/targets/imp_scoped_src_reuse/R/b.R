# no imports here: mutate() is imported only by a.R
fb <- function(d) mutate(d, b = 2, pid = Sys.getpid())
