# Test tables are generated ON the server (no upload from R): a row-number generator `i`, and a
# deterministic pseudo-random int r = (i * 2654435761) mod 1000003 in [0, 1000002]. Same formula on
# every engine, so every engine holds the same values. Needs CREATE TABLE (Oracle) / a schema you
# can write to (SQL Server). Table names: bm_<type>_<rows>_<ncol>, columns x1..xk.

# per type: SQL type + expression per engine. {r} = pseudo-random int, {i} = row number (unique).
# NA = type doesn't exist on that engine.
col_types <- tibble::tribble(
  ~type,       ~mssql,                                                                        ~oracle,                                                              ~duckdb,
  "int_zero",  "CAST(0 AS INT)",                                                              "CAST(0 AS NUMBER(10))",                                              "CAST(0 AS INTEGER)",
  "int_rand",  "CAST(1000000 + {r} AS INT)",                                                  "CAST(1000000 + {r} AS NUMBER(10))",                                  "CAST(1000000 + {r} AS INTEGER)",
  "dbl",       "CAST({r} AS FLOAT) / 7",                                                      "TO_BINARY_DOUBLE({r}) / 7",                                          "CAST({r} AS DOUBLE) / 7",
  "num",       NA,                                                                            "CAST(TO_BINARY_DOUBLE({r}) / 7 AS NUMBER)",                          NA,
  "dec",       "CAST({r} / 100.0 AS DECIMAL(12,2))",                                          "CAST({r} / 100 AS NUMBER(12,2))",                                    "CAST({r} / 100 AS DECIMAL(12,2))",
  "lgl",       "CAST({r} % 2 AS BIT)",                                                        "CAST(MOD({r}, 2) AS NUMBER(1))",                                     "({r} % 2 = 1)",
  "lgl_bool",  NA,                                                                            "CAST(MOD({r}, 2) AS BOOLEAN)",                                       NA,
  "chr1",      "CAST(CHAR(65 + {r} % 10) AS VARCHAR(1))",                                     "CAST(CHR(65 + MOD({r}, 10)) AS VARCHAR2(1))",                        "chr(CAST(65 + {r} % 10 AS INTEGER))",
  "chr20_lo",  "CAST('value_' + RIGHT('00000000000000' + CAST({r} % 10 AS VARCHAR(14)), 14) AS VARCHAR(20))",
                                                                                              "CAST('value_' || LPAD(MOD({r}, 10), 14, '0') AS VARCHAR2(20))",     "'value_' || lpad(CAST({r} % 10 AS VARCHAR), 14, '0')",
  "chr20_hi",  "CAST('value_' + RIGHT('00000000000000' + CAST({i} AS VARCHAR(14)), 14) AS VARCHAR(20))",
                                                                                              "CAST('value_' || LPAD({i}, 14, '0') AS VARCHAR2(20))",              "'value_' || lpad(CAST({i} AS VARCHAR), 14, '0')",
  "nchr20_hi", "CAST('value_' + RIGHT('00000000000000' + CAST({i} AS VARCHAR(14)), 14) AS NVARCHAR(20))",
                                                                                              "CAST('value_' || LPAD({i}, 14, '0') AS NVARCHAR2(20))",             NA,
  "date",      "CAST(DATEADD(day, {r} % 20000, '1970-01-01') AS DATE)",                       "DATE '1970-01-01' + MOD({r}, 20000)",                                "DATE '1970-01-01' + CAST({r} % 20000 AS INTEGER)",
  "dttm",      "CAST(DATEADD(second, CAST({r} * 997 % 1000000000 AS INT), '1970-01-01') AS DATETIME2(0))",
                                                                                              "CAST(TIMESTAMP '1970-01-01 00:00:00' + NUMTODSINTERVAL(MOD({r} * 997, 1000000000), 'SECOND') AS TIMESTAMP(0))",
                                                                                                                                                                    "TIMESTAMP '1970-01-01' + to_seconds({r} * 997 % 1000000000)"
)

# pseudo-random int, shifted per column so the k columns of a wide table differ
r_expr <- \(engine, j = 1) {
  base <- if (engine == "oracle") "MOD(i * 2654435761 + %d, 1000003)" else "(i * 2654435761 + %d) %% 1000003"
  sprintf(base, (j - 1) * 7919)
}
col_expr <- \(engine, type, j = 1) col_types[[engine]][col_types$type == type] |>
  gsub(pattern = "{r}", replacement = paste0("(", r_expr(engine, j), ")"), fixed = TRUE) |>
  gsub(pattern = "{i}", replacement = "i", fixed = TRUE)
has_type <- \(engine, type) !is.na(col_types[[dialect_of(engine)]][col_types$type == type])

