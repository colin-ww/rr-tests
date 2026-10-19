# dbplyr × box × NSE × callr × crew × targets: what actually happens

Answers issues #1 and #3. Almost every claim comes from a script in this folder that you can re-run. The few that come from reading source code or docs, or from a one-off check by hand, say so. Each script writes a CSV to `results/`, and `docs/` explains the results in plain language.

- **Start here:** [CHEATSHEET.md](CHEATSHEET.md). Plain rules, safe to paste into an LLM.
- **Upstream issues:** [plain-language explanations](docs/upstream-issues.md) · [ready-to-paste drafts](docs/upstream-drafts.md). Nothing was filed.

## Words used in these docs

- **In-memory**: dplyr on a data frame (tibble) in R. The old README called this "tibble".
- **Database**: a dbplyr lazy table from `tbl(con, ...)`. Tested on duckdb and SQLite, and for [SQL Server / Oracle](docs/05-sql-server-oracle.md) also on real engines. The old README called this "dbplyr".
- **R variable**: an object in your session or in a function (not an OS environment variable like `R_BOX_PATH`).
- **build / render / execute**: when a database query fails.
  - *build* = when you call `mutate()` / `filter()`;
  - *render* = when the SQL text is made (`show_query()`, `collect()`);
  - *execute* = when the database runs it (`collect()`).
- **translated**: dbplyr knows an SQL version of the function.
- **`pkg::fn`** is R's own operator. **`mod$fn`** is a box module (or package object) plus `$`. dbplyr treats them very differently.

## Answers to issue #3, one by one

