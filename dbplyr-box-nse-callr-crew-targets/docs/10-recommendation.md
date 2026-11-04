# Ranked recommendation: loading your own code and package imports (targets + box + crew)

This doc pulls together [04](04-targets.md), [08](08-box-caching.md) and [09](09-imports-fresh-process.md), plus 4 new checks (`10-source-scoped-checks.R`, `tests/testthat/test-source-scoped.R`).

The questions, from the sc-nts-frame session:
- What's the ranked recommendation for loading your own code and for importing packages?
- Are real per-file imports worth it?
- `source_scoped()` or `box::use()` inside each function?
- What are `source_scoped()`'s downsides, and what goes where?

There are two separate questions, and they're easy to mix up:
- **Own code**: how your `R/` functions get into the pipeline. This mostly decides **caching**.
- **Packages**: how those functions find dplyr and co. This mostly decides **crew**, and whether per-file imports are real or only documentation.


## Short answer

- **Rank 1:** `envir` line + `source_scoped()` + `box::use()` at the top of each file.
- **Rank 2,** if per-file imports don't matter to you: `envir` line + `tar_source()`. It's one line on top of the usual setup.
- **Real per-file imports are worth it, but not urgent.** Switch in the same step as turning crew on, because both need the `envir` line.
- **Of the two "real" options, `source_scoped()` is the more reasonable:**
  - You keep one import block per file.
  - You don't need an import line in every function.
  - `box::use()` inside each function wins only where changing an import must re-run targets.
- **New catches: "real" isn't strict for names base R already has, or for anything attached in the session.**
  - Say a file forgets `dplyr[filter]`. It gets `stats::filter()` instead, with a confusing error (`object 'v' not found`), not `could not find function`. The same goes for `lag()`.
  - Anything `library()`d in `_targets.R`, `.Rprofile` or the test session is visible to every file.
- **With the `envir` line, your own functions aren't in the global env.** Top-level code in `_targets.R` (eg a startup check) can't call them by name. Use the environment that `source_scoped()` returns: `e <- source_scoped(files); e$check_env()`.
- **Switching between `tar_source()`, the `envir` line and `source_scoped()` re-runs nothing** (all 6 directions checked).


## Ranked: own code + packages together

