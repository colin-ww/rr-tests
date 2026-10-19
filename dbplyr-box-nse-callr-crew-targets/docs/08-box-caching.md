# targets caching with box::use() vs tar_source() (issue #5)

Your report: with `tar_source()`, targets re-runs exactly what changed. With `box::use()` it seems not to. "Maybe only caches for short periods of time? Perhaps if anything changed in that entire file?"

## Short answer

- **Reproduced.** Both of your guesses are right, and there is a third cause.
- What goes wrong depends on how you use box:
  - **`box::use(R/clean)` + `clean$fn()` (module object): targets re-runs too much.** It fingerprints the whole module as one block, and that block includes source information that box always keeps: every line of the file, the file's modification time and its full path. So each of these re-runs **every** target that uses the module:
    - any change to the text, even a comment or a spacing change;
    - the same text with a newer modification time: anything that rewrites the file, such as switching git branches and back, copying, syncing, or an editor that saves unchanged files;
    - the project in another folder (a colleague's clone, another machine, a moved project);
    - a real edit to any **one** function in the file.
  - **`box::use(R/clean[add_x])` (attach) or `box::use()` inside a wrapper function: targets re-runs too little.** It never notices edits to the module. (Attaching also fails on crew, see [04](04-targets.md).)
  - **One R session** (`tar_make(callr_function = NULL)`): box keeps serving the module it loaded first, so your edit is not used. And R compiles a function the first time it runs, which changes the module's fingerprint, so targets says everything is outdated even when nothing changed.
- **`tar_source()` is immune**: targets fingerprints a function by its code only. Comments, spaces, file times and folders don't matter.
- **Not box's fault, and not box-only.** A plain `list()` of functions loaded with `tar_source()` behaves exactly like a box module (`src_list` below). It is how targets fingerprints anything that is not a function.
- **Fix that works today** (tested, with crew too): keep `tar_source()` and keep `box::use()` at the top of each script. Add one line so the pipeline gets its own environment:

  ```r
  # _targets.R
  library(targets)
  tar_option_set(envir = new.env(parent = globalenv()))   # before tar_source()
  tar_source()                                            # R/*.R, each starting with box::use(...)
  ```

  - box then puts each script's imports in a parent of that environment instead of on the search path, and targets sends the whole environment to crew workers. So this **also fixes your crew problem**, without `box::use()` inside every function.
  - Caching is the same as plain `tar_source()`: one function at a time, ignoring comments, spaces, file times and folders.
  - Want each file to see **only its own** imports, like a box module? Use the 9-line `source_scoped()` below instead of `tar_source()`. That is about as close to your `tar_source(as_modules = TRUE)` idea as you can get today.
- **Your `ingest_boxuse()` helper**: as written it does not work, even without crew: `could not find function "mutate"`. box puts the imports inside the helper's own call, which is gone when the helper returns. `eval.parent(quote(box::use(...)))` fixes it: it works on crew and caches correctly. It still needs one line in every function, which the `envir` fix doesn't.
- **Upstream:** yes, **targets, not box**. One issue, which can be shown without box. A PR is not a good first step, because any fix changes the fingerprints, so existing pipelines would re-run once after upgrading. That is the maintainer's call. Others have hit this: targets discussion #1188 (a box user's pipeline was "always outdated" on a second machine) and #936. See [draft 13](upstream-drafts.md#13-ropenscitargets-imported-lists--environments-of-functions-box-modules-are-fingerprinted-with-their-source-references-modification-time-full-path-every-line-and-byte-code).

## Results

Each variant is a small project in `targets/cache_<variant>/` with the same two functions, `add_x()` and `add_y()`, in `R/clean.R`, and the targets `raw` → `out_x`, `out_y`. `Rscript 08-box-caching.R` reruns all of them (about 5 min).

How to read the tables:
- "no controller" = plain `tar_make()`. "crew" = `crew_controller_local(workers = 2)`.
- The change columns: I made one change, asked a fresh `tar_outdated()` which targets it would re-run, then undid the change (text and modification time). `–` = nothing re-runs. `x` = `out_x`, `y` = `out_y`.
- **Correct** answers: `y` for "add_y edited", `–` for every other column (for "imports changed", `–` and `x, y` are both fine). Wrong answers and failures are in **bold**. An empty cell means the pipeline failed, so there was nothing to check.

