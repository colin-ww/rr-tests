# Guards for part 9 (package imports vs where targets run). The first two tests are fast (callr processes).
# The pipeline test runs real tar_make() + crew on the projects 09-imports-fresh-process.R wrote: opt in with RUN_TARGETS_TESTS=true.
proj <- normalizePath(test_path("../.."))
no_tt <- c(callr::rcmd_safe_env(), TESTTHAT = "false", R_BOX_PATH = "")   # as test-targets.R

test_that("top-of-file box::use() in the global env: a package alias is a global object, attached names are not", {
  f <- withr::local_tempfile(fileext = ".R")
  writeLines(c("box::use(stringr)", "box::use(dplyr[mutate])"), f)
  got <- callr::r(\(f) {
    sys.source(f, envir = globalenv())
    c(alias = exists("stringr", envir = globalenv(), inherits = FALSE),     # an object: targets ships it to crew workers
      attached = exists("mutate", envir = globalenv(), inherits = FALSE),  # not in the global env ...
      search_path = exists("mutate"))                                      # ... but on the search path (mod:dplyr)
  }, args = list(f), env = no_tt)
  expect_equal(got, c(alias = TRUE, attached = FALSE, search_path = TRUE))
})

test_that("source_scoped() keep.source = TRUE gives the same function fingerprint as FALSE", {
  f <- withr::local_tempfile(fileext = ".R")
  writeLines("add_x <- function(d) d  # a comment", f)
  fp <- \(keep) callr::r(\(f, keep) {
    e <- new.env(); sys.source(f, envir = e, keep.source = keep); targets::tar_deparse_safe(e$add_x)
  }, args = list(f, keep), env = no_tt)
  expect_equal(fp(TRUE), fp(FALSE))
})

test_that("a fresh process per target (crew tasks_max = 1): envir still pools imports, source_scoped() enforces them", {
  skip_if_not(identical(Sys.getenv("RUN_TARGETS_TESTS"), "true"), "set RUN_TARGETS_TESTS=true to run real pipelines")
  run <- \(variant) callr::r(\(dir) {
    setwd(dir); unlink("_targets", recursive = TRUE)
    targets::tar_make(reporter = "silent")
    m <- targets::tar_meta(fields = c(error))
    stats::setNames(is.na(m$error[match(c("out_a", "out_b", "out_c"), m$name)]), c("a", "b", "c"))
  }, args = list(file.path(proj, "targets", variant)), env = no_tt)
  expect_equal(run("imp_envir_fresh"), c(a = TRUE, b = TRUE, c = TRUE))
  expect_equal(run("imp_scoped_fresh"), c(a = TRUE, b = FALSE, c = TRUE))
})
