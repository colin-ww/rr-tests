# collect() speed, column types, joins and file IO: SQL Server and Oracle from R

Every number here comes from a script in this folder. The CSVs are in `results/`, and `docs/` explains each part in plain language. To run it on your own servers, see [docs/run-at-statcan.md](docs/run-at-statcan.md).

**Setup used:** SQL Server 2022 (16.0 CU28) and Oracle AI Database 26ai Free (23.26.4), in Docker on the **same 4-core, 15 GB Linux machine as R**. So there is **no network** in these numbers: on your servers everything takes longer, and the network part is what's missing here. Drivers: Microsoft ODBC Driver 18.7 and Oracle Instant Client 23.26 ODBC through the **odbc** package (1.7.2), plus **ROracle** 1.5-1 (Oracle's own client library, no ODBC). **duckdb** in-process is the floor: what R itself costs with no driver and no network. The test tables are generated on each server, with the same values everywhere.

## Short version

1. **`collect()` time is a straight line in rows**: 10× the rows is 10× the time, from 100k to 100M. **Rows cost more than values.** The odbc package fetches one row per ODBC call, so 10M values come ~2× faster as 1M rows × 10 columns than as 10M × 1. [03](docs/03-collect.md)
2. **The driver matters more than the type.** Per row, Oracle via odbc was **~3× slower than SQL Server** via odbc. Oracle via **ROracle** was as fast as SQL Server, and `bulk_read = 10000L` halved its time again for numbers. For Oracle odbc, `FBS=1048576;` in the connection string gave 25-30% for free. [03](docs/03-collect.md), [07](docs/07-driver-knobs.md)
3. **Numbers all cost about the same** (int, double, logical: ±10%). **All zeros vs random 1-2 million makes no difference** to collect. It does change file sizes. **Text is the expensive type**: unique 20-character strings cost 2-3× an int, and half of that is R itself making the strings. [03](docs/03-collect.md)
4. **A table stored as all-text collects 2.2-6× slower** than the same data with proper types, and converting afterwards in R adds more. If you're stuck with one, **CAST in SQL before `collect()`** (dbplyr's `as.integer()` etc. do it). That brings you back to near the typed speed. [04](docs/04-convert-join.md)
5. **`mutate(age = age + 1L)` before or after `collect()`: no difference.** `collect()` is ~99% of the time. But new columns are cheaper in R: SQL has to send them over. Rule: on the server, what makes data **smaller** (filter, aggregate, semi-join: 4-14× faster). In R, what makes it **bigger** (derived columns, labels from a small lookup table). [02](docs/02-mutate.md), [04](docs/04-convert-join.md)
6. **Files:** <!-- 05-SHORT --> [05](docs/05-io-formats.md)
7. **GTTs / temp tables belong to one session.** A fresh R process (callr, crew, targets) can't see them, except SQL Server `##global` ones. An Oracle GTT's default `ON COMMIT DELETE ROWS` empties it at the very next autocommit. dbplyr's `compute()` on Oracle makes a *private* temp table, not a GTT. Use normal tables for benchmarks. [06](docs/06-temp-tables.md)
8. **Measure in a fresh R process per case** (`callr::r()`). In one process, an earlier big result made later string collects 15-37% faster. `bench::mark()` is right for milli/microsecond things. For seconds-long collects, its default `filter_gc = TRUE` silently threw away 3-4 of 5 iterations. [00](docs/00-method.md)
9. **Memory:** while collecting, budget **~2× the final size of numeric columns** (odbc grows its buffers by doubling) on top of what's already in the session. The first big collect in a fresh session spent about a third of its time in R's garbage collector (10M unique strings). `R_NSIZE`/`R_VSIZE` at start-up cut that by 12-44%, at the cost of a higher peak. To get a table bigger than your pod's memory into a file, **stream it**: `dbFetch()` chunks into one parquet file used ~1/6 of the memory and was 15% faster than collect + write. [03](docs/03-collect.md), [07](docs/07-driver-knobs.md)
10. **Oracle text needs `NLS_LANG=AMERICAN_AMERICA.AL32UTF8`.** Without it, 'Québec' silently arrives as 'Quebec' (odbc) or 'Qu??bec' (ROracle). [07](docs/07-driver-knobs.md)

## Your questions, one by one

