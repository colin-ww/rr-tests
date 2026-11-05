# Own code vs package imports with targets: ranked recommendations

This doc pulls together [04](04-targets.md), [08](08-box-caching.md) and [09](09-imports-fresh-process.md), plus 7 new checks (`10-source-scoped-checks.R`, `tests/testthat/test-source-scoped.R`). The questions came from the sc-nts-frame session.

**These are two separate questions. Each gets its own ranking:**
- **A. Own code:** how the functions in your `R/` files get into the pipeline, and how files use each other's functions.
- **B. Package imports:** how those functions find dplyr, stringr and co.

They meet in exactly one place: how top-of-file `box::use()` lines behave depends on which loader you pick in A.


## Words

- **Loader:** how `_targets.R` runs your `R/` files. The three options are `tar_source()`, the `envir` line + `tar_source()`, and `source_scoped()`.
- **`envir` line:** `tar_option_set(envir = new.env(parent = globalenv()))`. It gives the pipeline its own environment instead of the global one.
- **Pipeline env:** where targets looks for your functions (`tar_option_get("envir")`). It's the global env by default, or the new env from the `envir` line.
- **Attached name:** `box::use(dplyr[filter])`, then `filter()`.
- **Alias:** `box::use(stringr)`, then `stringr$str_length()`.
- **Pooled:** one file's imports are visible to every file. **Per file:** each file sees only its own imports.


## Short answer

- **A. Own code:** use any of the three loaders. They are equal for own code: per-function caching, crew works, and every file can call every other file's functions by name.
  - Don't use box modules for own code: either too much re-runs, or nothing does.
  - Own code is always shared between files. That's how targets sees and tracks your functions.
- **B. Package imports:** `box::use()` at the top of each file, made per file by `source_scoped()`.
  - Runner-up: the same lines with the `envir` line + `tar_source()`. That's one line to add, and imports stay pooled.
- **So B picks the loader: `source_scoped()`.** You get shared own code and per-file package imports.
  - There is no setup with per-file **own-code** imports and correct caching.
- **Catches:**
  - A forgotten `dplyr[filter]` silently finds `stats::filter()`.
  - Anything attached in the session is visible to every file.
  - Once the `envir` line is in, `_targets.R` code that runs at load time must call your functions as `e$fn()`.
  - Own box modules imported inside `R/` files go wrong under `source_scoped()`.


## A. Own code: how your `R/` functions get into the pipeline

| rank | loader | caching | crew | your functions in the global env? | tested in |
|---|---|---|---|---|---|
| **1 (tie)** | plain `tar_source()` | right: per function; ignores comments, spacing, file times, folders | works: your functions are global objects, which targets ships | yes | 08 `src_global`, 09 |
| **1 (tie)** | `envir` line + `tar_source()` | right, the same | works | no: `_targets.R` load-time code uses `e$fn()`; debugging needs `attach()` | 08 `src_envir`, 09, 10 |
| **1 (tie)** | `envir` line + `source_scoped()` | right, the same | works | no, the same | 08 `src_scoped`, 09, 10 |
| ✗ | box module objects: `box::use(R/clean)`, `clean$fn()` | **too much**: any touch, comment, branch switch or new folder re-runs everything using the module | works | – | 08 `mod_object` |
| ✗ | attaching your own modules: `box::use(R/clean[fn])` in `_targets.R` | **never notices edits** | **fails** | – | 08 `mod_attach` |
| ✗ | `box::use()` of your own modules inside wrapper functions | **never notices edits** | works | – | 08 `mod_in_fn` |
| ✗ | a list or environment of functions as a namespace (`helpers$fn()`) | **too much**, the same as module objects | works | – | 08 `src_list` |

- **For own code, the three loaders behave the same.** Every file's functions go into one pipeline env. There, targets fingerprints each function by its code. The commands and all other files find them by name.
- **Switching between them re-runs nothing** (checked in all 6 directions, below).
- **Pick the loader in B.**


## B. Package imports: how your functions find dplyr

Which import styles work with which loader:

| package import style | plain `tar_source()` | `envir` line + `tar_source()` | `source_scoped()` |
|---|---|---|---|
| top of the file, attached: `box::use(dplyr[filter])` | pooled; **fails on crew** | pooled; crew works | **per file**; crew works |
| top of the file, alias: `box::use(stringr)` | pooled; crew works | pooled; crew works | **per file**; crew works |
| `box::use()` inside each function | per function; crew works | the same | the same |
| `tar_option_set(packages = )` or `library()` in `_targets.R` | whole packages, for every file; crew works | the same | the same, and it overrides per-file scoping for those packages |
| `pkg::fn()` | works everywhere | the same | the same |

