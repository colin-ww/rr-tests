# Part 1: does the measuring method change the numbers?
#  a. one R process for everything vs a fresh process per case: is call 1 slower? does a big
#     object still alive (or freed) change the next collect? (R's heap and global string cache)
#  b. bench::mark() defaults on a seconds-long collect: memory = TRUE overhead, filter_gc
#  c. odbc's `interruptible` (TRUE in RStudio, FALSE in Rscript): does it slow collect down?
#  d. collect() vs DBI::dbGetQuery(): does dbplyr add anything?
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

# --- a. same process, in sequence ---
seq_child <- function(wd, engine, small, big) {
  setwd(wd); suppressPackageStartupMessages(library(dplyr))
  for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)
  con <- bench_con(engine)
  t1 <- \() { gc(); t0 <- bench::hires_time(); x <- collect(tbl(con, small)); secs_since(t0) }
  tn <- \(n = 5) replicate(n, t1())
  first <- t1(); warm <- tn()
  b <- collect(tbl(con, big)); alive <- tn()
  rm(b); gc(); freed <- tn()
  DBI::dbDisconnect(con)
  tibble::tibble(phase = c("1. first call in a fresh process", "2. calls 2-6", "3. while a 10x bigger result is still in memory",
                           "4. after rm() + gc() of that result"),
                 med_s = c(first, median(warm), median(alive), median(freed)),
                 min_s = c(first, min(warm), min(alive), min(freed)), max_s = c(first, max(warm), max(alive), max(freed)))
}
seq_res <- tidyr::expand_grid(engine = engines(), type = c("chr20_hi", "dbl")) |>
  purrr::pmap(\(engine, type) callr::r(seq_child, list(getwd(), engine, tbl_name(type, 1e6), tbl_name(type, 1e7))) |>
                mutate(engine = engine, small = tbl_name(type, 1e6), big = tbl_name(type, 1e7), .before = 1)) |>
  purrr::list_rbind()
print(seq_res, n = Inf)

# --- b. bench::mark() as most people would call it, vs with memory = FALSE ---
mark_child <- function(wd, engine, name, memory, filter_gc) {
  setwd(wd); suppressPackageStartupMessages(library(dplyr)); source("R/connect.R")
  con <- bench_con(engine); collect(tbl(con, name))   # warm-up
  w <- character(); t0 <- Sys.time()
  bm <- withCallingHandlers(
    bench::mark(collect(tbl(con, name)), iterations = 5, check = FALSE, memory = memory, filter_gc = filter_gc),
    warning = \(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })
  wall <- as.numeric(difftime(Sys.time(), t0, units = "secs")); DBI::dbDisconnect(con)
  tibble::tibble(wall_s = wall, median_s = as.numeric(bm$median), mem_alloc_mb = as.numeric(bm$mem_alloc) / 1e6, n_itr = bm$n_itr,
                 n_gc = bm$n_gc, warning = paste(w, collapse = " | "))
}
mark_res <- tidyr::expand_grid(engine = engines(), type = c("chr20_hi", "dbl"),
                               setting = c("defaults (memory = TRUE, filter_gc = TRUE)", "memory = FALSE, filter_gc = FALSE")) |>
  purrr::pmap(\(engine, type, setting) callr::r(mark_child, list(getwd(), engine, tbl_name(type, 1e6),
                                                                 memory = startsWith(setting, "defaults"), filter_gc = startsWith(setting, "defaults"))) |>
                mutate(engine = engine, table = tbl_name(type, 1e6), setting = setting, .before = 1)) |>
  purrr::list_rbind()
print(mark_res, n = Inf)

# --- c + d. via run_case (fresh process each) ---
collect_tbl <- \(con, name) tbl(con, name) |> collect()
get_query <- \(con, name) DBI::dbGetQuery(con, paste("SELECT * FROM", DBI::dbQuoteIdentifier(con, name)))
cd_res <- tidyr::expand_grid(engine = engines(), type = c("chr20_hi", "dbl"), rows = c(1e6, 1e7),
                             how = c("collect()", "collect(), interruptible = TRUE", "DBI::dbGetQuery()")) |>
  filter(!(engine %in% c("duckdb", "roracle") & grepl("interruptible", how))) |>   # odbc-only setting
  purrr::pmap(\(engine, type, rows, how) run_case(engine, if (startsWith(how, "DBI")) get_query else collect_tbl,
    list(name = tbl_name(type, rows)), con_args = if (grepl("interruptible", how)) list(interruptible = TRUE) else list(),
    iterations = 3, type = type, rows = rows, how = how)) |>
  purrr::list_rbind()

bind_rows(seq_res |> mutate(part = "a. sequence in one process"),
          mark_res |> mutate(part = "b. bench::mark settings"),
          cd_res |> mutate(part = "c/d. interruptible, collect vs dbGetQuery")) |>
  relocate(part) |> save_results("01-method.csv")
