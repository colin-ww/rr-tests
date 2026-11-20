# Part 3, extra: does the ORDER of unique strings change collect() time? -> results/03-string-order.csv
# The generated unique text ('value_00000000000001', '..02', ...) arrives in a regular sequence. R keeps
# every distinct string once, in a global hash table, and looks each new string up there. R's string hash
# is simple, so a run of similar strings lands in neighbouring slots: CPU-cache friendly. Real unique text
# (names, record IDs not sorted) arrives in no such order. Same values here, shuffled on the server.
# Found via part 05: the same data.frame, saved with rows shuffled, took 2.3x as long to readRDS().
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

shuf_name <- \(rows) paste0("bm_chr20_hi_", short_n(rows), "_shuf")
shuffle_sql <- \(engine, from, to) {
  f <- qi(engine, from); t <- qi(engine, to); x <- qi(engine, "x1")
  switch(dialect_of(engine),
    # SQL Server ignores ORDER BY in SELECT INTO (and CHECKSUM barely shuffles): MD5 order + clustered index
    mssql  = c(sprintf("SELECT CAST(ROW_NUMBER() OVER (ORDER BY HASHBYTES('MD5', %s)) AS INT) AS ord, %s INTO %s FROM %s", x, x, t, f),
               sprintf("CREATE UNIQUE CLUSTERED INDEX ix_ord ON %s (ord)", t)),
    oracle = sprintf("CREATE TABLE %s NOLOGGING AS SELECT %s FROM %s ORDER BY ORA_HASH(%s)", t, x, f, x),
    duckdb = sprintf("CREATE TABLE %s AS SELECT %s FROM %s ORDER BY hash(%s)", t, x, f, x))
}
# share of neighbouring rows whose numbers follow each other: ~1 in row order, ~0 when shuffled
seq_share <- \(con, name) tbl(con, name) |> head(1e5) |> collect() |> pull(x1) |> substring(7) |> as.numeric() |> diff() |>
  (\(d) mean(d == 1))()

rows <- c(1e6, 1e7)
for (en in db_engines()) {
  con <- bench_con(en)
  for (n in rows) { drop_if_exists(con, shuf_name(n)); purrr::walk(shuffle_sql(en, tbl_name("chr20_hi", n), shuf_name(n)), \(q) DBI::dbExecute(con, q)) }
  DBI::dbDisconnect(con)
}
res <- tidyr::expand_grid(engine = engines(), rows = rows, order = c("row order", "shuffled")) |>
  purrr::pmap(\(engine, rows, order) {
    name <- if (order == "shuffled") shuf_name(rows) else tbl_name("chr20_hi", rows)
    con <- bench_con(engine); seq <- seq_share(con, name); DBI::dbDisconnect(con)
    if (order == "shuffled" && seq > 0.01) stop(engine, " ", name, " isn't shuffled (seq_share ", seq, ")")
    run_case(engine, \(con, name) tbl(con, name) |> select(x1) |> collect(), list(name = name), iterations = 3,
             type = "chr20_hi", rows = rows, order = order, seq_share = seq)
  }) |> purrr::list_rbind()
save_results(res, "03-string-order.csv")
for (en in db_engines()) { con <- bench_con(en); for (n in rows) drop_if_exists(con, shuf_name(n)); DBI::dbDisconnect(con) }
