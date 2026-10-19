# Part 5: how the same dplyr code renders as SQL Server / Oracle / Postgres / duckdb / SQLite SQL,
# plus sql_options(). Rendering needs no database (dialect_*() objects); duckdb + SQLite are real.
# OPTIONAL execution on real engines: if docker containers named `mssql` (SQL Server 2022),
# `mssql25` (SQL Server 2025) and `ora` (Oracle Free 23ai/26ai) are running, every rendered query is
# also run there, in one sqlcmd / sqlplus session inside the container (no ports published):
#   docker run -d --name mssql   --network none -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='Strong!Passw0rd' mcr.microsoft.com/mssql/server:2022-latest
#   docker run -d --name mssql25 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='Strong!Passw0rd' mcr.microsoft.com/mssql/server:2025-latest
#   docker run -d --name ora     -e ORACLE_PASSWORD=oraclepw ghcr.io/gvenzl/oracle-free:slim
# (SQL Server 2025 and Oracle fail to start with --network none; no -p, so nothing is reachable from outside.)
# Without them, exec = "not run" for those dialects. duckdb/SQLite queries are always executed.
# mssql15 SQL is run on SQL Server 2022 (16.x): dbplyr's SQL is the same for versions 11 to 16.
suppressPackageStartupMessages({library(dplyr); library(dbplyr)})
source("R/harness.R")
# dbplyr's "missing values are always removed" warning fires only once per session by default
options(rlib_warning_verbosity = "verbose", lifecycle_verbosity = "warning")

# --- data: NA in var1/name/flag, a trailing-space string, an empty string, a leap day ---
df <- tibble(id = 1:4, grp = c("a", "a", "b", "b"), var1 = c(1, 2.5, 3.7, NA),
             name = c("alpha", "beta  ", "", NA), flag = c(TRUE, FALSE, TRUE, NA),
             dt = as.Date(c("2024-01-01", "2024-01-02", "2024-02-01", "2024-02-29")))
df2 <- tibble(id = c(1L, 2L, 5L), name = c("ALPHA", "BETA", "EPS"), score = c(10, 20, 50))
con_d <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); con_s <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
for (con in list(con_d, con_s)) { copy_to(con, df, "df"); copy_to(con, df2, "df2") }

# simulated dialects (current API: dialect_*() + tbl_lazy()/lazy_frame()) + real connections
dialects <- list(mssql15 = dialect_mssql("15.0"), mssql17 = dialect_mssql("17.0"), oracle = dialect_oracle(),
                 postgres = dialect_postgres(), duckdb = con_d, sqlite = con_s)
is_real <- \(con) inherits(con, "DBIConnection") && !inherits(con, "TestConnection")  # simulate_*() = fake con
lazy_tbls <- \(con) if (is_real(con)) list(d = tbl(con, "df"), d2 = tbl(con, "df2")) else
  list(d = tbl_lazy(df, con = con, name = "df"), d2 = tbl_lazy(df2, con = con, name = "df2"))
code_txt <- \(expr) squish(deparse(expr, width.cutoff = 500))

# --- engines: each takes a vector of SQL strings, returns list(status, value) per query ---
# value = rows "a|b|c" joined by "; ", NULL shown as NULL
dbi_engine <- \(con) \(sqls) purrr::map(sqls, \(s) tryCatch({
  r <- DBI::dbGetQuery(con, s)
  list("ok", apply(as.data.frame(lapply(r, \(v) ifelse(is.na(v), "NULL", as.character(v)))), 1, paste, collapse = "|") |>
         paste(collapse = "; "))
}, error = \(e) list("error", err_txt(e))))
docker_up <- \(ctr) nzchar(Sys.which("docker")) &&
  identical(suppressWarnings(system2("docker", c("inspect", "-f", "{{.State.Running}}", ctr), stdout = TRUE, stderr = FALSE)), "true")
