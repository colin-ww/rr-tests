# the issue's idea, as written
clean_imports <- function() {
  box::use(dplyr[mutate])
}

add_x <- function(d) {
  clean_imports()
  mutate(d, x = var1 * 2)
}

add_y <- function(d) {
  clean_imports()
  mutate(d, y = var1 * 2)
}
