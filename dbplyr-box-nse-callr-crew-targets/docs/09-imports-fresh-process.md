# Package imports vs where targets run, incl. a fresh process per target (part 9)

Question (from a follow-up to issue #5): if every target ran in its own fresh R process, would per-file `box::use()` imports become real, or are they only documentation? And which import styles work with and without crew?

## Short answer

- **A fresh process per target changes nothing about imports.** With crew `tasks_max = 1`, each target really runs in its own process (3 targets → 3 process IDs). But each process gets whatever targets ships: the pipeline environment and its imports, or the packages from `packages =` / `library()`. So the results match one reused crew worker, row for row.
- **What makes per-file imports real is scoping, not processes.** Only `source_scoped()` and `box::use()` inside each function make a file that forgot an import fail, and they do so even without crew. With `tar_source()`, the `envir` line, `packages =` or `library()`, imports are pooled: a file without its own `box::use()` still works because another file imported the function. Per-file `box::use()` lines are then partly documentation.
- **Under plain `tar_source()` (global env) with crew, package aliases work and attached names fail.**
  - Why: `box::use(stringr)` creates an object `stringr` in the global env, and targets ships global objects to workers. `box::use(dplyr[mutate])` instead attaches a `mod:dplyr` entry on the search path, which workers don't get.
  - So "top-of-file `box::use()` fails on crew" ([08](08-box-caching.md), [04](04-targets.md)) applies to attached names (`pkg[fn]`, `pkg[...]`), not to `pkg$fn()` aliases.
- **`source_scoped()` with `keep.source = TRUE` caches exactly like `FALSE`.** targets fingerprints functions by their code only. So keeping source info costs nothing for caching, and it keeps file and line numbers in tracebacks (the reason [08](08-box-caching.md#basesource-instead-of-tar_source) gives for preferring `tar_source()`).
- **Caching was right in every variant:**
  - a second run, a touch and a comment re-ran nothing;
  - editing `fc()` re-ran only `out_c`;
  - undoing the change re-ran nothing.

## Results

`Rscript 09-imports-fresh-process.R` (about 3 min) writes `results/09-imports-fresh-process.csv` and the projects in `targets/imp_<load>_<ctrl>/`.

The three files in each project:
- `a.R` imports `dplyr[mutate]`.
- `b.R` uses `mutate()` **without importing it**.
- `c.R` uses `stringr$str_length()` (a package alias).

Run settings and columns:
- `ctrl`: `none` = plain `tar_make()`; `reuse` = 1 crew worker for all targets; `fresh` = 1 crew worker with `tasks_max = 1`, i.e. a fresh process per target.
- `processes` = distinct process IDs among the targets that ran.
- The caching columns come from changes to `c.R`. As in [08](08-box-caching.md#results), each change is made, checked with a fresh `tar_outdated()`, then undone (text and modification time). `-` = nothing re-runs, `c` = `out_c`.

| load | ctrl | a.R (own import) | b.R (no import) | c.R (alias) | processes | 2nd run | touched | comment | fc edited | undone |
|---|---|---|---|---|---|---|---|---|---|---|
| `tar_source()` (global) | none | works | works | works | 1 | - | - | - | c | - |
| `tar_source()` (global) | reuse | **fails** | **fails** | works | 1 | - | - | - | c | - |
| `tar_source()` (global) | fresh | **fails** | **fails** | works | 1 | - | - | - | c | - |
| `envir` + `tar_source()` | none / reuse / fresh | works | works | works | 1 / 1 / 3 | - | - | - | c | - |
| `envir` + `source_scoped()` | none / reuse / fresh | works | **fails** | works | 1 / 1 / 2 | - | - | - | c | - |
| `source_scoped(keep.source = TRUE)` | none / reuse / fresh | works | **fails** | works | 1 / 1 / 2 | - | - | - | c | - |
| `tar_option_set(packages =)` + `tar_source()` | none / reuse / fresh | works | works | works | 1 / 1 / 3 | - | - | - | c | - |
| `library()` in `_targets.R` + `tar_source()` | none / reuse / fresh | works | works | works | 1 / 1 / 3 | - | - | - | c | - |
| `box::use()` inside each function | none / reuse / fresh | works | **fails** | works | 1 / 1 / 2 | - | - | - | c | - |

"fails" = `could not find function "mutate"`. With `error = "continue"`, the other targets still ran.

## Ways to import packages, ranked (with crew in mind)

1. **`envir` line + `tar_source()`** ([08](08-box-caching.md#what-to-do-ranked-each-tested-above)): one line, works everywhere, per-function caching. Imports are pooled across files.
2. **`envir` + `source_scoped()`**: as 1, and each file's `box::use()` is real (a missing import fails, even without crew). Use `keep.source = TRUE`.
3. **`box::use()` inside each function**: real per function, works everywhere. One line per function, and box costs about 4 ms per call ([04](04-targets.md#results)).
4. **`tar_option_set(packages =)`** or **`library()`** in `_targets.R`: the standard targets way, and works everywhere. Whole packages are attached and pooled, and top-of-file `box::use()` lines become documentation.
5. **Plain `tar_source()` + top-of-file `box::use()`**: fine without crew. With crew, only `pkg$fn()` aliases survive.

To check imports without running targets at all, source each file alone in a fresh R (for example `callr::r()`) and call its functions. That fails on a missing import for options 1, 4 and 5 too.