| variant | setup | no controller | crew | 2nd run | touched | comment | spaces | add_y edited | imports changed | folder copied | undone |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `src_global` | `tar_source()` (your setup) | works | **fails: could not find function 'mutate'** | – | – | – | – | y | – | – | – |
| `src_envir` | `tar_option_set(envir = new.env())` + `tar_source()` | works | works | – | – | – | – | y | – | – | – |
| `src_scoped` | `tar_option_set(envir = new.env())` + `source_scoped()` | works | works | – | – | – | – | y | – | – | – |
| `src_helper_naive` | `tar_source()`; each function calls `clean_imports()`, which is `function() box::use(...)` (your helper) | **fails: could not find function 'mutate'** | **fails: could not find function 'mutate'** |  |  |  |  |  |  |  |  |
| `src_helper_fixed` | as above, but `clean_imports <- function() eval.parent(quote(box::use(...)))` | works | works | – | – | – | – | y | x, y | – | – |
| `src_list` | `tar_source()` of `clean <- list(add_x = ..., add_y = ...)`, `clean$add_x(raw)` (no box) | works | works | – | **x, y** | **x, y** | **x, y** | **x, y** | n/a | **x, y** | – |
| `src_list_source` | the same list, but `source("R/clean.R")` instead of `tar_source()` | works | works | – | – | – | – | **x, y** | n/a | – | – |
| `src_envir_source` | `tar_option_set(envir = new.env())` + `source("R/clean.R", local = tar_option_get("envir"))` | works | works | – | – | – | – | y | – | – | – |
| `mod_object` | `box::use(R/clean)`, `clean$add_x(raw)` | works | works | – | **x, y** | **x, y** | **x, y** | **x, y** | x, y | **x, y** | – |
| `mod_attach` | `box::use(R/clean[add_x, add_y])`, `add_x(raw)` | works | **fails: could not find function 'add_x'** | – | – | – | – | **–** | – | – | – |
| `mod_in_fn` | `box::use(R/clean)` inside wrapper functions in `_targets.R` | works | works | – | – | – | – | **–** | – | – | – |

