# Guards for the targets/crew/box findings (part 4). The first two tests are fast (one callr process each).
# The pipeline tests run real tar_make() + crew (~5 s each): opt in with RUN_TARGETS_TESTS=true.
# NB: testthat sets TESTTHAT=true, which makes box resolve modules from getwd() -> we unset it in children,
# otherwise module lookups that fail in real use would pass here.
proj <- normalizePath(test_path("../.."))
no_tt <- c(callr::rcmd_safe_env(), TESTTHAT = "false", R_BOX_PATH = "")   # as 04-targets.R: ignore the user's R_BOX_PATH

test_that("box::use(pkg[fn]) at top level attaches 'mod:pkg' on the search path, not in .GlobalEnv or .packages()", {
  r <- callr::r(\() {
    eval(quote(box::use(dplyr[mutate])), globalenv())   # = top level of a script (inside a fn it would be local)
    list(search2 = search()[2], in_global = exists("mutate", globalenv(), inherits = FALSE), pkgs = .packages())
  }, env = no_tt)
  expect_equal(r$search2, "mod:dplyr")
  expect_false(r$in_global)
  expect_false("dplyr" %in% r$pkgs)   # so targets' default packages = (.packages()) does not ship it either
})

test_that("in a callr child (how tar_make() runs _targets.R) box resolves modules from the callr temp dir, not cwd", {
  try_use <- \(p, set_path) { setwd(p); if (set_path) options(box.path = getwd())   # cwd = project, which HAS mods/helpers.R
    tryCatch({ box::use(mods/helpers); "ok" }, error = \(e) conditionMessage(e)) }
  r <- callr::r(try_use, args = list(proj, FALSE), env = no_tt)
  expect_match(r, "unable to load module")
  expect_match(r, "Rtmp")
  expect_equal(callr::r(try_use, args = list(proj, TRUE), env = no_tt), "ok")   # fix: options(box.path = getwd())
})

run_variant <- function(variant, crew) {
  dir <- file.path(proj, "targets", variant); store <- file.path(dir, "_targets")
  unlink(store, recursive = TRUE); on.exit(unlink(store, recursive = TRUE))
  r <- processx::run(file.path(R.home("bin"), "Rscript"), c("-e", "targets::tar_make(reporter = 'silent')"), wd = dir,
                     error_on_status = FALSE, env = c("current", USE_CREW = tolower(crew), TESTTHAT = "false", R_BOX_PATH = ""))
  m <- targets::tar_meta(fields = error, store = store) |> dplyr::filter(name == "out")
  if (!nrow(m)) paste("`out` never ran:", r$stderr) else if (is.na(m$error)) "ok" else m$error
}

test_that("crew: box::use() at top of _targets.R does not reach workers; inside the function it does", {
  skip_if_not(Sys.getenv("RUN_TARGETS_TESTS") == "true", "set RUN_TARGETS_TESTS=true to run pipelines")
  expect_equal(run_variant("pkg_box_top", crew = FALSE), "ok")
  expect_match(run_variant("pkg_box_top", crew = TRUE), "could not find function .mutate.")
  expect_equal(run_variant("pkg_box_in_fn", crew = TRUE), "ok")
  expect_equal(run_variant("pkg_library_top", crew = TRUE), "ok")      # library() IS shipped via packages = (.packages())
  expect_equal(run_variant("pkg_box_top_rargs", crew = TRUE), "ok")    # same box::use run on each worker via r_arguments -e
})

test_that("crew: a module object (box::use(mods/x) at top) is shipped; attached module names and box.path are not", {
  skip_if_not(Sys.getenv("RUN_TARGETS_TESTS") == "true", "set RUN_TARGETS_TESTS=true to run pipelines")
  expect_equal(run_variant("mod_alias_top", crew = TRUE), "ok")
  expect_match(run_variant("mod_attach_top", crew = TRUE), "could not find function .add_x.")
  expect_match(run_variant("shared_option_in_fn", crew = TRUE), "unable to load module")
  expect_equal(run_variant("shared_envvar_in_fn", crew = TRUE), "ok")
})
