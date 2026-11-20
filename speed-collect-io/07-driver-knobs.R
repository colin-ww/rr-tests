# Part 7: other things that change collect() speed or memory, without touching the data:
#  a. driver buffer sizes:
#     Oracle ODBC  FBS=<bytes>        in the connection string: fetch buffer size (default 64000)
#     SQL Server   PacketSize=<bytes> in the connection string: network packet size (default 4096, max 32767)
#     ROracle      dbConnect(bulk_read = <rows>, prefetch = TRUE/FALSE): rows per fetch (default 1000)
#  b. fetching in chunks (dbSendQuery + dbFetch(n)) instead of all at once
#  c. streaming chunks straight to a parquet file, so the whole table is never in R's memory
#  d. 4 connections in parallel, each pulling a quarter of the rows (by id range)
#  e. Oracle text: NLS_LANG unset (text converted to ASCII, accents lost) vs AL32UTF8
#  f. R's garbage collector at start-up (env vars read when R starts): the first big collect() in a
#     fresh process spends a lot of time in GC while R's heap grows. R_GC_MEM_GROW=3 grows it faster;
#     R_NSIZE / R_VSIZE set the starting GC triggers (not memory reserved up front). Look at first_s.
# BENCH_PARTS = "a,b,e,f" (b = b-d) runs only those parts, BENCH_CASE = regex on the setting/case name.
# Re-run rows replace the matching rows of an existing results/07-driver-knobs.csv.
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)
want <- \(p) p %in% strsplit(Sys.getenv("BENCH_PARTS", "a,b,e,f"), ",")[[1]]
case_ok <- \(x) grepl(Sys.getenv("BENCH_CASE", ""), x)

collect_tbl <- \(con, name, ...) tbl(con, name) |> collect()
# a and e on 1e6-row tables (time is linear in rows, see 03); b-d and f on 1e7 rows, where memory matters
tables <- c(tbl_name("int_rand", 1e6), tbl_name("dbl", 1e6), tbl_name("chr20_hi", 1e6), "bm_mix_1e6")
knobs <- dplyr::bind_rows(
  tibble(engine = "oracle", setting = c("(default)", paste0("FBS=", c(262144, 1048576, 4194304, 16777216), ";"))),
  tibble(engine = "mssql", setting = c("(default)", "PacketSize=8192;", "PacketSize=32767;")),
  tibble(engine = "roracle", setting = c("(default)", "bulk_read = 10000L", "bulk_read = 100000L", "prefetch = TRUE"))) |>
  mutate(extra = if_else(engine != "roracle" & setting != "(default)", setting, ""),
         con_args = purrr::map2(engine, setting, \(e, st) if (e == "roracle" && st != "(default)")
           eval(str2lang(paste0("list(", st, ")"))) else list())) |>
  filter(engine %in% engines(), want("a"), case_ok(setting))
res_a <- tidyr::expand_grid(knobs, table = tables) |>
  purrr::pmap(\(engine, setting, extra, con_args, table) run_case(engine, collect_tbl, list(name = table), extra = extra, con_args = con_args,
                                                              iterations = 3, part = "a. buffer size", table = table, setting = setting)) |>
  purrr::list_rbind()

