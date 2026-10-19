# Part 2: box::use interactions with NSE and dbplyr translation
suppressPackageStartupMessages(library(dplyr))
options(box.path = getwd())
box::use(mods/helpers)
box::use(dplyr[mutate_alias = mutate], lubridate, stringr[str_to_upper, nch = str_length])
source("R/harness.R")
backends <- setup_backends()
var1 <- 100; only_global <- 5

P <- "box"
res <- bind_rows(
  # --- box::use(base[...]) itself ---
  probe(P, "box::use(base[nchar]) (R 4.6.1 / box 1.2.3)", box::use(base[nchar])),
  # --- scoping: module env vs global env vs column ---
  probe_bk(P, "module fn: col + module var1 (999)",     helpers$add_var1(d)),
  probe_bk(P, "module fn: module-level only",           helpers$add_mod_only(d)),
  probe_bk(P, "module fn: global-only var (not visible)", helpers$add_global_only(d)),
  probe_bk(P, "module fn: .env$var1 -> module's 999",   helpers$add_dollar_env(d)),
  probe_bk(P, "module fn arg used in filter",           helpers$keep_gt(d, 1)),
  probe_bk(P, "module fn: pkg::fn translated",          helpers$add_pkg_fn(d)),
  probe_bk(P, "module topenv name",                     helpers$whoami()),
  # --- dbplyr translation looks at the CALL NAME, not the function object ---
  probe_bk(P, "module fn inside query (double_it on col)", mutate(d, x = helpers$double_it(var1))),
  probe_bk(P, "module fn in module query",              helpers$add_double(d)),
  probe_bk(P, "alias of dplyr verb (mutate_alias)",     mutate_alias(d, x = var1 * 2)),
  probe_bk(P, "alias of stringr fn (nch = str_length)",         mutate(d, x = nch(name))),
  probe_bk(P, "attached box import str_to_upper",       mutate(d, x = str_to_upper(name))),
  probe_bk(P, "ns$fn form: lubridate$year(dt)",         mutate(d, x = lubridate$year(dt))),
  probe_bk(P, "ns$fn form + R variable named like the column", (\(d) { dt <- as.Date("1999-05-05"); mutate(d, x = lubridate$year(dt)) })(d)),
  probe_bk(P, "pkg::fn form: lubridate::year(dt)",      mutate(d, x = lubridate::year(dt))),
  probe_bk(P, "plain year(dt) w/o import",              mutate(d, x = year(dt))),
  probe_bk(P, "box ns$str_to_upper (helpers$ style on pkg)", mutate(d, x = stringr$str_to_upper(name))),
  probe_bk(P, "dplyr$n()-style w/o attaching",          (\(d) { box::use(dplyr); dplyr$summarise(d, x = dplyr$n()) })(d)),
  probe_bk(P, "box::use inside function: dplyr[mutate]", (\(d) { box::use(dplyr[mutate]); mutate(d, x = var1) })(d)),
  probe_bk(P, "dbplyr .sql pronoun in module-style",    mutate(d, x = .sql$abs(var1)))
)
save_results(res, "02-box.csv")
cat("rows:", nrow(res), "\n")
