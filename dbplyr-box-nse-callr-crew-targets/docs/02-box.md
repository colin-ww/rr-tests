# box: scoping, imports, and dbplyr translation

Script: `02-box.R` + module `mods/helpers.R` → `results/02-box.csv`. Each case runs in-memory, on duckdb and on SQLite.

## What a box module can see

The lookup chain inside a module is:

1. the module itself (its own objects);
2. `imports:<module>`: what the module `box::use()`d;
3. a small box environment with `library`, `require` and `source` (they warn, then work);
4. `baseenv()`: base R;
5. nothing (the empty environment).

So a module **never** sees your global variables or the search path. Even `median()` (stats) and `head()` (utils) give `could not find function` inside a module unless you import them: `box::use(stats[median], utils[head])`, or `box::use(r/core[...])` (ships with box; it does not include `datasets`). That is stricter than `library()`, and that is good for reproducibility.

## Results

| situation | in-memory | database |
|---|---|---|
| module function uses a name that only exists as a **global** in your script | error: `object not found` (module can't see globals) | same |
| module-level object `var1 <- 999` **and** a column `var1` | column wins (1, 2, 3) | column wins |
| module-level object, no such column | module's value (42) | module's value |
| `.env$var1` inside a module function | the **module's** `var1` (999), not your global | same |
| `dplyr$summarise(d, x = dplyr$n())` | works | ❌ "Must only be used inside data-masking verbs". The `ns$fn` form is not translated. Use `box::use(dplyr[n])` + `n()`, or `dplyr::n()` |
| `lubridate$year(dt)` | works | ❌ build error. dbplyr runs `lubridate$year(dt)` in R, where `dt` is `stats::dt` (a function). If an R variable has the column's name, it is **silently** used instead (an R variable `dt <- as.Date("1999-05-05")` gives 1999 on every row, in-memory gives 2024). `lubridate::year(dt)` is translated ✅ |
| `helpers$double_it(col)` **inside** a dbplyr verb | works (2, 4, 6) | **silent wrong value** (200, 200, 200): the [silent-wrong-result](01-nse.md#silent-wrong-result) case |
| bare `double_it(col)` inside a module's dbplyr query | works | ❌ at `collect()`: `no such function: double_it` (sent to SQL) |
| aliased import `box::use(stringr[nch = str_length])`, then `nch(name)` | works | ❌ at `collect()`: `no such function: nch` |
| aliased **verb** `box::use(dplyr[mutate_alias = mutate])` | works | works (verbs dispatch on the table, not on the name) |
| `box::use(stringr[str_to_upper])`, then `str_to_upper(col)` | works | works (translated by name) |
| `box::use(dplyr[mutate])` inside a function | works | works |
| `box::use(base[nchar])` | ❌ box bug since box 1.1.3, not an R 4.6 change (box 1.1.2 works on the same R): ``no item called "getNamespaceInfo(mod_ns, "lazydata")" on the search list``. See [07-box-base.md](07-box-base.md) | same |

## Takeaways

- **dbplyr translates by call name, not by which function object it is.** So the *name* you import under matters more than *how* you import.
  - Keep translatable calls as bare names (`str_to_upper(x)`) or `pkg::fn(x)`.
  - Don't alias translatable functions (`nch = str_length`).
  - Never call `mod$fn(col)` on a column inside a dbplyr verb. Call module functions on the whole table instead (`helpers$add_x(d)`), as in the targets pattern ([04-targets.md](04-targets.md)).
- **Deprecation warnings hide inside box modules.** tidyverse "soft" deprecations (for example `select(chr_var)` without `all_of()`) only warn for code in the global environment, and box modules are not. They stay silent even with `options(lifecycle_verbosity = "warning")`. Only `options(lifecycle_verbosity = "error")` shows them, as errors. Useful in tests ([upstream-issues.md](upstream-issues.md#7-tidyselect-doesnt-warn-on-lazy-tables-my-test-was-wrong-drop-it)).
- For box in other processes (callr, crew, targets), see [03-callr-crew.md](03-callr-crew.md) and [04-targets.md](04-targets.md).

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
