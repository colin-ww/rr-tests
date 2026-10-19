# targets + crew + box

Your report: `box::use()` at the top of `_targets.R` worked with plain `tar_make()`, then broke when you added a crew controller.

## Short answer

- **Packages.** `box::use(dplyr[mutate])` at the top of `_targets.R` never reaches crew workers. A function that calls `mutate()` fails on the worker with `could not find function "mutate"`.
- `library(dplyr)` at the top **does** work on workers. targets notes it and loads dplyr again on each worker. That is why the usual targets examples work for people who use `library()`.
- **Your own modules.** `box::use(mods/helpers)` at the top, then `helpers$fn()` in the commands, **does** work on crew workers. The module object is sent to the worker. Attaching names from a module (`box::use(mods/helpers[fn])`) does **not** work.
- **Both of your ideas work** (each one tested):
  - `box::use()` inside each function works with and without crew. Two catches for **modules** (not packages):
    - The main process still needs `box.path` set (see "Second trap").
    - targets stops noticing edits to a module that is only used this way. Fix: add a file target (see below).
  - `tar_option_set(packages = "dplyr")` works for packages. It does nothing for modules. It also attaches the whole package on the worker, as `library()` does.
- **There is no `tar_load_pkgs()`.** The closest names:
  - `tar_option_set(packages =)` (above) is the one that loads packages on workers.
  - `tar_load_globals()` runs `_targets.R` in **your own** R session, for debugging. It does nothing for workers. (Checked: after it, `mod:dplyr` was attached in my session.)
  - `tar_load()` reads a finished target's value. It has nothing to do with packages.
- **Recommended:** keep pipeline functions in box modules. Import the *module object* at the top of `_targets.R`. Call `mod$fn()` in the commands. See "What to do".
- **If you want to keep your current top-of-script style:** crew can run the same `box::use()` line on every worker when the worker starts. See "Running setup code on every crew worker". It works, but it is a workaround.
- **A second trap, even without crew.** `box::use(mods/x)` at the top of `_targets.R` fails under plain `tar_make()` unless box is told where your modules are (`options(box.path = ...)` or the `R_BOX_PATH` environment variable).
  - *Guess, not checked:* one of these was probably already set on your machine. That would explain why it worked before.
  - To check, run `getOption("box.path")` and `Sys.getenv("R_BOX_PATH")`.

## What actually happens (from the source code)

Line numbers are from the upstream dev copies. The code of these functions is the same in the installed versions (checked).

1. `tar_make()` starts a fresh R process with `callr::r()` (the default `callr_function`). It runs `_targets.R` there, in the global environment (targets `R/utils_callr.R`, `tar_callr_inner_try()`, lines 205-207).
2. **No controller:** every target runs in that same process, so everything `_targets.R` set up is there. This is why "it worked with callr".
3. **crew controller:** each target is sent to a worker. A worker is another R process, started as `Rscript --no-save --no-restore -e "crew::crew_worker(...)"` (crew `R/crew_launcher_local.R`, `launch_worker()`, lines 296-307). targets `R/class_crew.R` (`produce_exports()` and `run_worker()`, lines 92-160) sends:
   - the target itself, including its `packages` list;
   - **every object in the global environment** (`as.list(globalenv())`), as crew "globals";
   - targets' own settings (`tar_option_set()`) and its `TAR_*` environment variables.

   It does **not** send:
   - the search path: everything attached with `library()` or `attach()`, which is where R looks up names that are not global (see it with `search()`);
   - R `options()`, so not `box.path`;
   - box's cache of loaded modules.
4. On the worker:
   - crew copies the globals into the worker's global environment (crew `R/crew_eval.R`, line 127: `list2env(globals, globalenv())`).
   - targets loads the target's `packages` with `require()` (targets `R/class_build.R`, line 64, and `R/utils_packages.R`, `load_packages()`).
   - Then the command runs.