| rank | `_targets.R` · `R/` files | caching | crew (reused or fresh process) | per-file imports | cost | tested in |
|---|---|---|---|---|---|---|
| **1** | `envir` line + `source_scoped()` · `box::use()` at the top of each file | right | works | **real**: a missing import fails, with or without crew, and in tests | a 10-line helper; every file declares all it uses | 08 `src_scoped`, 09 `scoped`/`scoped_src`, 10 |
| **2** | `envir` line + `tar_source()` · `box::use()` at the top of each file | right | works | pooled: documentation only | 1 line | 08 `src_envir`, 09 `envir` |
| **3** | `tar_source()` · `box::use()` inside each function | right; changing an import re-runs that function's targets | works | real, per function | 1 line per function, ~4 ms per call | 09 `in_function`, 08 `src_helper_fixed` |
| **4** | `tar_option_set(packages = ...)` or `library()` + `tar_source()` · no imports in files | right | works | none: files don't say what they use | none; the standard targets way | 09 `packages`/`library` |
| **5** | plain `tar_source()` · `box::use()` at the top (issue #3's setup) | right | **attached names fail** (`pkg[fn]`); aliases (`pkg$fn()`) work | pooled | none, while there's no crew | 08 `src_global`, 09 `global` |
| ✗ | box module objects: `box::use(R/clean)`, `clean$fn()` | **re-runs too much** (any touch, comment, branch switch or folder) | works | real | – | 08 `mod_object` |
| ✗ | attaching your own modules: `box::use(R/clean[fn])` | **never notices edits** | **fails** | – | – | 08 `mod_attach` |

Rules for every row:
- **With the `envir` line, define nothing that target commands use directly in `_targets.R`:** no constants, no helpers, no box aliases. crew workers don't get them, and targets doesn't track them ([08](08-box-caching.md#catches-of-the-envir-fix)).
  - In commands, call packages with `pkg::fn()` (eg `config::get()`, `dplyr::filter()`), or move the code into an `R/` function.
- **`pkg::fn()` works in every setup.** It's just verbose for dplyr verbs. dbplyr still translates `pkg::fn()`.
- **Package code and package versions are never tracked,** in any row. Updating dplyr re-runs nothing.


## Are real per-file imports worth it?

- **What you gain:**
  - A file sourced alone (tests, one-off checks) behaves the same as in the pipeline.
  - A forgotten import fails right away, instead of working because another file happened to import it.
  - The file header is an honest list of what the file uses, for people and for LLMs.
  - Moving a function to another file can't quietly lean on the old file's imports.
  - If two files import the same name from different packages, each file gets its own. With pooled imports, the file loaded last wins for everyone ([08](08-box-caching.md#catches-of-the-envir-fix)).
- **What it doesn't fix:**
  - Names that base R already has on the search path (`filter`, `lag`, `head`, …). See the catch above.
- **Verdict:** a cheap, real improvement, but no emergency.
  - The pooled setup (rank 2/5) isn't broken, just less honest.
  - Switch when you turn crew on, or as soon as tests start sourcing files one at a time.


## `source_scoped()` or `box::use()` inside each function?

Both make imports real. Prefer `source_scoped()` because:
- **It's what you already write:** one `box::use()` block at the top of each file, unchanged.
- **No line in every function:** forgetting that line is an error, and with dozens of functions it adds up to a lot of lines.
- **No ~4 ms per call:** irrelevant for most targets, but not inside loops.

`box::use()` inside each function wins when:
- **Changing an import must re-run targets.** The import line is part of the function's code, so its fingerprint changes. With `source_scoped()`, changing only the import block re-runs nothing ([08](08-box-caching.md#results), "imports changed").
- **A function must work wherever it's copied or sourced**, with no loader at all.


## How `source_scoped()` works

The code is [`R/source_scoped.R`](../R/source_scoped.R): about 10 lines, with `keep.source = TRUE` so tracebacks keep file and line numbers ([09](09-imports-fresh-process.md#short-answer)).

1. For each file, it makes a new environment, `file_env`, whose parent is the pipeline environment (`envir`).
2. It runs the file there (`sys.source()`). Because the file's `box::use()` is called from `file_env` and not from the global environment, box puts the imports in a **new parent of `file_env`**, so only this file's functions see them.
3. It copies the file's objects into `envir`. There, targets fingerprints each function by its code (as with `tar_source()`), and sends `envir` with its parents, imports included, to crew workers.
4. Each function keeps `file_env` as its home. When it looks up a name, R searches:

```
function body
 └ file_env               this file's own objects
    └ this file's imports  (box puts them here)
       └ envir             every file's functions + objects: what targets tracks and ships
          └ global env → search path (base, stats, utils, ...)   <- why a forgotten filter() finds stats::filter()
```


## What goes where

| where | what |
|---|---|
| `_targets.R` | `library(targets)` (and crew); `tar_option_set(envir = new.env(parent = globalenv()))` **before** loading; `source("R/source_scoped.R")`; `source_scoped(files)`; other `tar_option_set()`; the targets list. Commands call your functions by name and packages as `pkg::fn()`: with `source_scoped()`, the files' imports aren't visible to commands. Top-level code that calls your own functions (eg a startup check) needs `e <- source_scoped(files)`, then `e$fn()`. |
| each `R/` file | At the top, `box::use()` for **every** package it uses (`dplyr[...]`, `stringr`, …). Then functions and constants. Call other files' functions by name, without importing them. |
| `R/source_scoped.R` | The helper itself. It's harmless if it's also in the list of files to source. |
| imports of your **own** box modules from `R/` files | Not needed: other files' functions are already in `envir`. If you keep them (eg so a file still works when sourced alone), they load a second, separate copy. They also need `options(box.path = ...)` ([04](04-targets.md#second-trap-box-cannot-find-modules-from-_targetsr-even-without-crew)). |
| test helper | `source("R/source_scoped.R")`, then `source_scoped(<the files under test>)`. Outside a pipeline, `envir` defaults to the global env. A forgotten import then fails in tests too, unless the test session has that package attached (see downsides). |
| console debugging | `tar_load_globals()`, then `attach(tar_option_get("envir"), name = "pipeline")`. Without the `attach()`, your functions aren't visible in the session (checked in 10). |


## Downsides of `source_scoped()`

- **Not standard targets.** It's your own helper. `tar_source()` is what docs, colleagues and LLMs expect, so keep the helper's header comment.
- **Every file must import everything it uses.** That means more import lines (that's the point). A forgotten import shows up only when that function runs, not at load time. Tests catch it earlier.
- **Not strict for base R names.** A forgotten `dplyr[filter]` finds `stats::filter()`: `object 'v' not found` (checked in 10, plus a fast test). `lag()` works the same way. (`head()`/`tail()` are `utils` functions anyway, so forgetting those is harmless.)
- **Only as strict as the session's search path.** Anything attached is visible to every file: `library()` in `_targets.R` or `.Rprofile`, or in your console. In the fresh R that `tar_make()` starts, that's usually just targets (and crew). Found when the fast test passed alone but failed in the full suite, where another test file had run `library(dplyr)`. So run tests in a fresh R, with no `library(dplyr)` in the helpers.
- **No private helpers.** Every top-level object in a file is visible to the pipeline and to other files. There's no `#' @export`. If two files define the same name, the file loaded later silently wins, the same as with `tar_source()`.
- **Changing only the import block re-runs nothing**, the same as with `library()` or `tar_source()` ([08](08-box-caching.md#results)). If an import change changes results (eg which package's `filter()`), run `tar_invalidate()` on the affected targets.
- **The `envir` catches apply** (also to rank 2):
  - nothing used by commands may live directly in `_targets.R`;
  - top-level code in `_targets.R` can't call your functions by name (`object 'fa' not found`); use `e$fn()`;
  - `tar_load_globals()` needs the `attach()`.


## Switching an existing pipeline (rank 5 → 1)

1. In `_targets.R`:
   - add the `envir` line before anything is loaded;
   - replace `tar_source(files)` with `source("R/source_scoped.R")` + `e <- source_scoped(files)`;
   - top-level calls to your own functions become `e$fn()`;
   - commands use `pkg::fn()` for every package function (attached names, eg from `_targets.R`'s own `box::use()`, aren't visible), or call your own functions.
2. Run `tar_make()`.
   - Nothing should re-run (checked in 10, all 6 directions).
   - Each new error is an import a file uses but doesn't declare. `could not find function` is the plain case. The odd ones (`object 'v' not found`) are usually `stats` names. Add the import to that file.
3. Switch the test helper to `source_scoped()`, so tests catch the next forgotten import.
4. Then turn crew on, if wanted.


## Results of part 10

`Rscript 10-source-scoped-checks.R` (~40 s) writes `results/10-source-scoped-checks.csv` and regenerates `targets/scoped_checks/`.

| check | case | result |
|---|---|---|
| forgotten import, `source_scoped()` | a.R imports `dplyr[filter]` | works |
| | b.R forgot `dplyr[filter]` | error: object 'v' not found |
| | c.R forgot `dplyr[mutate]` | error: could not find function 'mutate' |
| switch loaders on a built pipeline | `tar_source` ↔ `envir` ↔ `source_scoped`, all 6 directions | nothing re-runs |
| `tar_load_globals()`, `source_scoped()` | `fa()` visible in the session | no |
| | after `attach(tar_option_get("envir"), name = "pipeline")` | yes |
| own function at the top level of `_targets.R` | `tar_source()` | works |
| | `envir` line + `tar_source()`, or `source_scoped()` | error: object 'fa' not found |
| | `e <- source_scoped()`, then `e$fa` | works |

- Fast tests: `testthat::test_file("tests/testthat/test-source-scoped.R")` (3 tests, 6 checks, no pipeline).
- Tested with targets 1.12.0, box 1.2.3, R 4.6.1.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md) · [08 caching](08-box-caching.md) · [09 fresh process](09-imports-fresh-process.md)