| you asked | short answer | details |
|---|---|---|
| No `options(dbplyr = strict)`? Any dbplyr options? | **Yes, one:** `options(dplyr.strict_sql = TRUE)`. The name starts with `dplyr.`, which is why I missed it before. It makes unknown functions error when the SQL is made. It does not catch the silent `mod$fn(col)` bug, and it blocks `.sql$fn()` for functions dbplyr doesn't know. The other options dbplyr reads are cosmetic (colours, name counters, messages) or Postgres-only (`lubridate.week.start`). Two non-dbplyr options show hidden warnings: `lifecycle_verbosity` and `rlib_warning_verbosity`. | [06 §1–2](docs/06-escape-hatches.md#1-is-there-a-strict-option-yes-one-dplyrstrict_sql) |
| Does `box::use(base)` make sense? Python? At least a clear error, or allow it with no harm? | It's redundant but legitimate. Python's `import builtins` / `from builtins import len` is legal too. It fails because of a **box bug since 1.1.3**, not because of R 4.6: on the same R 4.6.1, box 1.1.2 works and 1.1.3 fails (older R versions were not run). A one-line fix makes it work, and box's own tests still pass. My suggestion upstream: allow it. | [07](docs/07-box-base.md) |
| If I'm not explicit and two things match, warn? | Nothing warns today: dplyr, dbplyr, rlang, lintr and codetools all stay silent. lintr even flags the *correct* code. People asked dplyr for this before (tidyverse/dplyr#2949, #6885, both closed). So I wrote an opt-in helper: `mutate_chk()` / `filter_chk()` / `check_ambiguity()` in `R/check_ambiguity.R`, with tests. | [06 §6–7](docs/06-escape-hatches.md#6-does-anything-warn-when-a-name-is-both-a-column-and-an-object) |
| Did you try `sql()`, `.sql$`, `local()`? Does `.local` exist? | All tried, in-memory and database. **`.local` doesn't exist** anywhere. **`local(x)` means opposite things**: the column in-memory, the R variable on a database. `sql()` arguments run in R. `.sql$substr()` still gets R's translation. **None of them fixes the silent wrong result.** | [06 §3–5](docs/06-escape-hatches.md#3-escape-hatches-what-each-one-really-does) |
| "On tibble and dbplyr" means dplyr in-memory vs dbplyr? | Yes. Renamed to **in-memory** vs **database** in all docs (see above). The CSVs in `results/` still label the in-memory case `tibble`. | – |
| Explain each upstream issue simpler: why a problem, docs, what to expect, which package combo. | Rewritten: what happens / why it's a problem / what the docs say / what to expect / scope (e.g. "dbplyr only; box just makes it likely") / already reported? / verdict. **3 to file, 1 optional, 3 dropped** (two of my old ones were wrong). Plus 5 SQL Server/Oracle dbplyr problems (4 bugs, 1 likely bug), 1 docs request (`dplyr.strict_sql`) and 2 targets/box notes, explained the same way at the end of upstream-issues.md. | [upstream-issues.md](docs/upstream-issues.md), [drafts](docs/upstream-drafts.md) |
| Cheat sheet as plain .md, not a code block | Done. | [CHEATSHEET.md](CHEATSHEET.md) |
| box at the top of the script worked with callr/targets, broke with crew. Put `box::use()` in every function? Use `tar_option_set(packages)`? | Reproduced. `box::use(pkg[fn])` at the top attaches names in the **main** process only. crew workers get your global objects, but not the search path. **Both your ideas work**, with one limit: `tar_option_set(packages =)` loads packages only, not your own box modules. There is no `tar_load_pkgs()`: `tar_load_globals()` only runs `_targets.R` in your own session, for debugging. (There is no `tar_load_pkgs()`; `tar_option_set(packages =)` is the one that loads packages on workers.) My first choice: keep functions in box modules, put `options(box.path = getwd())` and `box::use(mods/clean)` at the top (the module *object* is a global, so it is sent to workers), and call `clean$fn(data)`. 27 mini projects were tested, with and without crew. | [04](docs/04-targets.md) |
| Add targets to the folder name | Renamed to `dbplyr-box-nse-callr-crew-targets`. | – |
| Explain `qualify_all_columns` / `cte` | `sql_options()` changes only the SQL **text**, never the results: `cte = TRUE` gives one named block per step (readable), `use_star = FALSE` lists every column, `qualify_all_columns = TRUE` prefixes every column with its table in joins. Example SQL shown (default vs `cte = TRUE`). | [05 `sql_options()`](docs/05-sql-server-oracle.md#sql_options-three-ways-to-write-the-same-query) |
| Can you simulate MSSQL / Oracle to see the SQL? | Yes: `lazy_frame(..., con = dialect_mssql())` / `dialect_oracle()`. Better still, the SQL was also **run** on real SQL Server 2022, SQL Server 2025 and Oracle 26ai (Docker in the sandbox). About 1 in 8 snippets (10 to 12 of 87 per engine) rendered fine but failed when run. A few of those fail on purpose (`foo()`, `Sys.Date()`). Big ones for SAS ports: Oracle dates, `as.integer()` rounds, `''` is NULL on Oracle, NULL sort order. | [05](docs/05-sql-server-oracle.md) |
| Name your branch better | `claude/issue-3-targets-dialects-feedback`. | – |

## Corrections to the first version (PR #2)

An adversarial re-check in fresh R processes found these. All are fixed in the docs.

- **Strict mode exists** (`dplyr.strict_sql`). The old test only looked for `dbplyr.*` names. The test now checks the real option.
- **The tidyselect warning on databases**: it does warn. The warning shows once per session, and the in-memory case had used it up. Dropped as an upstream issue.
- **callr losing local variables**: the real reason is that callr resets the function's environment to the global one (default `package = NULL`). With `package = TRUE` it works. This also explains why a module function that uses its imports fails as the callr function itself.
- **box in callr vs crew**: the module search order is `R_BOX_PATH` (which replaces `box.path` when set), then box's folder, then the "script folder". callr's child has a temp script, so lookup fails. crew workers have none, so `getwd()` is used. Fix: `Sys.setenv(R_BOX_PATH = ...)`.
- **What reaches a child process**: options don't, but environment variables, the project `.Rprofile` and the working directory do. callr also passes your `.libPaths()`. crew workers get only the library paths R sets at startup, so a `.libPaths()` call made in your session does not reach them.
- **crew state**: attached packages leak between tasks too, not just options (`reset_packages = FALSE`).
- **Unknown functions** are passed with their case unchanged. An untranslatable `pkg::fn()` errors early instead of being sent.
- **The silent-wrong-result rule** now lists its exceptions: `pkg::`, `.sql$`, `.data$`/`.env$`.
- **Box modules** see base only: not globals, not `stats`/`utils`.
- **`box::use(base)`** is a box regression since 1.1.3, not specific to R 4.6.
- Smaller fixes: the exact error wording, `filter(var1 == var1)` drops NA rows, SQLite date luck, the test counts, and a box test that used a local variable instead of a global.

## Files

| file | what | runtime |
|---|---|---|
| `01-nse.R` → [docs/01-nse.md](docs/01-nse.md) | column vs R variable, `.data`/`.env`/`!!`/`{{ }}`, tidyselect, unknown functions, the silent wrong result | ~10 s |
| `02-box.R` + `mods/helpers.R` → [docs/02-box.md](docs/02-box.md) | box module scope, aliasing, `ns$fn` vs `pkg::fn`, translation of box imports | ~5 s |
| `03-callr-crew.R` → [docs/03-callr-crew.md](docs/03-callr-crew.md) | what reaches a callr child / crew worker: globals, packages, options, env vars, modules, connections | ~20 s |
| `04-targets.R` + `targets/<variant>/` → [docs/04-targets.md](docs/04-targets.md) | 27 mini targets projects × {no controller, crew}: box at top / in function / module object / `packages =` / `.Rprofile` / `r_arguments` … | ~5 min |
| `05-dialects.R` → [docs/05-sql-server-oracle.md](docs/05-sql-server-oracle.md) | 87 snippets rendered for SQL Server 15/17, Oracle, Postgres, duckdb, SQLite, and run on real engines when the Docker containers are up; `sql_options()` | ~2 min |
| `06-escape-hatches.R` + `R/check_ambiguity.R` → [docs/06-escape-hatches.md](docs/06-escape-hatches.md) | every option dbplyr reads, `sql()`/`.sql$`/`local()`/`remote()`/`sql_glue2()`, how dbplyr decides "R or SQL", the ambiguity helper | ~15 s |
| `07-box-base.R` → [docs/07-box-base.md](docs/07-box-base.md) | `box::use(base)` root cause, 123 cases (118 in a fresh R process), tested fix | ~1 min |
| `R/harness.R` | `probe()`: captures value / SQL / warnings / messages / error and the stage it failed at | – |
| `build-report.R` → `results/tables.md`, `results/versions.md` | all per-case tables for parts 1–3, 6, 7 + versions | ~3 s |
| `tests/testthat/` | 22 tests: 73 expectations pass, 2 tests skip. With `RUN_TARGETS_TESTS=true` (runs real pipelines, ~1 min): 82 expectations, no skips | ~10 s |

Run everything from this folder:

```sh
for f in 0*.R; do Rscript "$f"; done; Rscript build-report.R
Rscript -e 'testthat::test_dir("tests/testthat")'
```

`05-dialects.R` runs queries on real SQL Server / Oracle only if the Docker containers named at the top of the script are running. Without them it still renders all the SQL and runs it on duckdb and SQLite, but it **overwrites** `results/05-dialects.csv` and the SQL Server / Oracle results become "not run".

## Versions

R 4.6.1 · dplyr 1.2.1 · dbplyr 2.6.0 · DBI 1.3.0 · duckdb 1.5.6 · RSQLite 3.53.3 · box 1.2.3 · callr 3.8.0 · crew 1.3.3 · mirai 2.7.3 · targets 1.12.0 · tarchetypes 0.14.1 · tidyselect 1.2.1 · rlang 1.3.0 · withr 3.0.3 · lintr 3.4.0. All packages were the latest on CRAN on 2026-10-16 ([results/versions.md](results/versions.md)). Key results were also re-checked against the GitHub dev versions of dbplyr (2.6.0.9000) and box: same behaviour. SQL engines: SQL Server 2022 (16.x), SQL Server 2025 (17.x), Oracle Free 26ai (23.26).

## Not covered

- Oracle **19c** (no SQL boolean): those notes come from the docs and were not run.
- Real odbc / ROracle / JDBC connections. The dialect a connection picks was read from dbplyr's source, and how to check yours is explained in [05](docs/05-sql-server-oracle.md#how-a-real-connection-picks-its-dialect).
- crew on a cluster (crew.cluster / SLURM). Only local workers on Linux were tested.
- `future` / `mirai::daemons()` directly. The same fresh-process rules are expected, but not tested.
