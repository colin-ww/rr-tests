# "I'll make the test data in GTTs": does that work on Oracle and SQL Server?

Script: `06-temp-tables.R` → `results/06-temp-tables.csv`. Checks on Oracle 26ai and SQL Server 2022 of who can see a temp table's rows: the same session, a 2nd connection from the same R, a fresh R process (callr, which is what every case here runs in, and what crew/targets workers are).

## Short version

- **Both have temp tables, they behave differently, and almost none of them can be seen from a fresh R process.** Temp table data belongs to *one session* (one connection). A callr / crew / targets worker opens its own connection, so it gets its own, empty view.
  - The only exception: a SQL Server **`##global`** temp table, which every session can see while the session that created it stays connected.
- So **for this benchmark, use normal tables** (`00-setup-tables.R`, dropped by `99-drop-tables.R`). On Oracle a GTT needs the CREATE TABLE privilege anyway, so if you can make a GTT you can make a normal table.
- **Oracle GTT trap: the default is `ON COMMIT DELETE ROWS`.** odbc and ROracle autocommit every statement, so the rows vanish right after the INSERT: 1000 rows inserted, then the count is **0**. Always write `ON COMMIT PRESERVE ROWS`.
- **dbplyr doesn't make GTTs on Oracle.** `copy_to(temporary = TRUE)` and `compute()` create an Oracle 18c+ **private temporary table** named `ORA$PTT_<name>`. It's visible only in this session and gone at disconnect.
- **SQL Server trap: odbc's `DBI::dbWriteTable(temporary = TRUE)` makes a normal, permanent table** unless the name starts with `#`. It only warns: "`temporary` is `TRUE`, but table name doesn't use # prefix".
- **Collect speed from a temp table is the same as from a normal table** (within ±10%, both servers).

## Who sees what

| server | kind | how it's made | same session | 2nd connection | fresh R process (callr) | after disconnect |
|---|---|---|---|---|---|---|
| Oracle | GTT, default | `CREATE GLOBAL TEMPORARY TABLE t (...)` | **0 rows** (deleted at the autocommit) | 0 | 0 | definition stays, empty |
| Oracle | GTT, `ON COMMIT PRESERVE ROWS` | `... ON COMMIT PRESERVE ROWS`, or `... AS SELECT` | ✅ rows | 0 rows | 0 rows | definition stays, empty |
| Oracle | private temp `ORA$PTT_` | dbplyr `copy_to(temporary = TRUE)`, `compute()` | ✅ rows | ORA-00942 (doesn't exist) | doesn't exist | gone |
| Oracle | GTT via odbc | `DBI::dbWriteTable(temporary = TRUE)` | ✅ rows | 0 rows | - | definition stays |
| SQL Server | `#local` | dbplyr `copy_to(temporary = TRUE)`, `compute()`, `SELECT ... INTO #t` | ✅ rows | "Invalid object name" | "Invalid object name" | gone |
| SQL Server | `##global` | `SELECT ... INTO ##t` | ✅ rows | ✅ rows | ✅ rows (while the creator is connected) | gone |
| SQL Server | **permanent!** | odbc `DBI::dbWriteTable(con, "t", df, temporary = TRUE)` | ✅ rows | ✅ rows | ✅ rows | **stays** (it's a normal `dbo` table) |

Notes:
- Oracle GTT rows from `DBI::dbWriteTable(temporary = TRUE)`: `user_tables` shows `TEMPORARY = Y, DURATION = SYS$SESSION`, i.e. `ON COMMIT PRESERVE ROWS`. odbc does that part right.
- SQL Server `##global`: it's dropped as the creating session closes. A query sent at the very moment of `dbDisconnect()` can still see it, so the check waits 1 s.
- On SQL Server any login can create `#` and `##` tables (they live in tempdb). You don't need CREATE TABLE rights in your database: that's their real advantage there.

## Collect speed: normal vs temp (same session, 5 calls, median seconds, 1M rows)

| server | table | normal | temp 1 | temp 2 |
|---|---|---|---|---|
| SQL Server | int | 0.252 | `#local` 0.234 | `##global` 0.223 |
| SQL Server | unique text | 0.601 | `#local` 0.617 | `##global` 0.525 |
| Oracle odbc | int | 0.771 | GTT 0.779 | `ORA$PTT_` 0.797 |
| Oracle odbc | unique text | 1.31 | GTT 1.31 | `ORA$PTT_` 1.27 |

## What this means for pipelines (not only benchmarks)

- `compute()` mid-pipeline is fine **inside one connection**. It gives the server a materialized intermediate result, and it's gone when you disconnect.
- With callr / crew / targets / mirai workers, **each worker is its own session**. A temp table made in the main process, or by another worker, doesn't exist there (SQL Server `##` aside). Pass a query, or write a normal (scratch) table, instead. This matches [the callr/crew notes](../../dbplyr-box-nse-callr-crew-targets/docs/03-callr-crew.md): connections can't be sent to workers, so each worker connects itself.