5. Where box puts things (box `R/env.r`, `find_import_env()`, lines 204-213; box `R/use.r`, `assign_alias()`, lines 525-532):
   - `box::use(dplyr[mutate])` or `box::use(mods/x[fn])` at top level: box attaches a new environment named `mod:dplyr` to the **search path** (like `attach()`). It is not in the global environment, so targets does not send it.
   - `box::use(mods/x)` or `box::use(dplyr)`: box creates an object (`x`, `dplyr`) **in the global environment**, so targets sends it. The module's own `box::use()` imports live inside it and go with it.
   - `box::use()` inside a function: the names are visible only inside that function call. This works in any R process that has box installed (modules also need the module path, see below).
6. Why `library(dplyr)` works:
   - `tar_target(packages =)` defaults to `tar_option_get("packages")`.
   - That defaults to `(.packages())`: the packages attached **at the moment `tar_target()` is called** (targets `R/class_options.R`, line 288).
   - So a `library()` call above your target list silently adds `dplyr` to every target's `packages`.
   - box never attaches `package:dplyr`, so `.packages()` does not list it and nothing is loaded on the worker.

What a target sees. Taken from `targets/mechanism_view`, whose `_targets.R` has `box::use(dplyr[mutate])`, `box::use(mods/tfuns)` and a function `add_x` at the top:

| where the target ran | global objects it sees | `mod:dplyr` on the search path? |
|---|---|---|
| main process (no controller) | `add_x`, `tfuns` (+ 2 leftover callr objects) | yes |
| crew worker | `add_x`, `tfuns` (+ the same 2) | **no** |

## Second trap: box cannot find modules from `_targets.R` (even without crew)

- callr runs R as `R -f /tmp/RtmpXXXX/callr-scr-...`. box guesses "the script's folder" from that `-f` argument (box `R/paths.r`, `r_path()`, line 124). So it looks for modules in the **temp folder**, not in your project.
- As a result, `box::use(mods/tfuns)` or `box::use(./mods/tfuns)` at the top of `_targets.R` fails under plain `tar_make()`, with: `unable to load module "mods/tfuns"; not found in ".../box/mod", "/tmp/RtmpgjW5LJ"`. It works with `tar_make(callr_function = NULL)` run from `Rscript -e`.
- crew workers are started with `Rscript -e`, which names no script file. So box falls back to the working directory. Local workers start in the project folder (tested).
- So the **opposite** happens for modules loaded inside functions: on a local crew worker they are found, but in the main callr process they are not (variant `mod_in_fn`).
- Fix for the main process: put `options(box.path = getwd())` at the top of `_targets.R` (or in the project `.Rprofile`). `box::set_script_path(file.path(getwd(), "_targets.R"))` also works.
- **Watch out: `R_BOX_PATH` beats `box.path`.** If the environment variable `R_BOX_PATH` is set, box ignores `options(box.path)` completely (box `R/paths.r`, `mod_search_path()`, lines 247-254).
  - Tested: `options(box.path = getwd())` plus `Sys.setenv(R_BOX_PATH = "<team lib>")`, then `box::use(mods/tfuns)`. This fails: box only looks in the team lib, box's own folder and `/tmp/Rtmp...`.
  - If IT or your `.Renviron` already sets `R_BOX_PATH`, `options(box.path = ...)` does nothing.
- `options(box.path = ...)` is **not** sent to workers. This only matters if your modules live **outside** the project folder (for example, a team library). In that case, either:
  - put **all** module folders in `R_BOX_PATH` at the top of `_targets.R`. Local workers inherit environment variables. Tested:

    ```r
    Sys.setenv(R_BOX_PATH = paste(getwd(), "/path/to/team/lib", sep = .Platform$path.sep))
    ```

  - or set `box.path` in the project `.Rprofile`. Workers read it, because crew starts them without `--vanilla`.
  - box's docs say a future major version will read `R_BOX_PATH` only once, when box loads (box `R/use.r`, lines 135-138). So set it at the very top, before any `box::use()`.
