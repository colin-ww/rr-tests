# SQL Server and Oracle: what SQL does dbplyr write?

Script: `05-dialects.R` → `results/05-dialects.csv`.

## Short version

- You can see SQL Server or Oracle SQL without a database: `lazy_frame(..., con = dialect_mssql())` or `dialect_oracle()`, then `show_query()`.
- I rendered 87 small dplyr snippets for 6 dialects: SQL Server 15 and 17 (2025), Oracle, Postgres, duckdb and SQLite. The snippets are the 15 NSE cases from [01-nse.md](01-nse.md) plus 72 common SAS-to-R ETL steps.
- Then I **ran** every query that rendered on real engines in Docker: SQL Server 2022, SQL Server 2025 and Oracle Free 26ai, plus duckdb and SQLite. Postgres was rendered only.
- **SQL that renders is not SQL that works.** Some snippets rendered with no error but failed when run:
  - 11 of the 87 on SQL Server 2022, 10 on SQL Server 2025 and 12 on Oracle (about 1 in 8).
  - A few of these are wrong on purpose (`foo()`, `Sys.Date()`, an escape hatch meant for the other database).
  - Others ran, but gave a different answer than R.
- I found 4 dbplyr bugs and 1 likely bug. They are drafted under "Upstream candidates" below. None are filed.

## What was verified, and how

- "Rendered" means the SQL text made by dbplyr 2.6.0. No database is involved.
- "Ran" means that exact SQL ran in a Docker container in this sandbox, through `sqlcmd` or `sqlplus`. The SQL comes from `remote_query()`, which is what `collect()` sends.
- My Oracle was **26ai (23.26)**, which has a BOOLEAN type. Oracle 19c does not. Anything below about booleans on 19c comes from the docs. It is not from a run.
- The SQL Server "15" queries ran on SQL Server 2022 (16.x). dbplyr only changes its SQL at versions 11 and 17. So 15 and 16 give the same SQL.
- Source line numbers below are from the dbplyr GitHub source (dev version 2.6.0.9000). I checked that the installed 2.6.0 functions are the same for every cited piece.
- Full results are in `results/05-dialects.csv`, one row per case × dialect. The columns are:
  - `sql`
  - `render`: ok / warning / error / hang
  - `render_error`
  - `exec`: ok / error / not run
  - `exec_value`: the rows as `a|b; ...`. For `mutate()` cases it shows only `id|new column`.
    - Text from SQL Server and Oracle loses its **trailing spaces** in this column (a side effect of how `sqlcmd`/`sqlplus` output is read). So compare lengths, not the shown text.
- To run the queries again, start the 3 containers listed at the top of `05-dialects.R`, with the Docker daemon running. It takes about 2 minutes (72 seconds of that is waiting out the hang bug below).
  - Without the containers, the script still renders everything and runs duckdb and SQLite.
  - But it then **overwrites the CSV**, and the SQL Server/Oracle `exec` columns become "not run".
- I re-ran the script with all engines up. It gave the same CSV, except for row order in duckdb queries that have no `ORDER BY`.

## How to simulate SQL Server / Oracle (dbplyr 2.6.0)

```r
library(dplyr); library(dbplyr)
# a fake table: use your real column names (Oracle: usually UPPERCASE)
lf <- lazy_frame(ID = 1L, NAME = "a", DT = as.Date("2024-01-01"),
                 con = dialect_oracle(), .name = "MY_TABLE")
lf |> filter(NAME == "a") |> head(5) |> show_query()
# or start from a local tibble
tbl_lazy(my_df, con = dialect_mssql(version = "16.0"), name = "my_table") |> count(grp) |> show_query()
```

- The 2.6.0 help pages recommend `dialect_mssql()` / `dialect_oracle()` with `lazy_frame()` or `tbl_lazy()` (see `?"backend-mssql"` and `?"backend-oracle"`).
- `simulate_mssql()` and `simulate_oracle()` still work and are **not** deprecated. They gave identical SQL in all 84 cases that don't use union.
- `dialect_mssql(version =)` matters:
  - From `"11.0"`, dbplyr uses `TRY_CAST()` (`"10.0"` gives plain `CAST()`).
  - From `"17.0"` (SQL Server 2025), regex `str_detect()`, `str_replace()` and similar are translated.
  - In my 87 cases, 15 and 17 differed only for `str_detect(x, "^a")` and `str_replace()`.
