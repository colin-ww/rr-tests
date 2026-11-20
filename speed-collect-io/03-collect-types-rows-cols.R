# Part 3: how long does collect() take, by column type x rows x number of columns?
# Every case = `tbl(con, "bm_<type>_<rows>_<k>") |> collect()` in a fresh R process (R/bench.R).
# Also records what R class each database type arrives as (results/03-r-types.csv).
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

collect_tbl <- \(con, name) tbl(con, name) |> collect()
iters <- \(cells) if (cells <= 1e6) 5 else if (cells <= 1e7) 3 else 2

# --- which R class does each type become? (5 rows, no timing) ---
r_types <- purrr::map(engines(), \(en) {
  con <- bench_con(en); on.exit(DBI::dbDisconnect(con))
  purrr::map(col_types$type[purrr::map_lgl(col_types$type, \(t) has_type(en, t))], \(ty) {
    x <- tryCatch(collect_tbl(con, tbl_name(ty, 1e5))$x1[1:3], error = \(e) e)
    rs <- DBI::dbSendQuery(con, paste("SELECT * FROM", qi(en, tbl_name(ty, 1e5)), "WHERE 1 = 0"))
    info <- DBI::dbColumnInfo(rs); DBI::dbClearResult(rs)
    tibble(engine = en, type = ty, db_type = info[[intersect(c("field.type", "type"), names(info))[1]]][1],
           r_class = if (inherits(x, "error")) "ERROR" else paste(class(x), collapse = "/"),
           example = if (inherits(x, "error")) squish(conditionMessage(x)) |> substr(1, 120) else paste(format(x), collapse = " | "))
  }) |> purrr::list_rbind()
}) |> purrr::list_rbind()
save_results(r_types, "03-r-types.csv")

# --- timings ---
res <- purrr::map(engines(), \(en) bind_rows(grid_narrow(en), grid_wide()) |>
  purrr::pmap(\(type, rows, k) run_case(en, collect_tbl, list(name = tbl_name(type, rows, k)),
                                        iterations = iters(rows * k), type = type, rows = rows, k = k)) |>
  purrr::list_rbind()) |> purrr::list_rbind() |>
  mutate(cells = rows * k, ns_per_cell = med_s / cells * 1e9, mcells_per_s = cells / med_s / 1e6, .after = k)
save_results(res, "03-collect.csv")

# free the space the 1e8-row tables take (Oracle Free: 12 GB cap) unless asked to keep them
if (!identical(Sys.getenv("BENCH_KEEP_BIG"), "true")) for (en in db_engines()) {
  con <- bench_con(en)
  grid_narrow(en) |> filter(rows >= 1e8) |> purrr::pwalk(\(type, rows, k) drop_if_exists(con, tbl_name(type, rows, k)))
  DBI::dbDisconnect(con)
}
