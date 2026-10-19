# Part 3: callr / crew (fresh R sessions) vs box::use, library(), globals, DB connections
suppressPackageStartupMessages({library(dplyr); library(callr)})
here <- getwd()
options(box.path = here)
source("R/harness.R")
var1 <- 100; only_global <- 5
df <- tibble::tibble(var1 = c(1, 2, 3), name = c("alpha", "beta", "gamma"))
box::use(mods/helpers)
con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); dplyr::copy_to(con, df, "df")
lazy <- tbl(con, "df")
fmt <- \(x) if (is.data.frame(x)) x else tibble::tibble(x = paste(format(x), collapse = ","))
r1 <- \(f, ...) fmt(callr::r(f, ...))   # all probes return a df/vector

P <- "callr"
res_callr <- bind_rows(
  probe(P, "baseline: library(dplyr) inside fn",   r1(\(d) { library(dplyr); mutate(d, x = var1) }, args = list(df))),
  probe(P, "no library(): mutate not found",       r1(\(d) mutate(d, x = var1), args = list(df))),
  probe(P, "dplyr::mutate qualified",              r1(\(d) dplyr::mutate(d, x = var1), args = list(df))),
  probe(P, "closure over GLOBAL var (only_global)", r1(\() only_global)),
  probe(P, "global var passed via args",           r1(\(g) g, args = list(only_global))),
  probe(P, "local var captured by closure",        (\() { loc <- 9; r1(\() loc) })()),
  # callr resets the fn's environment to .GlobalEnv unless package = TRUE (see ?callr::r)
  probe(P, "local var captured, package = TRUE",   (\() { loc <- 9; r1(\() loc, package = TRUE) })()),
  probe(P, "global fn captured (helper in global)", { gf <- \(x) x + 1; r1(\() gf(1)) }),
  probe(P, "box::use(dplyr[mutate]) inside fn",    r1(\(d) { box::use(dplyr[mutate]); mutate(d, x = var1) }, args = list(df))),
  probe(P, "box::use(mods/module) inside fn, box.path not set in child",
        r1(\() { box::use(mods/helpers); helpers$double_it(2) })),
  probe(P, "box::use(mods/module) inside fn, R_BOX_PATH env var set in parent",
        withr::with_envvar(c(R_BOX_PATH = here), r1(\() { box::use(mods/helpers); helpers$double_it(2) }))),
  probe(P, "box::use(module) inside fn, options(box.path) set in child (box::use(mods/helpers))",
        r1(\(p) { options(box.path = p); box::use(mods/helpers); helpers$double_it(2) }, args = list(here))),
  probe(P, "module fn passed as arg (env = module ns)", r1(\(f) f(2), args = list(helpers$double_it))),
  probe(P, "module fn using dplyr import, passed as arg", r1(\(f, d) f(d), args = list(helpers$add_var1, df))),
  probe(P, "module fn (no imports) as callr func directly", r1(helpers$double_it, args = list(2))),
  probe(P, "module fn USING a dplyr import as callr func directly", r1(helpers$add_var1, args = list(df))),
  probe(P, "...same with package = TRUE",          r1(helpers$add_var1, args = list(df), package = TRUE)),
  probe(P, "lazy duckdb tbl passed as arg",        r1(\(d) dplyr::collect(d), args = list(lazy))),
  probe(P, "lazy tbl passed as arg, dbplyr loaded in child", r1(\(d) { library(dbplyr); dplyr::collect(d) }, args = list(lazy))),
  probe(P, "con passed as arg",                    r1(\(con) DBI::dbGetQuery(con, "select 1"), args = list(con))),
  probe(P, "child opens own duckdb con",           r1(\() { con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); on.exit(DBI::dbDisconnect(con)); DBI::dbGetQuery(con, "select 1 as x") })),
  probe(P, "child cwd == parent cwd",              r1(\(h) identical(normalizePath(getwd()), normalizePath(h)), args = list(here))),
  probe(P, "child .libPaths same as parent",       r1(\(l) identical(.libPaths(), l), args = list(.libPaths()))),
  probe(P, "child options(box.path) inherited",    r1(\() getOption("box.path"))),
  probe(P, "r_bg + box::use inside fn",            { p <- callr::r_bg(\(d) { box::use(dplyr[mutate]); mutate(d, x = var1) }, args = list(df)); p$wait(); fmt(p$get_result()) })
)

