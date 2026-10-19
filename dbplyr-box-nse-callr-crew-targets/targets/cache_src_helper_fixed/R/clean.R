# runs box::use() in the function that calls clean_imports(), so the imports land there
clean_imports <- function() eval.parent(quote(box::use(dplyr[mutate])))

add_x <- function(d) {
  clean_imports()
  mutate(d, x = var1 * 2)
}

add_y <- function(d) {
  clean_imports()
  mutate(d, y = var1 * 2)
}
