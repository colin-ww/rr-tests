# SAS → R: validating R's outputs against SAS's

Lessons and a reusable compare harness from porting a SAS survey-frame pipeline to R (`targets` + dbplyr on SQL Server) and checking R's outputs against SAS's on the same inputs.

The project repo is private (`colin-ww/sc-nts-frame`). The real tables, counts and fixes live there, and the paths below point to them. Everything in this folder is generic and runs on made-up data.


## Files

| file | what |
|---|---|
| `R/compare.R` | the harness: `compare_all()`, `compare_tbl()`, `match_types()`, `sort_like()` |
| `01-compare-demo.R` → `results/01-compare-demo-{summ,diffs}.csv` | made-up R and SAS tables, laid out like a real compare script (1. R, 2. rename, 3. recode, 4. build, 5. compare) |
| `tests/testthat/` | 18 tests, 35 expectations: `test-compare.R` (harness, with fixtures) and `test-gotchas.R` (1 test per gotcha in §4 and §5) |

Run from this folder:

```sh
Rscript 01-compare-demo.R
Rscript -e 'testthat::test_dir("tests/testthat")'
```


## 1. Comparing R with SAS

- **SAS is the spec.** Every difference is an R bug, a SAS bug, or a deliberate difference. Write the deliberate ones down once: in the README, and in `known_diffs` with the reason.
- **Reshape SAS to look like R, not the other way round.** R's names are the ones the pipeline uses.
- **Only 2 operations on SAS, each in its own section:**
  - **rename** (also drops SAS-only cols)
  - **recode** (types, units such as ratio → pct, labels, layout)
  - Nothing in either may change a count. A reviewer can then see that no number was fudged.
