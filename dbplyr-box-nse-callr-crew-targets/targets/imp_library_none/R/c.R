box::use(stringr)
fc <- function(d) { d$c <- stringr$str_length("abc"); d$pid <- Sys.getpid(); d }