- Known upstream: klmr/box#199 "Callr module sourcing" (open since 2021). The person who reported it hit this with targets and used `callr_function = NULL` as a workaround.

## Running setup code on every crew worker

- crew 1.3.3 has no option made for this. `crew_controller_local()` has no setup or startup argument. targets has none either: `tar_hook_before()` only wraps each target's command.
- But crew starts each local worker as `Rscript <r_arguments> -e "crew::crew_worker(...)"`. Any extra `-e` code you put in `r_arguments` runs first, once per worker. Tested (`pkg_box_top_rargs`, `mod_attach_top_rargs`):

  ```r
  library(targets)
  box::use(dplyr[mutate])                     # main process, as before
  worker_setup <- "box::use(dplyr[mutate])"   # the same line, as text, for each crew worker
  tar_option_set(controller = crew::crew_controller_local(
    workers = 2, r_arguments = c("--no-save", "--no-restore", "-e", worker_setup)
  ))
  ```

- For modules, put the module path in the same text, for example `sprintf("options(box.path = %s); box::use(mods/tfuns[add_x])", deparse(getwd()))`.
- Catches:
  - crew's documentation only shows command-line flags here (such as `--vanilla`). Passing code is an unofficial use and could break in a future crew.
  - You must keep the two lines the same by hand.
  - targets still does not notice edits to module functions attached this way.
  - Tested only with local workers on Linux. Not tested on Windows (quoting) or with crew.cluster.

## Results

Each variant is a small project in `targets/<variant>/`. `Rscript 04-targets.R` reruns all of them (about 5 min).

How to read the tables:
- `none` = plain `tar_make()`. `crew` = `crew_controller_local(workers = 2)`.
- "2nd run" = how many targets a second `tar_make()` re-ran. 0 is correct.
- "edit noticed" = I changed `var1 * 2` to `var1 * 3` in the module or function file. Does `tar_outdated()` then list `out`?

Packages (a function defined in `_targets.R` calls `mutate()`):

| variant | setup | none | crew |
|---|---|---|---|
| `pkg_box_top` | `box::use(dplyr[mutate])` at top | works | FAILS: `could not find function "mutate"` |
| `pkg_box_alias_top` | `box::use(dplyr)` at top, `dplyr$mutate()` in the fn | works | works |
| `pkg_box_in_fn` | `box::use(dplyr[mutate])` inside the fn | works | works |
| `pkg_library_top` | `library(dplyr)` at top | works | works |
| `pkg_packages_opt` | `tar_option_set(packages = "dplyr")` | works | works |
| `pkg_qualified` | `dplyr::mutate()` | works | works |
| `pkg_box_top_main` | box at top + `deployment = "main"` | works | works (target runs in the main process) |
| `pkg_box_top_rargs` | box at top + the same line run on every worker via `r_arguments = c(..., "-e", worker_setup)` | works | works |
| `pkg_tar_source` | `tar_source()` of `R/functions.R`, which starts with `box::use(dplyr[mutate])` | works | FAILS: `could not find function "mutate"` |
| `pkg_box_top_hook` | box at top + `tarchetypes::tar_hook_before(hook = box::use(dplyr[mutate]))` | works | FAILS when `mutate()` is in a fn; works when `mutate()` is written in the command |
| `pkg_rprofile` | `box::use(dplyr[mutate])` in the project `.Rprofile` | works | works |
| `pkg_custom_envir` | box + fn inside `local(envir = e, ...)`, then `tar_option_set(envir = e)` | works | works (box puts the imports in a parent of `e`, and targets sends `e` whole) |
| `pkg_box_top_imports`, `pkg_imports_qualified` | `tar_option_set(imports = "dplyr")` | FAILS: `igraph::is_dag(graph) is not TRUE` | FAILS (same) |

Modules (`mods/tfuns.R` does its own `box::use(dplyr[mutate])`):

