# callr and crew: what reaches a fresh R process

Script: `03-callr-crew.R` → `results/03-callr-crew.csv`. For targets on top of this, see [04-targets.md](04-targets.md).

## What a new R process gets

Both callr and crew start a **new R process**.

| | callr child (`callr::r()`) | crew worker (`crew_controller_local()`) |
|---|---|---|
| your global variables | ❌ never | ❌ only what you pass in `data =` (targets passes them for you) |
| attached packages (`library()`, `box::use(pkg[fn])` at top level) | ❌ | ❌ (unless `packages =`) |
| options you set this session (`options(box.path = ...)`) | ❌ | ❌ |
| OS environment variables (`Sys.setenv(R_BOX_PATH = ...)`) | ✅ | ✅ |
| project `.Rprofile` in the working folder | ✅ (callr default `user_profile = "project"`) | ✅ (started without `--vanilla`). Both tested through targets in [04-targets.md](04-targets.md), variant `pkg_rprofile` |
| `.libPaths()`, `repos` | ✅ (callr passes them on purpose) | ⚠️ only the library paths R sets at startup. A `.libPaths()` call made in your session does **not** reach workers |
| working directory | ✅ same as parent | ✅ same as parent when the worker started |
| a DB connection or lazy `tbl()` | ❌ `Invalid connection` (it's a pointer into the parent's memory). A lazy `tbl()` first fails with `no applicable method for 'collect'` unless dbplyr is loaded in the child | ❌ same |

## Results

| case | callr | crew |
|---|---|---|
| `mutate()` without `library(dplyr)` | ❌ `could not find function "mutate"` | ❌ same; `packages = "dplyr"` fixes it ✅ |
| `dplyr::mutate()` | ✅ | ✅ |
| function uses a global variable | ❌ `object 'only_global' not found` | ❌ same; pass it via `data = list(...)` ✅ |
| global passed as an argument | ✅ | ✅ (via `data`) |
| function uses a variable from the function that created it | ❌ `object 'loc' not found` | not tested |
| …with `callr::r(f, package = TRUE)` | ✅ 9 | – |
| global helper function | ❌ `could not find function "gf"` | not tested |
| `box::use(dplyr[mutate])` inside the function / command | ✅ | ✅ |
| `box::use(mods/helpers)` inside the function, no module path set | ❌ `unable to load module "mods/helpers"; not found in ".../box/mod", "/tmp/Rtmp…"` | ✅ (found via the working directory) |
| …with `Sys.setenv(R_BOX_PATH = <project>)` in the parent | ✅ | ✅ (tested through targets in [04-targets.md](04-targets.md), variant `shared_envvar_in_fn`) |
| …with `options(box.path = <project>)` set **inside** the child | ✅ | ✅ |
| module function passed as an argument | ✅ (module and its imports travel with it) | ✅ |
| module function with **no** imports used as the callr function itself | ✅ | – |
| module function that **uses an import** (`mutate`) as the callr function itself | ❌ `could not find function "mutate"` | – |
| …with `package = TRUE` | ✅ | – |
| child opens its **own** duckdb connection | ✅ | ✅ |
| `options(box.path)` in a new child / worker | `NULL` | `NULL` at first; but after one task sets it, **later tasks on the same worker still see it** |
| `r_bg()` + `box::use()` inside the function | ✅ | – |

"–" / "not tested" means no case was run for it.

## Why the callr surprises happen

- **callr resets the function's environment to the global environment** before sending it (default `package = NULL`, which means "reset" for a normal function; see `?callr::r`). So a variable from an enclosing function is lost, and a module function loses its module's imports.
  - `callr::r(f, package = TRUE)` keeps the function's environment, so both work.
  - Real globals still fail even then, because your global environment is never sent.
  - Passing the function as an **argument** (`args = list(f = helpers$add_var1)`) also keeps its environment.
- **How box finds a module** (box `R/paths.r`, `mod_search_path()`), in order:
  1. the `R_BOX_PATH` environment variable; **if it is set, `options(box.path)` is ignored completely**;
  2. otherwise `options(box.path)`;
  3. box's own `mod` folder;
  4. last, the "current script folder": the folder of the script R was started with (`Rscript file.R`, `R -f file`), or `getwd()` if there is no script.
- callr starts its child as `R -f /tmp/RtmpXXXX/callr-scr-…`, so step 4 is callr's temp folder, and `mods/helpers` is not found.
- crew workers start as `Rscript -e …` (no script), so step 4 is `getwd()`, the project folder. If you start the parent from somewhere else, crew fails too.
- Under testthat, `TESTTHAT=true` reaches the child, and box then uses `getwd()` there as well. So a test can hide the callr failure.
- **Fix that works for both:** `Sys.setenv(R_BOX_PATH = "/path/to/project")` in the parent, before callr or crew starts its R processes (a process only gets the environment variables that existed when it started). If you have modules in several folders, list them all in `R_BOX_PATH`.
- Words: in box, `./mods/helpers` is a *relative* module (relative to the current script). `mods/helpers` is looked up on the *search path* above.

## crew state between tasks

crew reuses workers. Its defaults are `reset_globals = TRUE`, `reset_packages = FALSE`, `reset_options = FALSE`:

- globals are cleared after each task;
- **packages attached in one task stay attached** for later tasks on the same worker. A `library()` in one target can make a later target work by accident;
- **options set in one task stay set**.
- `crew_controller_local(reset_packages = TRUE, reset_options = TRUE)` detaches packages and restores options that existed before the task. A brand-new option such as `box.path` still leaks. This is stated in `?crew_controller_local`, and `03-callr-crew.R` checks it: the next task saw `box.path = "X"`, `digits` back to 7, and dplyr detached.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
