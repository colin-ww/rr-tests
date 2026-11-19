# Driver settings, chunks, streaming, parallel, NLS_LANG, R's GC

Script: `07-driver-knobs.R` → `results/07-driver-knobs.csv`. Parts a and e use 1M-row tables (time is linear in rows, see [03](03-collect.md)). Parts b-d and f use the 10M-row survey table `bm_mix_1e7` (10 columns, ~1.5 GB in R), where memory matters.

## Short version

- **Free speed, one setting each:**
  - **ROracle: `dbConnect(..., bulk_read = 10000L)`.** It's the number of rows fetched per round trip, default 1000. Numbers came **2× faster**, unique text 40%, the 10-column survey table 18%. 100000 was only a little better for numbers, and worse for text.
  - **ROracle `prefetch = TRUE` is a trap:** **2× slower** here. Leave it at `FALSE`.
  - **Oracle odbc: `FBS=1048576;` in the connection string.** That's the fetch buffer size in bytes, default 64000. Numbers 25-30% faster, the survey table ~30% (35% at 16 MB).
  - SQL Server `PacketSize=32767;`: no difference here. But here the server is on localhost. On a real network a bigger packet means fewer round trips, so **try it on your servers**. It's the one result I'd expect to change.
- **Fetching in chunks** (`dbSendQuery()` + `dbFetch(n)` + `bind_rows()`) is **not faster**. Peak memory was ~9% lower with odbc and higher with ROracle and duckdb, because you still hold all the chunks.
- **4 parallel connections**, each pulling a quarter of the rows (`filter(id > lo, id <= hi)`) and writing its own parquet part: **2 to 2.6 times faster** than one `collect()` + `write_parquet()`. That's with the database on the same 4 cores. Ask your DBA before you point 4 sessions at a shared server.
- **Oracle `NLS_LANG`: set it to `AMERICAN_AMERICA.AL32UTF8`.** Without it, accented text is silently converted to ASCII: odbc gives `Quebec Montreal` for 'Québec Montréal', ROracle `Qu??bec Montr??al`. Being correct costs odbc 10-22% on text-heavy tables. ROracle: no difference.
- **R start-up GC settings make the first big collect 12 to 44% faster:** `R_NSIZE=20000000` and `R_VSIZE=4G`, set before R starts (`~/.Renviron`, or `callr::r(env =)`). R then doesn't garbage-collect again and again while the heap grows. The cost is peak memory: up to +30% on the 10-column table (SQL Server, Oracle odbc), because R collects later. `R_GC_MEM_GROW=3` gives a smaller version of the same thing.

## a. Buffer sizes (median seconds, 1M rows)

| engine | setting | int | double | unique text | survey table (10 columns) |
|---|---|---|---|---|---|
| Oracle odbc | default (FBS = 64000) | 0.80 | 0.69 | 1.25 | 4.28 |
| | `FBS=262144;` | 0.56 | 0.55 | 1.07 | 3.20 |
| | `FBS=1048576;` | 0.56 | 0.52 | 1.01 | 3.04 |
| | `FBS=4194304;` | 0.57 | 0.51 | 0.93 | 3.11 |
| | `FBS=16777216;` | 0.55 | 0.55 | 0.97 | 2.79 |
| ROracle | default (`bulk_read = 1000L`) | 0.26 | 0.26 | 0.44 | 1.59 |
| | `bulk_read = 10000L` | **0.13** | **0.14** | **0.26** | **1.30** |
| | `bulk_read = 100000L` | 0.11 | 0.11 | 0.30 | 1.20 |
| | `prefetch = TRUE` | 0.58 | 0.53 | 0.72 | 2.14 |
| SQL Server | default (PacketSize 4096) | 0.21 | 0.25 | 0.52 | 2.34 |
| | `PacketSize=8192;` | 0.20 | 0.24 | 0.53 | 2.40 |
| | `PacketSize=32767;` | 0.22 | 0.22 | 0.54 | 2.34 |

- With `bulk_read = 10000L`, ROracle pulls numbers at about 130 ns per row: 1.6× as fast as SQL Server via odbc, which can't batch (the odbc package fetches one row per call).
- The FBS gain levels off above 256 KB for numbers. For the wide table it kept improving up to 16 MB. 1 MB is a reasonable default.
- The connection-string keyword is exactly `PacketSize` for ODBC Driver 18 (`Packet Size` with a space was ignored: the session stayed at 4096). Check with `SELECT net_packet_size FROM sys.dm_exec_connections WHERE session_id = @@SPID`.

