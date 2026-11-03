fa <- function(d) { box::use(dplyr[mutate]); mutate(d, a = 1, pid = Sys.getpid()) }