Notes:
- `src_global` fails on crew because `box::use()` at the top of a file run in the global environment attaches to the search path, which crew workers don't get ([04](04-targets.md#what-actually-happens-from-the-source-code)). That's the issue's starting point.
- `src_list` has no box at all. It shows the problem is in targets.
- `src_list_source` and `src_envir_source` use `base::source()`: see [`base::source()` instead of `tar_source()`?](#basesource-instead-of-tar_source).
- `tar_sitrep()` gives the same answer as `tar_outdated()`, with the reason `depend`. Checked for a touched file: `out_x` and `out_y` both `depend = TRUE` with `mod_object`, both `FALSE` with `src_envir`.
- "imports changed" is `x, y` for the fixed helper, because the helper function itself changed (arguably the most correct answer), and for the module object, because the whole module counts as changed. With `tar_source()` and `envir`, adding an import re-runs nothing, as with `library()`.

### In one R session

This is **box's own** module cache (`box::purge_cache()`), and it is separate from everything above. It only matters when targets runs inside **your** R session. `tar_make()`, `tar_outdated()`, `tar_sitrep()` and `tar_visnetwork()` all start a fresh R by default (`callr_function = callr::r`), where box has nothing cached and reads the file anew. So in normal use, what `tar_sitrep()` says depends only on targets' fingerprints.

`tar_make(callr_function = NULL)`, then (maybe) an edit to `add_y`, then `tar_outdated(callr_function = NULL)` in the same session. "new add_y in use" = does the pipeline now see the edited function?

| variant | in one session | should re-run | tar_outdated() says | new add_y in use |
|---|---|---|---|---|
| `mod_object` | nothing edited | – | **x, y** | – |
| `mod_object` | nothing edited, byte-compiler off (compiler::enableJIT(0)) | – | – | – |
| `mod_object` | add_y edited | y | **x, y** | **no** |
| `mod_object` | add_y edited, box::purge_cache() before tar_outdated() | y | **x, y** | yes |
| `src_global` | nothing edited | – | – | – |
| `src_global` | add_y edited | y | y | yes |

- box keeps a loaded module for the whole session ([klmr/box#234](https://github.com/klmr/box/issues/234), "autoreload", open). `box::purge_cache()` makes it read the file again (tested; `box::reload()` should too, not tested).
- The "nothing edited" row is wrong because of R's byte-compiler (the JIT): a function is compiled the first time it runs, which changes how the module object is stored. With `compiler::enableJIT(0)` the row is right.
- A normal `tar_make()` is not affected: it starts a fresh R and fingerprints everything **before** running any target (targets `R/class_active.R`, line 72).
- The targets maintainer already warns that `callr_function = NULL` "risks incorrectly invalidating some targets" (discussion #936). With box modules, that's what happens.

### Catches of the `envir` fix

A pipeline with `tar_option_set(envir = ...)` + `tar_source()` and a target `out_m = raw$var1 * multiplier`:

| multiplier <- 10 is in | no controller | crew | `multiplier` 10 → 20 re-runs `out_m`? |
|---|---|---|---|
| `_targets.R` | works | **fails: object 'multiplier' not found** | **no** |
| `R/settings.R` | works | works | yes |

- **Don't define things directly in `_targets.R`** (constants, small functions). They land in the global environment: targets doesn't track them, and crew workers never get them (tested with the constant above; functions go the same way). Put them in an `R/` file.
- **`tar_load_globals()`** (for debugging) now puts your functions in the pipeline environment, not in your session. Then run `attach(tar_option_get("envir"), name = "pipeline")`.
- **`tar_source()` + `envir`**: all files share one set of imports, like `library()`. A file can use a function that only another file imported (tested below). When two files import the same name, the file loaded last wins, and files load in the order `list.files()` returns them, roughly alphabetical (checked by hand). `source_scoped()` avoids both. Tested with two files: `R/util.R` imports `n_distinct` and defines `times2()` and `count_ids()`; `R/clean.R` defines `add_x()`, which calls `times2()`, and `leaky()`, which calls `n_distinct()` without importing it. "own" = `count_ids()` (its own file's import); "other file's" = `leaky()`. The box-like answer for "other file's" is an error.

| variant | no controller | crew | `times2()` edited (should re-run `x`) |
|---|---|---|---|
| `src_envir` | own: 3 · other file's: 3 | own: 3 · other file's: 3 | x |
| `src_scoped` | own: 3 · other file's: error: could not find function "n_distinct" | own: 3 · other file's: error: could not find function "n_distinct" | x |

## `base::source()` instead of `tar_source()`?

- **What `tar_source()` is:** for each `.R` file in a folder, `parse(file, keep.source = TRUE)`, then `eval()` into `tar_option_get("envir")` (targets `R/tar_source.R`, lines 61-75). That's all.
- **`source()`** does the same for one file, but:
  - it runs the code in the global environment unless you pass `local =`;
  - it keeps source information only if `getOption("keep.source")` is `TRUE`. In the R that `tar_make()` starts, it is `FALSE`, because that R is not interactive (checked). In the RStudio console it is `TRUE`.
- What that means for caching (rows `src_list_source` and `src_envir_source` above):
  - **Plain functions:** no difference. targets ignores source information for functions anyway.
  - **A list of functions:** `source()` is stable to a touch, a comment, spacing and another folder, because there is no source information to fingerprint. It is still one block: editing `add_y` re-runs both targets.
  - **box modules:** no difference. box reads module files itself, always with `keep.source = TRUE`.
- **crew and top-of-file `box::use()`:** what matters is the environment the file runs in, not `source()` vs `tar_source()`. `source(f, local = tar_option_get("envir"))` behaves exactly like the `envir` fix (tested, crew too). Plain `source(f)` runs in the global environment, so it should fail on crew like `src_global` (same mechanism; not run).
- **Verdict: no reason to switch.** `tar_source()` is shorter (a whole folder, the right environment by default), and source information is what gives you file and line numbers in tracebacks. If you have lists of functions, turn them into top-level functions instead.

## What actually happens (from the source code)

Line numbers are from the upstream dev copies (targets 1.12.0.9001 @ 06cae18, box 1.2.3 @ 2eb1430). The functions quoted are the same in the installed targets 1.12.0 (checked: `hash_import_object.default()`, `hash_object()`, `tar_source()`).

1. Before running anything, targets fingerprints every object in its environment (targets `R/utils_imports.R`, `hash_import_object()`, lines 79-103):
   - **a function**: by its code as text (`tar_deparse_safe()`), plus the fingerprints of the functions it calls. The deparse options (`R/utils_language.R`, lines 63-65) don't include `"useSource"`, so comments and spacing are dropped.
   - **anything else**: `secretbase::siphash13(object)` (`R/utils_hash.R`, line 6), which hashes the object exactly as R stores it on disk (serialized).
2. A box module object is an environment (class `box$mod`), so it takes the "anything else" path. Storing it stores every function in the module, and with them the module's insides: private helpers, the imports, module-level objects.
3. **box always keeps the source.** It reads module files with `parse(..., keep.source = TRUE)` (box `R/use.r`, line 396, `load_from_source()`), because it needs the comments to find `#' @export`. So each function carries a "srcref" pointing to one shared `srcfile` object. It holds (checked):
   - `lines`: every line of the file, comments included;
   - `timestamp`: the file's modification time;
   - `filename`: the file's full path, and `wd`: the working directory;
   - `parseData`, `Enc`, `isFile`, `fixedNewlines`.

   All of it goes into the module's fingerprint. Checked: touching the file changes the module fingerprint, but not the fingerprint targets computes for the function itself.
4. **R compiles functions when they first run.** Checked: running `clean$add_x()` once changes the module fingerprint. It doesn't with `compiler::enableJIT(0)`. A normal `tar_make()` fingerprints before running anything, so this only matters in one session.
5. **`clean$add_x(raw)` depends on `clean`, never on `add_x`.** targets finds a command's dependencies with `codetools::findGlobals()` (`R/utils_language.R`, `deps_function()`, lines 37-41). For `clean$add_x(raw)` that gives `$`, `clean`, `raw`. So targets can only track the module as one block. Per-function tracking of `mod$fn()` would need a change in targets.
6. `tar_source()` also parses with `keep.source = TRUE` (targets `R/tar_source.R`, lines 68 and 70). That's harmless for functions (point 1), but not for a list of functions (`src_list`).

Why `tar_option_set(envir = ...)` makes top-of-file `box::use()` work on crew:
- `tar_source()` runs each file in that environment (`e`). `box::use()` at the top of the file is then called from `e`, not from the global environment.
- In the global environment, box can only `attach()` (search path). Anywhere else, it puts the imports in a **new parent** of the calling environment: `parent.env(x) = new.env(parent = parent.env(x))` (box `R/env.r`, `find_import_env.environment()`, lines 204-210). Your functions live in `e`, so they find the imports by normal R scoping.
- With a non-global `envir`, targets sends that environment itself to crew workers (targets `R/class_crew.R`, `produce_exports()`, lines 92-108: `common$envir <- envir`). Storing an environment stores its parents too, so the imports travel with it. With the global environment, targets instead sends `as.list(globalenv())` (line 100), which leaves the search path behind.
- `source_scoped()` does the same, but with one new environment per file between the file and `e`. Each file's imports land in its own parent, and its functions are then copied into `e`, where targets fingerprints them one by one.

## Your symptoms, explained

- **"Doesn't cache"**: with a module object, almost anything that touches the file or the folder re-runs every target that uses the module. See the change columns above.
  - My guess (I can't see your setup): git operations, a project copied from or synced with "the filers", or a different home folder between RStudio Server and JupyterLab sessions. To check, compare `file.mtime("R/clean.R")` and `normalizePath("R/clean.R")` between a run that cached and one that didn't.
  - Discussion #1188 very likely has the same root cause: a box user shared one store between two machines, and every target was always outdated. The maintainer replied that "box and targets have different systems for managing objects in environments". The full path in the srcref (and maybe file times from the sync) would be the concrete reason. Not reproduced with their code, which I haven't seen.
- **"Perhaps if anything changed in that entire file"**: yes. Real edits (the module is one block) and non-edits (comments, spaces, times) both re-run everything that uses it.
- **"Only caches for short periods of time"**: most likely the modification time (anything that rewrites the file), or `callr_function = NULL` in one session. Also a guess, for the same reason.

## What to do (ranked; each tested above)

1. **`tar_option_set(envir = new.env(parent = globalenv()))` + `tar_source()`** (`src_envir`).
   - Pros: one line on top of what you have now. Keep `box::use()` at the top of each script. Works on crew. Caches exactly like `tar_source()`.
   - Cons:
     - Functions are called by name (`add_x(raw)`), as with `tar_source()` today. No `mod$fn()`.
     - All files share one set of imports.
     - The two catches above: nothing defined directly in `_targets.R`, and `attach()` after `tar_load_globals()`.
     - If your `R/` files `box::use()` your **own** modules (not just packages), the `box.path` trap from [04](04-targets.md#second-trap-box-cannot-find-modules-from-_targetsr-even-without-crew) still applies: put `options(box.path = getwd())` at the top of `_targets.R`.
2. **The same with `source_scoped()`** (`src_scoped`), if you want box-like per-file imports. Put this in `_targets.R` in place of `tar_source()`:

   ```r
   tar_option_set(envir = new.env(parent = globalenv()))
   # like tar_source(), but each file gets its own scope: its box::use() imports are seen by that file only
   source_scoped <- function(dir = "R", envir = tar_option_get("envir")) {
     for (f in list.files(dir, "\\.[rR]$", full.names = TRUE, recursive = TRUE)) {
       file_env <- new.env(parent = envir)
       sys.source(f, envir = file_env, keep.source = FALSE)
       list2env(as.list(file_env), envir)
     }
   }
   source_scoped()
   ```

   - Pros: as 1, plus each file sees only its own imports. Functions in other files are still callable, and tracked across files (tested: editing `times2()` in `R/util.R` re-ran only the target whose function calls it).
   - Cons: as 1, minus the shared imports. Every top-level object of a file is visible to the pipeline: there is no `#' @export`.
3. **Module objects, `clean$fn()`** (`mod_object`, the first choice in [04](04-targets.md#what-to-do-ranked-each-tested-above), now demoted). Keep it if you really want `mod$fn()` and true modules, and your targets are cheap to re-run. Use small modules, never `callr_function = NULL`, and expect a full re-run after a clone, a move or a `git checkout` that touches the file.
4. **Your helper, fixed** (`src_helper_fixed`), with plain `tar_source()`:

   ```r
   # R/ingest.R
   ingest_imports <- function() eval.parent(quote(box::use(dplyr[mutate, filter])))

   hospital_data <- function(d) {
     ingest_imports()
     mutate(d, ...)
   }
   ```

   - Pros: works on crew; caches correctly; changing the import list re-runs that file's targets.
   - Cons: one line in every function (forgetting it gives a loud `could not find function` error). box costs about 4 ms per call ([04](04-targets.md#results)), so keep these functions out of tight loops.
   - Why `eval.parent()`: `box::use()` imports into the environment it is called from. Inside your helper, that is the helper's own call, which disappears when the helper returns. `eval.parent()` runs it in the calling function instead.
5. **Don't:**
   - `box::use(R/clean[add_x])` at the top: edits are never noticed, and it fails on crew.
   - `box::use()` inside wrapper functions without a `format = "file"` target: edits are never noticed.
   - `callr_function = NULL` with box modules: old code, and everything looks outdated.
   - A list or environment of functions as a "namespace" (`helpers$fn()`), even without box: same fragile fingerprint as a module.

Rerun:
- `Rscript 08-box-caching.R` writes `results/08-box-caching.csv` and regenerates `targets/cache_*/` (about 5 min).
- Fast tests: `testthat::test_file("tests/testthat/test-box-caching.R")` (5 tests, 16 checks, about 9 s).
- Add `RUN_TARGETS_TESTS=true` to also run real pipelines (one more test with 4 checks: a touch re-runs `mod_object` but not `src_scoped`; `src_scoped` works on crew, `src_global` doesn't; about 20 s).
- Tested with targets 1.12.0, crew 1.3.3, mirai 2.7.3, box 1.2.3, callr 3.8.0, secretbase 1.3.1, R 4.6.1. Only local crew workers on Linux.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md) · [targets + crew + box (issue #3)](04-targets.md)
