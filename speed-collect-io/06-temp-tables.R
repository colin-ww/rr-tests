# Part 6: "I'll make the test data in GTTs (global temporary tables). Does that work on Oracle and SQL Server?"
# Checks, on each server: who can see a temp table's rows (same session / a second connection /
# a fresh R process via callr), what dbplyr's copy_to()/compute(temporary = TRUE) and
# DBI::dbWriteTable(temporary = TRUE) create, and whether collect() from a temp table is any faster.
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

# run an expression, keep its value or error as one line of text
try_txt <- \(expr) tryCatch({
  msgs <- character()
  v <- withCallingHandlers(expr, message = \(m) { msgs <<- c(msgs, squish(conditionMessage(m))); invokeRestart("muffleMessage") },
                           warning = \(w) { msgs <<- c(msgs, paste("warning:", squish(conditionMessage(w)))); invokeRestart("muffleWarning") })
  paste0(if (is.data.frame(v)) paste(unlist(v), collapse = ", ") else paste(format(v), collapse = ", "),
         if (length(msgs)) paste0("  [message: ", paste(msgs, collapse = " | "), "]") else "")
}, error = \(e) paste("ERROR:", squish(cli::ansi_strip(conditionMessage(e))) |> sub(pattern = "^.*?(ORA-\\d+[^•]*|\\[SQL Server\\][^•]*).*$", replacement = "\\1") |> substr(1, 160)))
n_of <- \(con, sql_name) DBI::dbGetQuery(con, paste("SELECT COUNT(*) AS n FROM", sql_name))[[1]]
# count rows from a brand-new R process (what a callr / crew / targets worker would see)
n_in_child <- \(engine, sql_name) try_txt(callr::r(\(wd, engine, sql_name) {
  setwd(wd); source("R/connect.R"); con <- bench_con(engine); on.exit(DBI::dbDisconnect(con))
  tryCatch(DBI::dbGetQuery(con, paste("SELECT COUNT(*) AS n FROM", sql_name))[[1]],
           error = \(e) stop(gsub("\\s+", " ", conditionMessage(e)), call. = FALSE))
}, list(getwd(), engine, sql_name)))

checks <- list()
log_check <- \(engine, step, result) checks[[length(checks) + 1]] <<- tibble(engine = engine, step = step, result = result)
src <- '"bm_int_rand_1e6_1"'

