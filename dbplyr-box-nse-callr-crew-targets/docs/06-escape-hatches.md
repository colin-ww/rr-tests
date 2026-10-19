# dbplyr options, escape hatches, and "warn me when a name is ambiguous"

Files: `06-escape-hatches.R` writes `results/06-escape-hatches.csv` (241 rows, about 16 s). The helper is in `R/check_ambiguity.R`. Tests are in `tests/testthat/test-escape-hatches.R` (11 tests, 50 checks, about 5 s).
Run it with `Rscript 06-escape-hatches.R`, then `testthat::test_file("tests/testthat/test-escape-hatches.R")`.

## 1. Is there a strict option? Yes, one: `dplyr.strict_sql`

**This corrects the first version of this README (PR #2).** dbplyr 2.6.0 has one strictness switch. Its name starts with `dplyr.`, not `dbplyr.`. That is why a search for `dbplyr.*` options missed it.

```r
options(dplyr.strict_sql = TRUE)
```

What it does (run on duckdb and SQLite; only rendered for Oracle and SQL Server, not run on a real server):
- An unknown function now fails when the SQL is built (`show_query()`, `collect()`), not when the verb runs. The message is ``Don't know how to translate `foo()` ``. Without the option, the name goes to the database as-is and fails there (or works by luck).
- It catches `foo(var1)`, a global R function `f(var1)`, `Sys.Date()`, `nvl()`, `TO_CHAR()`, `datediff()` and `%like%`.
- **It also blocks `.sql$instr(name, "a")`.** `.sql$` only removes the prefix, so the strict check still sees an unknown `instr()`. `.sql$abs()` still works, because dbplyr knows `abs`. In strict mode, write unknown database functions as `sql("instr(name, 'a')")`.
- **It does not catch the silent wrong result ([01-nse.md](01-nse.md#silent-wrong-result)).** `mutate(x = lst$f(var1))` still gives 200. That call runs in R before translation starts.
- The cost for Oracle and SQL Server users: anything you used to pass through (`NVL()`, `TO_CHAR()`, `DATEDIFF()`, `%like%`) must now go inside `sql("...")`.
- Two limits of `sql("...")`:
  - dbplyr does not touch the text, so column names are not quoted for you.
  - In a grouped `mutate()` it gets no `OVER (PARTITION BY ...)` (the SQL that makes a value per group). Neither do `.sql$fn()` or unknown functions (tidyverse/dbplyr#1526, open). `sum()` does get one.
- It does nothing in-memory (plain data frames).
- Source: `dbplyr/R/translate-sql.R:149`. It is documented only in the "Function translation" vignette (`vignettes/translation-function.Rmd:311-319`), not in any help page.

## 2. Options that matter for this topic

The script scans every function in the installed namespaces (`opt_inventory()`, rows with `part = "options"` in the CSV). That scan misses options that are read through helper functions (several rlang ones), so the table below comes from reading the CRAN source tarballs. Line numbers are from dbplyr 2.6.0, dplyr 1.2.1, rlang 1.3.0, lifecycle 1.0.5, duckdb 1.5.6 and odbc 1.7.2. odbc is not installed here, so I only read its source.

| option | where it is read | default | effect | matters here? |
|---|---|---|---|---|
| `dplyr.strict_sql` | dbplyr `R/translate-sql.R:149` | `FALSE` | error on untranslatable functions | **yes**, the only strict switch |
| `lifecycle_verbosity` | lifecycle `R/verbosity.R:51` | `"default"` | `"warning"` shows deprecation warnings every time; `"error"` turns them into errors | **yes**, use it in tests |
| `rlib_warning_verbosity` | rlang `R/cnd-signal.R:127` | `"default"` | `"verbose"` repeats "once every 8 hours" warnings, such as dbplyr's NA-removal warning (`R/translate-sql-aggregate.R:84`) | **yes** |
| `rlib_message_verbosity` | rlang `R/cnd-signal.R:195` | `"default"` | the same, for messages | minor |
| `rlang_backtrace_on_error` | rlang `R/cnd-abort.R:1505` | `"reminder"` when interactive, `"full"` in Rscript | how much backtrace an error prints | handy for debugging |
| `dplyr.summarise.inform` | dplyr `R/summarise.R:463`, dbplyr `R/verb-summarise.R:237` | message shown only when `summarise()` is called from a script or the console, not inside package functions | `FALSE` hides the "has grouped output" message | minor |
| `dplyr.legacy_locale` | dplyr `R/locale.R:75` | unset (C locale) | **deprecated in dplyr 1.2.0.** Use `arrange(.locale = "en")` instead. A database sorts with its own collation anyway | only to know it is going away |
| `lubridate.week.start` | dbplyr `R/backend-postgres.R:221` (also snowflake, db2), duckdb `backend-dbplyr__duckdb_connection.R:342` | 7 | week start for `wday()` in SQL | not for Oracle or SQL Server (their backends do not read it) |
| `dbplyr_highlight`, `dbplyr_use_colour` | dbplyr `R/utils-format.R:45,49` | blue / `FALSE` | colours in `show_query()` | no |
| `dbplyr_subquery_name`, `dbplyr_column_name` | dbplyr `R/utils.R:31,37` | 0 | internal counters for generated names | no |
| `dplyr.show_progress` | dplyr `R/progress.R:116`, dbplyr `R/progress.R:68` (only `do()`, which is deprecated) | `TRUE` | progress bar | no |
| `duckdb.debug`, `duckdb.allow_extensions`, `duckdb.temp_directory`, `duckdb.progress_display` | duckdb `dbConnect__duckdb_driver.R:77`, `extensions.R:121`, `storage-home.R:206`, `progress_display.R:41` | – | connection and engine behaviour | no (nothing to do with NSE) |
| `odbc.batch_rows`, `odbc.interruptible` | odbc `R/dbi-table.R:41`, `R/dbi-driver.R:184` | `NA`, `interactive()` | write batch size; Ctrl-C | speed only |

Also:
- tidyselect 1.2.1 and DBI 1.3.0 read no options at all. tidyselect's deprecation warnings go through `lifecycle_verbosity`.
- rlang has no option for a strict data mask. I grepped its source for every `"rlang_..."` / `"rlib_..."` name.
- `sql_options(cte, use_star, qualify_all_columns)` (dbplyr `R/db.R:151`) are **function arguments**, not global options. They change how SQL is written, not how strict dbplyr is.
- The NA-removal warning is never shown when `TESTTHAT=true` (`is_testing()`, `R/translate-sql-aggregate.R:75`). In a normal session it shows once every 8 hours: in the CSV, the first database warns and the second is silent. With `rlib_warning_verbosity = "verbose"`, both warn (`verbosity` rows).

## 3. Escape hatches: what each one really does

The global is `var1 <- 100`. The column `var1` is 1, 2, 3. Results are the same on duckdb and SQLite.

| code | in-memory | duckdb / SQLite | notes |
|---|---|---|---|
| `sql("var1 * 2")` | **a text column holding the SQL, silent** | 2, 4, 6 | raw SQL. Names are not quoted for you |
| `sql(paste(colname, "* 2"))` | text column | 2, 4, 6 | the arguments of `sql()` run in R |
| `sql(paste(var1, "* 2"))` | text "1 * 2", "2 * 2", ... (column) | **200 (object): SQL `100 * 2`** | same code, opposite meaning, like `local()` |
| `.sql$instr(name, "a")` | error | 1, 4, 2 | names a database function on purpose. Gives the same SQL as a bare `instr()`. Blocked by strict mode |
| `local(var1)` | **1, 2, 3 (column)** | **100 (object)** | **Same code, opposite meaning.** `base::local()` can see the data; dbplyr's `local()` means "run in R" |
| `remote(var1) * 2` | error: `could not find function "remote"` | 2, 4, 6 | a dbplyr-only keyword, not an exported function. It does not check that the column exists |
| `.local$var1` | error | error | **`.local` does not exist** in rlang, dplyr, dbplyr or tidyselect |
| `.env$var1`, `!!var1` | 100 | 100 | the object, on both. Safe |
| `.data$var1`, `.data[[colname]]` | 1, 2, 3 | 1, 2, 3 | the column, on both. Safe |
| `.data$f(var1)` | error | error: `Use local() or remote() to force evaluation of functions` | |
| `I(var1)` | 1, 2, 3 | execute error: `no such function: I` | `I()` is for table names (`tbl(con, I("schema.tab"))`), not for expressions |
| `!!sql_glue2(remote_con(d), "{.id colname} * {k}")` | error (a data frame has no connection) | 2, 4, 6, SQL `` `var1` * 2.0 `` | safe way to build SQL. `{.id x}` quotes a name; `{x}` escapes a value (`'alpha'' OR ''1''=''1'`). `con` can also be a dialect, e.g. `dialect_oracle()`. Its help page says it is meant for people who extend dbplyr, but it works here |
| `sql_glue2(...)` without `!!` | error | render error: ``Cannot translate a <tbl_...> object`` | always splice it with `!!` |
| `sql_glue("...")` (run on its own) | error everywhere | | it needs the connection that is only set while dbplyr translates (for backend authors) |

## 4. How dbplyr decides: run in R or send to SQL (`partial_eval`)

Before dbplyr writes any SQL, it walks your code (`partial_eval()`, `dbplyr/R/tidyeval.R:59`; the same in the dev version). The rules are documented in `?dbplyr::partial_eval`. In plain words:
- **A bare name** (`var1`). If it is a column, it stays a column. If not, and an R object with that name can be seen (function locals, then globals, then attached packages, so even `pi`), its value is pasted in as a constant. Otherwise you get `Object not found`. (lines 178-196)
- **`.data$x` / `.data[[v]]`** become the column. **`.env$x`** becomes the R value. (239-250)
- **`.sql$f(...)`** becomes the SQL function `f`, and its arguments follow these same rules. (232-233)
- **`local(expr)`** runs `expr` in R. **`remote(x)`** keeps `x` for SQL as-is. **`sql(...)`** runs its arguments in R and pastes in the resulting text. So a name inside `local()` or `sql()` means the R object, not the column. (257-262)
- **A call with a plain name, `f(...)`**, is kept for translation, and its arguments follow these same rules. If dbplyr does not know `f`, it is sent to SQL as-is, unless `dplyr.strict_sql` is on. (277)
- **A call whose function part is not a plain name** (`lst$f(...)`, `mod$f(...)`, `(\(x) x * 2)(...)`, `(!!f)(...)`) **runs in R right away, as a whole.** The data is never consulted, so `var1` inside it means the R object, not the column. (225-236, and 215-220 for an injected function object.) There are three exceptions:
  - `pkg::f()` is translated by name.
  - `.sql$f()` is translated by name.
  - An injected function that is identical to one dbplyr knows (e.g. `(!!mean)(x)`) is translated too.

In-memory dplyr evaluates everything inside the data, so the same code can give different answers in-memory and on a database.

History: tidyverse/dbplyr#200 (see section 6 below) stopped local evaluation of subsetting (`x$y`, `x[[i]]`) in dbplyr 1.4.0 (NEWS.md). A call whose head is `x$y`, such as `lst$f(var1)`, is still run locally.

## 5. Applying a local R function to a database column

None of the "wrappers" fixes the silent wrong result. Results:

| code | in-memory | duckdb / SQLite |
|---|---|---|
| `lst$f(var1)` | 2, 4, 6 | **200, 200, 200, silent** |
| `local(lst$f(var1))` | 2, 4, 6 | **200, silent** |
| `(!!lst$f)(var1)` | 2, 4, 6 | **200, silent** |
| `(\(x) x * 2)(var1)` | 2, 4, 6 | **200, silent** |
| `!!lst$f(var1)` | 200 | 200 (the same everywhere: you asked for the object) |
| `lst$f(.data$var1)` | 2, 4, 6 | build error: ``Can't subset `.data` outside of a data mask context`` (loud, which is good) |
| `lst$f(remote(var1))` | error | error: `could not find function "remote"` |
| `f <- lst$f; f(var1)` | 2, 4, 6 | execute error: `no such function: f` (with strict mode: render error) |

The correct ways, in order of preference. All give 2, 4, 6 in-memory, on duckdb and on SQLite:
1. **Write it as code dbplyr can translate:** `mutate(x = var1 * 2)`.
2. **Make the helper return code, not a value, then splice it with `!!`.** This also works as a box module function. I checked `!!mod$double_expr(var1)` with a real module: 2, 4, 6, SQL `` `var1` * 2.0 ``.
   ```r
   double_expr <- function(x) rlang::expr(!!rlang::enexpr(x) * 2)
   d |> mutate(x = !!double_expr(var1))     # SQL: var1 * 2.0
   ```
3. **Write a verb wrapper with `{{ }}`:** `double_col <- function(d, col) mutate(d, x = {{ col }} * 2)`.
4. **Write SQL:** `sql("var1 * 2")`, or `.sql$fn(var1)` for a database function. Only put literal text in `sql()`. Do not paste column names that are also R objects (see section 3 above).
5. **`collect()` first**, then use any R function. The data comes into R memory.

## 6. Does anything warn when a name is both a column and an object?

**No existing tool does this.**

| tool | warns? | what I saw |
|---|---|---|
| dplyr 1.2.1 / dbplyr 2.6.0 | no | `mutate(x = var1)` and `filter(var1 == var1)` give no warning, even with `lifecycle_verbosity = "warning"` and `rlib_warning_verbosity = "verbose"` |
| rlang 1.3.0 | no | it has no option for this (source grep) |
| lintr 3.4.0 `object_usage_linter` | no, and backwards | In a clean session it flags the **correct** code (`g <- function(d) mutate(d, x = var1)`: "no visible binding for global variable 'var1'"). It says nothing about the ambiguous `f` (a local `var1` plus the column). If a global `var1` exists, it reports nothing about `var1` at all. Its only rlang support is understanding `.env$x` (`R/object_usage_linter.R:11`). No lintr linter knows about data masking |
| `codetools::checkUsage` | no | same as lintr (lintr uses it) |
| `dplyr.strict_sql` | no | it is about function names, not variable names |

Upstream discussion I found. I could only read titles and states, plus a few opening posts; I did not see maintainers' replies.
- tidyverse/dplyr#2949 "error/warning/message on variable from environment / column ambiguity in filter" (closed, 2017). This is the same request. No such warning exists in dplyr 1.2.1.
- tidyverse/dplyr#6885 "Unexpected behavior in `filter()` when column name matches an environment variable" (closed, 2023). The reporter asked for a warning on `filter(cyl == cyl)`.
- tidyverse/dplyr#2591 ".data and .env need strict matching semantics" (closed, 2017). tidyverse/dplyr#3814 "Stronger `.data` pronoun" (closed, 2018).
- tidyverse/dbplyr#200 "Reconsider local evaluation" (closed, 2019). It proposed ending local evaluation of `pkg::bar()` and `x$y`, and deprecating `local()`, which it called "basically equivalent to `!!`". In-memory they are not equivalent (see the `local(var1)` row in section 3).
- tidyverse/dbplyr#1426 "Make namespaced functions error if no translation?" (closed).
- tidyverse/dbplyr#1526 "sql escape for 'non-translated' function in window context" (open): `sql()` gets no `OVER` clause in a grouped `mutate()`.
- I found no issue about any of these: a column/object clash warning in dbplyr, the `lst$f(col)` silent result, `.sql$` being blocked in strict mode, a lintr linter that understands data masking, or a strict data mask in rlang.

## 7. Opt-in helper: `check_ambiguity()` and the checked verbs

```r
source("R/check_ambiguity.R")          # or copy the ~50 lines into a box module (all calls are pkg::)
var1 <- 100
d |> check_ambiguity(x = var1)         # warns, then returns d unchanged
d |> mutate_chk(x = lst$f(var1))       # warns; on a database table it adds the "runs in R" note
d |> mutate_chk(x = .data$var1 * 2)    # quiet
d |> filter_chk(.data$var1 > !!var1)   # quiet
check_ambiguity(d, x = var1, .error = TRUE)   # error instead of a warning
```

The warning on a database table looks like this:

```
`var1` is both a column and an object in the calling environment.
i The column wins in dplyr. Say which one you mean: `.data$var1` (column) or `.env$var1` (object).
! dbplyr runs `lst$f(...)`-style calls, `local()` and `sql()` arguments in R, so here `var1` is the OBJECT, not the column (silent wrong result).
```

What it flags:
- A name that is a column, or a column made earlier in the same call (`mutate(y = 1, z = y)`), **and** is also a non-function object visible from where the code was written. That covers function arguments, function locals, box module objects, globals, and objects from base R and attached packages, such as `pi`, `letters` or `precip`. A column called `pi` really does win over `base::pi`.
- Inside `{{ }}`, it checks the caller's environment, which is where the user typed the name.
- On a database table, it adds the "OBJECT" note when the name is inside `lst$f()`-style calls, `local()` or `sql()`.

What it ignores:
- `.data$` / `.env$` / `.data[[ ]]` and `remote()`
- `!!value`
- function names in call position, and `pkg::fn`
- field names after `$`
- lambda arguments
- tidyselect arguments (`across(.cols)`, `pick()`, `c_across()`, `.by`)

The class is `ambiguous_name`, so you can catch it. It uses `colnames()`, which for a lazy table comes from dbplyr's stored column list (`op_vars()`, `R/tbl-lazy.R:32`), not from a query.

False positives:
- A common name used both as a column and as a variable (`year`, `id`, `n`) always warns, even when you meant the column. That is the point (write `.data$year`), but old scripts will be noisy.
- A column that happens to share a name with something from base R or an attached package (`letters`, a dataset name) warns too.
- `!!sym("var1")` warns, because after injection it looks like a bare name. Use `.data[["var1"]]` instead.
- `local(var1)` warns. That is correct: it means the column in-memory and the object on a database.

What it misses:
- It runs only on code that goes through `check_ambiguity()` or the `*_chk()` verbs. It is not a linter.
- It does not look at `select()`, `join_by()` or `arrange()` arguments unless you pass those expressions to `check_ambiguity()` yourself.
- An object that is a function is ignored, even when a column has the same name.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