Ranked:
1. **Top-of-file `box::use()` + `source_scoped()`.** It's what you already write, and it becomes real per file. A missing import fails, with or without crew, and in tests.
2. **Top-of-file `box::use()` + `envir` line + `tar_source()`.** One line to add, and crew works. Imports stay pooled, so they're partly documentation.
3. **`box::use()` inside each function.** Real per function, and works with any loader. Costs: one line per function, and ~4 ms per call. Changing an import re-runs that function's targets, which no other row does.
4. **`tar_option_set(packages = )` or `library()`.** The standard targets way, with no imports in the files. The files then don't say what they use.
5. **Top-of-file `box::use()` + plain `tar_source()`** (issue #3's setup). Fine until crew: attached names fail on crew workers.

Every option shares two things:
- **In `_targets.R` commands, use `pkg::fn()`** (eg `config::get()`, `dplyr::filter()`), or call your own functions.
  - Commands don't see the files' imports under `source_scoped()`.
  - On crew they may not see `_targets.R`'s own `box::use()` either: attached names never reach workers, and aliases don't once the `envir` line is on.
- **Package versions are never tracked.** Updating dplyr re-runs nothing.


## How A and B combine

- **A doesn't care which loader you use; B does.** So pick `source_scoped()`: own code is shared, package imports are per file.
- **Do you have to choose between per-file package imports and per-file own-code imports?** No. Own code is always shared (A), whatever you pick. Only package imports can be per file (B).
- **Why own code can't be per file:** targets tracks only functions it finds in the pipeline env, one by one. Hiding a function from other files means taking it out of that env. Then targets can't track it, and edits stop re-running targets (checks 5, 6). The ways that really scope own code are box modules, and they break caching (A, ✗ rows).


## Own box modules inside `R/` files (`box::use(R/util[db_connect])`, `box::use(util = R/util)`)

- **Not needed.** Every file's functions are already shared (A), so call `db_connect()` by name.
- **Under pooled loaders they do nothing.** The pipeline's copy of `db_connect()` is found first.
- **Under `source_scoped()` they take effect.** The file then uses box's own, second copy of `util.R` (check 5):
  - **Attached name** (`box::use(R/util[db_connect])`): editing `db_connect()` still re-runs the right targets. targets tracks the pipeline's copy, which has the same name. But it's two copies of one function.
  - **Alias** (`util$db_connect()`): targets doesn't see the dependency. Edit `db_connect()` and nothing re-runs, so you get **stale results** (check 5).
- **So drop them in pipeline files.** Keep them only in standalone scripts that targets doesn't run.


## Can a file import just one function from another file?

- **Not with targets-friendly loading.** Every function in every file is visible to all files and to the commands. That's the "shared own code" from A.
- **A `.`-named helper doesn't help either.** `source_scoped()` copies `.helper` into the pipeline env too (`all.names = TRUE`). Without that, `.helper` would be private to its file, and editing it would re-run nothing (check 6).
- **What's left are conventions:** a small number of files with clear names, and comments on helpers that only one file should use. Two files defining the same name: the file loaded later silently wins, the same as with `tar_source()`.


## Are real per-file package imports worth it?

- **Gains:**
  - A file sourced alone (tests, one-off checks) behaves the same as in the pipeline.
  - A forgotten import fails right away, instead of working because another file imported it.
  - The file header honestly lists what the file uses.
  - If two files import the same name from different packages, each gets its own. With pooled imports, the file loaded last wins for everyone ([08](08-box-caching.md#catches-of-the-envir-fix)).
- **Doesn't fix:** names that base R already has on the search path (`filter`, `lag`). See the downsides.
- **Verdict:** a cheap, real improvement, but not urgent. Switch in the same step as turning crew on, since both need the `envir` line.


## `source_scoped()` or `box::use()` inside each function?

Both make package imports real. Prefer `source_scoped()`:
- It keeps what you already write: one `box::use()` block per file.
- It needs no import line in every function, and no ~4 ms per call.

`box::use()` inside each function wins only when:
- changing an import must re-run targets (the import line is part of the function's code), or
- a function must work wherever it's copied, with no loader at all.


## Environments, briefly

`source_scoped()` and box are both about environments.
- **An environment is a set of named objects plus a pointer to one parent environment.**
  - It's like a shelf of labelled boxes, with a note saying which shelf to check next.
  - Many children can point to the same parent, but each environment has exactly one parent.
- **Looking up a name:** R checks the current environment, then its parent, then that one's parent, and so on. It stops when it finds the name, or errors at the end (`object 'x' not found`, `could not find function`).
- **Every function call** gets a new environment for its arguments and local variables. That environment's parent is the environment where the function was **defined** (its home), not where it's called. That's why a function finds its own file's imports.
- **Global env and search path:**
  - The global env is your workspace, the one the RStudio Environment pane shows by default. The pane's dropdown shows the others.
  - Its parents form the search path, `search()`: attached packages (`library()`, and box's `mod:...` entries when `box::use()` runs in the global env), then stats, graphics, utils, …, base.
- **Package namespace:** a package's functions live in its namespace (`asNamespace("dplyr")`). Their home chain is namespace → the package's own imports → base → global env → search path. `pkg::fn` reads straight from the namespace, with no attaching involved.
- **box:**
  - In the global env, `box::use(dplyr[filter])` attaches `mod:dplyr` to the search path.
  - Called from any other environment (a function, or `file_env` in `source_scoped()`), box creates a new environment holding `filter` and makes it that environment's new parent, "right above" it. Its own parent is the old parent.
  - An alias (`box::use(stringr)`) is bound in the calling environment itself (checked).
- **Module objects** (`stringr`, `util` from `box::use(util = R/util)`):
  - They're environments of class `box$mod`, locked, holding the module's exports.
  - For a package, the functions' home is the package namespace. For your own module, it's a box namespace environment (class `box$ns`).
- **Memory:**
  - Environments live in RAM like other R objects. Assigning one to a second name doesn't copy it: both names are the same environment.
  - They're written out only when serialized, eg by `saveRDS()`, or when targets sends the pipeline env to crew workers. Serializing stores the parents too, except the global env, packages and namespaces, which go by name.


## How `source_scoped()` works

[`R/source_scoped.R`](../R/source_scoped.R), line by line:
- **`file_env <- new.env(parent = envir)`:** an environment for this file, whose parent is the pipeline env.
- **`sys.source(f, envir = file_env, keep.source = TRUE)`:** base R's "run this file in that environment".
  - Same as `source(f, local = file_env)`, without `source()`'s extras (echo, printing, encoding handling, running in the global env by default).
  - Because the file's `box::use()` runs from `file_env`, box puts the attached imports in a new environment right above `file_env`, and binds aliases in `file_env` itself.
  - **`keep.source = TRUE`** keeps the file's text with each function: errors and tracebacks show file and line, and printed functions keep your comments and spacing. targets ignores it for caching (09).
- **`as.list(file_env, all.names = TRUE)`:** everything the file defined. `all.names = TRUE` includes names that start with `.`, which are skipped by default. Without them, targets couldn't track them (check 6).
- **`!vapply(objs, inherits, logical(1), what = "box$mod")`:** skips box aliases, so they stay with their file like attached names (check 7).
  - An earlier version (in 08 and 09) copied aliases too, which made them shared.
- **`list2env(..., envir)`:** copies the rest into the pipeline env. targets tracks those functions there, and commands and other files find them by name.

Each function keeps `file_env` as its home. When it looks up a name, R searches:

```
function body (one call)
 └ file_env               the file's own objects + its aliases (box::use(stringr))
    └ attached imports     box::use(dplyr[filter]) puts them here, "right above" file_env
       └ pipeline env      every file's functions + objects: what targets tracks and ships
          └ global env → search path (stats, graphics, utils, ..., base)   <- a forgotten filter() finds stats::filter()
```

- **crew:** targets sends the pipeline env to each worker. Each function travels with its home env and that env's parents, so each file's imports go along (check 7: works on crew).
- **Exists in a package?** Not that I know of. `tar_source()` has no per-file option (08), and box scopes but breaks caching. It's under 10 lines, so keep it in its own file, because both `_targets.R` and the test helper use it.


## What goes where

| where | what |
|---|---|
| `_targets.R` | `library(targets)` (and crew); the `envir` line **before** loading; `source("R/source_scoped.R")`; `e <- source_scoped(files)`; other `tar_option_set()`; the targets list. |
| `_targets.R`, load-time code | Code that runs while `_targets.R` is read uses `e$fn()`: top-level calls (eg a startup check), and **arguments** like `tar_option_set(cue = if (e$get_env("FORCE_RERUN")) ...)`. The `envir` line keeps your functions out of the global env (check 4). |
| `_targets.R`, target commands | The command inside `tar_target(name, command)` calls your functions **by name**. targets runs it later, in an environment whose parent is the pipeline env. For packages, use `pkg::fn()`. |
| each `R/` file | At the top, `box::use()` for every **package** it uses (`dplyr[...]`, `stringr`, …). Then functions and constants. Other files' functions: call them by name, with no import. |
| test helper | `source("R/source_scoped.R")`, then `source_scoped(<files under test>)` instead of `source()`. `source()` runs each file in the global env, so their top-of-file `box::use()` lines all land on the search path. Then one file's imports cover another's gaps in tests too. With `source_scoped()`, each file under test sees only its own imports, as in the pipeline. Outside a pipeline, `envir` defaults to the global env, so tests find the functions. |
| console debugging | `tar_load_globals()`, then `attach(tar_option_get("envir"), name = "pipeline")` (check 3). |


## Downsides of `source_scoped()`

- **It's not standard targets.** It's your own small helper, and `tar_source()` is what docs, colleagues and LLMs expect. Keep the header comment.
- **Every file must import every package it uses.** A forgotten import shows up only when that function runs, not at load time. Tests catch it earlier.
- **Not strict for names base R already has.** A forgotten `dplyr[filter]` finds `stats::filter()`, giving `object 'v' not found` (check 1). The same goes for `lag()`. (`head()`/`tail()` are `utils` functions anyway.)
- **Only as strict as the session's search path.** Anything attached is visible to every file: `library()` in `_targets.R` or `.Rprofile`, or in your console or test session. Run tests in a fresh R, with no `library(dplyr)` in the helpers.
- **No private helpers** (see above).
- **Changing only the import block re-runs nothing** ([08](08-box-caching.md#results)). If an import change changes results, run `tar_invalidate()` on the affected targets.
- **The `envir` line's catches:**
  - nothing that commands use may be defined directly in `_targets.R`;
  - load-time code needs `e$fn()`;
  - `tar_load_globals()` needs `attach()`.


## Switching an existing pipeline (plain `tar_source()` → `source_scoped()`)

1. **`_targets.R`:**
   - add the `envir` line before loading;
   - replace `tar_source(files)` with `source("R/source_scoped.R")` + `e <- source_scoped(files)`;
   - load-time calls to your own functions become `e$fn()`;
   - commands use `pkg::fn()` for package functions.
2. **`R/` files:** drop the imports of your own files (`box::use(R/...)`) and call those functions by name.
3. **Run `tar_make()`.**
   - Nothing should re-run.
   - Each new error is a package import that a file uses but doesn't declare: `could not find function`, or `object 'x' not found` for `stats` names. Add it to that file.
4. **Test helper:** switch to `source_scoped()`.
5. **Then turn crew on,** if wanted.


## Results of part 10

`Rscript 10-source-scoped-checks.R` (~1 min) writes `results/10-source-scoped-checks.csv`. It regenerates `targets/scoped_checks/`, `scoped_modules/`, `scoped_dotnames/` and `scoped_alias_*/`.

| # | check | case | result |
|---|---|---|---|
| 1 | forgotten import, `source_scoped()` | a.R imports `dplyr[filter]` | works |
| | | b.R forgot `dplyr[filter]` | error: object 'v' not found (it got `stats::filter`) |
| | | c.R forgot `dplyr[mutate]` | error: could not find function 'mutate' |
| 2 | switch loaders on a built pipeline | `tar_source` ↔ `envir` ↔ `source_scoped`, all 6 directions | nothing re-runs |
| 3 | `tar_load_globals()`, `source_scoped()` | `fa()` visible in the session | no |
| | | after `attach(tar_option_get("envir"), name = "pipeline")` | yes |
| 4 | own function at the top level of `_targets.R` | plain `tar_source()` | works |
| | | `envir` line + `tar_source()`, or `source_scoped()` | error: object 'fa' not found |
| | | `e <- source_scoped()`, then `e$fa` | works |
| 5 | own module imported in a `source_scoped()` file | b.R `box::use(R/a[fa])`: which `fa()` runs | box's own copy of a.R |
| | | b.R: `fa()` edited | re-runs, current value |
| | | c.R `box::use(am = R/a)`, `am$fa()`: `fa()` edited | **nothing re-runs, stale value** |
| 6 | `.helper()` edited | `source_scoped()`, `all.names = TRUE` | re-runs, current value |
| | | `all.names = FALSE` | **nothing re-runs, stale value** |
| 7 | box alias, `source_scoped()` | a.R uses its own alias, no controller and crew | works |
| | | b.R uses a.R's alias, no controller and crew | error: object 'stringr' not found |

- **"All 6 directions" (check 2):** there are 3 loaders. For each ordered pair (3 × 2 = 6), the pipeline is built with one loader, then `_targets.R` is switched to the other and `tar_outdated()` is asked. It was empty every time. The reason: targets fingerprints a function by its code, not by which environment it sits in or which loader put it there. Edits to target commands do re-run those targets.
- **Fast tests:** `testthat::test_file("tests/testthat/test-source-scoped.R")` (4 tests, no pipeline).
- **Versions:** targets 1.12.0, crew 1.3.3, box 1.2.3, R 4.6.1.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md) · [08 caching](08-box-caching.md) · [09 fresh process](09-imports-fresh-process.md)