docker_run <- \(ctr, cmd, lines) {   # pipe a script into a client inside the container
  f <- tempfile(fileext = ".sql"); on.exit(unlink(f)); writeLines(lines, f)
  processx::run("docker", c("exec", "-i", ctr, cmd), stdin = f, error_on_status = FALSE)$stdout
}
sqlcmd <- \(ctr, lines) docker_run(ctr, c("/opt/mssql-tools18/bin/sqlcmd", "-S", "127.0.0.1", "-U", "sa", "-P", "Strong!Passw0rd",
                                          "-C", "-h", "-1", "-W", "-s", "|", "-k1", "-i", "/dev/stdin"), c("SET NOCOUNT ON;", "GO", lines))
sqlplus <- \(lines) docker_run("ora", c("sqlplus", "-s", "-L", "system/oraclepw@localhost/FREEPDB1"),
  c("SET HEADING OFF FEEDBACK OFF PAGESIZE 0 DEFINE OFF NULL NULL SQLBLANKLINES ON", "SET MARKUP CSV ON DELIMITER | QUOTE OFF",
    lines, "EXIT"))
# one client session per engine; queries separated by @@i markers; errors = "Msg n" (MSSQL) / "ORA-n" (Oracle)
split_batch <- \(out, n) {
  lines <- strsplit(out, "\n")[[1]]; id <- cumsum(grepl("^@@\\d+$", lines))
  purrr::map(seq_len(n), \(i) {
    l <- lines[id == i][-1] |> trimws() |> purrr::discard(\(x) x == "")
    err <- grep("^(Msg \\d+|ORA-\\d+|SP2-\\d+)", l)
    if (length(err)) list("error", squish(l[err[1]:length(l)]) |> sub(pattern = " Help: https\\S+", replacement = "")) else
      list("ok", paste(l, collapse = "; "))
  })
}
# sqlcmd cuts "NULL" to the column width ("NU" in a 2-char column): restore it (no real value here is N/NU/NUL)
fix_null <- \(e) if (e[[1]] == "ok") list("ok", gsub("(?<=^|\\||; )(N|NU|NUL)(?=\\||;|$)", "NULL", e[[2]], perl = TRUE)) else e
mssql_engine <- \(ctr) \(sqls) sqlcmd(ctr, unlist(purrr::imap(sqls, \(s, i) c(sprintf("PRINT '@@%d';", i), "GO", s, "GO")))) |>
  split_batch(length(sqls)) |> purrr::map(fix_null)
ora_engine <- \(sqls) sqlplus(unlist(purrr::imap(sqls, \(s, i) c(paste0("PROMPT @@", i), paste0(s, ";"))))) |> split_batch(length(sqls))

engines <- list(duckdb = list(label = "duckdb", run = dbi_engine(con_d)), sqlite = list(label = "sqlite", run = dbi_engine(con_s)))
if (docker_up("mssql"))   engines$mssql15 <- list(label = "SQL Server 2022 (16.x)", run = mssql_engine("mssql"))
if (docker_up("mssql25")) engines$mssql17 <- list(label = "SQL Server 2025 (17.x)", run = mssql_engine("mssql25"))
if (docker_up("ora"))     engines$oracle  <- list(label = "Oracle Free 23.26 (26ai)", run = ora_engine)

# same rows in the real engines. Oracle: names quoted lowercase (as dbplyr quotes them), var1 NUMBER,
# flag NUMBER(1) as in pre-23ai schemas (no BOOLEAN type); df_upper = a typical unquoted (UPPERCASE) table
ddl_mssql <- c("DROP TABLE IF EXISTS df; DROP TABLE IF EXISTS df2;",
  "CREATE TABLE df (id INT, grp NVARCHAR(10), var1 FLOAT, name NVARCHAR(20), flag BIT, dt DATE);",
  "INSERT INTO df VALUES (1,'a',1,'alpha',1,'2024-01-01'), (2,'a',2.5,'beta  ',0,'2024-01-02'),",
  "  (3,'b',3.7,'',1,'2024-02-01'), (4,'b',NULL,NULL,NULL,'2024-02-29');",
  "CREATE TABLE df2 (id INT, name NVARCHAR(20), score FLOAT);",
  "INSERT INTO df2 VALUES (1,'ALPHA',10), (2,'BETA',20), (5,'EPS',50);", "GO")