# --- crew: persistent workers (mirai under the hood) ---
suppressPackageStartupMessages(library(crew))
ctl <- crew_controller_local(workers = 1, seconds_idle = 30)
ctl$start()
crew_run <- function(command, data = list(), packages = character()) {
  # push() captures `command` with substitute(), so splice the already-captured call into a fresh push() call
  eval(bquote(ctl$push(command = .(substitute(command)), data = data, packages = packages,
                       name = paste0("t", sample.int(1e9, 1)))))
  ctl$wait(seconds_timeout = 60)
  out <- ctl$pop()
  if (is.null(out)) stop("crew: no result (timeout)")
  if (!is.null(out$error) && !is.na(out$error)) stop(out$error, call. = FALSE)
  fmt(out$result[[1]])
}
P <- "crew"
res_crew <- bind_rows(
  probe(P, "worker getOption('box.path') BEFORE any task sets it", crew_run(getOption("box.path"))),
  probe(P, "baseline: dplyr::mutate qualified",     crew_run(dplyr::mutate(d, x = var1), data = list(d = df))),
  probe(P, "no library: mutate not found",          crew_run(mutate(d, x = var1), data = list(d = df))),
  probe(P, "packages = 'dplyr' option",             crew_run(mutate(d, x = var1), data = list(d = df), packages = "dplyr")),
  probe(P, "GLOBAL var referenced, not passed",     crew_run(only_global)),
  probe(P, "var passed via data",                   crew_run(g, data = list(g = only_global))),
  probe(P, "box::use(dplyr[mutate]) in command",    crew_run({ box::use(dplyr[mutate]); mutate(d, x = var1) }, data = list(d = df))),
  probe(P, "box::use(module) in command, no box.path", crew_run({ box::use(mods/helpers); helpers$double_it(2) })),
  probe(P, "box::use(module) + options(box.path) in command",
        crew_run({ options(box.path = p); box::use(mods/helpers); helpers$double_it(2) }, data = list(p = here))),
  probe(P, "module fn passed via data",             crew_run(f(2), data = list(f = helpers$double_it))),
  probe(P, "lazy duckdb tbl passed via data",       crew_run(dplyr::collect(d), data = list(d = lazy))),
  probe(P, "con passed via data",                   crew_run(DBI::dbGetQuery(con, "select 1"), data = list(con = con))),
  probe(P, "worker opens own duckdb con",           crew_run({ con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); on.exit(DBI::dbDisconnect(con)); DBI::dbGetQuery(con, "select 1 as x") })),
  probe(P, "worker cwd == parent cwd",              crew_run(identical(normalizePath(getwd()), normalizePath(h)), data = list(h = here))),
  probe(P, "worker getOption('box.path') AFTER an earlier task set it (state leak)",          crew_run(getOption("box.path")))
)
ctl$terminate()

# workers keep the library paths and settings they started with, so these need fresh controllers
fresh_ctl <- \(...) { ctl <<- crew_controller_local(workers = 1, seconds_idle = 30, ...); ctl$start() }
extra_lib <- normalizePath(tempdir())
.libPaths(c(extra_lib, .libPaths()))
fresh_ctl()
res_fresh <- bind_rows(
  probe("callr", "runtime .libPaths() change reaches child", r1(\(p) p %in% normalizePath(.libPaths()), args = list(extra_lib))),
  probe(P, "runtime .libPaths() change reaches worker",   crew_run(p %in% normalizePath(.libPaths()), data = list(p = extra_lib)))
)
ctl$terminate()
fresh_ctl(reset_packages = TRUE, reset_options = TRUE)
invisible(crew_run({ options(box.path = "X", digits = 3); library(dplyr); TRUE }))
res_fresh <- bind_rows(res_fresh,
  probe(P, "reset_packages/options = TRUE: next task sees box.path / digits / dplyr attached?",
        crew_run(c(box.path = getOption("box.path"), digits = getOption("digits"), dplyr = "package:dplyr" %in% search())))
)
ctl$terminate()
res <- bind_rows(res_callr, res_crew, res_fresh)
save_results(res, "03-callr-crew.csv")
cat("rows:", nrow(res), "\n")
