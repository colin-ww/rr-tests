#### 01-semantics.R  -  same dplyr code, different answer? Tiny-data probes of the known traps, per backend ####
# What a backend swap can silently change: NA join keys, all-NA sums, n_distinct(NA), rounding, as.integer(),
# integer medians, .by being ignored, sort order of NA / case, SAS "first.", and column TYPES on the way back
# (the schema question). Plus key-type mismatches in joins: does anything warn, error, or auto-cast?
# Each backend runs in its own process (collapse masking changes the search path).
# Output: results/01-semantics.csv (+ the wide table in results/tables.md via build-report.R)
#   Rscript 01-semantics.R      # ~1 min

options(width = 200)
source("R/backends.R")

PROBE_BACKENDS <- c("dplyr", "dtplyr", "tidytable", "duckplyr", "dbplyr_duckdb", "arrow", "tidypolars",
                    "fastplyr", "collapse_mask", "poorman", "data.table", "collapse")

tb <- tibble::tibble
CASES <- list(
  # ---- joins ----
  join_na_key = list(
    what = "left_join: NA key in both tables. Does NA match NA? (dplyr default na_matches = 'na'; SAS merge: yes)",
    data = list(t = tb(k = c("a", NA), x = 1:2), y = tb(k = c("a", NA), y = c(10L, 20L))),
    f = \(t, y) left_join(t, y, by = "k"),
    dt = \(t, y) y[t, on = "k"], cl = \(t, y) collapse::join(t, y, on = "k", verbose = 0)),
  join_chr_int = list(
    what = "left_join: chr key ('1','01','2') vs int key (1, 2). Error, warning, or auto-cast?",
    data = list(t = tb(k = c("1", "01", "2"), x = 1:3), y = tb(k = 1:2, y = c(10L, 20L))),
    f = \(t, y) left_join(t, y, by = "k"),
    dt = \(t, y) y[t, on = "k"], cl = \(t, y) collapse::join(t, y, on = "k", verbose = 0)),
  join_int_dbl = list(
    what = "left_join: int key vs double key (1, 2.5)",
    data = list(t = tb(k = 1:3, x = 1:3), y = tb(k = c(1, 2.5), y = c(10L, 20L))),
    f = \(t, y) left_join(t, y, by = "k"),
    dt = \(t, y) y[t, on = "k"], cl = \(t, y) collapse::join(t, y, on = "k", verbose = 0)),
  join_fct_chr = list(
    what = "left_join: factor key vs chr key",
    data = list(t = tb(k = factor(c("a", "b")), x = 1:2), y = tb(k = c("b", "c"), y = c(10L, 20L))),
    f = \(t, y) left_join(t, y, by = "k"),
    dt = \(t, y) y[t, on = "k"], cl = \(t, y) collapse::join(t, y, on = "k", verbose = 0)),
  join_dup_check = list(
    what = "left_join with relationship = 'many-to-one' when y has a duplicated key (like SAS 'repeats of BY values')",
    data = list(t = tb(k = c("a", "b"), x = 1:2), y = tb(k = c("a", "a", "b"), y = 1:3)),
    f = \(t, y) left_join(t, y, by = "k", relationship = "many-to-one"),
    dt = \(t, y) y[t, on = "k", mult = "error"], cl = \(t, y) collapse::join(t, y, on = "k", validate = "m:1", verbose = 0)),
  # ---- aggregates ----
  sum_all_na = list(
    what = "sum(x, na.rm = TRUE) for a group where x is all NA (R: 0; SQL SUM: NULL)",
    data = list(t = tb(g = c(1, 1, 2), x = c(1L, 2L, NA))),
    f = \(t, y) t |> group_by(g) |> summarise(s = sum(x, na.rm = TRUE)) |> ungroup() |> arrange(g),
    dt = \(t, y) t[, .(s = sum(x, na.rm = TRUE)), keyby = g], cl = \(t, y) t |> collapse::fgroup_by(g) |> collapse::fsummarise(s = collapse::fsum(x))),
  mean_all_na = list(
    what = "mean(x, na.rm = TRUE) for an all-NA group (R: NaN)",
    data = list(t = tb(g = c(1, 1, 2), x = c(1, 2, NA))),
    f = \(t, y) t |> group_by(g) |> summarise(m = mean(x, na.rm = TRUE)) |> ungroup() |> arrange(g),
    dt = \(t, y) t[, .(m = mean(x, na.rm = TRUE)), keyby = g], cl = \(t, y) t |> collapse::fgroup_by(g) |> collapse::fsummarise(m = collapse::fmean(x))),
  max_all_na = list(
    what = "max(x, na.rm = TRUE) for an all-NA group (R: -Inf + warning)",
    data = list(t = tb(g = c(1, 1, 2), x = c(1, 2, NA))),
    f = \(t, y) t |> group_by(g) |> summarise(m = max(x, na.rm = TRUE)) |> ungroup() |> arrange(g),
    dt = \(t, y) t[, .(m = max(x, na.rm = TRUE)), keyby = g], cl = \(t, y) t |> collapse::fgroup_by(g) |> collapse::fsummarise(m = collapse::fmax(x))),
  sum_int_overflow = list(
    what = "sum() of an int column past 2^31 (R: NA + warning)",
    data = list(t = tb(x = c(2e9L, 2e9L))),
    f = \(t, y) t |> summarise(s = sum(x)),
    dt = \(t, y) t[, .(s = sum(x))], cl = \(t, y) t |> collapse::fsummarise(s = collapse::fsum(x))),
  n_distinct_na = list(
    what = "n_distinct(c('a', 'a', NA)) (dplyr counts NA: 2; SQL COUNT(DISTINCT): 1)",
    data = list(t = tb(s = c("a", "a", NA))),
    f = \(t, y) t |> summarise(n = n_distinct(s)),
    dt = \(t, y) t[, .(n = data.table::uniqueN(s))], cl = \(t, y) t |> collapse::fsummarise(n = collapse::fndistinct(s))),
  median_int_grouped = list(
    what = "grouped mutate median() of an INT column; group 2 has an even count (median 2.5)",
    data = list(t = tb(g = c(1, 1, 1, 2, 2), x = c(1L, 2L, 3L, 2L, 3L))),
    f = \(t, y) t |> group_by(g) |> mutate(m = median(x)) |> ungroup(),
    dt = \(t, y) t[, m := median(x), by = g][], cl = \(t, y) t |> collapse::fgroup_by(g) |> collapse::fmutate(m = collapse::fmedian(x)) |> collapse::fungroup()),
  median_int_gforce_off = list(
    what = "same, plus a 2nd expression in that grouped mutate (n_ok = sum(!is.na(x))): data.table GForce off, the 1st group's type wins",
    data = list(t = tb(g = c(1, 1, 1, 2, 2), x = c(1L, 2L, 3L, 2L, 3L))),
    f = \(t, y) t |> group_by(g) |> mutate(n_ok = sum(!is.na(x)), m = median(x)) |> ungroup(),
    dt = \(t, y) t[, `:=`(n_ok = sum(!is.na(x)), m = median(x)), by = g][],
    cl = \(t, y) t |> collapse::fgroup_by(g) |> collapse::fmutate(n_ok = collapse::fnobs(x), m = collapse::fmedian(x)) |> collapse::fungroup()),
  by_ignored = list(
    what = "summarise(n = n(), .by = g): 2 groups expected. Is .by understood or silently made a column?",
    data = list(t = tb(g = c(1, 1, 2), x = 1:3)),
    f = \(t, y) t |> summarise(n = n(), .by = g),
    dt = NULL, cl = \(t, y) collapse::fsummarise(t, n = collapse::fnobs(x), .by = g)),
  count_type = list(
    what = "count(g): type of n",
    data = list(t = tb(g = c("a", "a", "b"))),
    f = \(t, y) t |> count(g),
    dt = \(t, y) t[, .N, by = g], cl = \(t, y) collapse::fcount(t, g)),
  # ---- row-wise ----
  round_half = list(
    what = "round(c(0.5, 1.5, 2.5, -0.5)) (R/IEC: half to even 0 2 2 0; SAS/SQL: half away 1 2 3 -1)",
    data = list(t = tb(x = c(0.5, 1.5, 2.5, -0.5))),
    f = \(t, y) t |> mutate(r = round(x)),
    dt = \(t, y) t[, r := round(x)][], cl = \(t, y) collapse::fmutate(t, r = round(x))),
  as_integer = list(
    what = "as.integer(c(2.7, -2.7)) (R: truncates 2 -2; SQL CAST: rounds 3 -3)",
    data = list(t = tb(x = c(2.7, -2.7))),
    f = \(t, y) t |> mutate(i = as.integer(x)),
    dt = \(t, y) t[, i := as.integer(x)][], cl = \(t, y) collapse::fmutate(t, i = as.integer(x))),
  int_div_mod = list(
    what = "-7 %/% 2 and -7 %% 3 (R: -4 and 2; SQL: -3 and -1)",
    data = list(t = tb(x = -7L)),
    f = \(t, y) t |> mutate(q = x %/% 2L, r = x %% 3L),
    dt = \(t, y) t[, `:=`(q = x %/% 2L, r = x %% 3L)][], cl = \(t, y) collapse::fmutate(t, q = x %/% 2L, r = x %% 3L)),
  paste_na = list(
    what = "paste0('a', NA) (R: 'aNA'; SQL ||: NULL; CONCAT: 'a')",
    data = list(t = tb(s = c("b", NA))),
    f = \(t, y) t |> mutate(p = paste0("a", s)),
    dt = \(t, y) t[, p := paste0("a", s)][], cl = \(t, y) collapse::fmutate(t, p = paste0("a", s))),
  if_else_na = list(
    what = "if_else(x > 1, 'y', 'n') and case_when(x > 1 ~ 'y', .default = 'n') where x is NA (dplyr: NA and 'n')",
    data = list(t = tb(x = c(2, NA))),
    f = \(t, y) t |> mutate(i = if_else(x > 1, "y", "n"), c = case_when(x > 1 ~ "y", .default = "n")),
    dt = \(t, y) t[, `:=`(i = data.table::fifelse(x > 1, "y", "n"), c = data.table::fcase(x > 1, "y", default = "n"))][],
    cl = NULL),
  date_diff = list(
    what = "as.numeric(as.Date('2026-01-11') - d) (days: 10)",
    data = list(t = tb(d = as.Date("2026-01-01"))),
    f = \(t, y) t |> mutate(days = as.numeric(as.Date("2026-01-11") - d)),
    dt = \(t, y) t[, days := as.numeric(as.Date("2026-01-11") - d)][], cl = NULL),
  # ---- order ----
  sort_na = list(
    what = "arrange(x) with an NA (dplyr: NA last)",
    data = list(t = tb(x = c(2, NA, 1))),
    f = \(t, y) t |> arrange(x),
    dt = \(t, y) data.table::setorder(data.table::copy(t), x, na.last = TRUE), cl = \(t, y) collapse::roworder(t, x)),
  sort_na_desc = list(
    what = "arrange(desc(x)) with an NA (dplyr: NA last too; SQL DESC: depends on the engine)",
    data = list(t = tb(x = c(2, NA, 1))),
    f = \(t, y) t |> arrange(desc(x)),
    dt = \(t, y) data.table::setorder(data.table::copy(t), -x, na.last = TRUE), cl = \(t, y) collapse::roworder(t, -x)),
  sort_strings = list(
    what = "arrange(s) for b B a _ A (dplyr 1.1+: C locale -> A B _ a b; SAS: same)",
    data = list(t = tb(s = c("b", "B", "a", "_", "A"))),
    f = \(t, y) t |> arrange(s),
    dt = \(t, y) data.table::setorder(data.table::copy(t), s), cl = \(t, y) collapse::roworder(t, s)),
  first_dot = list(
    what = "SAS first.: arrange(g, desc(v)) |> distinct(g, .keep_all = TRUE) -> v = 3, 9",
    data = list(t = tb(g = c(1, 1, 2, 2), v = c(1, 3, 9, 5))),
    f = \(t, y) t |> arrange(g, desc(v)) |> distinct(g, .keep_all = TRUE),
    dt = \(t, y) unique(data.table::setorder(data.table::copy(t), g, -v), by = "g"),
    cl = \(t, y) collapse::roworder(t, g, -v) |> collapse::fsubset(!collapse::fduplicated(g))),
  grouped_filter = list(
    what = "group_by(g) |> filter(v == max(v)) -> v = 3, 9",
    data = list(t = tb(g = c(1, 1, 2, 2), v = c(1, 3, 9, 5))),
    f = \(t, y) t |> group_by(g) |> filter(v == max(v)) |> ungroup(),
    dt = \(t, y) t[t[, .I[v == max(v)], by = g]$V1], cl = NULL),
  factor_groups = list(
    what = "summarise by a factor with levels c('z', 'a'): type and order of the group column",
    data = list(t = tb(f = factor(c("a", "z", "a"), levels = c("z", "a")), x = 1:3)),
    f = \(t, y) t |> group_by(f) |> summarise(s = sum(x)) |> ungroup(),
    dt = \(t, y) t[, .(s = sum(x)), keyby = f], cl = \(t, y) t |> collapse::fgroup_by(f) |> collapse::fsummarise(s = collapse::fsum(x))),
  # ---- schema round trip ----
  roundtrip_types = list(
    what = "column types after a no-op round trip (filter(!is.na(i))): int dbl chr fct lgl Date POSIXct",
    data = list(t = tb(i = 1L, d = 1.5, s = "a", f = factor("lvl"), l = TRUE, dt = as.Date("2026-01-01"),
                       ts = as.POSIXct("2026-01-01 12:00:00", tz = "UTC"))),
    f = \(t, y) t |> filter(!is.na(i)),
    dt = \(t, y) t[TRUE], cl = \(t, y) collapse::fsubset(t, TRUE))
)

