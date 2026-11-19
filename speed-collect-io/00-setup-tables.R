# Part 0: create the benchmark tables ON each server (no upload from R). Re-runs skip tables
# that already exist with the right row count. Drop everything with 99-drop-tables.R.
# Needs: CREATE TABLE in your schema (Oracle) / a database+schema you can write to (SQL Server).
# Size: ~12 GB per engine with the 1e8-row tables (03 drops those at the end unless BENCH_KEEP_BIG=true).
# Why not GTTs / #temp tables: see docs/06-temp-tables.md (session-private, so a fresh R process can't see them).
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

for (en in db_engines()) {
  con <- bench_con(en)
  # small to big, so a quota error hits the 1e8 tables last
  bind_rows(grid_narrow(en), grid_wide()) |> arrange(rows * k) |>
    purrr::pwalk(\(type, rows, k) tryCatch(make_table(con, en, type, rows, k),
                                           error = \(e) message(en, " ", tbl_name(type, rows, k), " FAILED: ", squish(conditionMessage(e)))))
  for (n in c(1e6, 1e7)) { make_mix(con, en, n); make_mixstr(con, en, n); make_extra(con, en, n) }
  make_lookup(con, en)
  DBI::dbDisconnect(con)
}
