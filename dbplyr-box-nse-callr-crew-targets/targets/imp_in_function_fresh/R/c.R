fc <- function(d) { box::use(stringr); d$c <- stringr$str_length("abc"); d$pid <- Sys.getpid(); d }