- **Bug: `union()`, `union_all()` and `bind_queries()` never finish with `dialect_mssql()`.** `show_query()` and `remote_query()` hang at 100% CPU. Use `simulate_mssql()` for these. The hang does not happen with `simulate_mssql()` (verified). It also does not happen with a real connection wrapped in `with_dialect()` (verified on duckdb).
  - This only affects **simulation**. A real odbc connection is a different kind of R object, and the code never walks into it. This is expected from the code. It was checked with duckdb, not with a live SQL Server connection.

## How a real connection picks its dialect

dbplyr calls `sql_dialect(con)`:

1. If you wrapped the connection with `with_dialect(con, dialect_x())`, that wins (`R/sql-dialect.R:59-66`).
2. Otherwise dbplyr looks at the **connection class**:
   - **odbc**: the connection class is named after the database, e.g. `"Microsoft SQL Server"` or `"Oracle"`. dbplyr has methods for both (`R/backend-mssql.R:85`, `R/backend-oracle.R:50`). For SQL Server it reads the server version from `DBI::dbGetInfo(con)$db.version` (`R/backend-mssql.R:704-709`). So SQL Server 2025 gets the regex translations automatically. But see the compatibility-level gotcha under "Strings".
   - **ROracle**: class `OraConnection` gets the Oracle dialect (`R/backend-oracle.R:54`).
   - **JDBC** (RJDBC, new in 2.6.0): the dialect comes from the Java driver class. `oracle.*` gets Oracle and `com.microsoft.sqlserver.*` gets SQL Server (`R/backend-jdbc.R:48-100`). SQL Server over JDBC always gets the default version 15, so no regex. Fix: `with_dialect(con, dialect_mssql("17.0"))`.
   - **ADBC**: the dialect comes from the vendor name. SQL Server is mapped. **Oracle is not mapped**, so it falls back to the generic ODBC dialect (`R/backend-adbc.R:63-90`). Fix: `with_dialect(con, dialect_oracle())`.
   - An odbc database that dbplyr doesn't know gets the generic `dialect_odbc()`.
- To check on your machine, run `class(con)` and `class(sql_dialect(con))`. For SQL Server, also run `sql_dialect(con)$version`. If the class is `sql_dialect_mssql` or `sql_dialect_oracle` (and the SQL Server version matches what you simulate), the simulation above uses the same translation code as your connection.
- odbc, ROracle and JDBC are not installed here. The class names above come from dbplyr's source, not from a live connection.
- I tested `with_dialect()` on a duckdb connection: `head(2)` rendered `SELECT TOP 2 *`, and duckdb rejected it, as expected.
- `tbl(with_dialect(con, ...), "x")` fails if the dialect doesn't match the database. dbplyr checks the columns using the new dialect's quoting. Pass `vars =` to skip that check.

## Gotchas by topic (ran on real engines unless marked)

**Dates: the biggest Oracle risk**

- An R `Date` put into a query (`filter(dt <= cutoff)` or `!!cutoff`) becomes a **plain string**, `'2024-01-02'`.
  - SQL Server converts it, so it works.
  - **Oracle fails with `ORA-01861: literal does not match format string`.** A `POSIXct` fails the same way. Oracle reads date strings using `NLS_DATE_FORMAT`, which was `DD-MON-RR` here.
