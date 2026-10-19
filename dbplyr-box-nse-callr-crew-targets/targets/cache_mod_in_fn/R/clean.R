box::use(dplyr[mutate])

#' @export
add_x <- function(d) mutate(d, x = var1 * 2)

#' @export
add_y <- function(d) mutate(d, y = var1 * 2)
