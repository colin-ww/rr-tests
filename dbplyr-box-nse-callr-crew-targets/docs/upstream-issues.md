# Upstream issue candidates (plain-language version; **nothing filed**)

Short version:

| # | package | the problem in one line | silent? | verdict |
|---|---|---|---|---|
| 1 | dbplyr | `mod$fn(col)` runs in R and uses a same-named **R object**, not the column | **yes, wrong numbers** | **file** (most important) |
| 2 | dbplyr | `.sql$fn()` still gets R's translation (`.sql$substr(x, 2, 3)` becomes `SUBSTR(x, 2, 2)`), and strict mode rejects `.sql$` for functions dbplyr doesn't know | **yes** for `substr` / `substring` | **file** (new) |
| 3 | box | `box::use(base[...])` fails with a cryptic error | no | **file** |
| 4 | dbplyr | an R vector of length > 1 used as a value becomes an SQL tuple `(10, 20, 30)`, which gives a DB error or an odd column | mostly no | optional, low priority |
| 5 | dbplyr | "there is no strict mode" | – | **drop**: `options(dplyr.strict_sql = TRUE)` exists |
| 6 | dbplyr | the unknown-function error has no "not translated" hint | no | **drop** as an issue; use strict mode |
| 7 | tidyselect | "no deprecation warning on lazy tables" | – | **drop**: my test was wrong |

