# Part 2: mutate on the database before collect(), or in R after collect()?
# Table bm_mix_<rows>: 10 columns (id, age, sex, prov, income, wgt, ref_date, flag, name, amount).
#  - building a lazy query (tbl(), mutate(), show_query()): microseconds-to-ms -> bench::mark() is right here
#  - collect() alone / mutate in SQL then collect / collect then mutate in R / the R mutate alone /
#    compute() (the database does the work and keeps the result: no transfer)
#  - age + 1L vs age + 1: the second one changes the type (1 is a double in R)
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

# 5 typical derived variables (a SAS data step's worth)
mutate5 <- \(x) x |> mutate(age_grp = case_when(age < 15L ~ "0-14", age < 65L ~ "15-64", TRUE ~ "65+"),
                            inc_w = income * wgt, ont = if_else(prov == "35", 1L, 0L),
                            yr = year(ref_date), name10 = substr(name, 1L, 10L))
cases <- list(
  "collect() only"                      = \(con, name, data) tbl(con, name) |> collect(),
  "SQL: mutate(age = age + 1L) |> collect()" = \(con, name, data) tbl(con, name) |> mutate(age = age + 1L) |> collect(),
  "SQL: mutate(age = age + 1) |> collect()"  = \(con, name, data) tbl(con, name) |> mutate(age = age + 1) |> collect(),
  "R: collect() |> mutate(age = age + 1L)"   = \(con, name, data) tbl(con, name) |> collect() |> mutate(age = age + 1L),
  "R: mutate(age = age + 1L) alone"          = \(con, name, data) data |> mutate(age = age + 1L),
  "SQL: mutate(age + 1L) |> compute()"       = \(con, name, data) tbl(con, name) |> mutate(age = age + 1L) |> compute(),
  "SQL: mutate5() |> collect()"              = \(con, name, data) tbl(con, name) |> mutate5() |> collect(),
  "R: collect() |> mutate5()"                = \(con, name, data) tbl(con, name) |> collect() |> mutate5(),
  "R: mutate5() alone"                       = \(con, name, data) data |> mutate5())
needs_data <- \(case) grepl("alone$", case)

res <- tidyr::expand_grid(engine = engines(), rows = c(1e6, 1e7), case = names(cases)) |>
  purrr::pmap(\(engine, rows, case) run_case(engine, cases[[case]],
    list(name = paste0("bm_mix_", short_n(rows)), data = NULL), globals = list(mutate5 = mutate5),
    setup = if (needs_data(case)) \(con, name, data) tbl(con, name) |> collect(),
    pkgs = c("lubridate"), iterations = 3, rows = rows, case = case)) |>
  purrr::list_rbind()
save_results(res, "02-mutate.csv")

# --- lazy query building + what SQL / R type `age + 1` vs `age + 1L` gives (one process per engine) ---
lazy_child <- function(wd, engine) {
  setwd(wd); suppressPackageStartupMessages({library(dplyr); library(dbplyr)})
  for (f in c("R/connect.R", "R/make-data.R")) source(f)
  con <- bench_con(engine); on.exit(DBI::dbDisconnect(con))
  lz <- tbl(con, "bm_mix_1e6")
  bm <- bench::mark(`tbl(con, name)` = tbl(con, "bm_mix_1e6"), `lazy |> mutate(age = age + 1L)` = mutate(lz, age = age + 1L),
                    `lazy |> mutate(...) |> sql_render()` = sql_render(mutate(lz, age = age + 1L)),
                    check = FALSE, min_iterations = 20)
  sql <- \(x) sql_render(x) |> as.character() |> gsub(pattern = "\\s+", replacement = " ")
  age_class <- \(x) x |> filter(id <= 3L) |> collect() |> pull(age) |> class() |> paste(collapse = "/")
  dplyr::bind_rows(
    tibble::tibble(engine = engine, what = bm$expression |> as.character(), median_ms = as.numeric(bm$median) * 1e3,
                   mem_alloc_kb = as.numeric(bm$mem_alloc) / 1024),
    tibble::tibble(engine = engine, what = c("age (as stored)", "age + 1L", "age + 1"),
                   sql = c(sql(lz), sql(mutate(lz, age = age + 1L)), sql(mutate(lz, age = age + 1))),
                   age_class = c(age_class(lz), age_class(mutate(lz, age = age + 1L)), age_class(mutate(lz, age = age + 1)))))
}
purrr::map(engines(), \(en) callr::r(lazy_child, list(getwd(), en))) |> purrr::list_rbind() |>
  save_results("02-lazy.csv") |> print(n = Inf, width = 250)
