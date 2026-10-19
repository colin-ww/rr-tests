# Part 1: NSE / data-masking: column vs. env variable, across tibble / duckdb / sqlite
suppressPackageStartupMessages({library(dplyr); library(dbplyr)})
source("R/harness.R")
backends <- setup_backends()

# globals: var1 is ALSO a column; the others are not
var1 <- 100; only_global <- 5; vec3 <- c(10, 20, 30); vec2 <- c(1, 2); chr_global <- "var1"
colname <- "var1"; myfun <- \(x) x * 2

P <- "nse"
res <- bind_rows(
  # --- who wins: column or global? ---
  probe_bk(P, "col + global same name",        mutate(d, x = var1)),
  probe_bk(P, "global only",                   mutate(d, x = only_global)),
  probe_bk(P, "neither exists",                mutate(d, x = nothing_here)),
  probe_bk(P, "col + global: .data$var1",      mutate(d, x = .data$var1)),
  probe_bk(P, "col + global: .env$var1",       mutate(d, x = .env$var1)),
  probe_bk(P, "col + global: !!var1",          mutate(d, x = !!var1)),
  probe_bk(P, ".env$ of missing var",          mutate(d, x = .env$nothing_here)),
  probe_bk(P, ".data$ of missing col",         mutate(d, x = .data$nothing_here)),
  probe_bk(P, "arith col + global-only",       mutate(d, x = var1 + only_global)),
  probe_bk(P, "filter(var1 == var1) tautology", filter(d, var1 == var1)),
  probe_bk(P, "filter(var1 == !!var1)",        filter(d, var1 == !!var1)),
  probe_bk(P, "filter(var1 > only_global)",    filter(d, var1 > only_global)),
  # --- function scope ---
  probe_bk(P, "fn local var shadows global (col named same)", (\(d) { var1 <- 7; mutate(d, x = var1) })(d)),
  probe_bk(P, "fn local only",                 (\(d) { loc <- 9; mutate(d, x = loc) })(d)),
  probe_bk(P, "fn arg same name as col",       (\(d, var1) mutate(d, x = var1))(d, 55)),
  probe_bk(P, "fn arg same name, .env$",       (\(d, var1) mutate(d, x = .env$var1))(d, 55)),
  probe_bk(P, "fn arg same name, {{ }}",       (\(d, v) mutate(d, x = {{ v }}))(d, var1)),
  # --- vectors / strings ---
  probe_bk(P, "global vector len 3 as value",  mutate(d, x = vec3)),
  probe_bk(P, "global vector len 2 as value",  mutate(d, x = vec2)),
  probe_bk(P, "col %in% global vector",        filter(d, var1 %in% vec2)),
  probe_bk(P, "string var as column: .data[[]]", mutate(d, x = .data[[colname]])),
  probe_bk(P, "string var as column: bare",    mutate(d, x = colname)),
  probe_bk(P, "string var as column: sym()",   mutate(d, x = !!rlang::sym(colname))),
  # --- tidyselect: env-variable vs column ---
  probe_bk(P, "select(chr_global) no all_of",  select(d, chr_global)),
  probe_bk(P, "select(all_of(chr_global))",    select(d, all_of(chr_global))),
  probe_bk(P, "select(only_global) numeric global", select(d, only_global)),
  probe_bk(P, "select(var1) col+global",       select(d, var1)),
  probe_bk(P, "select(all_of('nope'))",        select(d, all_of("nope"))),
  probe_bk(P, "select(any_of('nope'))",        select(d, any_of("nope"))),
  probe_bk(P, "across(all_of(colname))",       mutate(d, across(all_of(colname), \(v) v * 2, .names = "x"))),
  # --- functions: R function in a query ---
  probe_bk(P, "global fn on column",           mutate(d, x = myfun(var1))),
  probe_bk(P, "global fn on global (no col)",  mutate(d, x = myfun(only_global))),
  probe_bk(P, "global fn via !!",              mutate(d, x = !!myfun(only_global))),
  probe_bk(P, "unknown fn on column",          mutate(d, x = foo(var1))),
  probe_bk(P, "unknown fn: .sql$foo()",        mutate(d, x = .sql$abs(var1))),
  probe_bk(P, "unknown fn: sql('ABS(var1)')",  mutate(d, x = sql("ABS(var1)"))),
  probe_bk(P, "base fn nchar() on string col", mutate(d, x = nchar(name))),
  probe_bk(P, "R-only fn on column (rev)",     mutate(d, x = rev(var1))),
  probe_bk(P, "pkg-qualified stringr::str_to_upper", mutate(d, x = stringr::str_to_upper(name))),
  probe_bk(P, "pkg-qualified fn not translatable", mutate(d, x = stringr::str_squish(name))),
  probe_bk(P, "if_else on col + global",       mutate(d, x = if_else(var1 > only_global, 1, 0))),
  probe_bk(P, "NA global in comparison",       (\(d) { na_g <- NA; filter(d, var1 == na_g) })(d)),
  probe_bk(P, "NULL global in mutate",         (\(d) { null_g <- NULL; mutate(d, x = null_g) })(d)),
  probe_bk(P, "date global as value",          (\(d) { dg <- as.Date("2024-01-02"); filter(d, dt == dg) })(d)),
  probe_bk(P, "Sys.Date() in filter",          filter(d, dt < Sys.Date())),
  probe_bk(P, "data.frame col access: global$col", (\(d) { lst <- list(a = 2); filter(d, var1 == lst$a) })(d)),
  probe_bk(P, "mutate then refer to new col",  mutate(d, x = var1 * 2, y = x + 1) |> select(x, y) |> mutate(x = y)),
  probe_bk(P, "mutate x = x (self-ref, no x)", mutate(d, x = x))
)
save_results(res, "01-nse.csv")
cat("rows:", nrow(res), "\n")