ddl_ora <- c('DROP TABLE IF EXISTS "df";', 'DROP TABLE IF EXISTS "df2";', "DROP TABLE IF EXISTS df_upper;",
  'CREATE TABLE "df" ("id" NUMBER(10), "grp" VARCHAR2(10), "var1" NUMBER, "name" VARCHAR2(20), "flag" NUMBER(1), "dt" DATE);',
  sprintf("INSERT INTO \"df\" VALUES (%s);", c("1, 'a', 1, 'alpha', 1, DATE '2024-01-01'", "2, 'a', 2.5, 'beta  ', 0, DATE '2024-01-02'",
                                              "3, 'b', 3.7, '', 1, DATE '2024-02-01'", "4, 'b', NULL, NULL, NULL, DATE '2024-02-29'")),
  'CREATE TABLE "df2" ("id" NUMBER(10), "name" VARCHAR2(20), "score" NUMBER);',
  sprintf("INSERT INTO \"df2\" VALUES (%s);", c("1, 'ALPHA', 10", "2, 'BETA', 20", "5, 'EPS', 50")),
  "CREATE TABLE df_upper (id NUMBER, name VARCHAR2(10));", "INSERT INTO df_upper VALUES (1, 'x');", "COMMIT;")
for (ctr in c("mssql", "mssql25")) if (docker_up(ctr)) sqlcmd(ctr, ddl_mssql)
if (docker_up("ora")) invisible(sqlplus(ddl_ora))

# for `SELECT *, new AS x` queries keep only id + the new columns in exec_value (df has 6 columns)
trim_star <- \(sql, val) if (is.na(val) || !grepl('^SELECT (\\*|"df"\\.\\*), ', sql)) val else
  strsplit(val, "; ", fixed = TRUE)[[1]] |>
  purrr::map_chr(\(r) paste(strsplit(paste0(r, "|"), "|", fixed = TRUE)[[1]][-(2:6)], collapse = "|")) |> paste(collapse = "; ")
# fill exec_* for every row whose `dialect` has an engine (one batch per engine)
run_engines <- function(res) {
  res <- mutate(res, exec_engine = NA_character_, exec = if_else(is.na(sql), NA_character_, "not run"), exec_value = NA_character_)
  for (dn in intersect(names(engines), res$dialect)) {
    i <- which(res$dialect == dn & !is.na(res$sql)); ex <- engines[[dn]]$run(res$sql[i])
    res$exec_engine[i] <- engines[[dn]]$label; res$exec[i] <- purrr::map_chr(ex, 1)
    res$exec_value[i] <- purrr::map2_chr(res$sql[i], ex, \(s, e) clip(if (e[[1]] == "ok") trim_star(s, e[[2]]) else e[[2]], 300))
  }
  res
}

# dbplyr 2.6.0 bug: remote_query()/show_query() never return for union()/union_all()/bind_queries() on a
# dialect_mssql() lazy table (the MSSQL BIT post-processing walks into the dialect's numeric_version
# `version`, which contains itself). So those cases are tried in a child process with a timeout.
mssql_union_hangs <- \(expr, version, secs = 12) tryCatch({
  callr::r(\(expr, df, df2, version) {
    suppressPackageStartupMessages({library(dplyr); library(dbplyr)})
    con <- dialect_mssql(version); d <- tbl_lazy(df, con = con, name = "df"); d2 <- tbl_lazy(df2, con = con, name = "df2")
    remote_query(eval(expr))
  }, args = list(expr, df, df2, version), timeout = secs); FALSE
}, callr_timeout_error = \(e) TRUE)
is_union <- \(expr) any(all.names(expr) %in% c("union", "union_all", "bind_queries"))

