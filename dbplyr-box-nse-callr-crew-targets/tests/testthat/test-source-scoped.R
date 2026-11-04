# R/source_scoped.R without a pipeline: each file sees only its own imports, but base R's search path stays visible.
# Part 10 (10-source-scoped-checks.R) runs the same files in a real pipeline.
source(test_path("..", "..", "R", "source_scoped.R"))

scoped_env <- function(...) {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  files <- list(...)
  for (f in names(files)) writeLines(files[[f]], file.path(dir, f))
  # parent = stats, not the global env: skips whatever this session attached (eg another test file's library(dplyr)),
  # which every scoped file would see too. Like the search path of the fresh R that tar_make() starts
  source_scoped(file.path(dir, names(files)), envir = new.env(parent = as.environment("package:stats")))
}

test_that("a file sees its own imports, not another file's", {
  e <- scoped_env(
    a.R = c("box::use(dplyr[mutate])", "fa <- function(d) mutate(d, w = 1)"),
    c.R = "fc <- function(d) mutate(d, w = 1)"   # forgot dplyr[mutate]
  )
  d <- data.frame(v = 1:3)
  expect_equal(e$fa(d)$w, rep(1, 3))
  expect_error(e$fc(d), "could not find function \"mutate\"")
})

test_that("a forgotten import that base R also has gets base R's: dplyr filter() -> stats::filter()", {
  e <- scoped_env(b.R = "fb <- function(d) filter(d, v > 1)")  # forgot dplyr[filter]
  expect_identical(environment(e$fb) |> parent.env(), e)     # file env -> pipeline env -> global -> search path (stats)
  expect_error(e$fb(data.frame(v = 1:3)), "object 'v' not found")
})

test_that("functions from other files are found by name, and every top-level object is visible", {
  e <- scoped_env(
    a.R = c("times2 <- function(x) x * k", "k <- 2"),
    b.R = "fb <- function(x) times2(x) + 1"
  )
  expect_equal(e$fb(5), 11)
  expect_true(exists("k", envir = e, inherits = FALSE))   # no private helpers / @export
})