## b-d. Chunks, streaming, parallel (10M rows × 10 columns; median of 2 runs, seconds; peak = growth of the R process's peak RSS in MB)

| case | SQL Server | Oracle odbc | ROracle | duckdb |
|---|---|---|---|---|
| `collect()` all at once | 22.9 (peak 2290) | 38.2 (2556) | 14.1 (1970) | 5.6 (2730) |
| `dbFetch(n = 1e5)` chunks + `bind_rows()` | 21.4 (2088) | 35.9 (2319) | 16.4 (2311) | 7.6 (3091) |
| `dbFetch(n = 1e6)` chunks + `bind_rows()` | 21.3 (2088) | 38.3 (2319) | 16.1 (2349) | 7.2 (3096) |
| `collect()` then `arrow::write_parquet()` | 29.5 (2744) | 44.4 (3048) | 22.2 (2457) | 10.5 (2729) |
| stream 1e6-row chunks into one parquet file | <!-- STREAM --> | | | |
| 4 parallel connections, 1 parquet part each | **14.9** | **16.8** | **9.4** | - |

- The R result is 1.5 to 1.6 GB (`id` and `age` are doubles on Oracle). The peak grew by 1.4 to 2× that.
- The parallel row's time includes starting 4 R processes (~1 s). Its peak is the parent's only (~20 MB): each worker holds its own quarter, so the memory is spread over 4 processes, not saved.
- duckdb can't do the parallel case: a duckdb file is opened by one process at a time.

## e. Oracle NLS_LANG (median seconds, 1M rows)

| engine | NLS_LANG | unique text | survey table |
|---|---|---|---|
| Oracle odbc | (unset): **accents lost** | 0.95 | 3.35 |
| | `AMERICAN_AMERICA.AL32UTF8` | 1.16 | 3.73 |
| ROracle | (unset): **accents become `??`** | 0.38 | 1.63 |
| | `AMERICAN_AMERICA.AL32UTF8` | 0.35 | 1.59 |

SQL Server via ODBC Driver 18 on Linux needs nothing: it returns UTF-8 by itself. **Don't** set odbc's `encoding = "windows-1252"` there: it converts a second time and you get `QuÃ©bec` (VARCHAR only; NVARCHAR stays right). Checked by hand, not in the CSV.

## f. R's GC settings: the first collect in a fresh R process (seconds, GC seconds in brackets; peak MB)

| engine | table | default | `R_GC_MEM_GROW=3` | `R_NSIZE=2e7, R_VSIZE=4G` |
|---|---|---|---|---|
| SQL Server | 10M unique strings | 12.9 (4.6), 966 | 11.2 (3.3), 1002 | **8.0 (0)**, 873 |
| | survey table 10M | 29.5 (6.9), 2289 | 27.7 (5.5), 2558 | **21.8 (0)**, 2946 |
| Oracle odbc | 10M unique strings | 20.2 (4.7), 968 | 18.2 (3.4), 1004 | **14.6 (0)**, 873 |
| | survey table 10M | 47.3 (6.5), 2555 | 45.5 (5.3), 2575 | **41.5 (0)**, 3360 |
| ROracle | 10M unique strings | 10.4 (3.8), 1164 | 8.7 (2.2), 1198 | **6.4 (0)**, 1008 |
| | survey table 10M | 19.5 (2.8), 1983 | 18.6 (2.6), 1985 | **16.5 (0)**, 1845 |
| duckdb | 10M unique strings | 8.6 (3.7), 1277 | 6.5 (2.0), 1309 | **4.8 (0)**, 1081 |
| | survey table 10M | 8.6 (2.5), 2737 | 8.2 (2.6), 2736 | **5.7 (0)**, 2523 |

- `R_NSIZE` (cons cells, one per string among other things) and `R_VSIZE` (vector heap) only set *when R first garbage-collects*. They don't reserve memory. R still grows past them, and never shrinks below them.
- With `R_VSIZE=4G`, R won't collect garbage until ~4 GB of vectors are in use. In a pod with a tight memory limit, pick a value well under the limit.
- One run per setting: single numbers, so read differences under ~10% as noise.
