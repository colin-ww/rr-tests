# Part 10: checks behind the ranked recommendation (docs/10-recommendation.md), not covered by parts 8-9:
#   1. source_scoped(): what a file that forgot an import gets, when base R has a function of the same name (stats::filter)
#   2. switching loaders (tar_source() <-> envir line <-> source_scoped()) on a built pipeline: does anything re-run?
#   3. tar_load_globals() with source_scoped(): where do the functions land, and does attach() fix it?
#   4. calling your own function at the top level of _targets.R (eg a startup check), for each loader
#   5. own box modules imported inside a source_scoped() file: which copy runs, and does editing the module re-run targets?
#   6. a dot-named helper (.helper) with source_scoped(): tracked by targets with all.names = TRUE vs FALSE?
#   7. box aliases (box::use(stringr), then stringr$fn()) with source_scoped(): per file or shared? with and without crew
# Mini projects in targets/scoped_checks/, scoped_modules/, scoped_dotnames/, scoped_alias_<ctrl>/. Writes results/10-source-scoped-checks.csv. ~1 min.
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

## 4. own function called at the top level of _targets.R (load time, main process)
TOP <- list(
  tar_source                 = c(LOADS$tar_source,    "stopifnot(is.function(fa))"),
  envir                      = c(LOADS$envir,         "stopifnot(is.function(fa))"),
  source_scoped              = c(LOADS$source_scoped, "stopifnot(is.function(fa))"),
  `source_scoped, e$fa`      = c(head(LOADS$source_scoped, -1), "e <- source_scoped()", "stopifnot(is.function(e$fa))")
)
res4 <- dplyr::bind_rows(lapply(names(TOP), \(v) {
  writeLines(c("library(targets)", TOP[[v]], TARGETS), "_targets.R")
  r <- tryCatch({ tar_make(reporter = "silent"); "works" }, error = \(e) {
    m <- regmatches(conditionMessage(e), regexpr("object '[^']+' not found|could not find function \"[^\"]+\"", conditionMessage(e)))
    paste("error:", if (length(m)) m else "other") })
  tibble::tibble(check = "own function at top level of _targets.R", case = v, result = r)
}))

## 5. own box modules imported inside a source_scoped() file
# a.R defines fa(). b.R imports it as an attached name, c.R as a module alias. Both files are also in the pipeline env.
mod_dir <- file.path(dirname(dir), "scoped_modules")
unlink(mod_dir, recursive = TRUE); dir.create(file.path(mod_dir, "R"), recursive = TRUE)
A <- "fa <- function(d) { d$a <- 1; d }"
writeLines(A, file.path(mod_dir, "R/a.R"))
writeLines(c("box::use(R/a[fa])", "fb <- function(d) fa(d)"), file.path(mod_dir, "R/b.R"))
writeLines(c("box::use(am = R/a)", "fc <- function(d) am$fa(d)"), file.path(mod_dir, "R/c.R"))
writeLines(c("library(targets)", "options(box.path = getwd())", LOADS$source_scoped,
             "list(tar_target(raw, data.frame(v = 1:3)), tar_target(out_b, fb(raw)), tar_target(out_c, fc(raw)))"),
           file.path(mod_dir, "_targets.R"))
setwd(mod_dir)
tar_make(reporter = "silent")
own_copy <- callr::r(\(d, helper) {               # does fb() call the pipeline's fa(), or the module's copy?
  setwd(d); options(box.path = d); source(helper)
  e <- source_scoped(list.files("R", full.names = TRUE), envir = new.env(parent = globalenv()))
  identical(get("fa", envir = environment(e$fb)), e$fa)
}, args = list(mod_dir, file.path(old, "R", "source_scoped.R")))
writeLines(sub("<- 1", "<- 2", A, fixed = TRUE), "R/a.R")   # edit fa(): a = 1 -> 2
o <- tar_outdated(); tar_make(reporter = "silent")
now <- \(t) if (tar_read_raw(t)$a[1] == 2) "2 (current)" else "1 (stale)"
res5 <- tibble::tibble(
  check  = "own module imported in a source_scoped() file",
  case   = c("b.R: box::use(R/a[fa]), fa(): which fa() runs", "b.R: fa() edited -> re-runs out_b?", "c.R: box::use(am = R/a), am$fa(): fa() edited -> re-runs out_c?"),
  result = c(if (own_copy) "the pipeline's copy" else "box's own copy of a.R (not the pipeline's)",
             paste0(if ("out_b" %in% o) "yes" else "no", "; value after tar_make(): ", now("out_b")),
             paste0(if ("out_c" %in% o) "yes" else "no", "; value after tar_make(): ", now("out_c")))
)

