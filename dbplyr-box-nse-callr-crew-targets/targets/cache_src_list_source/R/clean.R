# no box at all: a plain list of functions
clean <- list(
  add_x = function(d) dplyr::mutate(d, x = var1 * 2),
  add_y = function(d) dplyr::mutate(d, y = var1 * 2)
)