# --- b/c/d on bm_mix_1e7 ---
fetch_chunks <- \(con, name, n, ...) {
  rs <- DBI::dbSendQuery(con, paste("SELECT * FROM", DBI::dbQuoteIdentifier(con, name))); on.exit(DBI::dbClearResult(rs))
  out <- list(); while (!DBI::dbHasCompleted(rs)) out[[length(out) + 1]] <- DBI::dbFetch(rs, n = n)
  bind_rows(out)
}
# write each chunk to one parquet file as it arrives; returns the file size (MB). No full copy in R.
stream_parquet <- \(con, name, n, file, ...) {
  rs <- DBI::dbSendQuery(con, paste("SELECT * FROM", DBI::dbQuoteIdentifier(con, name))); on.exit(DBI::dbClearResult(rs))
  w <- NULL
  while (!DBI::dbHasCompleted(rs)) {
    tab <- arrow::arrow_table(DBI::dbFetch(rs, n = n))
    if (is.null(w)) {   # NB arrow 26: the default `properties =` errors (column_names missing), so pass it
      sink <- arrow::FileOutputStream$create(file)
      w <- arrow::ParquetFileWriter$create(tab$schema, sink, properties = arrow::ParquetWriterProperties$create(names(tab)))
    }
    w$WriteTable(tab, chunk_size = n)
  }
  w$Close(); sink$close(); file.size(file) / 1e6
}
collect_write <- \(con, name, file, ...) { d <- tbl(con, name) |> collect(); arrow::write_parquet(d, file); file.size(file) / 1e6 }
# d. 4 background R processes, each with its own connection, each writes one parquet part (nothing sent back)
parallel_parts <- \(con, name, file, engine, workers = 4, rows = 1e7, ...) {
  part <- \(wd, engine, name, lo, hi, file) {
    setwd(wd); suppressPackageStartupMessages(library(dplyr)); source("R/connect.R")
    con <- bench_con(engine); on.exit(DBI::dbDisconnect(con))
    d <- tbl(con, name) |> filter(id > lo, id <= hi) |> collect(); arrow::write_parquet(d, file); nrow(d)
  }
  cuts <- round(seq(0, rows, length.out = workers + 1))
  ps <- purrr::map(seq_len(workers), \(w) callr::r_bg(part, list(getwd(), engine, name, cuts[w], cuts[w + 1], sub("\\.parquet$", paste0("-", w, ".parquet"), file))))
  purrr::walk(ps, \(p) p$wait()); n <- sum(purrr::map_int(ps, \(p) p$get_result()))
  stopifnot(n == rows); sum(file.size(sub("\\.parquet$", paste0("-", seq_len(workers), ".parquet"), file))) / 1e6
}
pq <- file.path(fs::dir_create(file.path(bench_dir(), "io")), "stream.parquet")
cases <- list(
  "collect() all at once"                      = list(fn = collect_tbl, args = list()),
  "dbFetch(n = 1e5) chunks + bind_rows()"      = list(fn = fetch_chunks, args = list(n = 1e5)),
  "dbFetch(n = 1e6) chunks + bind_rows()"      = list(fn = fetch_chunks, args = list(n = 1e6)),
  "collect() then arrow::write_parquet()"      = list(fn = collect_write, args = list(file = pq)),
  "stream 1e6-row chunks into one parquet file" = list(fn = stream_parquet, args = list(n = 1e6, file = pq)),
  "4 parallel connections, 1 parquet part each (incl. R start-up)" = list(fn = parallel_parts, args = list(file = pq)))
res_bcd <- tidyr::expand_grid(engine = engines(), case = names(cases)) |>
  filter(!(engine == "duckdb" & startsWith(case, "4 parallel")), want("b"), case_ok(case)) |>   # a duckdb file: one process at a time
  purrr::pmap(\(engine, case) run_case(engine, cases[[case]]$fn, c(list(name = "bm_mix_1e7", engine = engine), cases[[case]]$args),
                                       pkgs = "arrow", iterations = 2, part = "b-d. chunks, streaming, parallel", table = "bm_mix_1e7", setting = case)) |>
  purrr::list_rbind()
unlink(list.files(dirname(pq), "^stream.*parquet$", full.names = TRUE))

res_e <- tidyr::expand_grid(engine = intersect(engines(), c("oracle", "roracle")), nls = c("", "AMERICAN_AMERICA.AL32UTF8"),
                            table = c(tbl_name("chr20_hi", 1e6), "bm_mix_1e6")) |>
  filter(want("e"), case_ok(nls)) |>
  purrr::pmap(\(engine, nls, table) run_case(engine, collect_tbl, list(name = table), env = c(NLS_LANG = nls), iterations = 3,
                                            part = "e. Oracle NLS_LANG", table = table, setting = paste0("NLS_LANG=", if (nls == "") "(unset)" else nls))) |>
  purrr::list_rbind()
gc_env <- list("(default)" = character(), "R_GC_MEM_GROW=3" = c(R_GC_MEM_GROW = "3"),
               "R_NSIZE=2e7, R_VSIZE=4G" = c(R_NSIZE = "20000000", R_VSIZE = "4G"))
res_f <- tidyr::expand_grid(engine = engines(), setting = names(gc_env), table = c(tbl_name("chr20_hi", 1e7), "bm_mix_1e7")) |>
  filter(want("f"), case_ok(setting)) |>
  purrr::pmap(\(engine, setting, table) run_case(engine, collect_tbl, list(name = table), env = gc_env[[setting]], iterations = 1,
                                                part = "f. R GC start-up settings", table = table, setting = setting)) |>
  purrr::list_rbind()
new <- bind_rows(res_a, res_bcd, res_e, res_f)
old <- if (file.exists("results/07-driver-knobs.csv")) readr::read_csv("results/07-driver-knobs.csv", show_col_types = FALSE) |>
  anti_join(new, by = c("engine", "part", "table", "setting"))
bind_rows(old, new) |> save_results("07-driver-knobs.csv")
