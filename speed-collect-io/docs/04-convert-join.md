# Type conversion and joins: on the server before collect(), or in R after?

Script: `04-convert-join.R` → `results/04-convert-join.csv`, `results/04-classes.csv`. Tables (1M rows; collect time is linear in rows, see [03](03-collect.md), so the ratios hold at 10M):

- `bm_mix_1e6`: 10 columns with proper types.
- `bm_mixstr_1e6`: **the same values, every column stored as text**. Dates are `'YYYY-MM-DD'`, numbers have 6 decimals, the flag is `'0'`/`'1'`. This is the "every column is a string so the parser can't guess wrong" schema.
- `bm_prov_lu`: 13 province codes, each with two ~32-character names.
- `bm_extra_1e6`: id + 4 more columns, 1:1 with `bm_mix_1e6`.

## Short version

- **Storing everything as text makes the collect itself 2.2 to 6 times slower**, before any conversion: SQL Server 7.3 s vs 2.4 s for the same 1M rows. In R the data is also **2.3× bigger** (337 vs 148 MB), because every number is now a string.
- **If you're stuck with an all-text table, convert in SQL, then collect.** dbplyr writes the CASTs for you (`mutate(x = as.integer(x))` etc.). That gets you within 10 to 40% of the typed table. Collecting text and converting in R took **2.5 to 8.4 times as long** as converting in SQL.
- `readr::type_convert(col_types = spec)` is as fast as base `as.integer()`/`as.numeric()`/`as.Date()`, and it uses more memory. The guessing that people fear only happens if you leave out `col_types`.
- **Number → text: do it in R.** In SQL it's slower (SQL Server 3.9 s vs 2.5 s), because text is more expensive to transfer than numbers.
- **Joins:**
  - **Small lookup table** (code → label): **join in R.** In SQL, the labels are sent again for every row. In R, only the codes travel, and the joined labels are shared strings. Oracle odbc took 4.5 s in R vs 7.1 s in SQL; SQL Server 2.8 vs 3.2.
  - **1:1 join** of two 1M-row tables: about even, SQL 8 to 18% faster (duckdb 33%). The same data travels either way, and R then has to do the join too.
  - **Filtering join** (`semi_join`, keep 10%): **in SQL, 4 to 14 times faster**, and the R process needed 34 MB instead of 292 MB. Never collect a table just to throw 90% of it away.
- **Oracle bugs and gotchas found here:**
  - **`as.Date(column)` is broken on Oracle in dbplyr 2.6.0.** It renders `DATE "ref_date"`, which is only valid for literals (`DATE '2024-01-01'`), so you get `ORA-00936: missing expression`. Use `TO_DATE(ref_date, "YYYY-MM-DD")` (unknown functions are passed through to SQL as they are). This is new: the earlier dialect notes in this repo only covered `as.Date()` of a literal, which works.
  - `as.integer()` in SQL on Oracle gives `CAST(x AS INT)`, which still arrives in R as a double (see 03).

## Seconds (median), 1M rows

| case | SQL Server | Oracle odbc | Oracle ROracle | duckdb |
|---|---|---|---|---|
| **typed table:** `collect()` | **2.44** | **3.90** | **1.63** | **0.55** |
| text table: `collect()`, no conversion | 7.26 | 9.20 | 3.63 | 3.48 |
| text table: convert in SQL, then `collect()` | **2.66** | **5.35** | **2.04** | **0.76** |
| text table: `collect()`, then convert in R (base `as.*`) | 10.06 | 13.42 | 7.02 | 6.39 |
| text table: `collect()`, then `readr::type_convert(col_types = spec)` | 9.66 | 12.59 | 7.09 | 6.86 |
| typed table: id to text in SQL, then `collect()` | 3.92 | 5.71 | 1.85 | 0.91 |
| typed table: `collect()`, then id to text in R | 2.51 | 3.97 | 1.71 | 0.55 |
| lookup join (13 rows) in SQL, then `collect()` | 3.21 | 7.06 | 1.94 | 0.81 |
| lookup join: `collect()` both, join in R | **2.80** | **4.53** | **1.63** | 0.86 |
| 1:1 join on id in SQL, then `collect()` | **3.11** | **6.42** | **2.86** | **0.67** |
| 1:1 join: `collect()` both, join in R | 3.68 | 6.96 | 3.16 | 0.89 |
| filtering join (keep 10%) in SQL | **0.25** | **1.11** | **0.78** | **0.14** |
| filtering join: `collect()` both, join in R | 3.45 | 7.01 | 3.11 | 0.87 |

The "Oracle odbc" text-to-types row in SQL uses `TO_DATE()` for the date (see above). Everything else is the same dplyr code on every engine.

## Memory, SQL Server (MB): result size / peak growth during the first call

| case | result | peak |
|---|---|---|
| typed table: `collect()` | 148 | 244 |
| text table: `collect()` | 337 | 456 |
| text table: convert in SQL, then `collect()` | 148 | 251 |
| text table: `collect()`, convert in R | 148 | 498 |
| text table: `collect()`, `readr::type_convert()` | 148 | 583 |
| filtering join in SQL | 15 | 34 |
| filtering join in R | 15 | 292 |

## What the conversions look like (`results/04-classes.csv`)

dbplyr's SQL for `mutate(across(c(id, age, flag), as.integer), across(c(income, wgt, amount), as.numeric), ref_date = as.Date(ref_date))`:

- SQL Server: `TRY_CAST(TRY_CAST([id] AS NUMERIC) AS INT)`, `TRY_CAST([income] AS FLOAT)`, `TRY_CAST([ref_date] AS DATE)`. `TRY_CAST` gives NULL instead of an error for bad values, just as R's `as.integer("x")` gives NA.
- Oracle: `CAST("id" AS INT)`, `CAST("income" AS NUMBER)`, and **`DATE "ref_date"`** (the bug). A bad value is then an error on Oracle (`ORA-01722: invalid number`), not NULL (Oracle behaviour, not tested here).
- duckdb: `TRY_CAST(id AS INTEGER)` etc.

The classes in R afterwards: SQL Server and duckdb give integer / double / Date. Oracle gives double for everything numeric and POSIXct for the date, same as a typed Oracle table.