# --- render one case on one dialect ---
# sql = remote_query() = what show_query()/collect() send; sql_render() skips the MSSQL BIT post-processing
render_case <- function(group, case, expr, dialect, env) {
  warns <- msgs <- character(); stage <- "build"; sql <- sql_r <- NA_character_; hung <- FALSE
  con <- dialects[[dialect]]
  err <- tryCatch(withCallingHandlers({
    res <- eval(expr, env); stage <- "render"
    sql_r <- squish(sql_render(res))
    if (inherits(con, "sql_dialect_mssql") && is_union(expr) && mssql_union_hangs(expr, as.character(con$version))) {
      # record the hang, then render with simulate_mssql() (same SQL otherwise) so the query can still be run
      hung <- TRUE; msgs <- c(msgs, "remote_query() with dialect_mssql() hung (killed after 12 s); SQL shown is from simulate_mssql()")
      res <- eval(expr, case_env(simulate_mssql(as.character(con$version))))
    }
    sql <- squish(remote_query(res)); NA_character_
  }, warning = \(w) { warns <<- c(warns, err_txt(w)); invokeRestart("muffleWarning") },
     message = \(m) { msgs <<- c(msgs, squish(cli::ansi_strip(conditionMessage(m)))); invokeRestart("muffleMessage") }),
  error = \(e) err_txt(e))
  tibble(part = "dialects", group = group, case = case, dialect = dialect, code = code_txt(expr),
         render = if (!is.na(err)) "error" else if (hung) "hang" else if (length(warns)) "warning" else "ok",
         failed_at = if (!is.na(err)) stage else NA_character_, render_error = err, sql = sql,
         sql_render_differs = !is.na(sql) && sql != sql_r,
         warnings = paste(warns, collapse = " || "), messages = paste(msgs, collapse = " || "))
}

# globals used by the NSE cases (same idea as 01-nse.R)
var1 <- 100; only_global <- 5; vec3 <- c(10, 20, 30); vec2 <- c(1, 2.5); na_g <- NA; cutoff <- as.Date("2024-01-02")