if ("oracle" %in% engines()) {
  a <- bench_con("oracle"); b <- bench_con("oracle")
  for (t in c("BM_GTT_DEL", "BM_GTT_KEEP", "BM_GTT_CTAS")) try(DBI::dbExecute(a, paste("DROP TABLE", t)), silent = TRUE)
  DBI::dbExecute(a, "CREATE GLOBAL TEMPORARY TABLE bm_gtt_del (x NUMBER)")               # default: ON COMMIT DELETE ROWS
  DBI::dbExecute(a, "INSERT INTO bm_gtt_del SELECT LEVEL FROM dual CONNECT BY LEVEL <= 1000")
  log_check("oracle", "GTT, default ON COMMIT DELETE ROWS: 1000 rows inserted, then count (same session)", try_txt(n_of(a, "bm_gtt_del")))
  DBI::dbExecute(a, "CREATE GLOBAL TEMPORARY TABLE bm_gtt_keep (x NUMBER) ON COMMIT PRESERVE ROWS")
  DBI::dbExecute(a, "INSERT INTO bm_gtt_keep SELECT LEVEL FROM dual CONNECT BY LEVEL <= 1000")
  log_check("oracle", "GTT, ON COMMIT PRESERVE ROWS: count, same session", try_txt(n_of(a, "bm_gtt_keep")))
  log_check("oracle", "GTT, ON COMMIT PRESERVE ROWS: count, 2nd connection", try_txt(n_of(b, "bm_gtt_keep")))
  log_check("oracle", "GTT, ON COMMIT PRESERVE ROWS: count, fresh R process (callr)", n_in_child("oracle", "bm_gtt_keep"))
  log_check("oracle", "GTT: CREATE GLOBAL TEMPORARY TABLE ... ON COMMIT PRESERVE ROWS AS SELECT (1e6 rows)",
            try_txt({ DBI::dbExecute(a, paste("CREATE GLOBAL TEMPORARY TABLE bm_gtt_ctas ON COMMIT PRESERVE ROWS AS SELECT * FROM", src)); n_of(a, "bm_gtt_ctas") }))
  log_check("oracle", "dbplyr copy_to(temporary = TRUE): table name, count same session",
            try_txt({ copy_to(a, tibble(x = 1:3), "bm_tmp_copy", temporary = TRUE); n_of(a, "ORA$PTT_bm_tmp_copy") }))
  log_check("oracle", "dbplyr copy_to(temporary = TRUE): count, 2nd connection", try_txt(n_of(b, "ORA$PTT_bm_tmp_copy")))
  log_check("oracle", "dbplyr compute() (temporary = TRUE by default)",
            try_txt({ q <- tbl(a, "bm_int_rand_1e6_1") |> filter(x1 < 1100000L) |> compute(); paste(dbplyr::remote_name(q), "rows:", count(q) |> pull(n)) }))
  log_check("oracle", "DBI::dbWriteTable(temporary = TRUE) via odbc: what it creates",
            try_txt({ DBI::dbWriteTable(a, "bm_tmp_dbi", data.frame(x = 1:3), temporary = TRUE, overwrite = TRUE)
                      DBI::dbGetQuery(a, "SELECT temporary, duration FROM user_tables WHERE table_name = 'bm_tmp_dbi'") |>
                        mutate(rows_same_session = n_of(a, '"bm_tmp_dbi"'), rows_2nd_conn = n_of(b, '"bm_tmp_dbi"')) }))
  DBI::dbDisconnect(a); a <- bench_con("oracle")
  log_check("oracle", "after disconnect + reconnect: GTT still defined? rows?", try_txt(n_of(a, "bm_gtt_keep")))
  log_check("oracle", "after disconnect + reconnect: private temp table (ORA$PTT_)?", try_txt(n_of(a, "ORA$PTT_bm_tmp_copy")))
  # what you can do instead of a GTT: a plain table, visible to every session (needs the same CREATE TABLE privilege)
  for (t in c("BM_GTT_DEL", "BM_GTT_KEEP", "BM_GTT_CTAS", '"bm_tmp_dbi"')) try(DBI::dbExecute(a, paste("DROP TABLE", t)), silent = TRUE)
  DBI::dbDisconnect(a); DBI::dbDisconnect(b)
}

