# Part 6: dbplyr options, escape hatches (sql(), .sql$, local(), remote(), pronouns, !!, sql_glue2()),
# how to apply a local R function to a DB column, and an opt-in "ambiguous name" check (R/check_ambiguity.R).
# tibble / duckdb / sqlite via probe_bk(). Writes results/06-escape-hatches.csv.
suppressPackageStartupMessages({library(dplyr); library(dbplyr)})
source("R/harness.R"); source("R/check_ambiguity.R")
backends <- setup_backends()

# --- 1. option inventory: every option / env var name read by the installed namespaces ---
# (scans deparsed function bodies; R6 methods are not functions in the namespace, e.g. dbplyr's
#  progress bar reads dplyr.show_progress -> see README for the source-line citations)
opt_re <- c(option = "(?:getOption|peek_option)\\(\"([^\"]+)\"", option = "(?<![A-Za-z_.])options\\((?:list\\()?([A-Za-z_.]+) =",
            envvar = "Sys\\.getenv\\(\"([^\"]+)\"")
opt_inventory <- \(pkg) {
  ns <- asNamespace(pkg)
  src <- ls(ns, all.names = TRUE) |> purrr::keep(\(f) is.function(ns[[f]])) |>
    purrr::map(\(f) tibble(fn = f, line = deparse(ns[[f]]))) |> purrr::list_rbind()
  purrr::imap(opt_re, \(re, kind) src |> mutate(option = stringr::str_match(line, re)[, 2], kind = kind)) |>
    purrr::list_rbind() |> filter(!is.na(option), !grepl(":::", option)) |>   # drop rlang-internal "rlang:::x" options
    summarise(read_in = paste(sort(unique(fn)), collapse = " "), .by = c(option, kind)) |> mutate(package = pkg)
}
inv <- c("dbplyr", "dplyr", "tidyselect", "rlang", "lifecycle", "DBI", "duckdb", "RSQLite") |>
  purrr::map(opt_inventory) |> purrr::list_rbind()
print(as.data.frame(filter(inv, package %in% c("dbplyr", "dplyr", "lifecycle"))))
res_inv <- inv |> transmute(part = "options", case = option, backend = package, code = purrr::map_chr(read_in, clip, 200),
                            outcome = "ok", failed_at = NA, value = kind, sql = NA, warnings = "", messages = "")
# dplyr.legacy_locale is itself deprecated in dplyr 1.2.0 (locale.R:89): fresh process, so the once-per-session warning shows
res_inv <- bind_rows(res_inv, probe("options", "dplyr.legacy_locale = TRUE (fresh process)", callr::r(\() {
  options(dplyr.legacy_locale = TRUE)
  tryCatch({ dplyr::arrange(data.frame(x = c("b", "A")), x); "no warning" }, warning = \(w) conditionMessage(w))
})))

# globals: var1 is ALSO a column (1,2,3); helpers for the "local function" cases
var1 <- 100; only_global <- 5; colname <- "var1"; k <- 2; bad <- "alpha' OR '1'='1"
lst <- list(f = \(x) x * 2); f <- lst$f
f_expr <- \(x) rlang::expr(!!rlang::enexpr(x) * 2)        # returns CODE, not a value -> splice with !!
lst2 <- list(f = f_expr)                                  # same thing, box-module style mod$fn
double_col <- \(d, col) mutate(d, x = {{ col }} * 2)     # verb wrapper with {{ }}

# --- 2. dplyr.strict_sql: the one "strict" switch dbplyr has (translate-sql.R:149) ---
# set globally, not with_options(): translation happens at sql_render(), after the verb returns
P <- "strict_sql"
lf_ora <- lazy_frame(x = "a", y = "b", con = dialect_oracle()); lf_ms <- lazy_frame(x = "a", y = "b", con = dialect_mssql())
op <- options(dplyr.strict_sql = TRUE)
res_strict <- bind_rows(
  probe_bk(P, "strict: unknown fn foo(var1)",          mutate(d, x = foo(var1))),
  probe_bk(P, "strict: global R fn f(var1)",           mutate(d, x = f(var1))),
  probe_bk(P, "strict: Sys.Date()",                    mutate(d, x = Sys.Date())),
  probe_bk(P, "strict: .sql$instr() (real SQL fn)",    mutate(d, x = .sql$instr(name, "a"))),
  probe_bk(P, "strict: .sql$abs() (known fn)",         mutate(d, x = .sql$abs(var1))),
  probe_bk(P, "strict: sql('instr(...)')",             mutate(d, x = sql("instr(name, 'a')"))),
  probe_bk(P, "strict: lst$f(var1) still silent",      mutate(d, x = lst$f(var1))),
  probe_bk(P, "strict: stringr::str_squish (no transl.)", mutate(d, x = stringr::str_squish(name))),
  # pass-through SQL that Oracle / SQL Server users often rely on (rendered only, no DB needed)
  probe(P, "strict: oracle nvl(x, 0)",                 sql_render(mutate(lf_ora, z = nvl(x, 0)))),
  probe(P, "strict: mssql x %like% 'a%'",              sql_render(filter(lf_ms, x %like% "a%"))),
  probe(P, "strict: mssql datediff(x, y)",             sql_render(mutate(lf_ms, z = datediff(x, y)))),
  probe(P, "strict: oracle sql('NVL(x, 0)')",          sql_render(mutate(lf_ora, z = sql("NVL(x, 0)"))))
)
options(op)