# CREATE TABLE ... AS <generator>: `select` = SQL select-list over columns i (row number) and r
qi <- \(engine, x) if (dialect_of(engine) == "mssql") paste0("[", x, "]") else paste0('"', x, '"')
ctas_sql <- function(engine, name, select, n) {
  n <- format(n, scientific = FALSE)
  switch(engine,
    mssql = paste0("WITH n AS (SELECT TOP (", n, ") CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS BIGINT) AS i ",
                   "FROM sys.all_columns a CROSS JOIN sys.all_columns b CROSS JOIN sys.all_columns c) ",
                   "SELECT ", select, " INTO ", qi(engine, name), " FROM n"),
    oracle = paste0("CREATE TABLE ", qi(engine, name), " NOLOGGING AS ",
                    "WITH g AS (SELECT LEVEL AS l FROM dual CONNECT BY LEVEL <= 10000), ",
                    "n AS (SELECT (g1.l - 1) * 10000 + g2.l AS i FROM g g1 CROSS JOIN g g2 WHERE g1.l <= CEIL(", n, " / 10000)) ",
                    "SELECT ", select, " FROM n WHERE i <= ", n),
    duckdb = paste0("CREATE TABLE ", qi(engine, name), " AS SELECT ", select,
                    " FROM (SELECT CAST(range + 1 AS BIGINT) AS i FROM range(", n, "))"))
}

tbl_name <- \(type, rows, k = 1) sprintf("bm_%s_%s_%d", type, short_n(rows), k)
short_n <- \(n) format(n, scientific = TRUE) |> sub(pattern = "\\+0?", replacement = "")   # 1e+06 -> 1e6

# Oracle: DROP TABLE alone moves the table to the recycle bin and keeps its space; PURGE frees it
drop_if_exists <- \(con, name) if (DBI::dbExistsTable(con, name)) {
  if (inherits(con, c("Oracle", "OraConnection"))) DBI::dbExecute(con, paste("DROP TABLE", DBI::dbQuoteIdentifier(con, name), "PURGE"))
  else DBI::dbRemoveTable(con, name)
}
n_rows <- \(con, engine, name) DBI::dbGetQuery(con, paste("SELECT COUNT(*) AS n FROM", qi(engine, name)))[[1]]

# CREATE TABLE name AS SELECT <select> FROM <generator of `rows` rows>; skipped if it already exists
# with the right row count. `select` = named character vector of SQL expressions (names = columns).
make_select_table <- function(con, engine, name, select, rows, overwrite = FALSE) {
  if (!overwrite && DBI::dbExistsTable(con, name) && n_rows(con, engine, name) == rows) return(invisible(name))
  drop_if_exists(con, name)
  sel <- paste(select, "AS", qi(engine, names(select)), collapse = ", ")
  t0 <- Sys.time(); DBI::dbExecute(con, ctas_sql(engine, name, sel, rows))
  message(engine, " ", name, " created in ", round(difftime(Sys.time(), t0, units = "secs"), 1), " s")
  invisible(name)
}

# k columns x1..xk of `type`
make_table <- \(con, engine, type, rows, k = 1, ...)
  make_select_table(con, engine, tbl_name(type, rows, k),
                    purrr::map_chr(seq_len(k), \(j) col_expr(engine, type, j)) |> setNames(paste0("x", seq_len(k))), rows, ...)

# --- the grid used by 03-collect-types-rows-cols.R ---
# 1e8 rows: int_rand, dbl (+ chr1, except on Oracle: Oracle Free's 12 GB cap; ~13 bytes/row even for 1 char)
# BENCH_MAX_ROWS (default 1e8): e.g. 1e7 skips the 100M-row tables (~5 GB less per server)
max_rows <- \() as.numeric(Sys.getenv("BENCH_MAX_ROWS", "1e8"))
grid_narrow <- \(engine) tidyr::expand_grid(type = col_types$type, rows = c(1e5, 1e6, 1e7), k = 1) |>
  dplyr::bind_rows(tidyr::expand_grid(type = c("int_rand", "dbl", if (dialect_of(engine) != "oracle") "chr1"), rows = 1e8, k = 1)) |>
  dplyr::filter(purrr::map_lgl(type, \(t) has_type(engine, t)), rows <= max_rows())
# wide: 1e5 x {2,10,100}, 1e6 x {2,10,100}; chr20_lo stops at 1e6 x 10 (Oracle Free's 12 GB cap)
grid_wide <- \() tidyr::expand_grid(type = c("int_rand", "dbl", "chr20_lo"), rows = c(1e5, 1e6), k = c(2, 10, 100)) |>
  dplyr::filter(!(type == "chr20_lo" & rows == 1e6 & k == 100))

