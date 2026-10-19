# box module used by 02-box.R / 03-callr-crew.R
box::use(dplyr[mutate, filter])

var1 <- 999            # module-level object with the SAME name as a column
mod_only <- 42         # module-level object, no such column

#' @export
double_it <- function(x) x * 2

#' @export
add_var1 <- function(d) mutate(d, x = var1)            # column vs module-level var1

#' @export
add_mod_only <- function(d) mutate(d, x = mod_only)    # module-level only

#' @export
add_global_only <- function(d) mutate(d, x = only_global)  # defined in the CALLER's global env

#' @export
add_dollar_env <- function(d) mutate(d, x = .env$var1)

#' @export
add_double <- function(d) mutate(d, x = double_it(var1))   # module fn on a column

#' @export
add_pkg_fn <- function(d) mutate(d, x = stringr::str_to_upper(name))

#' @export
keep_gt <- function(d, cut) filter(d, var1 > cut)

#' @export
whoami <- function() environmentName(topenv())