# --- 3. escape hatches ---
P <- "escape"
res_escape <- bind_rows(
  probe_bk(P, "sql('var1 * 2')",                       mutate(d, x = sql("var1 * 2"))),
  probe_bk(P, "sql(paste(colname, '* 2')) (args run in R)", mutate(d, x = sql(paste(colname, "* 2")))),
  probe_bk(P, ".sql$instr(name, 'a') (not translated)", mutate(d, x = .sql$instr(name, "a"))),
  probe_bk(P, "unknown fn instr() w/o .sql$",          mutate(d, x = instr(name, "a"))),
  probe_bk(P, "sql(paste(var1, '* 2')) var1 = col AND object", mutate(d, x = sql(paste(var1, "* 2")))),
  probe(P, "grouped sql()/.sql$: no OVER (dbplyr#1526)", sql_render(mutate(group_by(lf_ms, x), z = sql("STDEVP(y)"), w = .sql$STDEVP(y)))),
  probe_bk(P, "local(var1) -> R env",                  mutate(d, x = local(var1))),
  probe_bk(P, "local(only_global * 2)",                mutate(d, x = local(only_global * 2))),
  probe_bk(P, "remote(var1) * 2 -> column",            mutate(d, x = remote(var1) * 2)),
  probe_bk(P, ".local$var1 (no such pronoun)",         mutate(d, x = .local$var1)),
  probe_bk(P, ".env$var1",                             mutate(d, x = .env$var1)),
  probe_bk(P, "!!var1",                                mutate(d, x = !!var1)),
  probe_bk(P, ".data$var1",                            mutate(d, x = .data$var1)),
  probe_bk(P, ".data[[colname]]",                      mutate(d, x = .data[[colname]])),
  probe_bk(P, ".data$f(var1) (fn via pronoun)",        mutate(d, x = .data$f(var1))),
  probe_bk(P, "I(var1)",                               mutate(d, x = I(var1))),
  probe_bk(P, "!!sql_glue2(con, '{.id colname} * {k}')", mutate(d, x = !!sql_glue2(remote_con(d), "{.id colname} * {k}"))),
  probe_bk(P, "sql_glue2() escapes values (injection)", filter(d, name == !!sql_glue2(remote_con(d), "{bad}"))),
  probe_bk(P, "sql_glue2() without !!",                mutate(d, x = sql_glue2(remote_con(d), "{.id colname} * 2"))),
  probe(P, "sql_glue() outside a translation method",  sql_glue("{.id colname}"))
)

# --- 4. the silent wrong-result case: a local R function applied to a column ---
P <- "local_fn"
res_fn <- bind_rows(
  probe_bk(P, "lst$f(var1)  [the bug]",                mutate(d, x = lst$f(var1))),
  probe_bk(P, "lst$f(.data$var1)",                     mutate(d, x = lst$f(.data$var1))),
  probe_bk(P, "local(lst$f(var1))",                    mutate(d, x = local(lst$f(var1)))),
  probe_bk(P, "lst$f(remote(var1))",                   mutate(d, x = lst$f(remote(var1)))),
  probe_bk(P, "!!lst$f(var1)",                         mutate(d, x = !!lst$f(var1))),
  probe_bk(P, "(!!lst$f)(var1) (inject the fn object)", mutate(d, x = (!!lst$f)(var1))),
  probe_bk(P, "(\\(x) x * 2)(var1) (inline lambda)",    mutate(d, x = (\(x) x * 2)(var1))),
  probe_bk(P, "f <- lst$f; f(var1) (bare name)",       mutate(d, x = f(var1))),
  probe_bk(P, "FIX: var1 * 2 (translatable code)",     mutate(d, x = var1 * 2)),
  probe_bk(P, "FIX: !!f_expr(var1) (fn returns code)", mutate(d, x = !!f_expr(var1))),
  probe_bk(P, "FIX: !!lst2$f(var1) (module fn returns code)", mutate(d, x = !!lst2$f(var1))),
  probe_bk(P, "FIX: double_col(d, var1) (verb wrapper)", double_col(d, var1)),
  probe_bk(P, "FIX: collect() first, then R fn",       collect(d) |> mutate(x = lst$f(var1))),
  probe_bk(P, "FIX: sql('var1 * 2')",                  mutate(d, x = sql("var1 * 2")))
)