| variant | setup | none | crew | 2nd run | edit noticed |
|---|---|---|---|---|---|
| `mod_alias_top_nopath` | `box::use(mods/tfuns)` at top, no `box.path` | FAILS: module not found (`/tmp/Rtmp...`) | FAILS (same) | | |
| `mod_alias_top_relative` | `box::use(./mods/tfuns)` at top | FAILS (same) | FAILS (same) | | |
| `mod_setscript_top` | `box::set_script_path(...)` + `box::use(./mods/tfuns)` | works | works | 0 | not tested |
| `mod_alias_top` | `options(box.path = getwd())` + `box::use(mods/tfuns)`, command `tfuns$add_x(raw)` | works | works | 0 | **yes** |
| `mod_attach_top` | as above but `box::use(mods/tfuns[add_x])`, command `add_x(raw)` | works | FAILS: `could not find function "add_x"` | 0 | **no** |
| `mod_attach_top_rargs` | as `mod_attach_top` + `box.path` and the same `box::use()` run on every worker via `r_arguments` | works | works | 0 | no |
| `mod_in_fn` | `box::use(mods/tfuns)` inside the fn, no `box.path` | FAILS: module not found (`/tmp/Rtmp...`) | works | | |
| `mod_in_fn_boxpath` | as above + `options(box.path = getwd())` | works | works | 0 | **no** |
| `mod_in_fn_tracked` | as above + `tar_target(tfuns_file, "mods/tfuns.R", format = "file")`, used by `out` | works | works | 0 | yes |
| `shared_option_in_fn` | module outside the project; `options(box.path = ...)` + box inside the fn | works | FAILS: module not found | 0 | no |
| `shared_envvar_in_fn` | as above, but `Sys.setenv(R_BOX_PATH = ...)` | works | works | 0 | not tested |
| `shared_rprofile_in_fn` | as above, but `options(box.path = ...)` in the project `.Rprofile` | works | works | 0 | not tested |
| `shared_alias_top` | module outside the project; `options(box.path = ...)` + `box::use(teamlib/shmod)` at top | works | works | 0 | yes |

Side findings:
- **`tar_option_set(imports = ...)` does not load anything.** It only makes targets *track* a package's functions. With dplyr it breaks the whole pipeline. dplyr has internal functions that call each other in a loop: I found two pairs, `expand_pick_call`/`expand_pick_quo` and `dplyr_order_legacy`/`dplyr_proxy_order_legacy`. targets requires the graph of imported functions to have no loops (targets `R/utils_imports.R`, line 26: `stopifnot(igraph::is_dag(graph))`).
- **Module objects are tracked, but as one block.** targets saves a fingerprint (hash) of a top-level module object, like any other global. The fingerprint stays the same between sessions: a second run re-ran 0 targets.
  - An edit **anywhere** in the module re-runs **every** target that uses that module. Tested: I edited only `add_x`, and both `clean$add_x()` and `clean$add_y()` targets became outdated.
  - Functions loaded with `tar_source()` are tracked one by one. With the same edit, only the `add_x` target became outdated.
- **Cost of `box::use()` inside a function, per call:** about 3.8 ms for `dplyr[mutate]` and about 0.6 ms for an already-loaded module. `dplyr::mutate` takes under 1 microsecond. This does not matter once per target. It adds up inside a loop: 10,000 calls is about 40 s.
- **Packages stay attached on crew workers between tasks.** `crew_controller_local()` defaults to `reset_packages = FALSE` (and `reset_options = FALSE`). Tested with one worker: after one task ran `library(dplyr)`, a later task found `mutate`. So a `library()` call inside one target can make a later target on the same worker work by accident. (`box::use()` inside a command did not leave anything behind.)
- **Testing these pipelines inside testthat hides the callr trap.** testthat sets `TESTTHAT=true`, and then box looks for modules in `getwd()` (box `R/paths.r`, `testthat_path()`, line 175). `tests/testthat/test-targets.R` turns this off for the R processes it starts.

## What to do (ranked; each tested above)