- **Join on key columns, not by position.** waldo / `all.equal()` compare row i with row i. One extra row (tiny combos one side has and the other hasn't) then makes the whole table "differ".
- **Strings first, then parse.** Use `sprintf("%.15g")`, not `as.character()` (`1e+05`).
- **Each cell is a count, a pct, a $ sum or text:**
  - counts: bucket |diff| into 0 / 1-100 / 101-1000 / >1000. Off by >1000 usually means the wrong variable, denominator or input.
  - pcts: the tolerance is the rounding of R's formatted string ("97.8" → ±0.05), so there's nothing to tune per table.
  - $ sums: relative diff.
  - rows on one side only: the missing side counts as 0, so they get buckets too.
- **Table verdict.** RED if any of:
  - a count is off by >1000
  - a pct is off by >1 pp
  - a $ sum is off by >1%
  - >1% of rows are on one side only (skipped for `known_diffs`)
  - those rows hold >0.1% of the table's units (never skipped)
- **Judge unmatched rows by units, not only rows.** In the demo, 25% of rows are unmatched, but that's 0.04% of units.
- **Reading diffs:** equal and opposite diffs in neighbouring cells (eg +570 / −560) mean units *moved* between categories (linking, imputation, cut points). No units were lost.
- **List what's not compared** (R-only tables/cols, SAS rows with no R equivalent), so it's a decision and not an accident.
- **Hand-filled SAS summaries are the least reliable source.** Here, the SAS checklist had values copied from the previous run. SAS's own output tables matched R.
- Project: `validation/r_vs_sas/2026-oct/compare_r_vs_sas.R` + `README.md` (findings, status).


## 2. Bug classes the compare found (R side)

Generic version of the findings table in the project's `validation/r_vs_sas/2026-oct/README.md`.

| bug | how it showed | fix |
|---|---|---|
| input table version hardcoded in a function, not read from config | everything downstream of that input off, some cells >1000 | from config. Grep the code for config values (§6) |
| counted a counted table without `wt = n` (+ a broad `starts_with()` also grabbed an id col) | counts in the tens where SAS had millions | keep `n`, `count(wt = n)`, name the cols |
| wrong denominator: all input units, incl. excluded ones | every pct/total table too big | filter to frame units, `stopifnot()` the row count between steps |
| result built but never assigned to the output list | a whole checklist section missing | the summary's "missing in R" / not-compared columns |
| linking key from a different input vintage than SAS | links moved between geography levels (equal and opposite) | same vintage as SAS |
| imputation donors included excluded units | imputed counts moved between levels, units moved between neighbouring income groups | donors = frame units only (SAS imputes on the frame) |
| function read a global object instead of its argument | not in the compare: found in review | pass it as an argument. `codetools::findGlobals(fn)` lists a function's free variables |


## 3. SAS behaviours that bite ports

From reading the SAS code and the SAS docs. No SAS was run here, so the tests only check the R side.

- **Data step `MERGE` (1:1): the later dataset's value wins for shared variables, even when it's missing.**
  - R equivalent: `rows_update()` / `rows_upsert()`, or `if_else(in_later, later, earlier)`. Not `coalesce(later, earlier)`.
  - SAS `UPDATE` is the one that skips missing values (≈ `coalesce()`).
  - So the order in the `MERGE` statement decides which table's values you get. Misreading it led to a wrong conclusion once in this project.
- **PROC SQL `count(*)` over an already-aggregated subquery counts groups.** That was a SAS-side bug here (a "ratio" of 1/n). It's the same bug as R's `count()` without `wt` (§4).
- **Steps run on different subsets.** Here, exclusion stats use all input units, while imputation and every later step use frame units only. Check where each `set` / `from` reads from, not just the step's logic.
- **Thresholds live in macro vars** (eg min donors for a median). Port each `%let` into config.
- **Compare against the outputs of the SAS code that actually ran.** The repo copy can be older.
- Project: `sas/README.md` ("How the SAS actually behaves").


## 4. R / dplyr gotchas

Each one is a test in `tests/testthat/test-gotchas.R`.

| gotcha | do instead |
|---|---|
| `count()` on a counted table counts groups | `count(wt = n)` |
| same on a database: `COUNT(*)` over the grouped subquery | same |
| `starts_with("geo")` also picks up `geo_uid` → 1 group per id | name the cols, or `& !ends_with("_uid")` |
| `recode_values()` on a factor errors if a key isn't a level | `as.character()` first |
| `as.logical("1")`, `as.logical("Reserve")` are `NA`, with no warning | cast 0/1 → lgl only on numeric cols (`match_types()`) |
| `as.character(1e5)` is `"1e+05"` | `sprintf("%.15g", x)` |
| `left_join(unmatched = "error")` checks y only, so x rows with no match pass | `inner_join(unmatched = c("error", "drop"))` |
| `coalesce(new, old)` is SAS `UPDATE`, not `MERGE` | `rows_update()` (§3) |
| waldo compares by position | join on keys (`compare_tbl()`) |


## 5. Testing patterns

- **Fixed, hand-made, tiny fake data:**
  - one csv per input, with a `note` col saying what each row tests
  - expected outputs hand-computed from the spec (SAS logic), not captured from what the code returns today
  - check that the tests fail on the pre-fix code
  - example: `tests/testthat/fixtures/` here; project: `tests/README.md`
- **Factor levels:** fixtures need the full level sets, or code using `recode_values()` errors (§4).
- **Files with `box::use()` at the top:** `source()` them in a test helper, like `tar_source()` does. Sourcing one file alone also exposes imports it forgot, which the pipeline hides by pooling them (`../dbplyr-box-nse-callr-crew-targets/`, PR #7).
- **Locale:** in a C locale, run tests with `LC_ALL=C.UTF-8`, or code that cleans non-ASCII names warns.
- **DB code without the server:**
  - SQLite + `ATTACH ':memory:' AS myschema` makes `I("myschema.tbl")`, `in_schema()` and `DBI::Id()` all work.
  - duckdb 2.0.0 reads a schema table only via `DBI::Id()`: `I()` and `in_schema()` error.


## 6. Project patterns (targets + config)

- **One-off validation run = its own config file + its own targets store:**
  - `R_CONFIG_FILE` points at a config pinned to SAS's inputs; `TAR_PROJECT` picks a store from `_targets.yaml`. The prod store isn't touched.
  - `Sys.unsetenv()` afterwards, since env vars stay set for the rest of the R session.
  - Project: `validation/r_vs_sas/2026-oct/run_r_vs_sas.R`, and the repo README's validation config decision.
- **`here::here()`**, not hardcoded `setwd()` paths.
- **Grep for hardcoded values:** search the code (not comments) for the config's values and for generic patterns (years, yyyymm, home/network paths, file names). Keep an allowlist of the intentional ones. Project: `dev/TODO.txt`.
- **`stopifnot()` invariants between steps** (unique ids, rows out = frame units), instead of checklist rows that someone fills in by hand.
- **Package imports, own modules, crew:** `../dbplyr-box-nse-callr-crew-targets/` (PR #6: doc 08; PR #7: doc 09, fresh process per target). Project summary: `dev/notes_imports_modules.md`.


## 7. Checklist ideas (for after R has been in production a while)

- numerators and denominators, not only pcts: a wrong denominator becomes visible
- generated by the pipeline, not typed; people only sign off and comment
- keep a history and flag moves vs the previous run
- turn consistency rows into `stopifnot()`s
- Project: `dev/proposal_checklist.md`.


## Versions

R 4.6.1 · dplyr 1.2.1 · dbplyr 2.6.0 · DBI 1.3.0 · RSQLite 3.53.3 · duckdb 2.0.0 · tidyr 1.3.2 · purrr 1.2.2 · stringr 1.6.0 · vctrs 0.7.3 · box 1.2.3 · readr 2.2.0 · waldo 0.6.2 · testthat 3.3.2 · withr 3.0.3 (2026-11-03).
