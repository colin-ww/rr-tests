# NSE: column or R variable, which one wins?

Script: `01-nse.R` → `results/01-nse.csv`. Every case runs three times: **in-memory** (dplyr on a tibble), and **database** (dbplyr lazy table) on duckdb and on SQLite. Words used here are defined in the [README](../README.md#words-used-in-these-docs).

Corrected after the issue #3 audit: the strict option, the tidyselect warning, unknown-function wording, and the exact limits of the silent-wrong-result case.

## The rule

- **For a bare name, a column always beats an R variable with the same name.** The R variable can be in your session (global) or in a function. This is the same in-memory and in a database.
- **One exception, database only:** inside a call that dbplyr runs in R (`lst$f(var1)`, `mod$fn(var1)`, `(\(z) z * 2)(var1)`), **the R variable wins** and you get no warning. See [Silent wrong result](#silent-wrong-result) below.
- If no column has the name, the R variable's value is used. On a database it is pasted into the SQL as a constant (`SELECT *, 5.0 AS x`).

| what you write | in-memory | database (duckdb / SQLite) |
|---|---|---|
| `mutate(x = var1)`, `var1` is a column **and** an R variable | column (1, 2, 3) | column (1, 2, 3) |
| only an R variable has the name | its value (5) | its value, pasted into the SQL as `5.0` |
| neither exists | error when you call `mutate()`: `object 'nothing_here' not found` | same moment, dbplyr wording: ``Object `nothing_here` not found.`` |
| `.env$var1` or `!!var1` | the R variable (100) | the R variable (100) |
| `.data$var1` | the column | the column |
| `.data$missing` | error at `mutate()` | **no error until `collect()`**, then the database's own "column not found" error |
| function argument named like a column: `\(d, var1) mutate(d, x = var1)` | **column wins, argument ignored** | same |
| function-local variable, no column with that name | works | works |
| `filter(var1 == var1)` | always TRUE: keeps every row where `var1` is not missing (NA rows dropped), no warning | same (NULL rows dropped) |
| column name stored in a string `colname <- "var1"` | `.data[[colname]]` or `!!sym(colname)` work; bare `colname` is just the text `"var1"` | same |

The classic footgun is the function-argument row. Fix it with `{{ arg }}`, `.env$arg`, or by not naming arguments like columns. The opt-in helper `mutate_chk()` in `R/check_ambiguity.R` warns about exactly this ([06-escape-hatches.md](06-escape-hatches.md#7-opt-in-helper-check_ambiguity-and-the-checked-verbs)).

## Where database and in-memory differ

- **An R vector longer than 1 used as a value**
  - In-memory: a data frame accepts length 1 or length = number of rows. Anything else is an error.
  - Database: dbplyr pastes a SQL tuple `(10.0, 20.0, 30.0)`. duckdb quietly returns a struct column (each row gets all the values). SQLite errors (`row value misused`). SQL Server and Oracle reject it too ([05-sql-server-oracle.md](05-sql-server-oracle.md)).
  - For "is in this list" use `%in%`, which is translated correctly.
- **`filter(var1 == na_var)`** becomes SQL `= NULL`, which returns **0 rows, with no warning**. In-memory gives 0 rows too, for the same NA logic. Use `is.na()`.
- **`mutate(x = null_var)`** (an R `NULL`) is silently a no-op on both.
- **`Sys.Date()` inside `filter()`**: works in-memory. On a database dbplyr passes `Sys.Date()` to SQL as-is, and it **fails at `collect()`**. Use `today()` (translated) or compute outside: `!!Sys.Date()` (on Oracle also see the date notes in [05-sql-server-oracle.md](05-sql-server-oracle.md)).
- **`select(chr_var)`** (a character vector of names, without `all_of()`): gives tidyselect's deprecation warning **in-memory and on databases**. The warning shows **once per R session**, so whichever case runs first gets it. (The old README said "no warning on dbplyr". That was wrong: the in-memory case had used up the once-per-session warning.) Always write `all_of()` / `any_of()`.
- **`select(any_of("nope"))`**: in-memory returns a 0-column tibble. Database errors when the SQL is made: "Query contains no columns".
- **SQLite has no date type.** `copy_to()` stores a `Date` as a number (`19723`), so `year(dt)` gives `-4659`. Even `!!Sys.Date()` filters give the right answer only by luck: SQLite treats every number as smaller than every text. `dt > !!as.Date("2000-01-01")` returns 0 rows on SQLite and 3 on duckdb. RSQLite's `extended_types = TRUE` only fixes what `collect()` returns, not filters. **Don't test date logic on SQLite.**

## Unknown functions on a database

- **A bare function name that dbplyr doesn't know is sent to SQL unchanged** (`foo(var1)` → `foo(var1)`, same case). So the error appears at `collect()`, with the database's message. This is why `Sys.Date()`, `myfun(col)` and `rev(col)` fail only at `collect()`. It is a documented feature (*"Any function that dbplyr doesn't know how to convert is left as is"*, `vignette("translation-function")`). It lets you call database functions that dbplyr doesn't know, such as Oracle's `NVL()` or `DECODE()`.
- **`pkg::fn()` is different.** If dbplyr has a translation, it is used (`stringr::str_to_upper`, `lubridate::year`). If not, it **errors when the SQL is made**, before anything is sent: `base::rev(var1)` gives "No known SQL translation"; `stringr::str_squish(name)` on SQLite gives "`str_squish()` is not available in this SQL variant". (Since dbplyr 2.5.0, tidyverse/dbplyr#1426.)
- **To call a database function on purpose:** `.sql$abs(var1)` (new in 2.6.0) or `sql("ABS(var1)")`. Both work on duckdb and SQLite. Catch: `.sql$substr()` and friends still get R's translation ([upstream-issues.md](upstream-issues.md#2-dbplyr-sqlfn-is-not-always-the-sql-function-file-it-new)).
- **There IS a strict mode:** `options(dplyr.strict_sql = TRUE)`. Note the name starts with `dplyr.`, not `dbplyr.` (the old README missed it for that reason). With it on, unknown functions error when the SQL is made: ``Don't know how to translate `foo()` ``. It does **not** catch the silent wrong result below, and it also blocks `.sql$fn()` for functions dbplyr doesn't know. Details: [06-escape-hatches.md](06-escape-hatches.md#1-is-there-a-strict-option-yes-one-dplyrstrict_sql).
- Also available: `local(x)` (run in R) and `remote(x)` (keep for SQL) are documented in `?dbplyr::partial_eval`. But `local()` means the **opposite** in-memory ([06-escape-hatches.md](06-escape-hatches.md#3-escape-hatches-what-each-one-really-does)).

## Silent wrong result

Before writing SQL, dbplyr walks your code and decides, piece by piece, "this runs in R" or "this becomes SQL" (`partial_eval()`). A call whose function part is **not a plain name** runs in R as a whole, and the data is never consulted. So a column name inside it means the R variable:

```r
var1 <- 100; lst <- list(f = \(x) x * 2); d <- memdb_frame(var1 = 1:3)
d |> mutate(x = lst$f(var1)) |> show_query()
#> SELECT *, 200.0 AS `x`        <- R variable var1 (100) * 2, not the column
d |> mutate(x = lst$f(var1)) |> collect()   # x = 200, 200, 200   (in-memory gives 2, 4, 6)
rm(var1)                                     # now it errors at mutate(): object 'var1' not found
```

- **Which calls:** `lst$f(col)`, `mod$fn(col)` (box modules!), `obj$method(col)`, `(\(z) z * 2)(col)`, `(!!f)(col)`.
- **Not affected:** `pkg::fn(col)` (translated or error), `.sql$fn(col)` (sent as SQL), `.data$fn()` / `.env$fn()` (error: "Use local() or remote() to force evaluation of functions").
- **It is silent only when an R variable with the column's name is visible**: global, function-local, or a box module-level object. Otherwise you get `object not found`, which is confusing but loud.
- `options(dplyr.strict_sql = TRUE)` does not catch it.
- A comment in the examples of `?dbplyr::partial_eval` says "Functions are always assumed to be remote", which this contradicts. The real rule is only in a code comment (`R/tidyeval.R:225`).
- Same on dbplyr's dev version (GitHub main, 2026-10-16). No upstream issue found. Explained simply and drafted for filing in [upstream-issues.md](upstream-issues.md#1-dbplyr-modfncol-silently-uses-an-r-object-instead-of-the-column-file-it).
- **How to apply your own R function to a database column:** you can't directly. Write translatable code, write a helper that **returns code** and splice it with `!!`, write a verb wrapper with `{{ }}`, or `collect()` first. Worked examples: [06-escape-hatches.md](06-escape-hatches.md#5-applying-a-local-r-function-to-a-database-column).

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
