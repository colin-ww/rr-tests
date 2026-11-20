# How the timings were taken, and why

Scripts: `R/bench.R` (the harness) and `01-method.R` → `results/01-method.csv`.

## Short version

- **Every case runs in a fresh R process** (`callr::r()`): connect, call once (`first_s`), then 3 to 5 more calls with `gc()` before each (`med_s` = their median).
- **Timer:** `bench::hires_time()`. `bench::mark()` is used only where it shines: things that take micro- to milliseconds (building a lazy query, part 02).
- **Memory:** R object size (`lobstr::obj_size()`) and how much the process's peak RSS grew during the first call (`/proc/self/status`, Linux). That second number is what a k8s pod memory limit cares about.
- **Caches:** R's are handled by the fresh process. The database's buffer cache is handled by the untimed first call. The OS file cache (part 05) is handled by evicting the file before "cold" reads. You can't flush the database's cache without DBA rights, so don't try.

## What 01-method.R measured

### a. One R process, the same `collect()` over and over (1e6 rows, seconds)

| table | engine | 1. first call | 2. calls 2-6 | 3. while a 10x bigger result is alive | 4. after `rm()` + `gc()` of it |
|---|---|---|---|---|---|
| chr20_hi (unique strings) | SQL Server | 1.17 | 0.56 | 0.55 | **0.47** |
| | Oracle odbc | 1.89 | 1.32 | 1.18 | **1.10** |
| | Oracle ROracle | 0.94 | 0.40 | 0.38 | **0.34** |
| | duckdb | 0.74 | 0.24 | 0.22 | **0.15** |
| dbl | SQL Server | 0.37 | 0.26 | 0.24 | 0.24 |
| | Oracle odbc | 0.79 | 0.63 | 0.64 | 0.63 |
| | Oracle ROracle | 0.38 | 0.25 | 0.25 | 0.24 |
| | duckdb | 0.18 | 0.02 | 0.02 | 0.02 |

- **The first call is slower**, by 0.1 to 0.6 s here. Fine for a one-off job, misleading in a comparison. Reported separately as `first_s`.
- **A big result made and freed earlier made later string collects 15 to 37% faster.** R grew its heap for the big one and keeps the higher GC thresholds, so it garbage-collects less afterwards. Numbers didn't change.
  - So inside one process, the *order* of cases changes their timings. A fresh process per case fixes that.
- The first `collect()` of 1e7 unique strings took **1.6 to 2.5 times** as long as later ones (SQL Server 12.6 s vs 7.1 s, ROracle 10.8 vs 4.8, duckdb 8.2 vs 3.2). Most of that is R's garbage collector while the heap grows. For a production job that pulls one big table in a fresh R session, `first_s` is the realistic number. 07 part f tests R's start-up GC settings for it.

### b. `bench::mark(iterations = 5)` on a 1e6-row collect