| you asked | short answer | details |
|---|---|---|
| Lazy `mutate()` that doesn't change the size (`age + 1`), then collect, vs collect then mutate? | Same time within noise (±5%). The R mutate on 10M rows takes 0.02 s; `collect()` is the rest. **Use `1L`**: `age + 1` becomes `age + 1.0` in SQL and comes back as a double (twice the memory). | [02](docs/02-mutate.md) |
| Time `tbl \|> mutate()` (\*) to know how long the pre-collect part took? | It doesn't measure the database: a lazy `mutate()` only builds the query in R (~6 ms), and nothing runs until `collect()`. To see the server's share, time `compute()`: same query, result stored on the server, no transfer. Through odbc that was 13-19% of a collect at 1M rows. | [02](docs/02-mutate.md#how-to-see-the-databases-own-time-if-you-need-it) |
| Time (\*\*) to compare collect vs mutate ×2? | Done for `age + 1L`, `age + 1` and 5 derived columns, in SQL and in R, 1M and 10M rows, 4 engines. 5 derived columns in SQL then collect: 18% (SQL Server) to 60% (Oracle odbc) **slower** than collect then mutate in R. | [02](docs/02-mutate.md) |
| Collect time per type, 1 column × 100k-100M rows: chr1, chr2, lgl, float, int | Linear in rows. SQL Server ~210-230 ns/row for any number type, 1-char text 1.4×, 20-char text 1.8× (few values) to 3× (unique). 100M ints: 21 s (SQL Server), 74 s (Oracle odbc), 29 s (ROracle), 0.8 s (duckdb). "chr1, chr2": I took that as short vs longer text, with few vs many distinct values. | [03](docs/03-collect.md) |
| Does int all 0s vs a 1-2M runif mix matter? | **Not for collect**: 2.14 vs 2.32 s (SQL Server), identical on Oracle. Over ODBC an int is a fixed 4 bytes. It matters a lot for **compressed files** (05). | [03](docs/03-collect.md), [05](docs/05-io-formats.md) |
| Then 2, 10, 100 columns? | Per value, wide is cheaper: SQL Server ~140 ns per row + ~95 per value, Oracle odbc ~410 + ~310, ROracle ~180 + ~70. So keeping 1 of 10 columns cut the time ~80%, not 90%. Filtering rows pays off in full. | [03](docs/03-collect.md#rows-vs-columns-the-same-10m-int-values-different-shapes-seconds) |
| Type conversion or joins before vs after collect? | Text → types: **in SQL** (2.5-8× faster than collect-then-convert). Number → text: in R. Small lookup join: **in R** (labels aren't sent for every row). 1:1 join: about even. Filtering join: **in SQL**, 4-14× faster and 1/10 of the memory. | [04](docs/04-convert-join.md) |
| Then IO: collect → mutate → write rds / qs / parquet / feather / csv / csv.gz | <!-- 05-ANSWER --> `qs` is archived on CRAN, so its successor `qs2` (same author) was tested. | [05](docs/05-io-formats.md) |
| "Will do this via GTT, works on both Oracle and SQL Server?!" | Both have them, but **temp data is per session**, so a fresh R process per case can't see it (SQL Server `##` aside). Oracle GTTs need `ON COMMIT PRESERVE ROWS`, or the autocommit empties them. And an Oracle GTT needs CREATE TABLE rights anyway. → Plain `bm_*` tables, made on the server by `00-setup-tables.R`, dropped by `99-drop-tables.R`. | [06](docs/06-temp-tables.md) |
| What packages for benchmarking, and why? | **bench** (`hires_time()` timer, `mark()` for sub-second things), **callr** (fresh process per case), **lobstr** (`obj_size()`), `/proc/self/status` for peak RSS. Not needed here: microbenchmark (ns precision, no memory info), tictoc (logging real pipelines), atime (scaling curves: a good alternative for the rows sweep), profvis (*where* the time goes). | [00](docs/00-method.md#which-packages-and-why) |
| Avoid caching / GC: callr or withr, or does bench do that? | **callr.** withr only changes and resets *settings* (options, env vars, temp files) inside the same process: same heap, same caches. **bench doesn't isolate** and doesn't `gc()` between iterations. With its defaults it does one untimed extra run (a warm-up). Database caches can't be flushed without DBA rights, so use the untimed first call and compare warm medians. The OS file cache *can* be evicted per file without root (05 does it). | [00](docs/00-method.md#what-benchmark-does-and-doesnt-do-read-from-bench-114s-source) |
| Do you already know the answers, or are they published? | Partly. Known: strings are R's expensive type (R's global string cache), ROracle's `bulk_read` and the Oracle ODBC fetch buffer are documented tuning settings, and file-format benchmarks are everywhere (qs2 and arrow publish their own). Not published anywhere I know: **your** servers, network and k8s pods. That's what the scripts are for. New here: odbc's row-at-a-time cost model, the all-text penalty, the GC first-call effect, `bench::mark`'s `filter_gc` on DB pulls, and the dbplyr / odbc / Oracle gotchas below. | - |
| Other ideas? | Tried: Oracle `FBS`, ROracle `bulk_read`/`prefetch`, SQL Server `PacketSize`, chunked `dbFetch()` (no faster), streaming chunks into a parquet file (~85% less memory, 15% faster), 4 parallel connections (2-2.6× faster), R's GC start-up settings, `NLS_LANG`. Not tried: Arrow-native drivers (ADBC, arrow-odbc), JDBC, columnstore tables, server-side compression. | [07](docs/07-driver-knobs.md) |

## Gotchas found on the way (correctness, not speed)

- **Oracle `NLS_LANG` unset → accents lost** with both drivers (see 10 above).
- **SQL Server, ODBC Driver 18 on Linux, already returns UTF-8.** Setting odbc's `encoding = "windows-1252"` converts a second time: `QuÃ©bec` (VARCHAR only).
- **dbplyr 2.6.0: `as.Date(column)` on Oracle renders `DATE "col"`, which isn't valid SQL** (`ORA-00936`). Use `TO_DATE(col, "YYYY-MM-DD")`.
- **Oracle through odbc: every number is a double in R**, `NUMBER(1)` flags included (ROracle gives integer for those). Oracle `DATE` is POSIXct. Oracle 26ai `BOOLEAN` columns can't be read by either driver (`Invalid SQL data type <-25>`).
- **`age + 1` vs `age + 1L`** changes the column type on SQL Server and duckdb.
- **odbc `dbWriteTable(temporary = TRUE)` on SQL Server** makes a permanent table unless the name starts with `#` (only a warning).
- **Oracle `DROP TABLE` keeps the space** (recycle bin) unless you add `PURGE`. `99-drop-tables.R` does.
- **arrow 26: `ParquetFileWriter$create()` fails with its own default `properties =`** ("column_names is missing"). Pass `ParquetWriterProperties$create(names(tab))`.
- **`bench::mark()` defaults on seconds-long calls:** `filter_gc = TRUE` keeps only the iterations without a GC, and warns only when *none* are left.

## Files

| file | what | runtime here |
|---|---|---|
| `R/connect.R` | connections from env vars (`BENCH_MSSQL`, `BENCH_ORACLE`, `BENCH_RORACLE`), duckdb | - |
| `R/make-data.R` | the test tables, generated by SQL on each server; the grids | - |
| `R/bench.R` | `run_case()`: one fresh R process per case; first call, median of repeats, GC time, peak RSS | - |
| `00-setup-tables.R` | creates ~60 `bm_*` tables per server | ~15 min |
| `01-method.R` → [docs/00-method.md](docs/00-method.md) | one process vs fresh processes, `bench::mark()` settings, `interruptible`, `collect()` vs `dbGetQuery()` | ~10 min |
| `02-mutate-pre-post.R` → [docs/02-mutate.md](docs/02-mutate.md) | mutate in SQL or R, `compute()`, lazy-query build time, `age + 1` vs `1L` | ~60 min |
| `03-collect-types-rows-cols.R` → [docs/03-collect.md](docs/03-collect.md) | 13 types × 100k-100M rows, 1-100 columns, R classes, memory | ~45 min |
| `04-convert-join.R` → [docs/04-convert-join.md](docs/04-convert-join.md) | all-text table, conversions and joins in SQL or R | ~20 min |
| `05-io-formats.R` → [docs/05-io-formats.md](docs/05-io-formats.md) | 14 ways to write and read, warm and cold file cache, sizes, types kept | <!-- 05-TIME --> |
| `06-temp-tables.R` → [docs/06-temp-tables.md](docs/06-temp-tables.md) | GTT, private temp, `#`/`##`: who sees what, speed | ~2 min |
| `07-driver-knobs.R` → [docs/07-driver-knobs.md](docs/07-driver-knobs.md) | FBS, bulk_read, PacketSize, chunks, streaming, parallel, NLS_LANG, GC settings | ~45 min |
| `99-drop-tables.R` | drops all `bm_*` tables (with PURGE on Oracle) | - |
| `run-all.sh`, `build-report.R` | run everything; `results/tables.md`, charts, versions | - |
| [docs/run-at-statcan.md](docs/run-at-statcan.md) | packages, `.Renviron`, privileges, space, how to run | - |

## Versions

R 4.6.2 · dplyr 1.2.1 · dbplyr 2.6.0 · DBI 1.3.0 · odbc 1.7.2 · ROracle 1.5-1 · duckdb 2.0.0 · bench 1.1.4 · callr 3.8.0 · lobstr 1.2.2 · arrow 26.0.1 · nanoparquet 0.5.2 · qs2 0.4.0 · data.table 1.18.6.1 · readr 2.2.0 · vroom 1.7.1 ([results/versions.md](results/versions.md)). Servers: SQL Server 2022 Developer 16.0.4325.4 (CU28), Oracle AI Database 26ai Free 23.26.4. Drivers: Microsoft ODBC Driver 18.7.1.1 for SQL Server, Oracle Instant Client 23.26.4 (ODBC + OCI), unixODBC 2.3.12.

## Not covered

- **A real network**, and servers shared with other people. Everything here ran on one machine. The scripts are ready to run on your servers ([how](docs/run-at-statcan.md)).
- Oracle 19c (only 26ai Free was run; FBS, bulk_read and NLS_LANG work the same on 19c, and 19c has no BOOLEAN). Windows drivers. Kerberos / TLS overhead.
- Arrow-native transfer (ADBC drivers, arrow-odbc), JDBC (RJDBC), the `fst` format.
- Your filers for part 05: run it with `BENCH_DIR` pointing there.