## one backend, all cases ----
# which result column(s) each case is about (NULL = all), and whether row order is the point
KEY <- list(join_na_key = "y", join_chr_int = "y", join_int_dbl = c("k", "y"), join_fct_chr = c("k", "y"), join_dup_check = "y",
            sum_all_na = "s", mean_all_na = "m", max_all_na = "m", sum_int_overflow = "s", n_distinct_na = "n",
            median_int_grouped = "m", median_int_gforce_off = "m", by_ignored = "n", count_type = c("n", "N"), round_half = "r", as_integer = "i",
            int_div_mod = c("q", "r"), paste_na = "p", if_else_na = c("i", "c"), date_diff = "days",
            sort_na = "x", sort_na_desc = "x", sort_strings = "s", first_dot = "v", grouped_filter = "v",
            factor_groups = c("f", "s"), roundtrip_types = NULL)
ORDERED <- c("sort_na", "sort_na_desc", "sort_strings", "factor_groups")

## one backend, all cases ----
probe_backend <- function(bk, root) {
  setwd(root); source("R/backends.R")
  options(warn = 1)
  if (!bk %in% c("data.table", "collapse")) setup_backend(bk)
  lazy <- c("data.frame", "tbl_lazy", "dtplyr_step", "ArrowTabular", "arrow_dplyr_query", "polars_lazy_frame", "polars_data_frame")
  norm1 <- \(x) { if (is.factor(x)) x <- as.character(x); if (is.numeric(x) || inherits(x, "integer64")) x <- format(as.numeric(x), digits = 10, trim = TRUE); as.character(x) }
  # -> list(show = full value with types, vals = key column values without types, types = key column classes)
  fmt <- function(r, case) {
    if (inherits(r, lazy)) {
      r <- to_tibble(r)                         # collects: SQL/arrow/polars errors surface here
      r <- r[order(tolower(names(r)))]          # column ORDER is not compared (data.table joins put the key first)
      if (!case %in% ORDERED && nrow(r)) r <- r[do.call(order, unname(as.list(r))), , drop = FALSE]   # SQL/polars row order is arbitrary
      show <- paste(purrr::imap_chr(r, \(v, nm) sprintf("%s<%s>=%s", nm, class(v)[1], paste(format(v), collapse = ","))), collapse = "; ")
      k <- if (is.null(KEY[[case]])) r else r[intersect(KEY[[case]], names(r))]
      if (!length(k)) k <- r[0]
    } else {
      k <- if (is.list(r)) r else list(unname(r))
      show <- paste(vapply(k, \(v) sprintf("<%s>%s", class(v)[1], paste(format(unname(v)), collapse = ",")), ""), collapse = " | ")
    }
    list(show = show, vals = paste(vapply(k, \(v) paste(norm1(v), collapse = ","), ""), collapse = " | "),
         types = paste(vapply(k, \(v) class(v)[1], ""), collapse = ","))
  }
  purrr::imap(CASES, \(cs, case) {
    msgs <- character()
    f <- switch(bk, data.table = cs$dt, collapse = cs$cl, task_fun(cs$f, bk, style = "group_by"))
    if (is.null(f)) return(tibble::tibble(case = case, backend = bk, outcome = "n/a", vals = NA_character_, types = NA_character_, value = NA_character_, msgs = NA_character_))
    v <- tryCatch(withCallingHandlers({
      dat <- purrr::imap(cs$data, \(df, nm) switch(bk, data.table = data.table::as.data.table(df), collapse = df, to_backend(df, bk, name = nm)))
      fmt(f(dat$t, dat$y), case)
    },
    warning = \(w) { msgs <<- c(msgs, paste("W:", conditionMessage(w))); invokeRestart("muffleWarning") },
    message = \(m) { msgs <<- c(msgs, paste("M:", conditionMessage(m))); invokeRestart("muffleMessage") }),
    error = \(e) list(show = paste("ERROR:", conditionMessage(e)), vals = "ERROR", types = "ERROR"))
    msgs <- gsub("\\s+", " ", msgs)
    tibble::tibble(case = case, backend = bk,
                   outcome = if (v$vals == "ERROR") "error" else if (any(grepl("fallback|Pulling data into R", msgs, ignore.case = TRUE))) "fallback"
                             else if (any(startsWith(msgs, "W:"))) "warning" else "ok",
                   vals = v$vals, types = v$types,
                   value = substr(gsub("\\s+", " ", v$show), 1, 400), msgs = substr(paste(unique(msgs), collapse = " || "), 1, 400))
  }) |> purrr::list_rbind()
}

if (sys.nframe() == 0L) {
  res <- purrr::map(PROBE_BACKENDS, \(bk) {
    cat(bk, "... ")
    callr::r(\(bk, root, cases_file) { source(cases_file); probe_backend(bk, root) },
             args = list(bk, getwd(), normalizePath("01-semantics.R")))
  }) |> purrr::list_rbind()
  ref <- res |> filter(backend == "dplyr") |> select(case, ref_vals = vals, ref_types = types)
  res <- res |>
    left_join(ref, by = "case") |>
    mutate(same_values = vals == ref_vals, same_types = types == ref_types, .after = outcome) |>
    select(-ref_vals, -ref_types) |>
    left_join(tibble::tibble(case = names(CASES), what = purrr::map_chr(CASES, "what")), by = "case")
  readr::write_csv(res, "results/01-semantics.csv")
  cat("\nwrote results/01-semantics.csv\n")
}
