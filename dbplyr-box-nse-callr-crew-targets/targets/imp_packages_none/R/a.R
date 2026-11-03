box::use(dplyr[mutate])
fa <- function(d) mutate(d, a = 1, pid = Sys.getpid())
