# Upstream drafts (ready to paste; **none filed**)

These are drafts only. Filing is your call.

- Fixes found when I re-checked the drafts are already in the draft bodies. A "Note for you" line under a draft is not part of the text to paste.
- Before filing, search the tracker once more. I could read issue titles and opening posts, but not comment threads.
- Plain-language explanation of each one (why it's a problem, what to expect, which package): [upstream-issues.md](upstream-issues.md).

| # | repo | title |
|---|---|---|
| 1 | tidyverse/dbplyr | Calls with a non-symbol function (`obj$fn(col)`, `(\(x) ...)(col)`) are evaluated in R and silently use a same-named local variable instead of the column |
| 2 | tidyverse/dbplyr | `.sql$fn()` still applies R translations (e.g. `.sql$substr()` changes the SUBSTR length) and is rejected by `dplyr.strict_sql` |
| 3 | klmr/box | box::use(base[...]) fails with a misleading error since 1.1.3 (lazydata lookup on the base namespace) |
| 4 | tidyverse/dbplyr | Local vectors of length > 1 outside `%in%` are inlined as an SQL tuple instead of erroring |
| 5 | tidyverse/dbplyr | Document dplyr.strict_sql in the reference docs (only mentioned in a vignette) |
| 6 | tidyverse/dbplyr | union()/union_all()/bind_queries() hang forever with dialect_mssql() (modify_tree recurses into numeric_version) |
| 7 | tidyverse/dbplyr | Oracle: difftime() translation has the sign reversed |
| 8 | tidyverse/dbplyr | Oracle: %% translates to % (ORA-00911); should use MOD() |
| 9 | tidyverse/dbplyr | SQL Server: arrange() on a logical expression renders invalid ORDER BY (e.g. ORDER BY ([x] IS NULL)) |
| 10 | tidyverse/dbplyr | Oracle: Date/POSIXct values spliced into a query are escaped as plain strings and fail with ORA-01861 |
| 11 | ropensci/targets | tar_option_set(imports = "dplyr") fails with 'igraph::is_dag(graph) is not TRUE' (mutually recursive package functions) |
| 12 | klmr/box | (comment for #199) box::use() at the top of a targets _targets.R fails under tar_make() because callr runs R with -f <tempfile> |

## 1. tidyverse/dbplyr: Calls with a non-symbol function (`obj$fn(col)`, `(\(x) ...)(col)`) are evaluated in R and silently use a same-named local variable instead of the column

*Related, already on the tracker:* tidyverse/dbplyr#200 'Reconsider local evaluation' (closed 2019-01-09; body: partial_eval locally evaluates `pkg::bar()` and `x$y`, worth reconsidering with unquoting). tidyverse/dbplyr#1870 'filter does not work when creating a vector on the fly for %in%' (open; different silent wrong result from the same local/remote heuristic, reproduced here). tidyverse/dbplyr#1426 'Make namespaced functions error if no translation?' (closed, completed; precedent for erroring). No exact duplicate found by issue search (I could not read comment threads).

<details><summary>Draft body</summary>

`partial_eval_call()` evaluates any call whose function is not a plain symbol (apart from the `.data$`/`.env$`/`.sql$` pronouns and `pkg::`) in R, via `eval_bare(call, env)` (R/tidyeval.R, "Compound calls, apart from pronouns and `::` aren't translatable"). If an argument of that call is a column name that also exists as a variable in the calling environment, the variable is used, the result is inlined as a constant, and there is no error or warning. The same code on a local data frame uses the column.

``` r
library(dplyr, warn.conflicts = FALSE)
library(dbplyr)

var1 <- 100
lst <- list(f = function(x) x * 2)
db <- memdb_frame(var1 = 1:3)

db |> mutate(x = lst$f(var1)) |> show_query()
#> <SQL>
#> SELECT *, 200.0 AS `x`
#> FROM `dbplyr_tmp_...`

db |> mutate(x = lst$f(var1)) |> pull(x)
#> [1] 200 200 200
collect(db) |> mutate(x = lst$f(var1)) |> pull(x)
#> [1] 2 4 6
```

The same happens with `(\(z) z * 2)(var1)` and `(!!f)(var1)`, and with a variable defined in a function or a box module rather than globally. Without any `var1` in scope you get `object 'var1' not found` instead, which is confusing but at least loud. `options(dplyr.strict_sql = TRUE)` changes nothing.

Why it matters: `obj$fn(col)` is the normal style for box modules (`helpers$clean(col)`), R6 objects, and lists of helpers. The rule documented in `?partial_eval` ("If the tbl variables are known, and the symbol matches a tbl variable, then remote") is silently broken. The near-identical `.data$f(var1)` already errors ("Use local() or remote() to force evaluation of functions"), and since 2.5.0 namespaced calls without a translation error too (#1426).

Suggestion: keep evaluating such calls locally when their arguments are purely local (e.g. `lubridate$ymd("2024-01-01")`, which is useful). But error when a locally evaluated call refers to a column of the table, and point to `local()` for opting in. A rough prototype is one extra check before the `return(eval_bare(call, env))` in the compound-call branch:

``` r
cols <- intersect(all.names(call[-1]), op_vars(data))
if (length(cols)) {
  cli::cli_abort(c(
    "{.code {expr_deparse(fun)}()} is evaluated in R, but its arguments use column {.var {cols}}.",
    i = "dbplyr can only translate functions called by name. Use {.code local()} if you really mean the R objects."
  ), call = NULL)
}
```

With it, `lst$f(var1)` and `(\(z) z * 2)(var1)` error, while `lubridate$ymd("2024-01-01")`, `local(lst$f(var1))` and `lst$f(only_global)` still work. I have not run the test suite with it. Two known gaps: `(!!f)(var1)` goes through a separate branch (the `is.function(fun)` one, R/tidyeval.R:215-219) and is not caught; and `all.names()` also matches `$` field names, so `lst$f(cfg$var1)` is a false alarm. A real fix probably needs a more careful walk.

Related: #200 (closed) discussed when `partial_eval()` evaluates `x$y` locally. #1870 (open) is another silent wrong result from the local/remote guess.

Tested with dbplyr 2.6.0 (CRAN) and main @ f478e20 (2.6.0.9000); R 4.6.1, RSQLite 3.53.3, duckdb 1.5.6.

</details>

## 2. tidyverse/dbplyr: `.sql$fn()` still applies R translations (e.g. `.sql$substr()` changes the SUBSTR length) and is rejected by `dplyr.strict_sql`

*Related, already on the tracker:* tidyverse/dbplyr#1117 'Export a mask akin to rlang::.data for custom SQL functions' (closed, completed 2025-12-15; origin of .sql, motivated by R CMD check notes). tidyverse/dbplyr#1570 'Translation to REGEXP_INSTR errors in snowflake with options(dplyr.strict_sql = TRUE)' (closed, completed; shows strict mode is maintained). No duplicate found.

<details><summary>Draft body</summary>

`?.sql` says: "Use `.sql$foo(x, y)` to make it clear that you're calling the SQL `foo()` function, not the R `foo()` function." It also says "`.sql` itself does nothing and is just `NULL`; it is automatically removed when dbplyr translates your R code to SQL", which hints at the behaviour below but doesn't spell it out. The pronoun is only stripped in `partial_eval()` (`call[[1]] <- fun[[3]]`), and the remaining call then goes through normal translation. This has two consequences.

**1. If the SQL function has the same name as a translated R function, you get R's translation, sometimes with a different meaning:**

``` r
library(dplyr, warn.conflicts = FALSE)
library(dbplyr)
db <- memdb_frame(x = "alpha")

db |> transmute(y = .sql$substr(x, 2, 3)) |> show_query()
#> <SQL>
#> SELECT SUBSTR(`x`, 2, 2) AS `y`          # R's substr(start, stop) -> SQL length 2
#> FROM `dbplyr_tmp_...`
db |> transmute(y = .sql$substr(x, 2, 3)) |> pull()
#> [1] "lp"
db |> transmute(y = .sql$SUBSTR(x, 2L, 3L)) |> pull()   # upper case is not in the translator
#> [1] "lph"
```

(The upper-case workaround needs integer literals: with `2, 3` dbplyr writes `2.0, 3.0`, which duckdb rejects in `SUBSTRING(x, 2.0, 3.0)`.)

Other examples: `.sql$nchar(x)` becomes `LENGTH(x)` (Oracle) or `LEN(x)` (SQL Server), `.sql$round(y)` becomes `ROUND(y, 0)`, and `.sql$paste(x, y)` becomes `x || ' ' || y`.

**2. With `options(dplyr.strict_sql = TRUE)`, `.sql$` calls to functions dbplyr doesn't know are rejected.** So there is no way to combine "error on accidental untranslated R functions" with "deliberately call this SQL function", except raw `sql()` strings:

``` r
options(dplyr.strict_sql = TRUE)
lf <- lazy_frame(y = 1, con = dialect_oracle())
lf |> mutate(z = .sql$nvl(y, 0))
#> Error: Don't know how to translate `nvl()`
lf |> mutate(z = sql("NVL(y, 0)"))   # works, but y is not quoted/escaped
```

Expected: `.sql$foo(...)` renders as `foo(<translated args>)` with no R translation of `foo`, and it is allowed under `dplyr.strict_sql`. Then `.sql$` would be the explicit "this is SQL" marker that the docs and the strict-mode section of `vignette("translation-function")` suggest. If that's not the intent, it would help if `?.sql` and the vignettes said that `.sql$` is only a marker (for R CMD check) and that known R names are still translated.

Context: `.sql` came from #1117 and is new in 2.6.0, so this may be a good time to settle the semantics.

Tested with dbplyr 2.6.0 (CRAN) and main @ f478e20 (2.6.0.9000).

</details>

## 3. klmr/box: box::use(base[...]) fails with a misleading error since 1.1.3 (lazydata lookup on the base namespace)

*Related, already on the tracker:* Searched klmr/box issues and found no report of this bug. Related, all closed: klmr/box#219 'Support package data' (added the lazydata lookup that causes this); klmr/box#294 'Attaching datasets with box::use()'; klmr/box#200 'Auto-use (optionally) R's standard library?'; klmr/box#181 'Behavior with stats package'. Only titles/states were visible (plus #200's body); I could not read the comments.

<details><summary>Draft body</summary>

Importing from `base` fails in every form, at top level and inside modules:

```r
box::use(base[nchar])
#> Error in box::use(base[nchar]) :
#>   no item called "getNamespaceInfo(mod_ns, "lazydata")" on the search list
#> In addition: Warning message:
#> In ls(getNamespaceInfo(mod_ns, "lazydata")) :
#>   'getNamespaceInfo(mod_ns, "lazydata")' converted to character string
```

`box::use(base)`, `box::use(base[nch = nchar])` and `box::use(base[...])` fail the same way. Other default packages (stats, utils, methods, tools, graphics, grDevices, datasets) and lazydata packages (e.g. `stringr[fruit]`, `dplyr[starwars]`) import fine.

**Cause.** `mod_export_names.box$pkg_info` (R/use.r) calls `ls(getNamespaceInfo(mod_ns, 'lazydata'))`. `getNamespaceInfo()` uses `asNamespace(ns, base.OK = FALSE)`, so for base it errors with `operation not allowed on base namespace`. `ls()` then swallows that error, deparses the argument and looks it up as a search-list name, which gives the confusing message above. The lookup was added with lazydata support in 1.1.3 (#219). In 1.1.2 the method was `getNamespaceExports(mod_ns)`, which special-cases base, so `box::use(base[...])` used to work. (Checked by installing both CRAN versions on R 4.6.1: 1.1.2 imports base, 1.1.3 fails with the error above.)

**Why support it.** Inside modules base is always visible, so importing it is usually redundant. But it has real uses: aliases (`base[nch = nchar]`), re-pinning a base function after a wildcard import masked it (`box::use(dplyr[...], base[intersect])`), and a "declare every dependency" style. `base::nchar` is fine in R, and Python allows `from builtins import len`. If you'd rather disallow it, an explicit error ("base is always available inside modules") would still beat the current message.

**Suggested fix:**

```diff
 `mod_export_names.box$pkg_info` = function (info, mod_ns) {
-    c(getNamespaceExports(mod_ns), ls(getNamespaceInfo(mod_ns, 'lazydata')))
+    exports = getNamespaceExports(mod_ns)
+    # The base namespace has no namespace info, and hence no lazydata.
+    if (isBaseNamespace(mod_ns)) return(exports)
+    c(exports, ls(getNamespaceInfo(mod_ns, 'lazydata')))
 }
```

Possible test (tests/testthat/test-pkg.r):

```r
test_that('base can be imported', {
    expect_error(box::use(base[nch = nchar]), NA)
    expect_equal(nch('abc'), 3L)
    expect_error(box::use(base), NA)
    expect_identical(base$nchar, base::nchar)
})
```

**Verification.** I put the patched method into the installed namespace (`assignInNamespace`, scratch session) and ran these checks:

- All four base forms work, at top level and in a module.
- Lazydata imports (datasets, dplyr, stringr) still work.
- The test above passes.
- The full test suite from current HEAD gives identical results with and without the patch: 167 tests, 551 expectations, 0 failures. The one error, in `only exported things can be attached`, is only there because devtools is not installed locally.

**Session.** R 4.6.1 (2026-06-24), x86_64-pc-linux-gnu, Ubuntu 24.04.5 LTS, box 1.2.3 (CRAN). HEAD 2eb1430 has the same code. Not R-4.6-specific as far as I can tell: the failing call is pure R and R NEWS shows no relevant change.

(Minor, related doc nit: vignettes/mod-envs.rmd says the imports env's parent is the base *namespace* environment. In the code it is `baseenv()`, via the legacy `library`/`require`/`source` intercept env.)

</details>

## 4. tidyverse/dbplyr: Local vectors of length > 1 outside `%in%` are inlined as an SQL tuple instead of erroring

*Related, already on the tracker:* None found. Loosely related: tidyverse/dbplyr#1870 'filter does not work when creating a vector on the fly for %in%' (open), tidyverse/dbplyr#1281 'Invalid SQL generated when using %in% to filter to values in a vector subset' (closed 2023).

<details><summary>Draft body</summary>

(Low priority.)

``` r
library(dplyr, warn.conflicts = FALSE)
library(dbplyr)
vec3 <- c(10, 20, 30)
db <- memdb_frame(v = 1:3)

db |> mutate(x = vec3) |> show_query()
#> SELECT *, (10.0, 20.0, 30.0) AS `x` ...
db |> mutate(x = vec3) |> collect()
#> Error in `collect()`: ! Failed to collect lazy table.
#> Caused by error: ! row value misused

db |> filter(v == vec3) |> show_query()
#> SELECT * ... WHERE (`v` = 10.0, 20.0, 30.0)
```

On duckdb, `filter()` errors with a conversion error. But `mutate(x = vec3)` doesn't error: it returns a struct column (`x` is a data frame with three constant columns). The Oracle and SQL Server dialects render the same SQL.

The tuple comes from `escape()` wrapping vectors of length > 1 in parens. That is right for `%in%` (as in the `?partial_eval` example `id %in% ids`). Everywhere else there is no sensible SQL meaning, because database rows have no order. A build-time error naming the variable would be much clearer than a database error, e.g. "`vec3` has length 3; only length-1 values can be used here. Did you mean `%in%`?". Code moved from a local tibble (where `mutate(x = vec3)` works) is the typical way to hit this.

Tested with dbplyr 2.6.0 (CRAN) and main @ f478e20 (2.6.0.9000).

</details>

## 5. tidyverse/dbplyr: Document dplyr.strict_sql in the reference docs (only mentioned in a vignette)

*Related, already on the tracker:* None found.

<details><summary>Draft body</summary>

`options(dplyr.strict_sql = TRUE)` is the only strictness switch in dbplyr (R/translate-sql.R:149). The only place it is documented is the 'Function translation' vignette (vignettes/translation-function.Rmd:311-319). Because the name starts with `dplyr.`, users who search for `dbplyr` options do not find it. Could it be listed in `?translate_sql`, in `?partial_eval` or on a package-level options page? An alias such as `dbplyr.strict_sql` might also help.

</details>

## 6. tidyverse/dbplyr: union()/union_all()/bind_queries() hang forever with dialect_mssql() (modify_tree recurses into numeric_version)

*Related, already on the tracker:* None found. Searched tidyverse/dbplyr issues for 'dialect_mssql union hangs infinite recursion', 'union_all SQL Server lazy_frame numeric_version modify_tree', 'SQL Server union freezes show_query' and 'union_all mssql dialect hang show_query never returns' (results unrelated: #1317, #1269, #1134 closed). Searched tidyverse/purrr for 'modify_tree numeric_version infinite recursion': none.

<details><summary>Draft body</summary>

With dbplyr 2.6.0 (R 4.6.1), rendering a union of two lazy tables that use `dialect_mssql()` never returns; R spins at 100% CPU.

```r
library(dbplyr)
a <- lazy_frame(x = 1, con = dialect_mssql())
remote_query(dplyr::union_all(a, a))   # never returns (also show_query(), union(), bind_queries())

b <- lazy_frame(x = 1, con = simulate_mssql())
remote_query(dplyr::union_all(b, b))   # fine
```

`intersect()`, `setdiff()`, `semi_join()`, `anti_join()` are fine, and so is `with_dialect(<real con>, dialect_mssql())`.

Cause (I think): `db_sql_render.sql_dialect_mssql()` -> `mssql_render_preprocess()` calls `purrr::modify_tree(sql$lazy_query, is_node = \(x) is.list(x) || inherits(x, "lazy_query"), ...)`. A union query stores the RHS `tbl_lazy` itself (`$unions$table`), whose `src$con` is the dialect object, a list with `version = numeric_version("15.0")`. A `numeric_version` is a list whose `[[1]]` is identical to itself (`identical(v[[1]], v)` is `TRUE`), so the tree walk never ends. Minimal: `purrr::modify_tree(list(v = numeric_version("15.0")), is_node = is.list)` does not return.

Possible fix: stop the walk at `numeric_version`, `sql_dialect` and `DBIConnection` objects:

```r
mssql_render_preprocess <- function(sql) {
  sql$lazy_query <- purrr::modify_tree(
    sql$lazy_query,
    is_node = \(x) inherits(x, "lazy_query") ||
      (is.list(x) && !inherits(x, c("numeric_version", "sql_dialect", "DBIConnection"))),
    post = mssql_update_where_clause
  )
  sql
}
```

Patched in locally, this ends the hang and keeps the BIT cast on both sides of a union (`WHERE (cast([f] AS [BIT]) = 1)`) and in joins. The broader `is_node = \(x) inherits(x, "lazy_query") || (is.list(x) && !is.object(x))` is not enough: it also ends the hang, but the right-hand side of the union then renders `WHERE ([f])`, which SQL Server rejects.

</details>

## 7. tidyverse/dbplyr: Oracle: difftime() translation has the sign reversed

*Related, already on the tracker:* tidyverse/dbplyr#1525 'Translation of `difftime()` is inverted on Snowflake, MSSQL, Redshift' (closed) fixed the same bug for those backends, not Oracle.

<details><summary>Draft body</summary>

```r
library(dbplyr)
lazy_frame(dt = Sys.Date(), con = dialect_oracle()) |>
  dplyr::mutate(y = difftime(dt, as.Date("2024-01-02"), units = "days")) |>
  show_query()
#> SELECT "df".*, CEIL(CAST(DATE '2024-01-02' AS DATE) - CAST("dt" AS DATE)) AS "y"
```

R's `difftime(time1, time2)` is `time1 - time2`, but the Oracle translation (R/backend-oracle.R, `sql_glue("CEIL(CAST({time2} AS DATE) - CAST({time1} AS DATE))")`) computes `time2 - time1`. Run on Oracle 23.26 (Free) with dt = 2024-01-01, 2024-01-02, 2024-02-01, 2024-02-29 it returns 1, 0, -30, -58; SQL Server and duckdb (and R) return -1, 0, 30, 58. Postgres was fixed to `time1 - time2`. Also `CEIL()` rounds partial days up for DATE values with a time part, which differs from R.

</details>

## 8. tidyverse/dbplyr: Oracle: %% translates to % (ORA-00911); should use MOD()

*Related, already on the tracker:* None found. Searched 'Oracle modulo %% translated to % instead of MOD' (results unrelated, e.g. #1315, #155, #661 closed).

<details><summary>Draft body</summary>

```r
library(dbplyr)
lazy_frame(x = 1L, con = dialect_oracle()) |> dplyr::mutate(y = x %% 2L) |> show_query()
#> SELECT "df".*, "x" % 2 AS "y" FROM "df"
```

Oracle has no `%` operator; on Oracle 23.26 Free this fails with `ORA-00911: %: invalid character after <identifier>`. `MOD("x", 2)` works (verified with `.sql$MOD(x, 2L)`). The base translation `%%` = `sql_infix("%")` is not overridden in the Oracle backend.

</details>

## 9. tidyverse/dbplyr: SQL Server: arrange() on a logical expression renders invalid ORDER BY (e.g. ORDER BY ([x] IS NULL))

*Related, already on the tracker:* Related but different: tidyverse/dbplyr#1839 'Inconsistent translation of filter conditions to SQL in SQL Server/ODBC' (closed, filter on join RHS), #318 'MSSQL regression in boolean/bit coercion' (closed). None about ORDER BY.

<details><summary>Draft body</summary>

```r
library(dbplyr)
lf <- lazy_frame(x = 1, con = dialect_mssql())
lf |> dplyr::arrange(is.na(x)) |> show_query()
#> ORDER BY ([x] IS NULL)          -> Msg 156 Incorrect syntax near the keyword 'IS'
lf |> dplyr::arrange(x > 1) |> show_query()
#> ORDER BY [x] > 1.0
```

Verified failing on SQL Server 2022 and 2025. `mssql_needs_bit()` casts to BIT when the context clause is SELECT or ORDER, but in `sql_build.lazy_select_query()` the main ORDER BY is translated with `translate_sql_(op$order_by, con = con)` (no `context = list(clause = "ORDER")`); ORDER context is only used for window order vars. Passing the ORDER context there should produce `CAST(CASE WHEN ... THEN 1 ELSE 0 END AS BIT)`. Workaround: `arrange(if_else(is.na(x), 1L, 0L))`.

</details>

## 10. tidyverse/dbplyr: Oracle: Date/POSIXct values spliced into a query are escaped as plain strings and fail with ORA-01861

*Related, already on the tracker:* tidyverse/dbplyr#1468 'Incorrect translation of dates with Oracle ODBC.' (closed, about as.Date literal), #1389 'Translation of as.Date in Oracle is not correct in version 2.4' (closed), #661 'Possible incorrect date literal translation for Oracle?' (closed, 2022), #526 'How filter on DateTime in Oracle' (closed). I could only see titles/state; could not read their bodies to confirm whether escaped values were discussed.

> Note for you: the workaround `as.Date(!!format(x))` works on Oracle, SQL Server and duckdb, but not on SQLite. There it renders `CAST('2024-01-02' AS DATE)`, which SQLite evaluates to the number 2024.

<details><summary>Draft body</summary>

```r
library(dbplyr)
cutoff <- as.Date("2024-01-02")
lazy_frame(dt = Sys.Date(), con = dialect_oracle()) |> dplyr::filter(dt <= !!cutoff) |> show_query()
#> WHERE ("dt" <= '2024-01-02')
```

The same happens without `!!` (global inlined) and for POSIXct (`'2024-01-02T00:00:00Z'`). On Oracle this relies on implicit conversion with the session NLS_DATE_FORMAT; with the default `DD-MON-RR` (Oracle 23.26 Free) it fails: `ORA-01861: literal does not match format string`. `as.Date("2024-01-02")` inside the query already renders `DATE '2024-01-02'` and works, so escaping Date values as `DATE 'yyyy-mm-dd'` (and POSIXct as `TIMESTAMP 'yyyy-mm-dd hh:mi:ss'`) would make spliced values safe too.

</details>

## 11. ropensci/targets: tar_option_set(imports = "dplyr") fails with 'igraph::is_dag(graph) is not TRUE' (mutually recursive package functions)

*Related, already on the tracker:* None found: the issue searches 'imports option' and 'is_dag cycle' in ropensci/targets returned nothing. The search index looked sparse, so treat this as not verified.

<details><summary>Draft body</summary>

targets 1.12.0 (also in dev 1.12.0.9001, R/utils_imports.R line 26). With

```r
library(targets)
tar_option_set(imports = "dplyr")
list(tar_target(out, dplyr::mutate(data.frame(var1 = 1:3), x = var1 * 2)))
```

`tar_make()` errors with `igraph::is_dag(graph) is not TRUE`. The cause is `graph_edges()`: `stopifnot(igraph::is_dag(graph))`. dplyr has mutually recursive internals (2 strongly connected groups: `expand_pick_call` <-> `expand_pick_quo` and `dplyr_order_legacy` <-> `dplyr_proxy_order_legacy`), so the import graph has cycles.

Suggestions: (a) a clear error naming the functions involved (as tar_igraph()/find_cycle() already do for targets), and/or (b) collapse strongly connected components of imports into one hashed node, since mutual recursion is legitimate in package code (and user code).

</details>

## 12. klmr/box: (comment for #199) box::use() at the top of a targets _targets.R fails under tar_make() because callr runs R with -f <tempfile>

*Related, already on the tracker:* klmr/box#199 'Callr module sourcing' (open, 2021-04-25; reporter used targets with callr_function = NULL). Seen only via issue search (title, state, body); comments not read.

> Note for you: this one is a **comment** on an existing open issue (klmr/box#199), not a new issue.

<details><summary>Draft body</summary>

Still reproducible with box 1.2.3, targets 1.12.0, callr 3.8.0, R 4.6.1 (Linux).

targets::tar_make() runs _targets.R in a callr::r() child. callr starts R as `R --slave --no-save --no-restore -f /tmp/RtmpXXXX/callr-scr-XXXX`, so `r_path()` (R/paths.r) takes the temp dir as the script dir. Module lookups then use that temp dir instead of the project:

```r
# project/_targets.R
library(targets)
box::use(mods/tfuns)   # project/mods/tfuns.R exists
list(tar_target(out, tfuns$add_x(data.frame(var1 = 1:3))))
```

```
Rscript -e 'targets::tar_make()'
#> unable to load module "mods/tfuns"; not found in ".../box/mod", "/tmp/RtmpgjW5LJ"
```

The same happens with `box::use(./mods/tfuns)`, and with box::use() inside a function that runs in the callr process. Works: `tar_make(callr_function = NULL)`, `options(box.path = getwd())`, or `box::set_script_path()`.

Possible fix: in `r_path()`, ignore `-f` files that are callr temp scripts (basename matches `^callr-scr-` under tempdir()) and fall through to `wd_path()`. That is the behaviour box already has for crew/mirai workers started with `Rscript -e`.

</details>


---
[← back to README](../README.md) · [plain-language explanations](upstream-issues.md)