# --- survey-like tables for 02 (mutate), 04 (convert/join), 05 (IO) ---
# mix: id, age (int), sex (chr1), prov (2-char code, 13 values), income/wgt (double), ref_date (date),
# flag (lgl), name (unique 20 chars), amount (decimal). r = this row's pseudo-random int.
mix_cols <- function(engine) {
  r <- paste0("(", r_expr(engine), ")")
  m <- \(a, b) if (engine == "oracle") sprintf("MOD(%s, %s)", a, b) else sprintf("(%s %% %s)", a, b)
  int <- if (engine == "oracle") "NUMBER(10)" else "INT"
  c(id = sprintf("CAST(i AS %s)", int), age = sprintf("CAST(%s AS %s)", m(r, 100), int),
    sex = col_expr(engine, "chr1"),
    prov = switch(engine, oracle = sprintf("CAST(TO_CHAR(10 + %s) AS VARCHAR2(2))", m(r, 13)),
                  mssql = sprintf("CAST(10 + %s AS VARCHAR(2))", m(r, 13)), duckdb = sprintf("CAST(10 + %s AS VARCHAR)", m(r, 13))),
    income = col_expr(engine, "dbl", 2), wgt = col_expr(engine, "dbl", 3), ref_date = col_expr(engine, "date"),
    flag = col_expr(engine, "lgl"), name = col_expr(engine, "chr20_hi"), amount = col_expr(engine, "dec", 4))
}
make_mix <- \(con, engine, rows, ...) make_select_table(con, engine, paste0("bm_mix_", short_n(rows)), mix_cols(engine), rows, ...)

# the same table with every column stored as text (dates 'YYYY-MM-DD', numbers with 6 decimals, flag '0'/'1')
mixstr_cols <- function(engine) {
  x <- \(nm) qi(engine, nm)
  v <- if (engine == "oracle") "VARCHAR2" else "VARCHAR"
  txt <- \(e, n) sprintf("CAST(%s AS %s(%d))", e, v, n)
  num6 <- \(nm) if (engine == "oracle") sprintf("TO_CHAR(CAST(%s AS NUMBER(18,6)), 'FM999999999990.000000')", x(nm)) else
    txt(sprintf("CAST(%s AS DECIMAL(18,6))", x(nm)), 30)
  c(id = txt(x("id"), 10), age = txt(x("age"), 3), sex = x("sex"), prov = x("prov"),
    income = num6("income"), wgt = num6("wgt"),
    ref_date = switch(engine, mssql = sprintf("CONVERT(VARCHAR(10), %s, 23)", x("ref_date")),
                      oracle = sprintf("TO_CHAR(%s, 'YYYY-MM-DD')", x("ref_date")), duckdb = sprintf("strftime(%s, '%%Y-%%m-%%d')", x("ref_date"))),
    flag = if (engine == "duckdb") sprintf("CAST(CAST(%s AS INTEGER) AS VARCHAR)", x("flag")) else txt(x("flag"), 1),
    name = x("name"), amount = txt(x("amount"), 20))
}
make_mixstr <- function(con, engine, rows) {
  name <- paste0("bm_mixstr_", short_n(rows)); src <- paste0("bm_mix_", short_n(rows))
  if (DBI::dbExistsTable(con, name) && n_rows(con, engine, name) == rows) return(invisible(name))
  drop_if_exists(con, name)
  sel <- paste(mixstr_cols(engine), "AS", qi(engine, names(mixstr_cols(engine))), collapse = ", ")
  sql <- if (engine == "mssql") sprintf("SELECT %s INTO %s FROM %s", sel, qi(engine, name), qi(engine, src)) else
    sprintf("CREATE TABLE %s AS SELECT %s FROM %s", qi(engine, name), sel, qi(engine, src))
  t0 <- Sys.time(); DBI::dbExecute(con, sql)
  message(engine, " ", name, " created in ", round(difftime(Sys.time(), t0, units = "secs"), 1), " s")
  invisible(name)
}

# lookup: 13 province codes -> two ~30-char names. extra: id + 4 more columns, for a 1:1 join.
make_lookup <- function(con, engine) {
  cat3 <- \(a, b, c) if (engine == "mssql") sprintf("CONCAT(%s, %s, %s)", a, b, c) else sprintf("(%s || %s || %s)", a, b, c)
  code <- switch(engine, oracle = "TO_CHAR(9 + i)", mssql = "CAST(9 + i AS VARCHAR(2))", duckdb = "CAST(9 + i AS VARCHAR)")
  make_select_table(con, engine, "bm_prov_lu", c(prov = code,
    prov_name_en = cat3("'Province or territory no. '", code, "' (EN)'"),
    prov_name_fr = cat3("'Province ou territoire no '", code, "' (FR)'")), 13)
}
make_extra <- \(con, engine, rows) make_select_table(con, engine, paste0("bm_extra_", short_n(rows)),
  c(id = if (engine == "oracle") "CAST(i AS NUMBER(10))" else "CAST(i AS INT)",
    x_int = col_expr(engine, "int_rand", 5), x_dbl = col_expr(engine, "dbl", 6),
    x_date = col_expr(engine, "date", 7), x_chr = col_expr(engine, "chr20_lo", 8)), rows)
