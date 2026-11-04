# Part 10: three checks behind the ranked recommendation (docs/10-recommendation.md), not covered by parts 8-9:
#   1. source_scoped(): what a file that forgot an import gets, when base R has a function of the same name (stats::filter)
#   2. switching loaders (tar_source() <-> envir line <-> source_scoped()) on a built pipeline: does anything re-run?
#   3. tar_load_globals() with source_scoped(): where do the functions land, and does attach() fix it?
# One mini project in targets/scoped_checks/. Writes results/10-source-scoped-checks.csv. ~30 s.
source("R/harness.R")                 # save_results()
suppressPackageStartupMessages(library(targets))
dir <- file.path(getwd(), "targets", "scoped_checks")
unlink(dir, recursive = TRUE); dir.create(file.path(dir, "R"), recursive = TRUE)

ENVIR  <- "tar_option_set(envir = new.env(parent = globalenv()))"
LOADS  <- list(
  tar_source    = "tar_source()",
  envir         = c(ENVIR, "tar_source()"),
  source_scoped = c(ENVIR, readLines("R/source_scoped.R"), "source_scoped()")
)
TARGETS <- "list(tar_target(raw, data.frame(v = 1:3)), tar_target(out_a, fa(raw)), tar_target(out_b, fb(raw)), tar_target(out_c, fc(raw)))"
write_r <- \(b, c) {
  writeLines(c("box::use(dplyr[filter, mutate])", "fa <- function(d) filter(d, v > 1)"), file.path(dir, "R/a.R"))
  writeLines(c(b, "fb <- function(d) filter(d, v > 1)"), file.path(dir, "R/b.R"))
  writeLines(c(c, "fc <- function(d) mutate(d, w = 1)"), file.path(dir, "R/c.R"))
}
write_targets <- \(load) writeLines(c("library(targets)", "tar_option_set(error = \"continue\")", LOADS[[load]], TARGETS), file.path(dir, "_targets.R"))
old <- setwd(dir)

## 1. forgotten imports under source_scoped()
write_r(b = "# forgot dplyr[filter]: stats::filter is on the search path", c = "# forgot dplyr[mutate]: nothing else has a mutate()")
write_targets("source_scoped")
try(tar_make(reporter = "silent"), silent = TRUE)
m <- tar_meta(fields = error)
res1 <- tibble::tibble(
  check  = "forgotten import, source_scoped()",
  case   = c("a.R imports dplyr[filter]", "b.R forgot dplyr[filter]", "c.R forgot dplyr[mutate]"),
  result = vapply(c("out_a", "out_b", "out_c"), \(t) { e <- m$error[m$name == t]; if (is.na(e)) "works" else paste("error:", e) }, "")
)

## 2. switch loaders on a built pipeline, then tar_outdated()
write_r(b = "box::use(dplyr[filter])", c = "box::use(dplyr[mutate])")
res2 <- dplyr::bind_rows(lapply(names(LOADS), \(from) dplyr::bind_rows(lapply(setdiff(names(LOADS), from), \(to) {
  tar_destroy(ask = FALSE); write_targets(from); tar_make(reporter = "silent")
  write_targets(to)
  o <- tar_outdated()
  tibble::tibble(check = "switch loaders: re-runs?", case = paste(from, "->", to), result = if (length(o)) paste(sort(o), collapse = ", ") else "nothing")
}))))

## 3. tar_load_globals() with source_scoped(), in a fresh R
write_targets("source_scoped")
g <- callr::r(\(d) {
  setwd(d); targets::tar_load_globals()
  before <- exists("fa", envir = globalenv())
  attach(targets::tar_option_get("envir"), name = "pipeline")
  c(before = before, after = exists("fa") && nrow(fa(data.frame(v = 1:3))) == 2)
}, args = list(dir))
res3 <- tibble::tibble(
  check  = "tar_load_globals(), source_scoped()",
  case   = c("fa() visible in the session", "after attach(tar_option_get(\"envir\"), name = \"pipeline\")"),
  result = ifelse(g, "yes", "no")
)

setwd(old)
res <- dplyr::bind_rows(res1, res2, res3)
save_results(res, "10-source-scoped-checks.csv")
print(res, n = Inf, width = Inf)