1. **Put functions in box modules, and import the module object at the top of `_targets.R`** (`mod_alias_top`; this exact file was also run with crew).

   ```r
   # _targets.R
   library(targets)
   tar_option_set(controller = crew::crew_controller_local(workers = 2))
   options(box.path = getwd())   # so the callr process that tar_make() starts finds mods/
   box::use(mods/clean)          # mods/clean.R itself starts with box::use(dplyr[mutate])
   list(
     tar_target(raw, data.frame(var1 = 1:3)),   # your real data step here
     tar_target(out, clean$add_x(raw))
   )
   ```

   - Pros:
     - works with and without crew;
     - the module's imports go with it;
     - no `library()`;
     - targets notices module edits.
   - Cons:
     - It needs the `box.path` line. If `R_BOX_PATH` is set on your machine, put the project folder in `R_BOX_PATH` instead.
     - Any edit to a module re-runs every target that uses that module. Smaller modules mean fewer re-runs.
     - Do not call `mod$fn()` on a *column* inside a dbplyr verb: that is the silent-wrong-result trap ([01-nse.md](01-nse.md#silent-wrong-result)). Call module functions on the whole table, as above.
2. **`box::use()` inside each function** (`pkg_box_in_fn`, `mod_in_fn_boxpath`). box's README shows this style: imports stay local to the function.
   - Pros: works in any process (main, callr, crew). It does not depend on what targets sends.
   - Cons:
     - For **modules**, targets no longer notices edits, because the function body does not change. Fix: add `tar_target(clean_file, "mods/clean.R", format = "file")` and mention `clean_file` in the command (`mod_in_fn_tracked`).
     - Module lookups still need `box.path` (or `R_BOX_PATH`) in the main process.
     - There is a small cost per call (see above).
3. **`tar_option_set(packages = c("dplyr", ...))` for packages only**, combined with 1 or 2 for your modules (`pkg_packages_opt`).
   - Pros: one line, and it is the standard targets way. Packages are loaded before each target on every worker.
   - Cons: it attaches whole packages on the worker (like `library()`, so names can mask each other), which is what box is meant to avoid. It does nothing for modules.
4. **Last resorts** (they work, but each has a catch):
   - Run your top-of-script `box::use()` line on every worker through `r_arguments` (see "Running setup code on every crew worker"). Unofficial use of crew; the two lines must be kept the same; edits to attached module functions are not noticed.
   - `deployment = "main"` on a target runs it in the main process, so that target gets no parallel speed-up.
   - A project `.Rprofile` with `box::use(...)` runs in every R session started in that folder, including yours. The setup is hidden.
   - `R_BOX_PATH` for a module library outside the project works on local workers. List the project folder in it too. Cluster workers (crew.cluster) were not tested.
5. **Do not rely on these:**
   - `box::use(pkg[fn])` or `box::use(mods/x[fn])` at the top on its own: attached names stay in the main process.
   - `tar_source()` of files that start with `box::use()`: same problem.
   - `tar_hook_before()`: it only fixes code written directly in the command, not code inside functions.
   - `tar_option_set(imports =)`: it is not about loading, and it breaks with dplyr.
   - `options(box.path)` alone, for modules outside the project.
   - `options(box.path)` and `R_BOX_PATH` together: `R_BOX_PATH` wins and the option is ignored.

Rerun:
- `Rscript 04-targets.R` writes `results/04-targets.csv` and regenerates `targets/<variant>/` (about 5 min).
- Fast tests: `testthat::test_file("tests/testthat/test-targets.R")` (6 checks, about 3 s).
- Add `RUN_TARGETS_TESTS=true` to also run the real pipelines (15 checks in total, about 55 s).
- Tested with targets 1.12.0, tarchetypes 0.14.1, crew 1.3.3, mirai 2.7.3, box 1.2.3, callr 3.8.0. Only local crew workers on Linux were tested.

---
[← back to README](../README.md) · [cheat sheet](../CHEATSHEET.md)