- Items 1–4 have ready-to-paste drafts with the same numbers in [upstream-drafts.md](upstream-drafts.md). Item 5 has a small docs request instead (draft 5). Items 6 and 7 have no draft.
- Also drafted: 5 SQL Server / Oracle problems (4 bugs, 1 likely bug) and 2 targets / box notes (drafts 6–12). They are explained the same way [at the end of this page](#also-drafted-sql-server--oracle-bugs-and-targets--box-notes).
- Old numbers (the upstream list in the first version, PR #2): item 1 was old 1. Item 2 is new (found while re-checking old 2). Item 3 was old 3. Items 4 and 5 were old 2, which had two parts. Item 6 was old 4. Item 7 was old 5.

How I re-checked:
- I ran each case in its own fresh `Rscript` process, so no warnings, options or modules carried over between cases.
- dbplyr: CRAN 2.6.0, and the dev version (GitHub main @ f478e20, 2.6.0.9000, which was GitHub HEAD on 2026-10-16) installed into a temporary library. Results were the same on both. The function at the heart of item 1 is identical in both.
- box 1.2.3. Its code is the same as GitHub main @ 2eb1430.
- In items 1–7, Oracle and SQL Server results are rendered SQL only. The drafts 6–10 section at the end uses the real-engine runs from the [SQL Server / Oracle page](05-sql-server-oracle.md).
- I searched the upstream issue trackers (read-only). Issue numbers below are ones I actually saw.

## 1. dbplyr: `mod$fn(col)` silently uses an R object instead of the column (file it)

**What happens.** Before dbplyr writes SQL, it looks at each piece of your code and decides one of two things:
- it is a column, so it goes to SQL; or
- it is an R thing, so dbplyr computes it now and pastes in the value.

A call whose function is *not a plain name* is always computed in R. Examples: `lst$f(col)`, `mod$fn(col)`, `(\(x) x * 2)(col)`. Inside R, `col` means your R object, not the column.

```r
library(dplyr); library(dbplyr)
var1 <- 100                     # an R object with the same name as a column
lst  <- list(f = \(x) x * 2)    # stands in for a box module, e.g. helpers$double_it
d    <- memdb_frame(var1 = 1:3)
d |> mutate(x = lst$f(var1)) |> show_query()
#> SELECT *, 200.0 AS `x` ...                      <- 100 * 2, computed in R
d |> mutate(x = lst$f(var1)) |> pull(x)           #> 200 200 200
collect(d) |> mutate(x = lst$f(var1)) |> pull(x)  #> 2 4 6   (in-memory uses the column)
```

- **Why it's a problem:** the SQL is valid, the query runs, and the numbers are wrong. There is no warning. The same code is right in-memory, so tests on local data won't catch it. In a targets pipeline, the wrong values just flow downstream.
- **What the docs say:** the help page `?dbplyr::partial_eval` is marked internal, so it is not in the help index.
  - Its description says: *"If the tbl variables are known, and the symbol matches a tbl variable, then remote."*
  - A comment in its Examples says: *"Functions are always assumed to be remote."*
  - This case breaks both. `var1` *is* a column, but the R value is used. And the function is *not* sent to SQL.
  - The real rule appears only in a code comment (*"Compound calls, apart from pronouns and `::` aren't translatable"*, `R/tidyeval.R:225`), followed by `eval_bare(call, env)`.
  - The user-facing vignettes don't mention local evaluation at all.
- **What you should expect, and why:** either the in-memory answer or an error. dbplyr already errors in almost identical cases:
  - `.data$f(var1)` and `.env$f(var1)` give *"Use local() or remote() to force evaluation of functions"* (`R/tidyeval.R:226-231`).
  - `pkg::fn(col)` with no translation has errored since dbplyr 2.5.0 (tidyverse/dbplyr#1426).
  - The silent case is the odd one out.
- **Scope:** **dbplyr only.** It is not box's fault, but box makes it likely, because `mod$fn(col)` is the normal box style.
  - It also hits lists of helpers, R6 `obj$method(col)`, inline lambdas, and `(!!f)(col)`. I tested all four.
  - It is *silent* only when an R object with the column's name is visible: global, function-local, or **box module-level**. A module with `var1 <- 999` that calls `helpers$double_it(var1)` gives `1998`, with no global involved. So box's isolation does not protect you.
  - When no such object is visible, you get `object 'var1' not found`. That is confusing, but at least loud.
  - `options(dplyr.strict_sql = TRUE)` does not catch it.
- **Already reported?** I found no matching issue.
  - The closest is tidyverse/dbplyr#200 "Reconsider local evaluation" (closed 2019). It discussed when `x$y` is computed locally.
  - tidyverse/dbplyr#1340 "Feature Request: Some mechanism for partially evaluating functions" (closed) asked how to reuse your own R helper functions in dbplyr. That is the same need, but it is not this bug.
  - tidyverse/dbplyr#1870 "filter does not work when creating a vector on the fly for %in%" (open) is a different silent wrong result from the same local-vs-remote guessing. I reproduced it: `v %in% c(as.character(1:2), LETTERS[1:2])` returns 0 rows instead of 2.
- **Verdict: file it.** I tested a small prototype: it errors when a locally computed call with a compound head mentions a column name.
  - It catches `lst$f(var1)` and lambdas.
  - It still allows `lubridate$ymd("2024-01-01")`, `local(...)` and global-only arguments.
  - Limits: it does not cover `(!!f)(col)`, which goes through a different branch (`R/tidyeval.R:215-219`). It also gives a false alarm on `lst$f(cfg$var1)`. A real fix needs more care.
- **Until it's fixed:**
  - Never put `mod$fn(col)` inside a dbplyr verb.
  - Use translatable code instead (`var1 * 2`).
  - Or write a verb wrapper with `{{ }}`.
  - Or write a function that *returns code* and splice it in with `!!`.
  - Or `collect()` first (examples in [06-escape-hatches.md](06-escape-hatches.md#5-applying-a-local-r-function-to-a-database-column)).
  - Build `%in%` lists outside the query (`ids <- c(...)`), because of #1870.

## 2. dbplyr: `.sql$fn()` is not always "the SQL function" (file it; new)

**What happens.** `.sql$` is meant to say "this is a database function, not an R function". But dbplyr just removes `.sql$` and then translates as usual. So if the name matches an R function that dbplyr knows, you get R's translation.

```r
d <- memdb_frame(x = "alpha")
d |> transmute(y = .sql$substr(x, 2, 3)) |> show_query()
#> SELECT SUBSTR(`x`, 2, 2) AS `y` ...    <- R's substr(start, stop) turned 3 into length 2
d |> transmute(y = .sql$substr(x, 2, 3)) |> pull()       #> "lp"
d |> transmute(y = .sql$SUBSTR(x, 2L, 3L)) |> pull()     #> "lph" (upper case is not translated)
```

The same happens for SQL Server users with the natural spelling:
- `.sql$substring(x, 2, 3)` becomes `SUBSTRING([x], 2, 2)`. R's `substring(text, first, last)` meaning wins over SQL Server's `SUBSTRING(text, start, length)`. On duckdb it returns `"lp"`, not `"lph"`.

Other names are also still translated, but these give the same result:
- `.sql$nchar(x)` becomes `LENGTH(x)` on Oracle and `LEN(x)` on SQL Server.
- `.sql$round(y)` becomes `ROUND(y, 0)`.
- `.sql$paste(x, y)` becomes `x || ' ' || y`.

Second part: with `options(dplyr.strict_sql = TRUE)`, `.sql$nvl(y, 0)` errors with *"Don't know how to translate `nvl()`"*. Known names like `.sql$abs(y)` are fine. So you cannot have "error on my mistakes" **and** "I really mean this Oracle function" at the same time. The only way is a raw `sql("NVL(y, 0)")` string.

- **Why it's a problem:** code converted from SAS to Oracle or SQL Server uses `SUBSTR(x, start, length)` or `SUBSTRING(x, start, length)` everywhere. Writing `.sql$substr(x, 2, 3)` or `.sql$substring(x, 2, 3)` looks like the explicit, safe choice. But it silently returns a shorter string.
- **What the docs say:**
  - `?dbplyr::.sql`: *"Use `.sql$foo(x, y)` to make it clear that you're calling the SQL `foo()` function, not the R `foo()` function."*
  - The same page then says: *"Note that `.sql` itself does nothing and is just `NULL`; it is automatically removed when dbplyr translates your R code to SQL."* A careful reader might guess from this that the rest is translated as usual. But it never says so.
  - `vignette("dbplyr")`: *"To make it more clear that you're calling a SQL function, not an R function, you can use the `.sql` pronoun"*.
  - `vignette("translation-function")` recommends `.sql$` for *"deliberately calling a SQL function"*. Separately, it recommends `dplyr.strict_sql` to *"error if it doesn't know how to translate a function"*.
  - Nowhere does it say that known R names are still translated after `.sql$`, or that strict mode rejects `.sql$` calls.
- **What you should expect, and why:** `.sql$foo(x)` should become `foo(x)` exactly, with only the arguments translated. It should also be allowed in strict mode. That is what "the SQL function, not the R function" means. At the very least, the docs should warn you.
- **Scope:** **dbplyr only.** `.sql` is new in 2.6.0.
  - It changes results only when the name matches an R function with a different meaning (`substr`, `substring`).
  - With strict mode off, unknown names like `.sql$nvl` pass through fine.
- **Already reported?** I found no matching issue. `.sql` came from tidyverse/dbplyr#1117 (closed). That issue asked for it mainly to quiet `R CMD check` notes.
- **Verdict: file it** as one issue covering both parts. If the maintainers say it works as intended, it becomes a docs fix.
- **Until it's fixed:**
  - Write SQL function names in UPPER CASE (`.sql$SUBSTR`, `.sql$SUBSTRING`, `.sql$NVL`). The Oracle, SQL Server and SQLite translation tables contain no upper-case names, so these pass through unchanged.
  - With upper case, write whole numbers as integers (`2L, 3L`). Otherwise dbplyr writes `2.0, 3.0`, and duckdb rejects `SUBSTRING(x, 2.0, 3.0)`. I did not test Oracle or SQL Server with `2.0`.
  - Upper case does *not* get past strict mode. Under strict mode, use `sql("...")`.
  - Check the result with `show_query()`.

## 3. box: `box::use(base[...])` fails (file it)

**What happens.**

```r
box::use(base[nchar])
#> Error in box::use(base[nchar]) :
#>   no item called "getNamespaceInfo(mod_ns, "lazydata")" on the search list
```

`box::use(base)`, `base[...]` and `base[nch = nchar]` fail the same way, both at top level and inside modules. Every other default package works in every form (see [07-box-base.md](07-box-base.md)).

- **Why it fails:** box asks R for each package's list of lazy-loaded data sets (`R/use.r:478`). R refuses that question for base (`getNamespaceInfo()` says "operation not allowed on base namespace"), and the error comes out garbled.
- **Why it's a problem:** mostly it's a papercut, because base is always visible inside modules. But there are real uses:
  - You need it to get a base function back after a wildcard import hid it. In a module, `box::use(dplyr[...])` replaces base's `intersect` with the version from generics, and `box::use(dplyr[...], base[intersect])` errors. (generics' `intersect` gives the same answer for ordinary vectors. So the problem is that you can't choose, not that you get wrong results.)
  - You also need it for aliases (`base[nch = nchar]`) and for "import everything explicitly" style rules.
  - The error message gives no useful clue.
- **What the docs say:**
  - box README: *"`box::use` provides a universal import declaration. It works for packages just as well as for modules."*
  - `?box::use` lists `pkg` with no exceptions.
  - The FAQ says *"Inside modules, only the 'base' package is attached."*
  - Nothing says base can't be imported.
- **What you should expect, and why:** it should work like any other package. Failing that, a clear message such as "base is always available; no need to import it".
- **Scope:** **box only.** It has nothing to do with dbplyr.
  - As far as I can tell, it is not specific to R 4.6. The failing line is box's own code, and R has long refused this for base (`asNamespace(ns, base.OK = FALSE)`).
  - It has been broken since box added lazy-data support (box 1.1.3, klmr/box#219). Tested: I installed box 1.1.2 and 1.1.3 on R 4.6.1. 1.1.2 imports base; 1.1.3 fails with today's error ([07-box-base.md](07-box-base.md#why-it-fails)).
  - Current box 1.2.3 (same code as box main today) still fails. Older R versions were not run.
- **Already reported?** I found no issue or PR in klmr/box.
- **Verdict: file it.** I tested a one-line fix (skip the lazy-data lookup for base). Base imports work with it, and packages with lazy data still work.
- **Until it's fixed:** inside the module, write `intersect <- base::intersect` (or `nch <- base::nchar`).

## 4. dbplyr: an R vector of length > 1 becomes an SQL tuple (optional, low priority)

**What happens.** A *tuple* is a list of values in brackets, like `(10, 20, 30)`. SQL only accepts it in a few places, such as `IN (...)`.

```r
vec3 <- c(10, 20, 30); d <- memdb_frame(v = 1:3)
d |> mutate(x = vec3) |> show_query()   #> SELECT *, (10.0, 20.0, 30.0) AS `x` ...
d |> filter(v == vec3) |> show_query()  #> ... WHERE (`v` = 10.0, 20.0, 30.0)
```

- SQLite gives `row value misused` at `collect()`.
- duckdb: `filter` errors, but `mutate` **quietly** returns an odd column (a data frame with three constant columns).
- The Oracle and SQL Server dialects produce the same SQL. I did not run it on those databases.
- **Why it's a problem:** in-memory, `mutate(x = vec3)` works on a 3-row data frame (one value per row). So code moved from local data to the database breaks. The error doesn't mention `vec3`, or you get a strange column.
- **What the docs say:** `?dbplyr::escape` says it *"will wrap in parens if length > 1"*. That is what makes `col %in% vec3` work, as in the `?partial_eval` example `id %in% ids`. Nothing covers other uses.
- **What you should expect, and why:** an error when the query is built, for example: "`vec3` has length 3; only single values can be used here. Did you mean `%in%`?" Database rows have no fixed order, so "one value per row" has no meaning there.
- **Scope:** **dbplyr only.** Strict mode doesn't catch it.
- **Already reported?** I found no matching issue.
- **Verdict:** optional. It is mostly loud; the error just isn't helpful. File it if you have time (a draft is ready).
- **Until it's fixed:** use `%in%` for membership. For "one value per row", put the values in a table and join.

## Dropped after re-checking

These three were in the first version. Re-checking showed they are wrong or not worth filing.

### 5. "dbplyr has no strict mode": wrong, drop it

- `options(dplyr.strict_sql = TRUE)` makes dbplyr error on any function it can't translate. For example, `mutate(x = myfun(var1))` gives *"Don't know how to translate `myfun()`"*.
- When: `mutate()` itself still runs. The error comes when dbplyr writes the SQL (`show_query()`, `collect()`, ...), before anything is sent to the database. So you get dbplyr's clear message instead of the database's.
- It is documented in `vignette("translation-function")`, section "Error for unknown translations": *"you can also use the `dplyr.strict_sql` option to force dbplyr to error if it doesn't know how to translate a function"*.
- My earlier search only looked for option names starting with `dbplyr.`. This option's name starts with `dplyr.`.
- Also, since dbplyr 2.5.0, `pkg::fn(col)` with no translation always errors (NEWS, #1426).
- Limits:
  - It doesn't catch item 1 (the silent wrong result).
  - It blocks `.sql$` for functions dbplyr doesn't know (2).
  - It also blocks SQL operators that the same vignette shows, such as `x %LIKE% "a%"`. Use `str_like(x, "a%")` instead, which works in strict mode.
- It is still useful during development and in tests: `withr::local_options(dplyr.strict_sql = TRUE)`.
- Optional docs request instead (draft 5): the option is only in a vignette, so ask dbplyr to list it in the help pages too.

### 6. "the unknown-function error has no hint": don't file

- **What happens:** with `myfun <- \(x) x * 2`, running `d |> mutate(x = myfun(var1)) |> collect()` gives *"Failed to collect lazy table. Caused by error: ! no such function: myfun"* (SQLite). duckdb says *"Scalar Function with name myfun does not exist!"*. Nothing says "this is an R function that dbplyr didn't translate". The dev version is the same.
- **What the docs say:** passing unknown functions through is a documented feature: *"Any function that dbplyr doesn't know how to convert is left as is."* (`vignette("translation-function")`).
- **Why not file it:**
  - Oracle users rely on this feature (`NVL`, `DECODE`, `INSTR`, ...).
  - A warning for "this name is also an R function" would also fire on SQL you wrote on purpose. `replace()`, `date()` and `trunc()` are base R functions **and** common SQL functions, and dbplyr passes all three through.
  - The early-error tool you want already exists: strict mode (item 5). It only needs item 2 fixed so it works smoothly with `.sql$`.
- **Scope:** **dbplyr only.**
- **Verdict:** drop. Use strict mode and `show_query()` while developing.

### 7. "tidyselect doesn't warn on lazy tables": my test was wrong, drop it

- In the original run, the in-memory case ran first in the same R session. This deprecation warning is shown **only once per session**, so the database cases after it were silent.
- Re-test, with one fresh `Rscript` per case:
  - SQLite alone: warns.
  - duckdb alone: warns.
  - in-memory alone: warns.
  - in-memory then SQLite, or SQLite then in-memory: only the first one warns.
  - With `options(lifecycle_verbosity = "warning")`: all warn.
- `?lifecycle::deprecate_soft` says: *"Warnings are only issued once per session to avoid overwhelming the user."*
- So the line in the first version saying dbplyr gives no warning was wrong.
- **What I found instead (box + tidyverse deprecations):** inside a **box module**, this warning never shows, not even with `lifecycle_verbosity = "warning"`.
  - Soft deprecations only warn for code that lives in the global environment (or in a package's tests), and box modules don't.
  - `?lifecycle::deprecate_soft` says so: *"`deprecate_soft()` warns only if the deprecated function is called directly, i.e. a user is calling a function they wrote in the global environment or a developer is calling it in their package."*
  - But `?lifecycle::verbosity` says `"warning"` means *"warn every time"*. That is not true here. So the lifecycle help is a bit misleading. This is not a box or dbplyr bug.
  - Only `options(lifecycle_verbosity = "error")` makes it visible (as an error).
  - Tip: turn that option on for a test run to find deprecated calls in your modules. Be aware that it turns *every* soft deprecation into an error, including ones inside other packages you use.

## Also drafted: SQL Server / Oracle bugs and targets / box notes

Same questions, shorter. Evidence: [05-sql-server-oracle.md](05-sql-server-oracle.md#upstream-candidates-drafted-not-filed) (drafts 6–10) and [04-targets.md](04-targets.md) (drafts 11–12). Ready-to-paste text: drafts 6–12 in [upstream-drafts.md](upstream-drafts.md).

| draft | package | the problem in one line | silent? | verdict |
|---|---|---|---|---|
| 6 | dbplyr | `union()` / `union_all()` / `bind_queries()` never finish with `dialect_mssql()` | no, R hangs | file |
| 7 | dbplyr | Oracle `difftime()` gives the number of days with the sign flipped | **yes, wrong numbers** | file |
| 8 | dbplyr | Oracle `x %% 2` becomes `x % 2`, which Oracle rejects | no | file |
| 9 | dbplyr | SQL Server `arrange(is.na(x))` writes invalid SQL | no | file |
| 10 | dbplyr | Oracle: an R date put into a query is sent as plain text | no: an error (it works only if your session's date format happens to match) | file, as a "likely bug" |
| 11 | targets | `tar_option_set(imports = "dplyr")` breaks the whole pipeline | no | optional, low priority |
| 12 | box | `box::use(mods/x)` at the top of `_targets.R` can't find the module under `tar_make()` | no | add a comment to the open issue klmr/box#199 |

### Draft 6. dbplyr: unions hang with `dialect_mssql()`

- **What happens:** with a fake SQL Server table (`lazy_frame(..., con = dialect_mssql())`), `show_query()` of a `union_all()` never returns. R runs at 100% CPU until you kill it.
- **Why it's a problem:** you lose your R session, with no message.
- **What the docs say:** `?"backend-mssql"` tells you to use `dialect_mssql()` with `lazy_frame()` to see SQL Server SQL. Nothing says unions are not supported.
- **What to expect:** the same SQL that `simulate_mssql()` gives.
- **Scope:** **dbplyr only**, and only when you **simulate** SQL Server. A real connection is not affected (expected from the code; checked on duckdb with `with_dialect()`, not on a live SQL Server).
- **Until it's fixed:** use `simulate_mssql()` for queries with unions.

### Draft 7. dbplyr: Oracle `difftime()` has the sign flipped

- **What happens:** `difftime(dt, as.Date("2024-01-02"), units = "days")` gave 1, 0, -30, -58 on Oracle. R and SQL Server gave -1, 0, 30, 58.
- **Why it's a problem:** the query runs and the numbers look plausible. "Days late" silently becomes "days early".
- **What the docs say:** R's `difftime(time1, time2)` is `time1 - time2`. dbplyr fixed the same bug for SQL Server, Snowflake and Redshift (tidyverse/dbplyr#1525, closed), but not for Oracle.
- **What to expect:** the same sign as R.
- **Scope:** **dbplyr's Oracle translation only.**
- **Until it's fixed:** on Oracle, write `dt - as.Date(!!chr)`.

### Draft 8. dbplyr: Oracle `%%` becomes `%`

- **What happens:** `x %% 2` becomes `"x" % 2`. Oracle fails with `ORA-00911` ("invalid character").
- **Why it's a problem:** the error is loud, but it does not tell you that the modulo is the cause.
- **What to expect:** `MOD(x, 2)`, Oracle's modulo function.
- **Scope:** **dbplyr's Oracle translation only.**
- **Until it's fixed:** `.sql$MOD(x, 2L)`.

### Draft 9. dbplyr: SQL Server `arrange()` on TRUE/FALSE

- **What happens:** `arrange(is.na(x))` becomes `ORDER BY ([x] IS NULL)`. SQL Server rejects it as a syntax error.
- **Why it's a problem:** `arrange(is.na(x))` is a common R way to put missing values last or first.
- **What to expect:** valid SQL. SQL Server can't sort by a TRUE/FALSE condition directly, so dbplyr already turns it into a 1/0 `BIT` value in `SELECT`. It forgets to do that in `ORDER BY`. With that step added, the SQL ran on SQL Server 2022.
- **Scope:** **dbplyr's SQL Server translation only.**
- **Until it's fixed:** `arrange(if_else(is.na(x), 1L, 0L), x)`.

### Draft 10. dbplyr: Oracle dates from R are sent as text

- **What happens:** `filter(dt <= !!cutoff)`, with an R `Date`, becomes `"dt" <= '2024-01-02'`. Oracle reads that text with the session's date format (`NLS_DATE_FORMAT`). With the default `DD-MON-RR` it fails: `ORA-01861`.
- **Why it's a problem:** the most natural way to filter by an R date fails on Oracle. Whether it works depends on a session setting you may not know about.
- **What the docs say:** nothing says R dates need converting. `as.Date("...")` written inside the query already becomes `DATE '...'` (fixed in tidyverse/dbplyr#1468 and #1389).
- **What to expect:** `DATE '2024-01-02'`.
- **Scope:** **dbplyr's Oracle translation only.** SQL Server converts the text itself, so it works there.
- **Why "likely bug":** the maintainers may say it is by design. Then it is a docs fix.
- **Until it's fixed:** `filter(dt <= as.Date(!!format(cutoff)))`.

### Draft 11. targets: `tar_option_set(imports = "dplyr")` fails

- **What happens:** `tar_make()` stops with `igraph::is_dag(graph) is not TRUE`.
- **Why it's a problem:** the message gives no clue. The cause: dplyr has two pairs of internal functions that call each other, and targets refuses loops between imported functions.
- **What the docs say:** `?tar_option_set` says targets "tracks every dataset and every object in the package namespace as if it were part of the global namespace". It lists 4 limits. Loops between functions are not one of them.
- **What to expect:** it works, or a clear error that names the functions.
- **Scope:** **targets only.** It hits any package with functions that call each other. Nothing to do with box or crew.
- **You don't need it:** `imports` only *tracks* functions. It does not load anything. To load packages, use `tar_option_set(packages =)`.

### Draft 12. box: modules not found when `tar_make()` runs `_targets.R`

- **What happens:** `tar_make()` runs `_targets.R` in a fresh R started by callr, as `R -f /tmp/.../callr-scr-...`. box takes that temp folder as "the script's folder". So `box::use(mods/x)` fails with `unable to load module`.
- **Why it's a problem:** the same file works with `tar_make(callr_function = NULL)`. The error names a temp folder, not your project.
- **What the docs say:** `?box::use` says that for an R file run from the command line, box uses that file's folder. Under callr, that file is a temp file, not your `_targets.R`.
- **What to expect:** box ignores callr's temp script and uses the working directory. It already does that for crew workers (started with `Rscript -e`).
- **Scope:** **box + callr.** targets hits it because `tar_make()` uses callr. crew is not involved.
- **Already reported:** klmr/box#199 "Callr module sourcing" (open since 2021). So add a comment there, not a new issue.
- **Until it's fixed:** `options(box.path = getwd())` at the top of `_targets.R`. If `R_BOX_PATH` is set on your machine, add the project folder to it instead (see [04-targets.md](04-targets.md#second-trap-box-cannot-find-modules-from-_targetsr-even-without-crew)).

---
[← back to README](../README.md) · [ready-to-paste drafts](upstream-drafts.md) · [cheat sheet](../CHEATSHEET.md)
