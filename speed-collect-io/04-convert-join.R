# Part 4: type conversion and joins, on the database before collect() or in R after?
# Tables (10 columns, see R/make-data.R): bm_mix_<n> (proper types), bm_mixstr_<n> (the same values
# stored as text: the "every column is a string" schema), bm_prov_lu (13 rows), bm_extra_<n> (1:1 by id).
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

# text -> proper types, in SQL (dbplyr translates as.integer() etc. to CAST) or in R.
# flag -> 0/1 integer (a logical expression in SELECT breaks on Oracle: no BOOLEAN before 23ai,
# and odbc can't read 23ai's BOOLEAN). ora = TRUE: Oracle's CAST(x AS DATE) depends on
# NLS_DATE_FORMAT (fails for 'YYYY-MM-DD' under the default DD-MON-RR), so use TO_DATE(x, format).
to_types <- \(x, ora = FALSE) x |> mutate(across(c(id, age, flag), as.integer), across(c(income, wgt, amount), as.numeric),
  ref_date = !!(if (ora) quote(TO_DATE(ref_date, "YYYY-MM-DD")) else quote(as.Date(ref_date))))
spec <- readr::cols(id = "i", age = "i", income = "d", wgt = "d", amount = "d", ref_date = "D", flag = "i", .default = "c")
cases <- list(
  # conversion
  "typed table: collect()"                     = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> collect(),
  "text table: collect() (no conversion)"      = \(con, n, ...) tbl(con, paste0("bm_mixstr_", n)) |> collect(),
  "text table: convert in SQL, then collect()" = \(con, n, ...) tbl(con, paste0("bm_mixstr_", n)) |> to_types(ora = inherits(con, c("Oracle", "OraConnection"))) |> collect(),
  "text table: collect(), convert in R (base as.*)" = \(con, n, ...) tbl(con, paste0("bm_mixstr_", n)) |> collect() |> to_types(),
  "text table: collect(), readr::type_convert(spec)" = \(con, n, ...) tbl(con, paste0("bm_mixstr_", n)) |> collect() |> readr::type_convert(col_types = spec),
  "typed table: id to text in SQL, then collect()" = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> mutate(id = as.character(id)) |> collect(),
  "typed table: collect(), id to text in R"    = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> collect() |> mutate(id = as.character(id)),
  # joins
  "lookup join (13 rows) in SQL, then collect()" = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> left_join(tbl(con, "bm_prov_lu"), by = "prov") |> collect(),
  "lookup join: collect() both, join in R"     = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> collect() |> left_join(collect(tbl(con, "bm_prov_lu")), by = "prov"),
  "1:1 join on id in SQL, then collect()"      = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> inner_join(tbl(con, paste0("bm_extra_", n)), by = "id") |> collect(),
  "1:1 join: collect() both, join in R"        = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> collect() |> inner_join(collect(tbl(con, paste0("bm_extra_", n))), by = "id"),
  "filtering join (keep 10%) in SQL"           = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> semi_join(tbl(con, paste0("bm_extra_", n)) |> filter(x_int < 1100000L), by = "id") |> collect(),
  "filtering join: collect() both, join in R"  = \(con, n, ...) tbl(con, paste0("bm_mix_", n)) |> collect() |> semi_join(tbl(con, paste0("bm_extra_", n)) |> collect() |> filter(x_int < 1100000L), by = "id"))

res <- tidyr::expand_grid(engine = engines(), rows = c(1e6, 1e7), case = names(cases)) |>
  purrr::pmap(\(engine, rows, case) run_case(engine, cases[[case]], list(n = short_n(rows)),
    globals = list(to_types = to_types, spec = spec), iterations = 3, rows = rows, case = case)) |>
  purrr::list_rbind()
save_results(res, "04-convert-join.csv")

# what each conversion gives back (classes), and the SQL dbplyr writes for it
check_child <- function(wd, engine, to_types) {
  setwd(wd); suppressPackageStartupMessages({library(dplyr); library(dbplyr)}); for (f in c("R/connect.R", "R/make-data.R")) source(f)
  con <- bench_con(engine); on.exit(DBI::dbDisconnect(con)); environment(to_types) <- globalenv()
  cls <- \(d) purrr::imap_chr(d, \(v, n) paste0(n, "=", class(v)[1])) |> paste(collapse = ", ")
  try_cls <- \(q) tryCatch(cls(collect(q)), error = \(e) paste("ERROR:", gsub("\\s+", " ", conditionMessage(e)) |> substr(1, 250)))
  sql1 <- \(q) sql_render(q) |> gsub(pattern = "\\s+", replacement = " ")
  s3 <- tbl(con, "bm_mixstr_1e6") |> filter(id %in% c("1", "2", "3"))
  tibble::tibble(engine = engine,
                 what = c("typed table", "text table", "text table, converted in SQL (as.Date)",
                          "text table, converted in SQL (TO_DATE, Oracle only)", "text table, converted in R"),
                 classes = c(cls(tbl(con, "bm_mix_1e6") |> head(3) |> collect()), cls(collect(s3)), try_cls(to_types(s3)),
                             if (inherits(con, c("Oracle", "OraConnection"))) try_cls(to_types(s3, ora = TRUE)) else NA, cls(collect(s3) |> to_types())),
                 sql = c(NA, NA, sql1(to_types(s3)), if (inherits(con, c("Oracle", "OraConnection"))) sql1(to_types(s3, ora = TRUE)) else NA, NA))
}
purrr::map(engines(), \(en) callr::r(check_child, list(getwd(), en, to_types))) |> purrr::list_rbind() |>
  save_results("04-classes.csv") |> print(width = 250)
