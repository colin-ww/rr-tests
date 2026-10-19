box::use(dplyr[mutate])

add_x <- function(d) mutate(d, x = var1 * 2)