# alist(): keeps !! / .env unevaluated until each dialect evaluates the case
cases <- list(
  nse = alist(
    "global inlined (only_global)"   = mutate(d, x = only_global),
    ".env$var1 (col + global)"       = mutate(d, x = .env$var1),
    "!!var1 in filter"               = filter(d, var1 == !!var1),
    "global vector len 3 as value"   = mutate(d, x = vec3),
    "%in% global vector"             = filter(d, var1 %in% vec2),
    "NA global: var1 == na_g"        = filter(d, var1 == na_g),
    "is.na(var1)"                    = filter(d, is.na(var1)),
    "Sys.Date() in filter"           = filter(d, dt < Sys.Date()),
    "Date global (no !!)"            = filter(d, dt <= cutoff),
    "Date via !!cutoff"              = filter(d, dt <= !!cutoff),
    "Date via as.Date(!!chr)"        = filter(d, dt <= as.Date(!!format(cutoff))),
    "POSIXct via !!"                 = filter(d, dt <= !!as.POSIXct("2024-01-02 00:00:00", tz = "UTC")),
    "unknown fn foo()"               = mutate(d, x = foo(var1)),
    ".sql$abs()"                     = mutate(d, x = .sql$abs(var1)),
    "sql('ABS(var1)') raw SQL"       = mutate(d, x = sql("ABS(var1)"))
  ),
  etl = alist(
    "if_else"                        = mutate(d, x = if_else(var1 > 2, "hi", "lo")),
    "if_else missing="               = mutate(d, x = if_else(var1 > 2, "hi", "lo", missing = "none")),
    "case_when .default"             = mutate(d, x = case_when(var1 < 2 ~ "low", var1 < 3 ~ "mid", .default = "high")),
    "logical result column"          = mutate(d, x = var1 > 2),
    "TRUE literal column"            = mutate(d, x = TRUE),
    "coalesce"                       = mutate(d, x = coalesce(var1, 0)),
    "paste (NULL name)"              = mutate(d, x = paste(grp, name)),
    "paste0 (NULL name)"             = mutate(d, x = paste0(grp, name)),
    "str_c (NULL name)"              = mutate(d, x = str_c(grp, name)),
    "nchar (trailing spaces, '')"    = mutate(d, x = nchar(name)),
    "str_length"                     = mutate(d, x = str_length(name)),
    "substr(name, 2, 3)"             = mutate(d, x = substr(name, 2, 3)),
    "str_sub(name, 2, 3)"            = mutate(d, x = str_sub(name, 2, 3)),
    "str_sub(name, -2) negative"     = mutate(d, x = str_sub(name, -2)),
    "str_detect regex ^a"            = filter(d, str_detect(name, "^a")),
    "str_detect fixed()"             = filter(d, str_detect(name, fixed("ph"))),
    "grepl"                          = filter(d, grepl("ph", name)),
    ".sql$REGEXP_LIKE (escape hatch)" = filter(d, .sql$REGEXP_LIKE(name, "^a")),
    "str_replace regex"              = mutate(d, x = str_replace(name, "a", "A")),
    "str_to_upper"                   = mutate(d, x = str_to_upper(name)),
    "str_trim"                       = mutate(d, x = str_trim(name)),
    "name == '' (empty string)"      = filter(d, name == ""),
    "name != ''"                     = filter(d, name != ""),
    "as.integer(2.5, 3.7)"           = mutate(d, x = as.integer(var1)),
    "as.integer(floor(var1))"        = mutate(d, x = as.integer(floor(var1))),
    "as.numeric(id)"                 = mutate(d, x = as.numeric(id)),
    "as.character(var1)"             = mutate(d, x = as.character(var1)),
    "as.Date('2024-03-01')"          = mutate(d, x = as.Date("2024-03-01")),
    "round(var1, 0)"                 = mutate(d, x = round(var1, 0)),
    "id %% 2"                        = mutate(d, x = id %% 2L),
    "id %/% 2"                       = mutate(d, x = id %/% 2L),
    ".sql$MOD(id, 2)"                = mutate(d, x = .sql$MOD(id, 2L)),
    "year()/month()"                 = mutate(d, y = year(dt), m = month(dt)),
    "date + 1"                       = mutate(d, x = dt + 1),
    "date + days(1)"                 = mutate(d, x = dt + days(1)),
    "add_days(dt, 1) (clock)"        = mutate(d, x = add_days(dt, 1L)),
    "difftime(dt, ref, days)"        = mutate(d, x = difftime(dt, as.Date(!!format(cutoff)), units = "days")),
    "date - date"                    = mutate(d, x = dt - !!cutoff),
    "date - as.Date(!!chr)"          = mutate(d, x = dt - as.Date(!!format(cutoff))),
    "today() in filter"              = filter(d, dt <= today()),
    "between()"                      = filter(d, between(var1, 1, 3)),
    "n_distinct"                     = summarise(d, x = n_distinct(grp)),
    "sum no na.rm"                   = summarise(d, x = sum(var1)),
    "sum na.rm = TRUE"               = summarise(d, x = sum(var1, na.rm = TRUE)),
    "mean/sd by group"               = summarise(d, .by = grp, m = mean(var1, na.rm = TRUE), s = sd(var1, na.rm = TRUE)),
    "median in summarise"            = summarise(d, x = median(var1, na.rm = TRUE)),
    "quantile in summarise"          = summarise(d, x = quantile(var1, 0.5, na.rm = TRUE)),
    "median in mutate (window)"      = mutate(d, .by = grp, x = median(var1, na.rm = TRUE)),
    "mean in mutate (window)"        = mutate(d, .by = grp, x = mean(var1, na.rm = TRUE)),
    "head(2)"                        = head(d, 2),
    "arrange + head"                 = d |> arrange(desc(var1)) |> head(2),
    "arrange(is.na()) + head"        = d |> arrange(is.na(var1), desc(var1)) |> head(2),
    "arrange(if_else(is.na())) + head" = d |> arrange(if_else(is.na(var1), 1L, 0L), desc(var1)) |> head(2),
    "slice_head(n = 2)"              = slice_head(d, n = 2),
    "slice_max(var1, n = 2)"         = slice_max(d, var1, n = 2),
    "arrange then filter"            = d |> arrange(var1) |> filter(id > 1),
    "lag/lead/row_number .order"     = mutate(d, .by = grp, .order = id, p = lag(var1), n = lead(var1), rn = row_number()),
    "cumsum window_order"            = d |> group_by(grp) |> window_order(id) |> mutate(x = cumsum(var1)) |> ungroup(),
    "row_number() no order"          = mutate(d, rn = row_number()),
    "filter(flag) logical col"       = filter(d, flag),
    "filter(!flag)"                  = filter(d, !flag),
    "filter(flag & var1 > 2)"        = filter(d, flag & var1 > 2),
    "filter(flag == TRUE)"           = filter(d, flag == TRUE),
    "distinct(grp)"                  = distinct(d, grp),
    "count(grp, sort = TRUE)"        = count(d, grp, sort = TRUE),
    "left_join suffix .x/.y"         = left_join(d, d2, by = "id"),
    "inner_join suffix = _l/_r"      = inner_join(d, d2, by = "id", suffix = c("_l", "_r")),
    "left_join then filter rhs"      = left_join(d, d2, by = "id") |> filter(score > 10),
    "union (distinct)"               = union(select(d, id), select(d2, id)),
    "union_all"                      = union_all(select(d, id), select(d2, id)),
    "bind_queries"                   = bind_queries(select(d, id), select(d2, id)),
    "setdiff"                        = setdiff(select(d, id), select(d2, id))
  )
)
case_env <- \(con) rlang::new_environment(lazy_tbls(con), parent = globalenv())
res_dialects <- purrr::imap(cases, \(cs, group) purrr::imap(cs, \(expr, case) purrr::imap(dialects, \(con, dname)
  render_case(group, case, expr, dname, case_env(con))) |> purrr::list_rbind()) |> purrr::list_rbind()) |>
  purrr::list_rbind() |> run_engines()

