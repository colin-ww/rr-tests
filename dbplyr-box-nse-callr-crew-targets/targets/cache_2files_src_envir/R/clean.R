box::use(dplyr[mutate])

add_x <- function(d) mutate(d, x = times2(var1))   # times2() is defined in R/util.R
add_y <- function(d) mutate(d, y = var1 + 1)
leaky <- function(d) n_distinct(d$var1)            # n_distinct is imported by R/util.R only