## 6. dot-named helper, source_scoped() with all.names = TRUE vs FALSE: edit .helper(), re-run?
dot_dir <- file.path(dirname(dir), "scoped_dotnames")
H <- c(".helper <- function(x) x + 1", "fa <- function(d) { d$a <- .helper(1); d }")
res6 <- dplyr::bind_rows(lapply(c(TRUE, FALSE), \(an) {
  setwd(old); unlink(dot_dir, recursive = TRUE); dir.create(file.path(dot_dir, "R"), recursive = TRUE)
  writeLines(H, file.path(dot_dir, "R/a.R"))
  writeLines(c("library(targets)", sub("all.names = TRUE", paste("all.names =", an), LOADS$source_scoped, fixed = TRUE),
               "list(tar_target(raw, data.frame(v = 1:3)), tar_target(out_a, fa(raw)))"), file.path(dot_dir, "_targets.R"))
  setwd(dot_dir); tar_make(reporter = "silent")
  writeLines(sub("x + 1", "x + 2", H, fixed = TRUE), "R/a.R")  # edit .helper()
  o <- tar_outdated(); tar_make(reporter = "silent")
  tibble::tibble(check = "dot-named helper, .helper() edited", case = paste0("source_scoped(), all.names = ", an),
                 result = paste0(if ("out_a" %in% o) "re-runs out_a" else "nothing re-runs",
                                 "; value after tar_make(): ", if (tar_read(out_a)$a[1] == 3) "3 (current)" else "2 (stale)"))
}))

## 7. box aliases: a.R has box::use(stringr), b.R uses stringr$ without importing it. no controller vs crew
res7 <- dplyr::bind_rows(lapply(c("none", "crew"), \(ctrl) {
  setwd(old); al_dir <- file.path(dirname(dir), paste0("scoped_alias_", ctrl))
  unlink(al_dir, recursive = TRUE); dir.create(file.path(al_dir, "R"), recursive = TRUE)
  writeLines(c("box::use(stringr, dplyr[mutate])", "fa <- function(d) { d <- mutate(d, w = 1); d$len <- stringr$str_length(\"abc\"); d }"), file.path(al_dir, "R/a.R"))
  writeLines(c("# forgot box::use(stringr): a.R's alias", "fb <- function(d) { d$len <- stringr$str_length(\"abc\"); d }"), file.path(al_dir, "R/b.R"))
  writeLines(c("library(targets)", "tar_option_set(error = \"continue\")",
               if (ctrl == "crew") "tar_option_set(controller = crew::crew_controller_local(workers = 1, seconds_idle = 10))",
               LOADS$source_scoped, "list(tar_target(raw, data.frame(v = 1:2)), tar_target(out_a, fa(raw)), tar_target(out_b, fb(raw)))"),
             file.path(al_dir, "_targets.R"))
  setwd(al_dir); try(tar_make(reporter = "silent"), silent = TRUE)
  m <- tar_meta(fields = error)
  st <- \(t) { e <- m$error[m$name == t]; if (!length(e)) "not run" else if (is.na(e)) "works" else paste("error:", e) }
  tibble::tibble(check = "box alias, source_scoped()", case = paste0(c("a.R: its own alias + attached import", "b.R: uses a.R's alias"), ", controller: ", ctrl),
                 result = c(st("out_a"), st("out_b")))
}))

setwd(old)
res <- dplyr::bind_rows(res1, res2, res3, res4, res5, res6, res7)
save_results(res, "10-source-scoped-checks.csv")
print(res, n = Inf, width = Inf)