# --- sql_options(): same pipeline, four renderings; run each and compare rows to the default ---
opts <- list(default = sql_options(), cte = sql_options(cte = TRUE), use_star_FALSE = sql_options(use_star = FALSE),
             qualify_all_columns = sql_options(qualify_all_columns = TRUE))
pipe <- \(t) t$d |> left_join(t$d2, by = "id") |> mutate(z = var1 * 2) |> filter(z > 2)
sorted_rows <- \(v) paste(sort(strsplit(v, "; ", fixed = TRUE)[[1]]), collapse = "; ")
res_opts <- purrr::imap(dialects[c("duckdb", "sqlite", "mssql15", "oracle")], \(con, dname) {
  q <- pipe(lazy_tbls(con))
  purrr::imap(opts, \(o, oname) tibble(part = "sql_options", group = "sql_options", case = oname, dialect = dname,
    code = code_txt(body(pipe)), render = "ok", sql = squish(remote_query(q, sql_options = o)))) |> purrr::list_rbind()
}) |> purrr::list_rbind() |> run_engines() |>
  mutate(same_rows_as_default = if (all(exec == "ok")) purrr::map_lgl(exec_value, \(v) sorted_rows(v) == sorted_rows(exec_value[1])) else NA,
         .by = dialect)
# collect(sql_options =) on duckdb returns the same data frame as plain collect()
q_d <- pipe(lazy_tbls(con_d)); base <- arrange(collect(q_d), id)
collect_same <- purrr::map_lgl(opts, \(o) identical(arrange(collect(q_d, sql_options = o), id), base))

# --- how a real connection picks its dialect + the inspection helpers ---
sql_all <- \(con) purrr::keep(unlist(cases), \(e) !is_union(e)) |>   # union cases hang with dialect_mssql()
  purrr::map_chr(\(e) tryCatch(squish(suppressWarnings(remote_query(eval(e, case_env(con))))), error = \(x) "ERR"))
