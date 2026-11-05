#### 02-bench.R  -  time every (backend, task) at one data size, each in a fresh R process ####
# Usage (from this folder):
#   Rscript 02-bench.R 1e5            # small: ~5 min
#   Rscript 02-bench.R 1e6            # medium
#   Rscript 02-bench.R 1e7            # full (~1 GB of data in RAM); skips combos that took > 30 s at 1e6 (-> > 5 min)
# Env vars: BENCH_REPS (3), BENCH_BUDGET (s per combo before it stops repeating, 30), BENCH_TIMEOUT (s, 900),
#           BENCH_THREADS (all cores), BENCH_BACKENDS / BENCH_TASKS (comma lists, default all), BENCH_DATA (data/)
# Output: results/bench_n<n>.csv (one row per combo, appended as it goes; reruns replace matching rows)

source("R/data.R"); source("R/backends.R"); source("R/tasks.R")
Sys.setenv(BENCH_DATA = Sys.getenv("BENCH_DATA", normalizePath("data", mustWork = FALSE)))

args <- commandArgs(TRUE)
n <- as.numeric(if (length(args)) args[1] else 1e5)
env_list <- \(var, all) { v <- Sys.getenv(var); if (nzchar(v)) intersect(all, strsplit(v, ",")[[1]]) else all }
bks   <- env_list("BENCH_BACKENDS", BACKENDS)
tasks <- env_list("BENCH_TASKS", names(TASKS))
reps    <- as.integer(Sys.getenv("BENCH_REPS", 3))
budget  <- as.numeric(Sys.getenv("BENCH_BUDGET", 30))
timeout <- as.numeric(Sys.getenv("BENCH_TIMEOUT", 900))
out_file <- sprintf("results/bench_n%s.csv", format(n, scientific = FALSE))

# combos that were slow one size down are skipped (10x data -> > 5 min); dplyr itself always runs (reference)
prev <- sprintf("results/bench_n%s.csv", format(n / 10, scientific = FALSE))
slow <- if (n >= 1e7 && file.exists(prev)) readr::read_csv(prev, show_col_types = FALSE) |> filter(backend != "dplyr", secs > 30 | status == "timeout") else tibble(backend = character(), task = character())

cat(sprintf("n = %s units | %d backends x %d tasks | threads = %d | data: %s\n", format(n, big.mark = ","), length(bks), length(tasks), threads(), ensure_data(n)))
cat(sprintf("data in RAM: %s MB\n", data_mb(load_data(n))))

one <- function(bk, task) {
  if (any(slow$backend == bk & slow$task == task)) {
    return(tibble(backend = bk, kind = backend_kind(bk), task = task, n = n, threads = threads(), status = "skipped",
                  note = sprintf("took > 30 s or timed out at n = %s", format(n / 10, scientific = FALSE))))
  }
  r <- tryCatch(
    callr::r(\(bk, task, n, reps, budget, root) { source(file.path(root, "R", "run_one.R")); run_one(bk, task, n, reps, budget, root) },
             args = list(bk, task, n, reps, budget, getwd()), timeout = timeout, env = c(callr::rcmd_safe_env(), BENCH_DATA = Sys.getenv("BENCH_DATA"), BENCH_THREADS = threads(),
                         if (nzchar(Sys.getenv("BENCH_STYLE"))) c(BENCH_STYLE = Sys.getenv("BENCH_STYLE")))),
    error = \(e) list(backend = bk, kind = backend_kind(bk), task = task, n = n, threads = threads(),
                      status = if (inherits(e, "callr_timeout_error")) "timeout" else "crash",
                      note = substr(gsub("\\s+", " ", conditionMessage(e)), 1, 300))
  )
  tibble::as_tibble(r)
}

res <- if (file.exists(out_file)) readr::read_csv(out_file, show_col_types = FALSE, col_types = readr::cols(.default = "c")) else NULL
for (task in tasks) for (bk in c("dplyr", setdiff(bks, "dplyr"))) {     # dplyr first: it writes the reference result
  if (bk == "dplyr" && !"dplyr" %in% bks && file.exists(file.path(Sys.getenv("BENCH_DATA"), sprintf("ref_n%s_%s.qs2", format(n, scientific = FALSE), task)))) next
  r <- one(bk, task)
  cat(sprintf("  %-15s %-15s %-14s %8s s  conv %6s s  peak %6s MB  %s\n", task, bk, r$status,
              if (is.null(r$secs) || is.na(r$secs)) "-" else format(round(r$secs, 2), nsmall = 2),
              if (is.null(r$convert_s) || is.na(r$convert_s)) "-" else round(r$convert_s, 2),
              if (is.null(r$peak_mb) || is.na(r$peak_mb)) "-" else r$peak_mb,
              if (is.null(r$note) || is.na(r$note)) "" else substr(r$note, 1, 90)))
  r <- mutate(r, across(everything(), as.character))
  res <- bind_rows(if (!is.null(res)) filter(res, !(backend == bk & task == !!task & threads == r$threads)), r)
  readr::write_csv(res, out_file)
}
cat("wrote", out_file, "\n")
