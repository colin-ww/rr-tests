# mutate() before or after collect()?

Script: `02-mutate-pre-post.R` → `results/02-mutate.csv`, `results/02-lazy.csv`. Table `bm_mix_<n>`: 10 survey-like columns (id, age, sex, prov, income, wgt, ref_date, flag, name, amount), 1M and 10M rows.

## Short version

- **"Time to `tbl |> mutate()`" doesn't measure the database.** A lazy `mutate()` only builds the query in R: **~6 ms**, nothing runs on the server. `tbl()` costs one round trip (4 to 10 ms) to learn the column names. Making the SQL text (`show_query()`, `sql_render()`) takes 15 to 30 ms. The database does the work during `collect()`.
- **`age + 1L` in SQL, in R after collect, or not at all: the same time, within noise.** `collect()` is ~99% of the cost. The R mutate on 10M rows takes 0.02 s.
- **`age + 1` (not `1L`) changes the type.** dbplyr writes `age + 1.0`. SQL Server and duckdb then return a **double** instead of an integer, which doubles that column's memory. On Oracle everything is already a double. Use `1L`.
- **Deriving new columns costs more in SQL than in R**, because each new column is extra data to transfer. 5 typical derived variables (age group, income × weight, a 0/1 flag, year, a substring), 10M rows:
  - SQL Server: 30.9 s in SQL vs 26.1 s in R (**+18%**).
  - Oracle odbc: 71.1 s vs 44.3 s (**+60%**).
  - ROracle: 20.5 s vs 18.0 s (+14%).
  - The R side, `mutate5()` alone on 10M rows: 1.4 to 1.6 s on every engine.
- **What the database's own share is:** `compute()` runs the same query and stores the result on the server, with nothing sent to R. At 1M rows it took 0.36 s on SQL Server vs 2.7 s for `collect()`. So **~85-90% of a collect is moving rows and turning them into R vectors**, not computing them.
- **Rule of thumb** (from this and 03's "time is linear in rows"): do on the server what makes the data *smaller* (filter, aggregate, select columns, semi-joins). Do in R what makes it *bigger* (new columns, recodes, text labels), after collect. The middle ground (type changes, joins) is in [04](04-convert-join.md).

## Seconds: median, with the first call in a fresh process in brackets

| rows | case | SQL Server | Oracle odbc | Oracle ROracle | duckdb |
|---|---|---|---|---|---|
| 1M | `collect()` only | 2.72 (3.43) | 4.69 (6.20) | 1.61 (2.03) | 0.33 (1.02) |
| 1M | SQL: `mutate(age = age + 1L) \|> collect()` | 2.65 (3.29) | 4.66 (6.37) | 1.56 (2.09) | 0.60 (1.02) |
| 1M | SQL: `mutate(age = age + 1) \|> collect()` | 2.88 (3.55) | 4.80 (5.98) | 1.57 (1.95) | 0.54 (1.00) |
| 1M | R: `collect() \|> mutate(age = age + 1L)` | 2.59 (3.42) | 4.68 (6.03) | 1.60 (2.01) | 0.58 (0.91) |
| 1M | R: `mutate(age = age + 1L)` alone | 0.004 | 0.004 | 0.005 | 0.004 |
| 1M | SQL: `mutate(age = age + 1L) \|> compute()` | 0.36 | 0.90 | 0.79 | 0.12 |
| 1M | SQL: `mutate5() \|> collect()` | 3.31 | 7.26 | 2.10 | 0.62 |
| 1M | R: `collect() \|> mutate5()` | 2.78 | 4.67 | 1.97 | 0.82 |
| 1M | R: `mutate5()` alone | 0.14 | 0.14 | 0.18 | 0.13 |
| 10M | `collect()` only | 23.2 (31.0) | 45.8 (55.1) | 15.7 (20.5) | 4.6 (9.4) |
| 10M | SQL: `mutate(age = age + 1L) \|> collect()` | 23.5 (31.2) | 45.9 (54.2) | 16.8 (20.9) | 4.8 (8.9) |
| 10M | SQL: `mutate(age = age + 1) \|> collect()` | 25.0 (33.4) | 43.2 (53.5) | 17.6 (21.9) | 5.9 (9.0) |
| 10M | R: `collect() \|> mutate(age = age + 1L)` | 24.0 (33.1) | 41.9 (51.2) | 17.0 (20.9) | 5.1 (9.1) |
| 10M | R: `mutate(age = age + 1L)` alone | 0.02 | 0.02 | 0.02 | 0.02 |
| 10M | SQL: `mutate(age = age + 1L) \|> compute()` | 6.2 | 10.2 | 6.8 | 0.7 |
| 10M | SQL: `mutate5() \|> collect()` | **30.9** | **71.1** | 20.5 | 7.7 |
| 10M | R: `collect() \|> mutate5()` | **26.1** | **44.3** | 18.0 | 8.0 |
| 10M | R: `mutate5()` alone | 1.53 | 1.36 | 1.57 | 1.63 |

- `mutate5()` = `age_grp = case_when(...)`, `inc_w = income * wgt`, `ont = if_else(prov == "35", 1L, 0L)`, `yr = year(ref_date)`, `name10 = substr(name, 1L, 10L)`.
- At 10M rows the noise between the four `age + 1` rows (±5%) is bigger than any real difference.
- The first call in a fresh process is 20 to 35% slower here, duckdb 2× (10 columns, including unique strings: R's GC while the heap grows; see [03](03-collect.md#the-first-collect-in-a-fresh-r-session)).

## Building the lazy query (bench::mark, milliseconds, 1M-row table)

| step | SQL Server | Oracle odbc | ROracle | duckdb |
|---|---|---|---|---|
| `tbl(con, name)`: one round trip for the column names | 6.0 | 4.6 | 3.6 | 10.1 |
| `lazy \|> mutate(age = age + 1L)`: R only | 6.1 | 7.3 | 6.9 | 6.8 |
| `... \|> sql_render()`: make the SQL text | 25.6 | 17.7 | 14.9 | 31.5 |

## What `age + 1` sends, and what comes back

| engine | `age + 1L` | `age + 1` |
|---|---|---|
| SQL Server | `[age] + 1` → **integer** | `[age] + 1.0` → **double** |
| Oracle (odbc, ROracle) | `"age" + 1` → double | `"age" + 1.0` → double (Oracle NUMBER is always double in R) |
| duckdb | `age + 1` → integer | `age + 1.0` → double |

## How to see the database's own time, if you need it

- `compute()` (above) is the simplest: it times the database doing the work, with no transfer.
- On the server itself: SQL Server `SET STATISTICS TIME ON` or `sys.dm_exec_query_stats` (needs VIEW SERVER STATE). Oracle `V$SQL.ELAPSED_TIME` or `DBMS_XPLAN.DISPLAY_CURSOR` (needs access to the V$ views). Ask your DBA.
- Don't use `count()` after a `mutate()` to time it: the optimizer skips computing a column nobody reads.