# --- 5. does anything warn on "column AND env object" ambiguity? ---
P <- "ambiguity"
# lintr / codetools read the code, not the data: they only know "is there a binding in scope?".
# Run in a clean session (as `lintr::lint_dir()` would) and again with a global `var1` defined.
amb_code <- "f <- function(d) { var1 <- 100; dplyr::mutate(d, x = var1) }  # ambiguous\ng <- function(d) dplyr::mutate(d, x = var1)  # fine (column)\n"
lint_msgs <- \(code, global) callr::r(\(code, global) {
  if (global) assign("var1", 100, globalenv())
  l <- as.data.frame(lintr::lint(text = code, linters = lintr::object_usage_linter()))
  if (nrow(l)) paste0("line ", l$line_number, ": ", l$message) else "no lints"
}, list(code, global))
check_usage <- \(global) callr::r(\(global) {
  if (global) assign("var1", 100, globalenv())
  fa <- function(d) { var1 <- 100; dplyr::mutate(d, x = var1) }; fg <- function(d) dplyr::mutate(d, x = var1)
  c(ambiguous = paste(capture.output(codetools::checkUsage(fa, all = TRUE)), collapse = ""),
    column_only = paste(capture.output(codetools::checkUsage(fg, all = TRUE)), collapse = ""))
}, list(global))
op <- options(lifecycle_verbosity = "warning", rlib_warning_verbosity = "verbose")
res_amb <- bind_rows(
  probe_bk(P, "dplyr/dbplyr: mutate(x = var1), verbose options", mutate(d, x = var1)),
  probe_bk(P, "dplyr/dbplyr: filter(var1 == var1)",    filter(d, var1 == var1)),
  probe(P, "lintr object_usage_linter, clean session", lint_msgs(amb_code, FALSE)),
  probe(P, "lintr object_usage_linter, global var1 exists", lint_msgs(amb_code, TRUE)),
  probe(P, "codetools::checkUsage, clean session",     check_usage(FALSE)),
  probe(P, "codetools::checkUsage, global var1 exists", check_usage(TRUE)),
  probe_bk(P, "check_ambiguity(d, x = var1)",          check_ambiguity(d, x = var1)),
  probe_bk(P, "check_ambiguity: .data$/.env$/!! are quiet", check_ambiguity(d, x = .data$var1, y = .env$var1, z = !!var1)),
  probe_bk(P, "mutate_chk(d, x = lst$f(var1))",        mutate_chk(d, x = lst$f(var1))),
  probe_bk(P, "mutate_chk(d, x = .data$var1 * 2)",     mutate_chk(d, x = .data$var1 * 2)),
  probe_bk(P, "mutate_chk(d, x = sql(paste(var1, '* 2')))", mutate_chk(d, x = sql(paste(var1, "* 2")))),
  probe_bk(P, "check_ambiguity: remote(var1) is quiet", check_ambiguity(d, x = remote(var1))),
  probe_bk(P, "fn arg named like col: check_ambiguity", (\(d, var1) filter_chk(d, var1 > 1))(d, 2)),
  probe_bk(P, "{{ }} wrapper: user passes bare var1", (\(d, col) mutate_chk(d, x = {{ col }}))(d, var1)),
  probe_bk(P, "false positive: !!sym('var1')",         check_ambiguity(d, x = !!rlang::sym("var1")))
)
options(op)

# NA-removal warning in SQL aggregates is shown once per 8 hours unless rlib_warning_verbosity = "verbose"
P <- "verbosity"
res_verb <- bind_rows(
  probe_bk(P, "mean(var1) default verbosity (1st db warns, 2nd silent)", summarise(d, m = mean(var1))),
  local({ op <- options(rlib_warning_verbosity = "verbose"); on.exit(options(op))
    probe_bk(P, "mean(var1) rlib_warning_verbosity='verbose'", summarise(d, m = mean(var1))) })
)

res <- bind_rows(res_inv, res_strict, res_escape, res_fn, res_amb, res_verb)
save_results(res, "06-escape-hatches.csv")
cat("rows:", nrow(res), "\n")
