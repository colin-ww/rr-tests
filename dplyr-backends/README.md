# dplyr backends: speed and "same code, same answer?" on frame-shaped data

The tests behind **rr-coding/dplyr_backends** (overview, pros/cons, links). Synthetic data only, shaped like the NTS frame pipeline: no real data is used or committed.

- **Result tables:** [results/tables.md](results/tables.md), generated from `results/*.csv`.
- **Versions / machine:** [results/versions.md](results/versions.md). 4 cores, 15 GB RAM. The Zone has more cores: see [threads](#threads-what-more-cores-would-buy): only DuckDB and Polars scale with them.

## TL;DR

Numbers are from n = 1M units (≈ 120 MB) unless they say 10M (≈ 1.2 GB), 4 threads. All tables (1e5, 1e6, 1e7): [results/tables.md](results/tables.md).

- **dplyr is not slow at joins, few-group summaries, recodes, filters and sorts.**
  - 0.1–0.7 s at 1M rows.
  - Swapping backends doesn't help those; converting and collecting often makes it slower.
  - Only collapse/fastplyr joins are ~10× faster.
- **dplyr *is* slow at many-group work:**
  - `summarise` by id (0.9M groups): 15 s;
  - grouped median by postal code: 1.7 s;
  - SAS `first.` via grouped filters: 7 s.

  That's where every alternative wins 5–120×.
- **Cheapest fix: keep dplyr and swap only the grouped bits for collapse fast functions.**
  - `mutate(m = fmedian(x, g, TRA = "fill"))` instead of `mutate(m = median(x), .by = g)`.
  - 16–56× on those steps, 17× on the end-to-end pipeline (10.4 s → 0.60 s), same results.
  - The frame's `join_income()` uses `fmedian()` *inside* `.by`, which is still one call per group: 2.5× instead of 26× (03-gotchas #2).
- **Best "same code" swap: dbplyr + in-memory DuckDB.**
  - Correct on all 10 tasks, 15× on the pipeline at 1M, **31× at 10M** (137 s → 4.4 s), 8.5× over the single steps.
  - It scales better than the collapse hybrid (17× → 18×), because DuckDB optimises the whole chain and uses all cores.
  - But it brings SQL semantics, so different answers on NA join keys, all-NA sums, `as.integer()`, `paste0(NA)` (01-semantics).
- **tidypolars is the fastest swap** (28× on the pipeline at 1M, 45× at 10M), but:
  - **not installable air-gapped** (not on CRAN; Rust build that downloads crates);
  - **wrong date differences (µs, not days)**;
  - int sums wrap past 2^31.
- **duckplyr:** stays in DuckDB only for `.by` summaries, where it's 66× (1M) to 130× (10M).
  - `case_when`, `paste0`, `as.numeric`, a `sum()` inside a windowed mutate and every `group_by()` pipe fall back to dplyr, silently by default.
  - Pipeline: 2.2–2.6×. Joins: no faster than dplyr.
  - **`collect()` is lazy:** the columns are ALTREP and the query runs on first use. A benchmark that stops at `collect()` overstates duckplyr (a 10M join looked 6× faster until the columns were touched).
- **dtplyr / tidytable:** 2.3–7×, and a real **silent-ish wrong result**: grouped `median()` of an integer column gets truncated (warning only).
  - The imputation task hit it at 1M but not at 10M: it depends on whether the first group's count is odd. That makes it worse, not better.
- **multidplyr** 1.5–3×, only for one-table grouped steps. **arrow:** approximate medians (wrong imputation), misses many functions. **poorman:** errors on modern dplyr and is ~9× slower.
- **More cores only help DuckDB and Polars.** From 1 → 4 threads at 10M, their pipeline got 3.3–3.8× faster. collapse, data.table and dtplyr stayed ~1×. Single-threaded, collapse is the fastest on the pipeline (7.4 s vs DuckDB 14.4 s).
- **dplyr's many-group steps also cost RAM.** At 10M, summarise by id peaked at 7.2 GB, and the pipeline at 6.0 GB, for 1.2 GB of data. collapse peaked at 1.3 / 3.5 GB.
- **Nothing warns about a wasteful schema.** 5 of 8 type guessers turn the code `"01"` into the number 1. `suggest_types()` reports instead.

## What is compared

**14 ways to run the same 10 tasks.**

| kind | backends |
|---|---|
| same dplyr code, dispatch on the object | dplyr (reference), dtplyr, duckplyr, dbplyr + duckdb (`copy_to`), arrow, tidypolars, multidplyr |
| same dplyr code, verbs re-bound | tidytable, fastplyr (`f_` verbs), collapse masking (`set_collapse(mask = …)`), poorman |
| rewrite / hybrid | data.table, collapse, dplyr + collapse fast functions in the grouped steps |

"Same code" is literal: each task in [`R/tasks.R`](R/tasks.R) is written once. [`R/backends.R`](R/backends.R) converts the input and re-binds the verb names (`with_verbs()`), so the function body is untouched.

**Code style.**
- Tasks are written `group_by() … ungroup()` and automatically rewritten to `.by =` (`to_by()`), which is your style.
- duckplyr only stays in DuckDB with `.by`. poorman and collapse's `fsummarise()` silently ignore `.by`, so those two (and multidplyr, which needs `partition()`) keep `group_by()`.

**The tasks** (frame-like; `n` = units):

| task | what | like in the frame |
|---|---|---|
| `join` | units ⟕ tax (id) ⟕ geo (postal code) ⟕ codes | `join_all()`, the export |
| `summarise_few` | filter + n/sum/mean by prov × type (~170 groups) | validation counts |
| `summarise_many` | persons → households: n, sum (NA if all NA), max by id (~0.9 n groups) | T1 income per bu_sn |
| `median_many` | grouped mutate: median income by postal code (n/20 groups), used if ≥ 5 donors | `join_income()` imputation |
| `case_when` | 5-branch `case_when`, `if_else`, `coalesce`, arithmetic | recodes |
| `strings_dates` | zero-padded id, `substr`/`toupper`, `paste0`, `year()`, date difference | export formatting |
| `first_per_id` | oldest person per id (ties → lowest person_id) via 2 grouped filters | SAS `first.` |
| `filter_arrange` | 4-condition filter + 3-key sort (row order checked) | |
| `distinct_count` | `n_distinct` + n by prov × status | checklist |
| `pipeline` | all of it chained, collected once: household income → 3 joins → exclusions → 2 grouped medians → impute → recode → summary | the whole build |

**Data** ([`R/data.R`](R/data.R)):
- `units` (n rows): id dbl, prov int, postal code chr (2% NA), type code `"01"`–`"13"`, status, income int (30% NA), date, hh size, weight;
- `tax` (0.66 n);
- `persons` (2 n);
- `geo` (n/20 postal codes; 3% of codes missing from it);
- `codes` (13 rows).

At n = 10M that's ≈ 1 GB in R.

**How it's measured** ([`R/run_one.R`](R/run_one.R)):
- **Fresh `Rscript` per (backend, task)**, so nothing leaks between backends: duckplyr methods, collapse masks, thread settings.
- **Time:** best of up to 3 runs, *including* collecting back to a tibble, excluding the one-off conversion (reported separately).
- **Peak RAM:** the process's peak RSS, reset after loading the data, so it covers conversion + task.
- **duckplyr results are materialised inside the timer:** they're lazy ALTREP columns otherwise (gotcha 8).
- **Correctness:** every result is compared with dplyr's after normalising types and row order. A different result is reported as **WRONG**, not timed as a win.
- **Threads:** all engines get all cores (`BENCH_THREADS`); dplyr is single-threaded by design.

## Results

### Headline (n = 1M; seconds, speed-up vs dplyr in brackets)

| | pipeline (end to end) | 9 single steps, total | many-group steps (summarise by id / median by postal code / first per id) | correct on all 10? |
|---|---|---|---|---|
| dplyr | 10.4 | 29 | 15 / 1.7 / 7.2 | reference |
| **dplyr + collapse fns** | **0.60 (17×)** | 5.1 (5.7×)¹ | 0.18 / 0.11 / 0.13 | yes |
| collapse (rewrite) | 0.51 (21×) | 1.9 (15×) | 0.18 / 0.056 / 0.29 | yes |
| data.table (rewrite) | 1.22 (8.5×) | 3.1 (9×) | 0.25 / 0.22 / 0.35 | yes |
| **dbplyr + duckdb** | **0.68 (15×)** | 3.4 (8.5×) | 0.32 / 0.32 / 0.50 | yes² |
| tidypolars | 0.37 (28×) | – | 0.13 / 0.35 / 0.23 | **no**: date difference in µs |
| collapse masking | 1.29 (8×) | – | 0.20 / 0.078 / error | **no**: grouped `filter()` errors |
| duckplyr | 4.7 (2.2×) fb | 18 (1.6×) | 0.23 / 2.1 fb / 8.2 fb | yes (by falling back) |
| dtplyr | 4.1 (2.6×) | – | 2.4 / **WRONG** / 2.0 | **no**: integer median truncated |
| tidytable | 4.2 (2.5×) | – | 2.2 / **WRONG** / 2.1 | **no**: same |
| fastplyr | 4.8 (2.2×) | 15 (1.9×) | 3.7 / 0.39 / 7.4 | yes |
| multidplyr | n/a | n/a | 4.5 / 1.1 / 4.0 | yes (one-table steps only) |
| arrow | **WRONG** | – | 1.5 / **WRONG** / 7.1 fb | **no**: approximate median; date difference errors |
| poorman | error | – | error / error / 67 | **no**: errors on `case_when(.default)`, `if_else(…, NA)` |

¹ only the 4 grouped steps rewritten; `strings_dates` stays dplyr at 3.5 s because of `str_pad()`. `sprintf("BU%010d", id)` takes 1.0 s, and `str_pad()` on doubles is the bug the frame export has.
² on these tasks, which avoid the SQL-semantics traps on purpose; see 01-semantics.

### Headline at n = 10M (≈ 1.2 GB; 5 tasks, without the backends already ruled out at 1M)

| | pipeline | summarise by id | median by postal code | first per id | join ×3 | peak RAM, GB |
|---|---|---|---|---|---|---|
| dplyr | 137 | 189 | 21 | 83 | 12.5 | 7.2 |
| **dplyr + collapse fns** | 7.8 (18×) | 2.5 (76×) | 1.65 (13×) | **2.8 (30×)** | (dplyr) | 3.6 |
| collapse (rewrite) | 7.0 (20×) | 2.5 (76×) | **1.10 (19×)** | 4.7 (18×) | **1.45 (8.6×)** | 3.5 |
| data.table (rewrite)³ | 24 (5.8×) | 3.0 (62×) | 3.6 (6×) | 3.1 (27×) | 10 (1.3×) | 5.4 |
| **dbplyr + duckdb** | **4.4 (31×)** | 2.5 (74×) | 4.6 (4.7×) | 4.6 (18×) | 12.9 (1.0×) | 4.6 |
| tidypolars | **3.1 (45×)** | **1.2 (156×)** | 6.3 (3.4×) | 3.3 (25×) | 22 (0.6×) | 4.2 |
| duckplyr | 53 (2.6×) fb | **1.4 (131×)** | 28 (0.8×) fb | 84 (1.0×) fb | 11.1 (1.1×) | 6.9 |
| dtplyr | 61 (2.3×) | 28 (6.8×) | 19 (1.2×) | 25 (3.3×) | 10 (1.2×) | 5.2 |
| tidytable | 59 (2.3×) | 28 (6.8×) | 17 (1.2×) | 27 (3.1×) | 13 (0.9×) | 4.3 |
| fastplyr | 69 (2.0×) | 50 (3.8×) | 4.4 (4.8×) | 90 (0.9×) | 1.7 (7.3×) | 5.5 |
| collapse masking | 29 (4.7×) | 2.8 (67×) | 1.35 (16×) | error | 12 (1.0×) | 4.1 |

³ my data.table code. Its pipeline does two `median()` by group with `:=`, which is slower than it should be. A data.table expert would do better.

Things the full tables show:
- **Joins:** everyone except collapse/fastplyr (~0.08 s, 8–10×) is 0.5–1 s, about the same as dplyr. tidypolars is the slowest at joins (1.0 s): copying 15 columns of strings back into R costs more than the join.
- **Small/simple tasks:** few-group summaries, `case_when`, filter + sort and `n_distinct` take 0.1–0.4 s in everything. The lazy/SQL backends are often *slower* than dplyr there (setup, translation, collect). Not worth swapping for.
- **Conversion in** (tibble → backend, not in the times above): ≤ 0.05 s for most at 1M. `copy_to()` into DuckDB 0.4–0.9 s, `partition()` for multidplyr ~2 s.
- **Peak RAM:**
  - collapse used the least (417 MB peak at 1M), and dplyr + collapse ~270 MB on the grouped steps;
  - arrow (3.0 GB) and poorman (2.3 GB) used the most;
  - DuckDB/polars memory is counted (process RSS); multidplyr's workers are not.

Full per-task tables for 1e5, 1e6 and 1e7, with notes on every error/fallback: [results/tables.md](results/tables.md).

### Threads: what more cores would buy

Same 10M data, 1 thread vs 4 (`BENCH_THREADS=1`). Full table: [results/tables.md](results/tables.md).

| task | collapse | data.table | dtplyr | dbplyr + duckdb | duckplyr | tidypolars |
|---|---|---|---|---|---|---|
| pipeline | 7.4 → 7.0 s (1.1×) | 29 → 24 (1.2×) | 64 → 61 (1.1×) | **14.4 → 4.4 (3.3×)** | 80 → 53 (1.5×) | **11.7 → 3.1 (3.8×)** |
| summarise by id | 2.5 → 2.5 (1.0×) | 4.5 → 3.0 (1.5×) | 28 → 28 (1.0×) | 3.5 → 2.5 (1.4×) | **4.9 → 1.4 (3.4×)** | **3.7 → 1.2 (3.0×)** |
| median by postal code | 1.15 → 1.10 (1.0×) | 3.5 → 3.6 (1.0×) | 18 → 19 (1.0×) | 5.9 → 4.6 (1.3×) | (falls back) | 8.2 → 6.3 (1.3×) |
| join ×3 | 1.2 → 1.5 (0.8×) | 11 → 10 (1.1×) | 12 → 10 (1.2×) | 11 → 13 (0.9×) | 17.5 → 11.1 (1.6×) | 20 → 22 (0.9×) |

- **Only DuckDB and Polars turn cores into speed.** 4 threads gave 3–4× on whole chains and big aggregations.
- **collapse, data.table (for these ops) and dtplyr don't scale with threads.** collapse is fast because it doesn't call R per group, not because of cores.
- **Single-threaded, collapse is the fastest on the pipeline** (7.4 s vs DuckDB 14.4, Polars 11.7). With 4 threads DuckDB/Polars overtake it.
- **Joins that return 10M wide rows barely scale for anyone.** The cost is copying the result (strings especially) back into R, which is single-threaded. Doing more work before `collect()` is what pays.
- **On the Zone (up to 24 cores):** expect DuckDB/Polars to gain more, but sub-linearly (the collect-to-R floor stays), and collapse/dplyr to stay where they are. Not measured: this container has 4 cores.

## Same code, different answer: 01-semantics.R

26 tiny probes × 12 backends. Full table: [results/tables.md](results/tables.md#01-semantics-same-dplyr-code-same-answer).

What changes if you swap the backend under *the same dplyr code* (✓ = same as dplyr; details in the table):

| trap | differs on | why it matters for SAS ports |
|---|---|---|
| **NA join key matches NA** in dplyr (`na_matches = "na"`, like SAS merge) | dbplyr/DuckDB: no match | unmatched rows silently lose their lookup values |
| `relationship = "many-to-one"` check | **silently ignored** by dtplyr, tidytable, duckplyr, arrow, poorman; errors (good) in dplyr, dbplyr, tidypolars, data.table/collapse equivalents | the duplicate-key guard you added does nothing |
| chr key `"01"` joined to int key 1 | dplyr errors (good); **dbplyr casts and matches `"01"` to 1**; fastplyr/collapse cast to chr and miss | silent wrong match or miss |
| `sum(x, na.rm = TRUE)` of an all-NA group | 0 in dplyr/dt/polars; **NA** in dbplyr, fastplyr, collapse, collapse masking | SAS `sum()` of all-missing is missing, so NA is often what you want, but it changes counts |
| `mean()` all-NA: NaN vs NA; `max()` all-NA: −Inf (+ warning) vs NA | most non-dplyr give NA | |
| `n_distinct(c("a", NA))` = 2 in dplyr | **1** in fastplyr, collapse | |
| grouped `median()` of an **int** column | **truncated** in dtplyr/tidytable/data.table when GForce is off; arrow approximate | wrong imputed values |
| `sum()` of int past 2^31 | dplyr → double; **tidypolars wraps to −294967296**; arrow → integer64 | |
| `as.integer(2.7)` = 2 | **3 in dbplyr/DuckDB** (SQL CAST rounds) | |
| `paste0("a", NA)` = `"aNA"` | `"a"` in dbplyr/DuckDB | |
| `Date - Date` in days | **µs in tidypolars**; arrow errors | |
| `summarise(.by = g)` | **poorman and collapse `fsummarise()` silently ignore it** (make a column `.by`) | wrong totals, no error |
| SAS `first.`: `arrange() |> distinct(.keep_all = TRUE)` | **arrow keeps an arbitrary row** | |
| summary row order / factor level order | arrow (alphabetical); polars' order varies run to run | sort explicitly before comparing |
| count `n` type | double in dbplyr, tidypolars | type checks downstream |

**No difference anywhere** (good news):
- `round()` half-to-even: DuckDB's dbplyr translation matches R. Real SQL Server/Oracle round half away from zero; see `../dbplyr-box-nse-callr-crew-targets`.
- NA sorts last both ways.
- C-locale string sort.
- `if_else`/`case_when` with an NA condition.
- Column types after a round trip through a filter (int, dbl, chr, factor, lgl, Date, POSIXct): identical everywhere, arrow included.

## Gotchas: 03-gotchas.R

Each one checked on its own (n = 1M units, 2M persons). Table: [results/tables.md](results/tables.md#03-gotchas).

1. **collapse fast functions are vectorised over groups only when called bare.**
   - `fsummarise(s = fsum(x))`: 0.22 s.
   - `collapse::fsum(x)`: 7.2 s; box-style `cl$fsum(x)`: 6.5 s. Same result, ~30× slower (1.8M groups).
   - With box: `box::use(collapse[fsum, fmedian, fnobs, ...])`, not `box::use(cl = collapse)`.
2. **Grouped median by postal code (50k groups):**
   - `mutate(median(x), .by = g)`: 1.4 s.
   - `mutate(fmedian(x), .by = g)` (the frame's `join_income()` today): 0.56 s.
   - `mutate(fmedian(x, g, TRA = "fill"))` (no `.by`): **0.053 s** (26×), identical values.
3. **data.table GForce:** `sum(!is.na(x))` by group isn't optimised (1.0 s); `sum(flag)` with the flag made first is (0.22 s). dtplyr inherits it: same translation, same cost.
4. **dtplyr: grouped `median()` of an int column with a second expression in the same `mutate()`** gives `2,2,2,2,2` instead of `2,2,2,2.5,2.5`, with only a "precision lost" warning. Fix: `median(as.numeric(x))`. tidytable got this `.by` case right but truncated in 01-semantics (`group_by()` style) and in the 1M benchmark. data.table itself does the same when GForce is off.
5. **duckplyr:** `group_by() |> summarise() |> ungroup()` 6.5 s (falls back to dplyr) vs `summarise(.by = id)` 0.18 s.
6. **`set_collapse(mask = "fast-stat-fun")` reaches your own code.** `sum(logical(0))` becomes `integer(0)` instead of 0. It broke this benchmark's own runner until it used `base::sum`.
7. **arrow `median()` is approximate.** All 13 province medians differed from dplyr's on 1M rows.
8. **duckplyr `collect()` is lazy.** A 1M-row join "finished" in 0.14 s, and the first use of its columns took another 0.29 s: the query runs then. `R/backends.R` touches every column of a duckplyr result inside the timer. The first run of this benchmark didn't, and showed duckplyr's 10M join as 2.0 s instead of 11.1 s.

Also found on the way:
- `as.character()` of a round double gives `"1.0377e+10"`, the root cause of the frame's `str_pad(bu_sn)` bug. `sprintf("%.0f")` is safe.
- Inside `tibble(a = x, b = if (a == ...) ...)`, `a` is the new column, not your variable.

## Schema: 04-schema.R + `R/suggest_types.R`

**Does anything warn about or fix a wasteful schema?**
- **No backend warns.** Some change types silently on the way back: counts → double (dbplyr, tidypolars), int64 (arrow), factor key joined to chr → factor (dbplyr, arrow, fastplyr, collapse).
- **Type guessers convert, and most destroy codes** (1M rows, every column chr, as the "everything as string" habit produces):

| tool | `"000123456"` / `"01"` | other columns |
|---|---|---|
| `utils::type.convert`, `hablar::retype`, `data.table::fread`, arrow CSV, polars CSV | **int/dbl: leading zeros lost** | int/dbl/Date; fread/arrow give `integer64` for big ids |
| `readr::type_convert`, `readr::read_csv`, DuckDB CSV | chr (kept) | double, not int, for whole numbers; Date |
| `suggest_types()` (this folder) | chr / factor, with the reason | int, double, logical, Date, factor; reports, never converts |

**`suggest_types(df, code = TRUE)`** prints, per column:
- class, % NA, n distinct;
- MB now → MB after;
- why;
- a ready `mutate()`.

On the test table: 248 MB → 128 MB.
- The big savings are **high-cardinality numbers stored as chr** (ids, amounts: 72 MB → 8 MB each).
- R stores each distinct string once, so a low-cardinality chr column costs only the 8-byte pointer per row; factor halves that.
- That's also why a chr-heavy R table is far smaller than the same SAS dataset with fixed-width `$200` columns.

It prints no values, so it's safe to run on real data.

## Files

| file | what | runtime here |
|---|---|---|
| `R/data.R` | synthetic frame-shaped data, cached as qs2 in `data/` (gitignored) | – |
| `R/backends.R` | convert in / collect out, verb re-binding, `.by` rewrite, engine setup (threads) | – |
| `R/tasks.R` | the 10 tasks, written once in dplyr | – |
| `R/tasks_native.R` | the same tasks in data.table, collapse, and dplyr + collapse | – |
| `R/run_one.R` | runs one (backend, task, n) in a fresh process: time, peak RAM, compare with dplyr | – |
| `R/suggest_types.R` | `suggest_types(df)`: wasteful-type report, prints no values | – |
| `01-semantics.R` | 26 trap probes × 12 backends → `results/01-semantics.csv` | ~1 min |
| `02-bench.R` | the benchmark at one size → `results/bench_n<n>.csv` | 1e5: ~8 min · 1e6: ~20 min · 1e7 (5 tasks × 11 backends): ~2 h |
| `03-gotchas.R` | the surprises, one by one → `results/03-gotchas.csv` | ~2 min |
| `04-schema.R` | type guessers vs `suggest_types()` → `results/04-schema.csv`, `results/04-suggest-types.csv` | ~30 s |
| `build-report.R` | → `results/tables.md`, `results/versions.md` | ~2 s |

Run from this folder:

```sh
Rscript 01-semantics.R
Rscript 02-bench.R 1e5 && Rscript 02-bench.R 1e6
# 1e7: the 5 tasks that matter, without the backends already wrong/slow at 1e6 (arrow, poorman, multidplyr)
BENCH_REPS=2 BENCH_BUDGET=20 BENCH_TASKS=join,summarise_many,median_many,first_per_id,pipeline \
  BENCH_BACKENDS=dplyr,dtplyr,tidytable,duckplyr,dbplyr_duckdb,tidypolars,fastplyr,collapse_mask,data.table,collapse,dplyr+collapse \
  Rscript 02-bench.R 1e7
# threads: the same at 1 thread for the multi-threaded engines
BENCH_THREADS=1 BENCH_REPS=2 BENCH_BUDGET=20 BENCH_TASKS=join,summarise_many,median_many,pipeline \
  BENCH_BACKENDS=dtplyr,duckplyr,dbplyr_duckdb,tidypolars,data.table,collapse Rscript 02-bench.R 1e7
Rscript 03-gotchas.R; Rscript 04-schema.R; Rscript build-report.R
```

- **Options:** `BENCH_BACKENDS=` / `BENCH_TASKS=` (comma lists) select a subset. `BENCH_TIMEOUT` (s) per combo.
- **Skipping:** at 1e7, combos (other than dplyr) that took > 30 s at 1e6 are skipped.
- **Packages:** everything is on CRAN except polars/tidypolars (R-multiverse; here a ~25 min Rust source build).

## Not covered

- **The Zone itself:** its cores, its RAM, its disk. Only this 4-core container was used.
- **Reading data** (DB, parquet, qs2): every task starts from data already in R.
- **Larger than RAM**, streaming engines (DuckDB spilling, Polars streaming, arrow datasets).
- **reticulate → Python, sparklyr.**
- **futurize / furrr / mirai:** they parallelise loops, not verbs. Argued in the rr-coding README, not benchmarked.
- **Real Oracle / SQL Server:** dbplyr here runs on in-memory DuckDB.