wd_tbl <- tbl(with_dialect(con_d, dialect_mssql()), "df", vars = names(df))  # vars=: skip the [df] field query duckdb can't parse
q_s <- filter(tbl(con_d, "df"), id > 2)
invisible(capture.output(show_query(q_s))); last_after_show <- last_sql()
invisible(sql_render(filter(tbl(con_d, "df"), id == 1))); last_after_render <- last_sql()   # sql_render() does not record
invisible(collect(head(tbl(con_s, "df2"), 1))); last_after_collect <- last_sql()             # collect() does, any connection
ora_up <- \(...) tbl_lazy(tibble(...), con = dialect_oracle(), name = "DF_UPPER")
res_conn <- tribble(
  ~case, ~dialect, ~value, ~sql,
  "class(sql_dialect(duckdb con))", "-", paste(class(sql_dialect(con_d)), collapse = "/"), NA,
  "class(sql_dialect(SQLite con))", "-", paste(class(sql_dialect(con_s)), collapse = "/"), NA,
  "with_dialect(duckdb con, dialect_mssql()) |> head(2)", "duckdb", NA, squish(remote_query(head(wd_tbl, 2))),
  "with_dialect(duckdb con, dialect_mssql()) |> union_all() (no hang: con is S4)", "-", squish(remote_query(union_all(wd_tbl, wd_tbl))), NA,
  "simulate_mssql() SQL identical to dialect_mssql() SQL, all non-union cases", "-",
    as.character(identical(sql_all(simulate_mssql()), sql_all(dialect_mssql()))), NA,
  "simulate_oracle() SQL identical to dialect_oracle() SQL, all non-union cases", "-",
    as.character(identical(sql_all(simulate_oracle()), sql_all(dialect_oracle()))), NA,
  "last_sql() after show_query()", "-", squish(last_after_show), NA,
  "last_sql() after a later sql_render() (unchanged?)", "-", squish(last_after_render), NA,
  "last_sql() after a later collect() on SQLite", "-", squish(last_after_collect), NA,
  "class(remote_query()) / class(sql_render())", "-", paste(class(remote_query(q_s))[1], class(sql_render(q_s))[1]), NA,
  "collect(sql_options = each) identical to collect() on duckdb", "-", paste(names(collect_same), collect_same, sep = "=", collapse = ", "), NA,
  "Oracle: lowercase R name vs UPPERCASE table: filter(id == 1)", "oracle", NA, squish(remote_query(filter(ora_up(id = 1), id == 1))),
  "Oracle: UPPERCASE R name: filter(ID == 1)", "oracle", NA, squish(remote_query(filter(ora_up(ID = 1), ID == 1))),
  "SQL Server: run the sql_render() text of filter(flag) (skips the BIT fix)", "mssql15", NA,
    squish(sql_render(filter(tbl_lazy(df, con = dialect_mssql(), name = "df"), flag))),
  "Oracle: session NLS_DATE_FORMAT (raw SQL)", "oracle", NA,
    "SELECT value FROM nls_session_parameters WHERE parameter = 'NLS_DATE_FORMAT'",
  "SQL Server: '2024-01-02' as DATETIME vs DATE under SET LANGUAGE French (raw SQL)", "mssql15", NA,
    "SET LANGUAGE French; SELECT CONVERT(VARCHAR(10), CAST('2024-01-02' AS DATETIME), 23) AS as_datetime, CAST('2024-01-02' AS DATE) AS as_date"
) |> mutate(part = "connection", group = "connection", render = "ok") |> run_engines()

res <- bind_rows(res_dialects, res_opts, res_conn)
save_results(res, "05-dialects.csv")
cat("rows:", nrow(res), "| engines executed:", paste(purrr::map_chr(engines, "label"), collapse = ", "), "\n")
res_dialects |> count(dialect, render, exec) |> print(n = 50)
