# Guards for the box + targets caching findings (part 8, issue #5). The first four tests are fast (callr processes).
# The pipeline test runs real tar_make() + crew on the projects 08-box-caching.R wrote: opt in with RUN_TARGETS_TESTS=true.
proj <- normalizePath(test_path("../.."))
no_tt <- c(callr::rcmd_safe_env(), TESTTHAT = "false", R_BOX_PATH = "")   # as test-targets.R

# what targets computes for an imported box module (serialize) and for an imported function (deparse)
module_hashes <- \(dir) callr::r(\(dir) {
  setwd(dir); options(box.path = getwd()); box::use(R/clean)
  c(module = secretbase::siphash13(clean), fn = secretbase::siphash13(targets::tar_deparse_safe(clean$add_x)))
}, args = list(dir), env = no_tt)

test_that("a box module's hash changes with the file's modification time and folder; a function's hash does not", {
  dir <- withr::local_tempfile(); dir.create(file.path(dir, "R"), recursive = TRUE)
  f <- file.path(dir, "R", "clean.R")
  writeLines(c("box::use(dplyr[mutate])", "#' @export", "add_x <- function(d) mutate(d, x = var1 * 2)"), f)
  Sys.setFileTime(f, as.POSIXct("2026-01-01", tz = "UTC")); h0 <- module_hashes(dir)
  expect_equal(module_hashes(dir), h0)                                  # stable across fresh sessions
  Sys.setFileTime(f, as.POSIXct("2026-01-02", tz = "UTC")); h1 <- module_hashes(dir)
  expect_false(h1[["module"]] == h0[["module"]])                        # same text, newer time -> new module hash
  expect_equal(h1[["fn"]], h0[["fn"]])
  copy <- withr::local_tempfile(); dir.create(copy)
  file.copy(file.path(dir, "R"), copy, recursive = TRUE, copy.date = TRUE)
  expect_false(module_hashes(copy)[["module"]] == h1[["module"]])       # same text and time, other folder
})

test_that("running a module function once changes the module's hash (R byte-compiles it); not with the JIT off", {
  first_call <- \(jit) callr::r(\(dir, jit) {
    compiler::enableJIT(jit); setwd(dir); options(box.path = getwd()); box::use(R/clean)
    h0 <- secretbase::siphash13(clean); clean$add_x(data.frame(var1 = 1)); h0 != secretbase::siphash13(clean)
  }, args = list(file.path(proj, "targets", "cache_mod_object"), jit), env = no_tt)
  expect_true(first_call(3))
  expect_false(first_call(0))
})

test_that("box::use() inside a helper function imports into the helper only; eval.parent() puts it in the caller", {
  r <- callr::r(\() {
    naive <- function() box::use(dplyr[mutate])
    fixed <- function() eval.parent(quote(box::use(dplyr[mutate])))
    try_it <- \(helper) tryCatch({ helper(); mutate(data.frame(a = 1), b = a + 1)$b }, error = \(e) conditionMessage(e))
    list(naive = try_it(naive), fixed = try_it(fixed), on_search_path = any(grepl("^mod:", search())))
  }, env = no_tt)
  expect_match(r$naive, "could not find function .mutate.")
  expect_equal(r$fixed, 2)
  expect_false(r$on_search_path)   # inside a function, box never attaches anything
})

test_that("box::use() run in a non-global env puts the imports in a new parent of that env (so the env carries them)", {
  r <- callr::r(\() {
    e <- new.env(parent = globalenv()); eval(quote(box::use(dplyr[mutate])), e)
    list(visible = exists("mutate", e), own = exists("mutate", e, inherits = FALSE),
         chain = identical(parent.env(parent.env(e)), globalenv()), search = any(grepl("^mod:", search())))
  }, env = no_tt)
  expect_true(r$visible); expect_false(r$own); expect_true(r$chain); expect_false(r$search)
})

T0 <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")   # the time 08-box-caching.R gives R/clean.R
run_in <- \(dir, code, crew = FALSE) processx::run(file.path(R.home("bin"), "Rscript"), c("-e", code), wd = dir,
  error_on_status = FALSE, env = c("current", USE_CREW = tolower(crew), TESTTHAT = "false", R_BOX_PATH = ""))
outdated_after_touch <- function(variant) {
  dir <- file.path(proj, "targets", paste0("cache_", variant)); f <- file.path(dir, "R", "clean.R")
  unlink(file.path(dir, "_targets"), recursive = TRUE)
  on.exit({ Sys.setFileTime(f, T0); unlink(file.path(dir, "_targets"), recursive = TRUE) })
  run_in(dir, "targets::tar_make(reporter = 'silent')")
  Sys.setFileTime(f, T0 + 86400)
  out <- strsplit(run_in(dir, "cat(targets::tar_outdated(reporter = 'silent'), sep = '\\n')")$stdout, "\n")[[1]]
  sort(out[nzchar(out)])
}
errors_with_crew <- function(variant) {
  dir <- file.path(proj, "targets", paste0("cache_", variant)); store <- file.path(dir, "_targets")
  unlink(store, recursive = TRUE); on.exit(unlink(store, recursive = TRUE))
  run_in(dir, "targets::tar_make(reporter = 'silent')", crew = TRUE)
  m <- targets::tar_meta(fields = error, store = store); m$error[m$name %in% c("out_x", "out_y")]
}

test_that("pipelines: touching the file re-runs everything with a module object, nothing with tar_source() into an env", {
  skip_if_not(Sys.getenv("RUN_TARGETS_TESTS") == "true", "set RUN_TARGETS_TESTS=true to run pipelines")
  expect_equal(outdated_after_touch("mod_object"), c("out_x", "out_y"))
  expect_equal(outdated_after_touch("src_scoped"), character())
  expect_equal(errors_with_crew("src_scoped"), c(NA_character_, NA_character_))   # top-of-file box::use() reaches workers
  expect_match(errors_with_crew("src_global"), "could not find function .mutate.") # the issue's starting point
})