- Defaults (`memory = TRUE`, `check = TRUE`, `filter_gc = TRUE`) add the one untimed extra run: 0.2 to 0.9 s more wall time. Medians stay the same, within noise.
- **`filter_gc = TRUE` silently threw away most iterations on the string table.** SQL Server and Oracle odbc kept 1 of 5 and ROracle and duckdb kept 2 of 5, so the "median" came from 1 or 2 runs, the ones without a GC. On the numeric table *every* odbc iteration had a GC, so bench warned and kept them all. You only get the warning in the all-or-nothing case.
- `mem_alloc` for an 8 MB result: **34 MB with odbc**, 8 MB with ROracle and duckdb. odbc builds the result in buffers that start at 100 rows and double as rows arrive (read from odbc's source: it also fetches **one row per ODBC call** and converts each value separately). ROracle and duckdb know the size up front.

### c/d. `interruptible`, `collect()` vs `DBI::dbGetQuery()` (fresh process each, 1e6 and 1e7 rows)

- `interruptible = TRUE` (RStudio's default): **no difference.** It only wraps `SQLExecute`, not the fetching.
- `collect()` vs `dbGetQuery()`: **no difference** beyond noise (±5%). dbplyr's overhead is building the SQL text, which takes milliseconds (02).

### Memory: extra peak RSS during the first collect vs the size of the result

| result | odbc (SQL Server, Oracle) | ROracle | duckdb |
|---|---|---|---|
| 1e7 doubles, 80 MB | 179 MB (2.2x) | 151 MB (1.9x) | 224 MB (2.8x) |
| 1e7 unique 20-char strings, 880 MB | 966 MB (1.1x) | 1164 MB (1.3x) | 1277 MB (1.45x) |

- Budget a pod's memory for **2 to 3 times the size of the numeric columns**, on top of what's already in the session. See 03 for more types.

## Which packages, and why

| package | used for | why this one |
|---|---|---|
| **bench** | `hires_time()` as the timer; `mark()` for sub-second things | High-resolution clock. `mark()` repeats, counts GCs per iteration, and checks that the results are equal. See below for what it does *not* do. |
| **callr** | one fresh R process per case | The only clean way to stop one case changing the next: R's heap size, its string cache and loaded packages all carry over inside one process (measured in 01a). A fresh process is also what a production job looks like, and it gives a clean peak-memory number. |
| **lobstr** | `obj_size()` | Counts shared strings once. `utils::object.size()` doesn't. |
| **withr** | not needed here | withr is for *temporarily changing state and undoing it*: `with_envvar()`, `local_options()`, `local_tempfile()`, `with_seed()`. It doesn't isolate anything: same process, same heap, same caches. Use it inside a case if the case needs a setting. Here `run_case(env = )` sets env vars in the child process instead. |
| microbenchmark | not used | Nanosecond precision, no memory info. For comparing two tiny functions. Overkill and the wrong tool for a 5-second `collect()`. |
| tictoc | not used | `tic()`/`toc()` around steps of a *real* pipeline, to log where the time goes. Good for that, but no repeats. |
| atime | not used | Times (and memory) over a range of N and plots the curve, to find O(N) vs O(N²). Fits "100k to 100M rows" well if you only want the scaling plot. It's what data.table uses for its own performance tests. |
| profvis | not used | Shows *where inside* one call the time goes (R code vs C). Use it if one case is surprisingly slow. |

## What `bench::mark()` does and doesn't do (read from bench 1.1.4's source)

- With `memory = TRUE` (the default) or `check = TRUE` (the default), it runs each expression **once extra, untimed**, before the timed iterations. That run records memory with `Rprofmem()` and keeps the result for `check`. So it doubles as a warm-up. With `memory = FALSE, check = FALSE` there is no warm-up: iteration 1 is cold.
- `mem_alloc` comes from that one extra run. It counts **R heap allocations only**, not memory malloc'ed by C code (the ODBC driver's buffers, arrow's memory pool).
- It does **not** call `gc()` between iterations, and does **not** isolate the process.
- `filter_gc = TRUE` (the default) drops every iteration that had a garbage collection. A big `collect()` triggers a GC in almost every iteration, so you get the warning *"Some expressions had a GC in every iteration; so filtering is disabled"*. Leaving GC out would be wrong anyway: GC is part of what a collect costs you.
- `min_time = 0.5` s: for a 5-second query it runs once (or `min_iterations`). Set `iterations =` yourself.
- `check = TRUE` keeps a copy of the first result alive the whole time. With a 2 GB result, that's 2 GB extra and more GC.
- So for seconds-long database pulls: `bench::mark(..., iterations = 3, check = FALSE, filter_gc = FALSE)` inside `callr::r()` is fine. The harness here does the same thing by hand, plus `gc()` between calls and peak RSS.

## Caches and noise: what can bias a collect() timing

| where | what | handled here by | at StatCan |
|---|---|---|---|
| R | first call pays for lazy-loading package code, S4 method caches, dbplyr translation setup | `first_s` reported separately | a one-off job pays it once; ignore for big pulls |
| R | heap size: after a big object, R raises its GC thresholds, so later calls GC less | fresh process per case | same |
| R | global string cache: a string that already exists in the session isn't allocated again | fresh process per case | same |
| database | buffer cache (SQL Server buffer pool, Oracle buffer cache): the first read of a table may come from disk | untimed first call; `first_s` vs `med_s` shows it | can't flush it without DBA rights (`DBCC DROPCLEANBUFFERS` needs sysadmin, `ALTER SYSTEM FLUSH BUFFER_CACHE` needs ALTER SYSTEM). Warm reads are the fair comparison. |
| database | other users' load on a shared server | n/a (private containers) | **the big one.** Repeat at different times of day, compare medians, look at min/max. |
| network | shared bandwidth and latency between the server and your pod | n/a (same machine) | the other big one. Everything here ran over localhost, so the network cost is ~0. |
| OS | page cache: a file you just wrote is read back from RAM | part 05 evicts it first (`dd if=file iflag=nocache count=0`, no root needed) | on the filers (SMB/NFS) caching differs again; run 05 there |
| all | run-to-run drift: the same script on the same idle machine gave 20-25% lower times on a second run (06), for every case alike | compare cases **within one run**; the ratios held, the absolute numbers moved | expect more on shared servers |
| CPU | the database and R on the same 4 cores here | n/a | in k8s, R may see the node's cores, not your pod's limit: multi-threaded readers/writers (arrow, data.table, vroom, qs2) can oversubscribe. Set their thread counts to your pod's CPU limit. |
