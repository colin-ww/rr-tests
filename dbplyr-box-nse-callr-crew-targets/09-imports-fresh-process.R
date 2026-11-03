# Part 9: package imports vs where targets run (main process, one reused crew worker, a fresh process per target).
# Questions: which import styles work in each, are per-file box::use() imports real or only documentation
# (does a file that forgot an import still work because another file imported it?), and does caching stay right.
# Writes one mini targets project per variant into targets/imp_<load>_<ctrl>/, with three files:
#   a.R imports dplyr[mutate] and uses mutate(); b.R uses mutate() WITHOUT importing it; c.R uses a package alias, stringr$str_length().
# Each target returns Sys.getpid(), so "processes" counts how many R processes the targets really ran in.
source("R/harness.R")                 # save_results()
suppressPackageStartupMessages(library(targets))
root <- file.path(getwd(), "targets")
T0 <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")   # fixed modification time, so undoing a change is exact

# ---- R/ files: imports at the top of each file, or inside each function ------------------------
TOP <- list(
  a.R = c("box::use(dplyr[mutate])", "fa <- function(d) mutate(d, a = 1, pid = Sys.getpid())"),
  b.R = c("# no imports here: mutate() is imported only by a.R", "fb <- function(d) mutate(d, b = 2, pid = Sys.getpid())"),
  c.R = c("box::use(stringr)", "fc <- function(d) { d$c <- stringr$str_length(\"abc\"); d$pid <- Sys.getpid(); d }")
)
IN_FN <- list(
  a.R = c("fa <- function(d) { box::use(dplyr[mutate]); mutate(d, a = 1, pid = Sys.getpid()) }"),
  b.R = TOP$b.R,
  c.R = c("fc <- function(d) { box::use(stringr); d$c <- stringr$str_length(\"abc\"); d$pid <- Sys.getpid(); d }")
)

# ---- how _targets.R loads them ------------------------------------------------------------------
ENVIR <- "tar_option_set(envir = new.env(parent = globalenv()))"
scoped <- \(keep) c(ENVIR,
  "source_scoped <- function(dir = \"R\", envir = tar_option_get(\"envir\")) {",
  "  for (f in list.files(dir, \"\\\\.[rR]$\", full.names = TRUE, recursive = TRUE)) {",
  "    file_env <- new.env(parent = envir)",
  sprintf("    sys.source(f, envir = file_env, keep.source = %s)", keep),
  "    list2env(as.list(file_env), envir)",
  "  }", "}", "source_scoped()")
LOAD <- list(
  global       = list(files = TOP,   code = "tar_source()"),                                       # issue #3's setup
  envir        = list(files = TOP,   code = c(ENVIR, "tar_source()")),                             # part 8's fix
  scoped       = list(files = TOP,   code = scoped("FALSE")),                                      # part 8's source_scoped()
  scoped_src   = list(files = TOP,   code = scoped("TRUE")),                                       # the same, keeping source info
  packages     = list(files = TOP,   code = c("tar_option_set(packages = c(\"dplyr\", \"stringr\"))", "tar_source()")),
  library      = list(files = TOP,   code = c("library(dplyr)", "library(stringr)", "tar_source()")),
  in_function  = list(files = IN_FN, code = "tar_source()")
)
CTRL <- list(
  none  = character(),
  reuse = "tar_option_set(controller = crew::crew_controller_local(workers = 1, seconds_idle = 10))",
  fresh = "tar_option_set(controller = crew::crew_controller_local(workers = 1, tasks_max = 1, seconds_idle = 10))"
)
TARGETS <- c("list(", "  tar_target(raw, data.frame(v = 1:2)),", "  tar_target(out_a, fa(raw)),",
             "  tar_target(out_b, fb(raw)),", "  tar_target(out_c, fc(raw))", ")")
OUT <- c("out_a", "out_b", "out_c")

# targets that would re-run, among those that built
outdated <- \(built) { o <- intersect(tar_outdated(), built); if (length(o)) paste(sort(sub("out_", "", o)), collapse = ",") else "-" }

run_one <- function(load, ctrl) {
  dir <- file.path(root, paste("imp", load, ctrl, sep = "_"))
  unlink(dir, recursive = TRUE); dir.create(file.path(dir, "R"), recursive = TRUE)
  files <- LOAD[[load]]$files
  for (f in names(files)) { writeLines(files[[f]], file.path(dir, "R", f)); Sys.setFileTime(file.path(dir, "R", f), T0) }
  writeLines(c("library(targets)", "tar_option_set(error = \"continue\")", CTRL[[ctrl]], LOAD[[load]]$code, TARGETS),
             file.path(dir, "_targets.R"))
  old <- setwd(dir); on.exit(setwd(old))
  try(tar_make(reporter = "silent"), silent = TRUE)
  m <- tar_meta(fields = c(error))
  status <- \(t) { e <- m$error[m$name == t]
    if (!length(e)) "not run" else if (!is.na(e)) paste("error:", e) else "works" }
  st <- vapply(OUT, status, "")
  built <- OUT[st == "works"]
  pids <- unlist(lapply(built, \(t) unique(tar_read_raw(t)$pid)))
  res <- tibble::tibble(load = load, ctrl = ctrl, a = st[["out_a"]], b_no_import = st[["out_b"]], c_alias = st[["out_c"]],
                        processes = length(unique(pids)))
  if ("out_c" %in% built) {                       # caching checks on c.R (the package alias), undoing each change
    c_file <- file.path("R", "c.R")
    res$rerun_2nd   <- outdated(built)
    Sys.setFileTime(c_file, T0 + 3600);                              res$touched <- outdated(built); Sys.setFileTime(c_file, T0)
    writeLines(c(files$c.R, "# a comment"), c_file); Sys.setFileTime(c_file, T0); res$comment <- outdated(built)
    writeLines(sub("\"abc\"", "\"abcd\"", files$c.R), c_file); Sys.setFileTime(c_file, T0); res$fc_edited <- outdated(built)
    writeLines(files$c.R, c_file); Sys.setFileTime(c_file, T0); res$undone <- outdated(built)
  }
  res
}

res <- do.call(rbind, lapply(names(LOAD), \(l) dplyr::bind_rows(lapply(names(CTRL), \(k) run_one(l, k)))))
save_results(res, "09-imports-fresh-process.csv")
print(res, n = Inf, width = Inf)