- Fix for SQL Server and Oracle: `filter(dt <= as.Date(!!format(cutoff)))`. Oracle gets `DATE '2024-01-02'` and SQL Server gets `TRY_CAST('2024-01-02' AS DATE)`.
  - It returned the right rows on SQL Server 2022, SQL Server 2025, Oracle and duckdb.
  - **On SQLite it runs but returns 0 rows.** SQLite turns `CAST('2024-01-02' AS DATE)` into the number 2024, and it stores R dates as day numbers. (SQLite has no date type; see [01-nse.md](01-nse.md#where-database-and-in-memory-differ).)
- **SQL Server with French as the language:** under `SET LANGUAGE French`, `CAST('2024-01-02' AS DATETIME)` gives **2024-02-01**. Day and month are swapped. `CAST(... AS DATE)` and `CAST(... AS DATETIME2)` are fine. So comparing a string date to a `DATETIME` column depends on the login language. (This was a raw SQL check, not a dbplyr query.)
- `Sys.Date()` inside a query fails on every engine when run. Use one of these instead:
  - `today()`: translated to `CAST(SYSDATETIME() AS DATE)` on SQL Server and `TRUNC(CURRENT_TIMESTAMP)` on Oracle. It ran with no error on both. (Weak test: all test dates are in 2024, so every row passes.)
  - `!!Sys.Date()` combined with the `as.Date()` fix above.
- Adding days:
  - `dt + 1` works only on Oracle (SQLite just adds to the number). SQL Server gives `Operand type clash`, and duckdb fails too.
  - `dt + days(1)` ran only on duckdb. It fails on SQL Server, Oracle and SQLite. Postgres renders `MAKE_INTERVAL(days => 1)` (not run).
  - **Use `clock::add_days(dt, 1L)`.** It becomes `DATEADD` on SQL Server and `NUMTODSINTERVAL` on Oracle. It ran correctly on SQL Server, Oracle and duckdb. It fails on SQLite.
- Days between two dates:
  - `dt - !!cutoff` fails on SQL Server and Oracle.
  - `difftime(dt, as.Date(!!chr), units = "days")` is correct on SQL Server and duckdb. **On Oracle the sign is flipped.** It gave 1, 0, -30, -58 instead of -1, 0, 30, 58 (dbplyr bug).
  - On Oracle use `dt - as.Date(!!chr)`. It ran correctly on Oracle but fails on SQL Server.

**Strings**

- On SQL Server, `nchar()` and `str_length()` become `LEN()`, which **ignores trailing spaces**. `"beta  "` gives 4, not 6. `str_sub(x, -2)` also uses `LEN()`. If values can have trailing spaces, apply `str_trim()` first.
- **On Oracle, `''` is NULL.** An inserted `''` came back as NULL. This means:
  - `nchar("")` gives NULL.
  - `filter(name == "")` returns 0 rows.
  - **`filter(name != "")` also returns 0 rows. It drops every row, even "alpha".**
  - On Oracle, test with `!is.na(name)` instead.
- Joining strings when one value is NULL gives different answers everywhere. Example row: `grp = "b"`, `name = NULL`:
  - R: `paste()` gives `"b NA"` and `str_c()` gives `NA`.
  - SQL Server (`+`): NULL for `paste`, `paste0` and `str_c`.
  - Oracle (`||`): `"b "` for `paste` (the space stays) and `"b"` for `paste0`/`str_c`. Oracle treats NULL as an empty string.
  - duckdb (`CONCAT_WS`): `"b"`. Postgres renders the same `CONCAT_WS` (not run).
  - SQLite: `paste` gives NULL and `str_c` gives `"b"`.
  - To get the same answer everywhere, say what you want: `coalesce(name, "")`. (SAS `CATS`/`CATX` skip missing values.)
- Regex:
  - `str_detect(x, "^a")` **fails at render** on SQL Server before 2025, on Oracle and on SQLite: "Only fixed patterns are supported".
  - On SQL Server 2025 it becomes `REGEXP_LIKE` and ran correctly.
  - **But `REGEXP_LIKE` needs database compatibility level 170.** (The compatibility level is a per-database setting that decides which SQL features that database accepts.)
    - On SQL Server 2025, in a database set to level 160 (common after an upgrade), it failed with `Msg 195 'REGEXP_LIKE' is not a recognized built-in function name`.
    - `REGEXP_REPLACE` (used by `str_replace()`) still worked at level 160.
    - dbplyr chooses the version from the *server* version, not the database level.
    - Check with `SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()`. If it is below 170, use `with_dialect(con, dialect_mssql("16.0"))` and `fixed()` patterns.
    - (Raw SQL check, not in the CSV.)
  - On Oracle use `.sql$REGEXP_LIKE(name, "^a")`. It ran correctly on Oracle and on SQL Server 2025.
  - `str_detect(x, fixed("ph"))` works everywhere. SQL Server uses `CHARINDEX` and Oracle uses `INSTR`, which are true fixed matches.
  - **On duckdb, `fixed()` is ignored.** `fixed(".")` became `REGEXP_MATCHES(x, '.')` and matched every row. So a pattern with `.`, `(`, `+` and so on can give different rows on local duckdb than on SQL Server/Oracle.
- `grepl()` is not translated for SQL Server, Oracle or SQLite. It is passed through and fails when run. Use `str_detect()`.

**Numbers**

- **`as.integer()` rounds on SQL Server and Oracle.** For 2.5 and 3.7:
  - R gives 2 and 3. It truncates, like SAS `INT()`.
  - SQL Server gives **3 and 4**. dbplyr casts to `NUMERIC` first, and that rounds.
  - Oracle gives 3 and 4 (`CAST(x AS INT)`).
  - duckdb gives 2 and 4.
  - SQLite gives 2 and 3.
  - Fix: `as.integer(floor(x))` gave 1, 2, 3 on all 5 engines. For negative numbers, `floor()` and truncation differ.
- `round(2.5)`:
  - R gives 2 (it rounds half to even), and so does duckdb.
  - SQL Server, Oracle and SQLite give 3. They round half away from zero, like SAS `ROUND`.
- `x %% 2` on Oracle renders `"x" % 2`, which fails with **`ORA-00911`** (dbplyr bug). On Oracle use `.sql$MOD(x, 2L)`. It ran correctly there, but SQL Server has no `MOD`.
- `x %/% 2` is not translated for SQL Server, Oracle, Postgres or SQLite. It fails at render.

**TRUE/FALSE (SQL Server BIT, Oracle before 23ai)**

- `filter(flag)` on SQL Server:
  - `show_query()` shows `WHERE (cast([flag] AS [BIT]) = 1)`, and it runs.
  - **`sql_render()` shows `WHERE ([flag])`, and SQL Server rejects it** (`Msg 4145`, verified).
  - `sql_render()` skips SQL Server's fix-up step. Always look at `show_query()` or `remote_query()`.
- `mutate(x = var1 > 2)` on SQL Server becomes `CAST(CASE WHEN ... THEN 1 ELSE 0 END AS BIT)`. **NA turns into 0 (FALSE).** R, duckdb, SQLite and Oracle 26ai keep it as NA/NULL.
- A TRUE/FALSE expression in `arrange()`, such as `arrange(is.na(x))`, renders `ORDER BY ([x] IS NULL)` on SQL Server. That is a **syntax error** (dbplyr bug). Use `arrange(if_else(is.na(x), 1L, 0L), ...)` instead. It ran correctly on all 5 engines.
- Oracle before 23ai has no BOOLEAN type in SQL:
  - `mutate(x = var1 > 2)` renders `"var1" > 2.0 AS "x"`.
  - `mutate(x = TRUE)` renders `TRUE AS "x"`.
  - `filter(flag == TRUE)` renders `"flag" = TRUE`.
  - `filter(flag)`, `filter(!flag)` and `filter(flag & ...)` render `WHERE ("flag")` / `NOT("flag")` on a 0/1 number column.
  - All of these ran on 26ai. **They should fail on 19c.** This comes from dbplyr's own `?"backend-oracle"` note and oracle-base.com. Not verified.
  - On 19c use `if_else(cond, 1L, 0L)` and `filter(flag == 1)`.

**Row limits, sorting, windows**

- `head(n)` becomes `SELECT TOP n` on SQL Server, `FETCH FIRST n ROWS ONLY` on Oracle, and `LIMIT n` elsewhere. `FETCH FIRST` needs Oracle 12c or later (from Oracle docs, not tested).
- **NULLs sort in different places:**
  - `arrange(desc(var1)) |> head(2)`: Oracle returned the **NULL row first**. SQL Server, duckdb and SQLite returned 3.7 and 2.5.
  - `arrange(var1)`: SQL Server and SQLite put NULL first. Oracle and duckdb put it last.
  - R always puts NA last.
  - Fix: `arrange(if_else(is.na(var1), 1L, 0L), desc(var1))`.
- `row_number()` with no order: SQL Server gets `ORDER BY (SELECT NULL)`, which means any order. Oracle fails with `ORA-30485`. Always give an order: `.order =`, `window_order()` or `arrange()`.
- `mutate(.by = grp, .order = id, p = lag(var1), rn = row_number())`, and `cumsum()` with `window_order()`, ran the same on every engine.
- `slice_head()` is not supported on any database and fails at render. Use `head()`, `slice_min()` or `slice_max()`.
- `median()` and `quantile()`:
  - Inside `summarise()`: **fails at render on SQL Server**. dbplyr's message suggests `mutate()` + `distinct()`. Oracle is fine (`PERCENTILE_CONT`).
  - Inside `mutate(.by =)`: SQL Server and Oracle are fine. Postgres and SQLite are not.
- `sum(x)` or `mean(x)` without `na.rm = TRUE` warns "Missing values are always removed in SQL aggregation functions". By default this warning shows **only once every 8 hours** per R session, so you will usually miss it. In 2.6.0, `n_distinct()` warns the same way (except on duckdb).

**Joins and set operations**

- The default `left_join()` suffixes create column names like `"name.x"`. They are valid, but SQL always needs quotes around them. On Oracle and SQL Server, prefer `suffix = c("_x", "_y")`.
- `setdiff()` becomes `MINUS` on Oracle and `EXCEPT` elsewhere. It ran correctly.
- `union()`, `union_all()` and `bind_queries()` ran correctly everywhere. Because of the hang bug, the SQL Server SQL for these came from `simulate_mssql()`.

**The NSE cases from 01-nse.md on the new dialects**

- A global vector of length > 1 used as a value renders `(10.0, 20.0, 30.0)`. That is a syntax error on SQL Server (`Msg 102`), on Oracle (`ORA-00907`) and on SQLite.
- An NA global in a comparison becomes `= NULL`, which returns 0 rows on every engine.
- Unknown functions are passed through and fail only when run, with the database's own error message. Examples: `foo()`, `Sys.Date()`, `grepl()`, and `days()` on SQL Server and Oracle.
- `.sql$abs(var1)` works everywhere.
- **`sql("ABS(var1)")` fails on Oracle** with `ORA-00904: "VAR1"`. Oracle turns unquoted names into UPPERCASE, but the column is `"var1"`.
- **Oracle UPPERCASE names:**
  - Oracle stores normal (unquoted) table and column names in UPPERCASE.
  - dbplyr always quotes names, so case matters.
  - On such a table, `filter(id == 1)` renders `"id"` and fails with `ORA-00904`. `filter(ID == 1)` works (verified).
  - Use the real names, or `rename_with(tolower)` once at the start.

## `sql_options()`: three ways to write the same query

You can pass `sql_options()` to `show_query()`, `remote_query()`, `collect()` and `compute()`. It changes only the SQL text. It does not change NSE or results:

- On duckdb, I collected the same join + mutate + filter pipeline with all four settings. The data frames were identical.
- I also ran all four settings on SQL Server 2022, Oracle 26ai and SQLite. They returned the same rows each time.

```r
q <- d |> left_join(d2, by = "id") |> mutate(z = var1 * 2) |> filter(z > 2)
show_query(q)                                                    # default: nested subqueries
show_query(q, sql_options = sql_options(cte = TRUE))
show_query(q, sql_options = sql_options(use_star = FALSE))
show_query(q, sql_options = sql_options(qualify_all_columns = TRUE))
collect(q, sql_options = sql_options(cte = TRUE))                # same data as collect(q)
```

- `cte = TRUE`: each step becomes a named block, `WITH q01 AS (...), q02 AS (...) SELECT ...`, instead of nested subqueries. (CTE = "common table expression", SQL's name for a `WITH` block.) Use it to read or debug long pipelines, or to paste the SQL into SSMS or SQL Developer. It ran on SQL Server and Oracle.
- `use_star = FALSE`: lists every column name instead of `*` (or `"q01".*` on Oracle). Use it to see exactly which columns flow through, or when someone will maintain the SQL by hand.
- `qualify_all_columns = TRUE`: writes `"df"."grp"` instead of `"grp"` inside joins. By default, only columns that are in both tables get the table prefix. Use it if you copy the SQL and add more joins by hand, so no column is ambiguous.
- The old `cte =` argument of `show_query()`, `remote_query()`, `collect()` and `compute()` is deprecated, and it warns in a fresh session. Use `sql_options = sql_options(cte = TRUE)` instead.

Oracle output, default vs `cte = TRUE`. I shortened the SELECT lists to one line; dbplyr puts one column per line.

```sql
-- default
SELECT "q01".*
FROM (
  SELECT "q01".*, "var1" * 2.0 AS "z"
  FROM (
    SELECT "df"."id" AS "id", "grp", "var1", "df"."name" AS "name.x", "df2"."name" AS "name.y", "score"
    FROM "df"
    LEFT JOIN "df2"
      ON ("df"."id" = "df2"."id")
  ) "q01"
) "q01"
WHERE ("z" > 2.0)

-- sql_options(cte = TRUE)
WITH "q01" AS (
  SELECT "df"."id" AS "id", "grp", "var1", "df"."name" AS "name.x", "df2"."name" AS "name.y", "score"
  FROM "df"
  LEFT JOIN "df2"
    ON ("df"."id" = "df2"."id")
),
"q02" AS (
  SELECT "q01".*, "var1" * 2.0 AS "z"
  FROM "q01"
)
SELECT "q01".*
FROM "q02" "q01"
WHERE ("z" > 2.0)
```

## Which "show me the SQL" function to use

- `show_query(x)`: prints the SQL that `collect()` will send. Use this one.
- `remote_query(x)`: the same SQL, returned as a value (class `sql`). Use it to save or log the SQL.
- `sql_render(x)`: a lower-level function. It **skips the backend's final fix-up step**. On SQL Server it can show SQL that is not what runs (see the BIT example above). Avoid it for SQL Server. It also does not update `last_sql()`.
- `last_sql()`: the last SQL that dbplyr produced through `show_query()`, `remote_query()` or `collect()`, on any connection. It is handy right after a `collect()` error, to see what was actually sent. Verified:
  - After `show_query()`, it held that query.
  - A later `sql_render()` did not change it.
  - A later `collect()` on SQLite replaced it.
- `collect(sql_options = ...)` and `compute(sql_options = ...)` change only the SQL text (see above).
- In this repo, the harness (`R/harness.R`) records `sql_render()`. That is fine for duckdb and SQLite, where the text was the same in all 87 cases. For SQL Server, `05-dialects.R` records `remote_query()` instead. It flags the 6 rows where the two differ in the `sql_render_differs` column: `filter(flag)`, `filter(!flag)` and `filter(flag & var1 > 2)`, each on SQL Server 15 and 17.

## Upstream candidates (drafted, not filed)

Plain-language version (why it's a problem, what to expect, which package): [upstream-issues.md](upstream-issues.md#also-drafted-sql-server--oracle-bugs-and-targets--box-notes). Ready-to-paste text: items 1–5 below are drafts 6–10 in [upstream-drafts.md](upstream-drafts.md).


1. **dbplyr: `union()`, `union_all()` and `bind_queries()` hang with `dialect_mssql()`.** Root cause: the SQL Server fix-up step walks every list inside the query. That reaches the dialect's `version` field, a `numeric_version`, whose first element is itself. So the walk never ends.
   - Fix note (tested by patching locally): stopping the walk at *every* classed object is **not** a good fix. It drops the BIT cast on the right-hand side of a union (`WHERE ([f])`). Skipping only `numeric_version` / `sql_dialect` / `DBIConnection` objects fixed the hang and kept the cast in both unions and joins.
2. **dbplyr: Oracle `difftime()` has the sign flipped.** It renders `time2 - time1` (`R/backend-oracle.R:197-209`). The same bug was fixed for SQL Server, Snowflake and Redshift in tidyverse/dbplyr#1525 (closed).
3. **dbplyr: Oracle `%%` renders `%`**, which gives `ORA-00911`. It should be `MOD()`.
4. **dbplyr: SQL Server `arrange()` on a TRUE/FALSE expression gives an invalid `ORDER BY`.** The main `ORDER BY` is translated without the "ORDER" context that the SQL Server BIT logic checks for (`R/query-select.R:130`). With that context, dbplyr produces `CAST(CASE WHEN ([x] IS NULL) THEN 1 ELSE 0 END AS BIT)`, and that SQL ran on SQL Server 2022.
5. **dbplyr (likely bug): on Oracle, `Date` and `POSIXct` values put into a query are written as plain strings.** They only work if the session's `NLS_DATE_FORMAT` happens to match.
   - Postgres already has its own date escaping (`R/backend-postgres.R:496`, renders `'2024-01-02'::date`). Oracle has none.
   - `as.Date("...")` inside a query was already fixed to `DATE '...'` (tidyverse/dbplyr#1468 and #1389, both closed).
   - Related, also closed: #1213 "Dates in MS SQL aren't escaped properly" and #727 "Dates escaped incorrectly in Postgres" (titles seen, bodies not read).
- Possible doc note, not a bug: SQL Server 2025 regex translations assume database compatibility level 170 (see "Strings"). The feature came from tidyverse/dbplyr#1671 "support SQL Server 2025 regexp functions?" (closed). I found no issue about compatibility levels.

## Caveats

- Oracle was 26ai, not 19c. The boolean notes for 19c are not verified.
- Postgres was rendered only.
- On duckdb, `today()` failed here only because duckdb could not download its ICU extension in this sandbox.
- The runs used `sqlcmd` and `sqlplus`, not odbc. Your ODBC driver or login can set things like `NLS_DATE_FORMAT` or the login language, which change how dates behave. To check Oracle, run `SELECT value FROM nls_session_parameters WHERE parameter = 'NLS_DATE_FORMAT'` on your connection.
- SQL Server and Oracle text in `exec_value` has trailing spaces removed (see "What was verified").

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