if ("mssql" %in% engines()) {
  a <- bench_con("mssql"); b <- bench_con("mssql")
  log_check("mssql", "dbplyr copy_to(temporary = TRUE): table name, count same session",
            try_txt({ copy_to(a, tibble(x = 1:3), "bm_tmp_copy", temporary = TRUE); n_of(a, "#bm_tmp_copy") }))
  log_check("mssql", "#local temp: count, 2nd connection", try_txt(n_of(b, "#bm_tmp_copy")))
  log_check("mssql", "#local temp: count, fresh R process (callr)", n_in_child("mssql", "#bm_tmp_copy"))
  log_check("mssql", "##global temp (SELECT INTO ##bm_g): count same session",
            try_txt({ DBI::dbExecute(a, paste("DROP TABLE IF EXISTS ##bm_g; SELECT * INTO ##bm_g FROM", "[bm_int_rand_1e6_1]")); n_of(a, "##bm_g") }))
  log_check("mssql", "##global temp: count, 2nd connection", try_txt(n_of(b, "##bm_g")))
  log_check("mssql", "##global temp: count, fresh R process (callr), creator still connected", n_in_child("mssql", "##bm_g"))
  log_check("mssql", "dbplyr compute() (temporary = TRUE by default)",
            try_txt({ q <- tbl(a, "bm_int_rand_1e6_1") |> filter(x1 < 1100000L) |> compute(); paste(dbplyr::remote_name(q), "rows:", count(q) |> pull(n)) }))
  log_check("mssql", "DBI::dbWriteTable(temporary = TRUE) via odbc: what it creates",
            try_txt({ DBI::dbWriteTable(a, "bm_tmp_dbi", data.frame(x = 1:3), temporary = TRUE, overwrite = TRUE)
                      c(plain_name = n_of(a, "bm_tmp_dbi"), hash_name = tryCatch(n_of(a, "#bm_tmp_dbi"), error = \(e) NA),
                        rows_2nd_conn = tryCatch(n_of(b, "bm_tmp_dbi"), error = \(e) NA)) }))
  DBI::dbDisconnect(a); Sys.sleep(1)   # the server drops it as the session closes; checking at once can still see it
  log_check("mssql", "##global temp after its creator disconnected: count, 2nd connection", try_txt(n_of(b, "##bm_g")))
  try(DBI::dbExecute(b, "DROP TABLE IF EXISTS bm_tmp_dbi"), silent = TRUE)
  DBI::dbDisconnect(b)
}
checks <- purrr::list_rbind(checks); print(checks, n = Inf, width = 250)

# --- is collect() from a temp table faster? same session, 5 calls each, median (no callr: temp tables need the session) ---
speed_child <- function(wd, engine) {
  setwd(wd); suppressPackageStartupMessages(library(dplyr)); for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)
  con <- bench_con(engine); on.exit(DBI::dbDisconnect(con))
  med <- \(sql_name) { DBI::dbGetQuery(con, paste("SELECT * FROM", sql_name))
    median(replicate(5, { gc(); t0 <- bench::hires_time(); x <- DBI::dbGetQuery(con, paste("SELECT * FROM", sql_name)); secs_since(t0) })) }
  purrr::map(c("int_rand", "chr20_hi"), \(ty) {
    src <- qi(engine, tbl_name(ty, 1e6))
    tmp <- if (engine == "mssql") {
      DBI::dbExecute(con, paste("SELECT * INTO #t FROM", src)); DBI::dbExecute(con, paste("SELECT * INTO ##t FROM", src))
      c(`#local temp` = "#t", `##global temp` = "##t")
    } else {
      DBI::dbExecute(con, paste("CREATE GLOBAL TEMPORARY TABLE bm_gtt_speed ON COMMIT PRESERVE ROWS AS SELECT * FROM", src))
      DBI::dbExecute(con, paste("CREATE PRIVATE TEMPORARY TABLE ora$ptt_speed ON COMMIT PRESERVE DEFINITION AS SELECT * FROM", src))
      c(`GTT (PRESERVE ROWS)` = "bm_gtt_speed", `private temp (ORA$PTT_)` = "ora$ptt_speed")
    }
    out <- tibble::tibble(engine = engine, table = tbl_name(ty, 1e6), kind = c("regular table", names(tmp)),
                          med_s = c(med(src), purrr::map_dbl(tmp, med)))
    if (engine == "mssql") DBI::dbExecute(con, "DROP TABLE #t; DROP TABLE ##t") else {
      DBI::dbExecute(con, "TRUNCATE TABLE bm_gtt_speed"); DBI::dbExecute(con, "DROP TABLE bm_gtt_speed"); DBI::dbExecute(con, "DROP TABLE ora$ptt_speed") }
    out
  }) |> purrr::list_rbind()
}
speed <- purrr::map(intersect(engines(), c("mssql", "oracle")), \(en) callr::r(speed_child, list(getwd(), en))) |> purrr::list_rbind()
print(speed)
bind_rows(checks, speed) |> save_results("06-temp-tables.csv")
