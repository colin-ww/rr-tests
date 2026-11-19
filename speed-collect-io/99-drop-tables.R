# Drop every bm_* table this benchmark created (and the duckdb file + BENCH_DIR/io files).
for (f in c("R/connect.R", "R/make-data.R")) source(f)
for (en in setdiff(db_engines(), "duckdb")) {
  con <- bench_con(en)
  tabs <- DBI::dbListTables(con) |> grep(pattern = "^bm_", value = TRUE)
  purrr::walk(tabs, \(t) drop_if_exists(con, t)); message(en, ": dropped ", length(tabs), " tables")
  DBI::dbDisconnect(con)
}
unlink(file.path(bench_dir(), c("bench.duckdb", "bench.duckdb.wal", "io")), recursive = TRUE)
