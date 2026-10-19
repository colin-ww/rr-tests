# Mistake-avoidance cheat sheet

Plain rules. Each rule links to the doc with the evidence (mostly script runs in this folder; a few come from reading docs or source, as marked). Safe to paste into an LLM prompt.

Checked with: R 4.6.1, dplyr 1.2.1, dbplyr 2.6.0, box 1.2.3, callr 3.8.0, crew 1.3.3, mirai 2.7.3, targets 1.12.0. "In-memory" = dplyr on a data frame. "Database" = a dbplyr lazy table from `tbl(con, ...)`.

## Column vs R variable (data masking)

- A bare name in `mutate()`, `filter()` and friends means the **column** if one exists, and an R variable only if not. In-memory and database alike. ([01](docs/01-nse.md#the-rule))
- Never name a function argument like a column: the column wins and the argument is ignored. To forward a column name, use `{{ arg }}`. To mean the variable, write `.env$x` or `!!x`. To mean the column, write `.data$x` or `.data[[chr]]`. ([01](docs/01-nse.md#the-rule))
- For a character vector of column names, always use `all_of()` / `any_of()`. ([01](docs/01-nse.md#where-database-and-in-memory-differ))
- `filter(x == var)` with `var` = `NA` returns 0 rows, silently. Use `is.na()`. ([01](docs/01-nse.md#where-database-and-in-memory-differ))
- Opt-in safety net: `mutate_chk()` / `filter_chk()` from `R/check_ambiguity.R` warn when a name is both a column and a variable. Useful while converting SAS code. ([06](docs/06-escape-hatches.md#7-opt-in-helper-check_ambiguity-and-the-checked-verbs))

## dbplyr (database tables)

- dbplyr sends unknown **bare** function names to SQL unchanged. The error appears at `collect()`, with the database's message. While developing, check `show_query()`. ([01](docs/01-nse.md#unknown-functions-on-a-database))
- Turn that into an early error with `options(dplyr.strict_sql = TRUE)`. The name starts with `dplyr.`, not `dbplyr.`. With it on, wrap real database functions in `sql("...")`, because `.sql$fn()` is blocked too for functions dbplyr doesn't know. ([06](docs/06-escape-hatches.md#1-is-there-a-strict-option-yes-one-dplyrstrict_sql))
- `pkg::fn(col)` is translated, or errors early if dbplyr has no translation. Bare imported `fn(col)` is translated by name. **Aliased** imports (`nch = str_length`) are not translated. ([01](docs/01-nse.md#unknown-functions-on-a-database), [02](docs/02-box.md#results))
- **Never call `mod$fn(col)`, `lst$f(col)` or `(\(x) ...)(col)` on a column inside a dbplyr verb.** dbplyr runs these in R. If an R variable has the column's name, it silently uses that variable: wrong numbers, no warning. (If not, you get an `object not found` error.) Strict mode doesn't catch it. ([01](docs/01-nse.md#silent-wrong-result))
- To apply your own logic to a database column: write translatable code; or write a helper that **returns code** (`rlang::expr(...)`) and splice it with `!!`; or write a verb wrapper with `{{ }}`; or `collect()` first. ([06](docs/06-escape-hatches.md#5-applying-a-local-r-function-to-a-database-column))
- `local(x)` means **opposite** things: the column in-memory, the R variable on a database. Use `.env$x` or `!!x` instead. `.local` does not exist. `remote(x)` is dbplyr-only; prefer `.data$x`. ([06](docs/06-escape-hatches.md#3-escape-hatches-what-each-one-really-does))
- `.sql$fn()` still applies R's translation when `fn` is a name dbplyr knows (`.sql$substr(x, 2, 3)` gives `SUBSTR(x, 2, 2)`). Use UPPER case (`.sql$SUBSTR(x, 2L, 3L)`, with integer literals) or `sql("...")`. ([upstream 2](docs/upstream-issues.md#2-dbplyr-sqlfn-is-not-always-the-sql-function-file-it-new))
- `sql("...")` text is not checked or quoted. Its arguments run in R, so never paste a name there that is both a column and a variable. In a grouped `mutate()`, it gets no `OVER (PARTITION BY ...)`. ([06](docs/06-escape-hatches.md#3-escape-hatches-what-each-one-really-does))
- Build SQL strings with `!!sql_glue2(con, "{.id col} = {value}")`, not `paste()` with values. ([06](docs/06-escape-hatches.md#3-escape-hatches-what-each-one-really-does))
- Don't put `Sys.Date()`, R-only functions, or R vectors longer than 1 (except with `%in%`) inside dbplyr queries. Use `today()`, or compute the date outside the query (on Oracle, see the date rule below). Use `%in%` for lists of values. ([01](docs/01-nse.md#where-database-and-in-memory-differ))
- Build `%in%` lists **outside** the query (`ids <- c(...)`): dbplyr can silently mis-handle vectors built inline (tidyverse/dbplyr#1870). ([upstream 1](docs/upstream-issues.md#1-dbplyr-modfncol-silently-uses-an-r-object-instead-of-the-column-file-it))
- SQLite is a poor stand-in for testing date logic (no date type). Test on duckdb or, better, on the real dialect. ([01](docs/01-nse.md#where-database-and-in-memory-differ))

## box

- box modules never see your global variables, and not even `stats`/`utils`. Import what you use: `box::use(stats[median])`, or `box::use(r/core[...])`. ([02](docs/02-box.md#what-a-box-module-can-see))
- Never import base (`box::use(base[...])`): box 1.1.3+ errors, and base is always visible anyway. For an alias write `nch <- base::nchar`. ([07](docs/07-box-base.md))
- tidyverse soft-deprecation warnings never show for code inside box modules, even with `lifecycle_verbosity = "warning"`. In tests, set `options(lifecycle_verbosity = "error")` to see them. ([02](docs/02-box.md#takeaways))

## callr, crew, targets

- callr children and crew workers are new R processes: no globals, no attached packages, no `options()` (so no `box.path`). Environment variables, the project `.Rprofile` and the working directory do carry over. callr also passes your `.libPaths()`; crew workers get only the library paths R sets at startup. ([03](docs/03-callr-crew.md#what-a-new-r-process-gets))
- Pass data in (`args =`, `data =`). Pass **connection details**, not connections, and open the connection inside the task. ([03](docs/03-callr-crew.md#what-a-new-r-process-gets))
- callr drops the function's environment unless `package = TRUE`: variables from an enclosing function and a module's imports are lost. ([03](docs/03-callr-crew.md#why-the-callr-surprises-happen))
- Tell box where modules are with `Sys.setenv(R_BOX_PATH = ...)` (inherited by child processes), not only `options(box.path = ...)` (not inherited). **If `R_BOX_PATH` is set, box ignores `options(box.path)`**, so list every module folder in it. ([03](docs/03-callr-crew.md#why-the-callr-surprises-happen))
- crew workers are reused: packages attached and options set by one task stay for later tasks on the same worker (`reset_packages`, `reset_options` default `FALSE`). Even with `reset_options = TRUE`, a brand-new option such as `box.path` stays. ([03](docs/03-callr-crew.md#crew-state-between-tasks))
- targets + crew: `box::use(pkg[fn])` at the top of `_targets.R` reaches only the main process, **not** crew workers. `library(pkg)` above the target list does reach workers (targets records `.packages()`). ([04](docs/04-targets.md#short-answer))
- Recommended targets pattern: put functions in box modules, `box::use(mods/clean)` at the top of `_targets.R` (the module **object** is sent to workers), and call `clean$fn(data)` in commands. Also put `options(box.path = getwd())` at the top, because `tar_make()` runs `_targets.R` through callr and box can't find `mods/` otherwise. If `R_BOX_PATH` is set on your machine, add the project folder there instead. ([04](docs/04-targets.md#what-to-do-ranked-each-tested-above))
- `box::use()` inside each function also works everywhere. For modules, the main process still needs the module path, and you should add a `format = "file"` target for each module so targets notices edits. ([04](docs/04-targets.md#what-to-do-ranked-each-tested-above))
- `tar_option_set(packages =)` loads packages on workers. It does nothing for box modules. `tar_option_set(imports =)` is not about loading, and breaks with dplyr. ([04](docs/04-targets.md#what-to-do-ranked-each-tested-above))
- A module object is tracked as one block: editing any function in it re-runs every target that uses the module. ([04](docs/04-targets.md))

## SQL Server and Oracle (rendered and run on real engines unless marked; [05](docs/05-sql-server-oracle.md))

- For SQL Server, look at `show_query()` or `remote_query()`, never `sql_render()`.
- Simulate with `lazy_frame(..., con = dialect_mssql("16.0"))` or `dialect_oracle()`. Use your real column names (usually UPPERCASE on Oracle). Use `simulate_mssql()` if the query has `union()`, `union_all()` or `bind_queries()` (`dialect_mssql()` hangs on those).
- Dates in filters: use `as.Date(!!format(my_date))`, not `!!my_date` (Oracle fails with ORA-01861). Use `today()`, not `Sys.Date()`.
- To add days, use `clock::add_days(dt, n)`.
- Days between dates: `difftime()` on SQL Server, `dt - as.Date(...)` on Oracle. dbplyr's Oracle `difftime()` has the sign flipped.
- To truncate, use `as.integer(floor(x))`, not `as.integer(x)`: SQL Server and Oracle round.
- `round()` rounds half away from zero on SQL Server and Oracle (like SAS `ROUND`). R rounds half to even.
- On Oracle, `''` is NULL. Never write `filter(x != "")`, because it drops every row. Use `!is.na(x)`.
- On SQL Server, `nchar()` ignores trailing spaces.
- NULL in string joining behaves differently on every database. Apply `coalesce(x, "")` first.
- Regex: `fixed()` patterns work on SQL Server and Oracle. Real regex needs SQL Server 2025 with database compatibility level 170, or `.sql$REGEXP_LIKE()` on Oracle. Don't trust local duckdb tests of `fixed()` patterns: duckdb treats them as regex.
- Oracle modulo: use `.sql$MOD(x, 2L)`, not `%%`.
- TRUE/FALSE: on SQL Server, `mutate(x = a > b)` turns NA into FALSE. Oracle 19c has no boolean, so use `if_else(cond, 1L, 0L)` and `filter(flag == 1)` (19c rule from the docs, not run).
- Sorting: NULLs come first with `desc()` on Oracle and with ascending order on SQL Server. Force the order with `arrange(if_else(is.na(x), 1L, 0L), x)`. Don't use `arrange(is.na(x))`; it breaks on SQL Server.
- Always give an order to `row_number()`, `lag()` and `cumsum()`: `.order =` or `window_order()`.
- `median()` in `summarise()` doesn't work on SQL Server. Use `mutate(.by =)` + `distinct()`.
- Use `head()`, not `slice_head()`.
- Use `na.rm = TRUE` in `sum()`, `mean()` and `n_distinct()`. Without it you get a warning that shows only once every 8 hours.

## Testing and debugging

- Many tidyverse warnings show once per session (or once every 8 hours). While developing, set `options(lifecycle_verbosity = "warning", rlib_warning_verbosity = "verbose")`. ([06](docs/06-escape-hatches.md#2-options-that-matter-for-this-topic))
- Test each "does it warn?" question in a fresh R process (`callr::r()`), or the first case uses up the warning. ([upstream 7](docs/upstream-issues.md#7-tidyselect-doesnt-warn-on-lazy-tables-my-test-was-wrong-drop-it))
- `last_sql()` shows the last SQL dbplyr produced, which is handy right after a `collect()` error. ([05](docs/05-sql-server-oracle.md#which-show-me-the-sql-function-to-use))
- `sql_options(cte = TRUE)` makes long SQL readable (one named block per step). It changes only the SQL text, not the results. ([05](docs/05-sql-server-oracle.md#sql_options-three-ways-to-write-the-same-query))
