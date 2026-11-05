box::use(stringr, dplyr[mutate])
fa <- function(d) { d <- mutate(d, w = 1); d$len <- stringr$str_length("abc"); d }
