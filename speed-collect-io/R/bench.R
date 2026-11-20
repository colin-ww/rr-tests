# run_case(): time fn(con, ...) in a FRESH R process (callr), so earlier cases can't leave a big
# heap, a warm string cache or loaded packages behind. In that process:
#   1. connect and run `setup` (not timed). setup(con, ...) returns `data`, passed on to fn as `data =`.
#   2. call fn once: first_s = first call in a fresh process (first_gc_s = R's GC time in it) (includes driver/plan warm-up and, if
#      the table isn't cached, the database's disk reads). peak_mb = how much the process's peak
#      RSS grew during that call (Linux: /proc/self/status VmHWM, reset via /proc/self/clear_refs).
#      Measured on the first call only: R keeps freed memory for reuse, so later calls barely grow it.
#   3. `iterations` more calls, gc() + before() before each (not timed), result dropped after each:
#      med_s / min_s / max_s. gc_s = median R garbage-collection time inside the timed call.
#   obj_mb = size of the result in R (lobstr::obj_size).
# Timer: bench::hires_time(). Why not bench::mark() for these: see docs/00-method.md.
# engine = "none": no connection (con = NULL), for in-R and file IO cases.

rss_mb <- \(field = "VmRSS") {
  l <- tryCatch(readLines("/proc/self/status"), error = \(e) character())
  v <- grep(paste0("^", field, ":"), l, value = TRUE)
  if (length(v)) as.numeric(gsub("\\D", "", v)) / 1024 else NA_real_
}
reset_peak <- \() tryCatch({ writeLines("5", "/proc/self/clear_refs"); TRUE }, error = \(e) FALSE, warning = \(w) FALSE)
secs_since <- \(t0) as.numeric(bench::hires_time() - t0)

case_child <- function(wd, engine, fn, args, iterations, extra, pkgs, setup, before, con_args, globals) {
  setwd(wd)
  suppressPackageStartupMessages(for (p in c("dplyr", "dbplyr", pkgs)) library(p, character.only = TRUE))
  for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)
  con <- if (engine != "none") do.call(bench_con, c(list(engine, extra = extra), con_args))
  on.exit(if (!is.null(con)) DBI::dbDisconnect(con))
  for (f in c("fn", "setup", "before")) if (is.function(get(f))) assign(f, `environment<-`(get(f), globalenv()))
  for (g in names(globals)) assign(g, if (is.function(globals[[g]])) `environment<-`(globals[[g]], globalenv()) else globals[[g]], globalenv())
  if (is.function(setup)) args$data <- do.call(setup, c(list(con), args))
  call <- \() do.call(fn, c(list(con), args))
  prep <- \() { if (is.function(before)) do.call(before, c(list(con), args)); gc() }

  prep(); base <- rss_mb(); peak_ok <- reset_peak()
  g0 <- gc.time()[1]; t0 <- bench::hires_time(); out <- call(); first <- secs_since(t0); first_gc <- gc.time()[1] - g0
  peak <- if (peak_ok) rss_mb("VmHWM") - base else NA_real_
  obj_mb <- as.numeric(lobstr::obj_size(out)) / 1e6
  dims <- if (is.data.frame(out)) dim(out) else c(NA, NA)
  rm(out)
  tm <- purrr::map(seq_len(iterations), \(k) {
    prep(); g0 <- gc.time()[1]; t0 <- bench::hires_time()
    x <- call(); c(t = secs_since(t0), gc = gc.time()[1] - g0)
  }) |> purrr::reduce(rbind) |> matrix(ncol = 2, dimnames = list(NULL, c("t", "gc")))
  tibble::tibble(first_s = first, first_gc_s = first_gc, med_s = median(tm[, "t"]), min_s = min(tm[, "t"]), max_s = max(tm[, "t"]),
                 gc_s = median(tm[, "gc"]), iterations = iterations, nrow = dims[1], ncol = dims[2],
                 obj_mb = obj_mb, peak_mb = peak)
}

# fn: function(con, ...) returning the thing to time. Self-contained apart from dplyr/dbplyr,
# the helpers in R/, packages in `pkgs`, and `args` (named list passed to fn, setup and before).
# extra / con_args: appended to the connection string / passed to dbConnect().
# globals: named list of helper objects/functions fn needs, put in the child's global env.
# env: environment variables to set in the child (e.g. c(NLS_LANG = "")).
# `...` = label columns for the result row (case = "...", rows = 1e6, ...).
run_case <- function(engine, fn, args = list(), iterations = 3, extra = "", pkgs = character(),
                     setup = NULL, before = NULL, con_args = list(), globals = list(), env = character(), timeout = 3600, ...) {
  t0 <- Sys.time()
  res <- tryCatch(
    callr::r(case_child, args = list(getwd(), engine, fn, args, iterations, extra, pkgs, setup, before, con_args, globals), timeout = timeout,
             env = c(callr::rcmd_safe_env(), env)),
    error = \(e) tibble::tibble(error = conditionMessage(e$parent %||% e) |> cli::ansi_strip() |> squish() |> substr(1, 300)))
  res <- tibble::tibble(engine = engine, ..., res)
  message(sprintf("%-6s %-50s %s  (%.0fs wall)", engine, paste(unlist(list(...)), collapse = " "),
                  if ("med_s" %in% names(res)) sprintf("med %.3fs  first %.3fs  peak %.0fMB", res$med_s, res$first_s, res$peak_mb)
                  else paste("ERROR", res$error),
                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  res
}

squish <- \(x) gsub("\\s+", " ", x) |> trimws()
# one CSV per script; bind_rows keeps an `error` column only when something failed
save_results <- \(res, file) { fs::dir_create("results"); readr::write_csv(res, file.path("results", file)); invisible(res) }
