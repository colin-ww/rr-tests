# box module: its imports live INSIDE the module
box::use(dplyr[mutate])

#' @export
add_x <- function(d) mutate(d, x = var1 * 2)
