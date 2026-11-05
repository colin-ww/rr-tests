#### 03-gotchas.R  -  small, surprising things found while building 02-bench.R, each shown on its own ####
# Speed traps (same answer, much slower) and silent-wrong traps. n = 1e6 units unless noted.
#   Rscript 03-gotchas.R      # ~2 min
# Output: results/03-gotchas.csv (+ printed)

suppressPackageStartupMessages({ library(dplyr); library(collapse, warn.conflicts = FALSE) })
source("R/data.R")
Sys.setenv(BENCH_DATA = Sys.getenv("BENCH_DATA", normalizePath("data", mustWork = FALSE)))
options(dplyr.summarise.inform = FALSE)
d <- load_data(1e6)
tm <- \(expr) { gc(); t <- system.time(v <- force(expr))[["elapsed"]]; list(secs = t, value = v) }
out <- list()
add <- \(gotcha, variant, secs, result) out[[length(out) + 1]] <<- tibble(gotcha = gotcha, variant = variant, secs = round(secs, 3), result = result)

## 1. collapse fast functions are only vectorised over groups when called BARE ----
box::use(cl = collapse)
p <- d$persons
a <- tm(p |> fgroup_by(id) |> fsummarise(s = fsum(income), m = fmax(age)))
b <- tm(p |> fgroup_by(id) |> fsummarise(s = collapse::fsum(income), m = collapse::fmax(age)))
c <- tm(p |> fgroup_by(id) |> fsummarise(s = cl$fsum(income), m = cl$fmax(age)))
add("1 collapse: bare vs pkg:: vs box alias inside fsummarise (1.8M groups)", "fsum(income)", a$secs, "reference")
add("1 collapse: bare vs pkg:: vs box alias inside fsummarise (1.8M groups)", "collapse::fsum(income)", b$secs, if (identical(a$value, b$value)) "identical" else "DIFFERS")
add("1 collapse: bare vs pkg:: vs box alias inside fsummarise (1.8M groups)", "cl$fsum(income)  (box::use(cl = collapse))", c$secs, if (identical(a$value, c$value)) "identical" else "DIFFERS")

## 2. dplyr: many-group grouped mutate. The single biggest dplyr cost in an imputation step ----
u <- d$units
a <- tm(u |> mutate(m = median(inc_sef, na.rm = TRUE), .by = postal_code))
f <- tm(u |> mutate(m = fmedian(inc_sef, na.rm = TRUE), .by = postal_code))       # = sc-nts-frame join_income() today
b <- tm(u |> mutate(m = fmedian(inc_sef, postal_code, TRA = "fill")))
c <- tm(u |> fgroup_by(postal_code) |> fmutate(m = fmedian(inc_sef)) |> fungroup())
same <- \(x, y) if (isTRUE(all.equal(as.numeric(x$m), as.numeric(y$m)))) "identical values" else "DIFFERS"
add("2 grouped median by postal_code (50k groups)", "dplyr mutate(median(x), .by = g)", a$secs, "reference")
add("2 grouped median by postal_code (50k groups)", "dplyr mutate(fmedian(x), .by = g)  (join_income() today)", f$secs, same(a$value, f$value))
add("2 grouped median by postal_code (50k groups)", "dplyr mutate(fmedian(x, g, TRA = 'fill'))  (no .by)", b$secs, same(a$value, b$value))
add("2 grouped median by postal_code (50k groups)", "collapse fgroup_by |> fmutate(fmedian())", c$secs, same(a$value, c$value))

## 3. data.table / dtplyr: an expression inside a grouped sum() switches GForce off ----
dt <- data.table::as.data.table(p)
a <- tm(dt[, .(n = sum(!is.na(income))), by = id])
dt[, has := !is.na(income)]
b <- tm(dt[, .(n = sum(has)), by = id])
lz <- dtplyr::lazy_dt(p |> mutate(has = !is.na(income)))
c <- tm(lz |> summarise(n = sum(!is.na(income)), .by = id) |> as_tibble())
e <- tm(lz |> summarise(n = sum(has), .by = id) |> as_tibble())
add("3 data.table GForce: sum(!is.na(x)) vs sum(flag), 1.8M groups", "data.table sum(!is.na(income))", a$secs, "reference")
add("3 data.table GForce: sum(!is.na(x)) vs sum(flag), 1.8M groups", "data.table sum(has)  (flag made first)", b$secs, if (isTRUE(all.equal(a$value$n, b$value$n))) "identical" else "DIFFERS")
add("3 data.table GForce: sum(!is.na(x)) vs sum(flag), 1.8M groups", "dtplyr sum(!is.na(income))", c$secs, "same translation, same cost")
add("3 data.table GForce: sum(!is.na(x)) vs sum(flag), 1.8M groups", "dtplyr sum(has)", e$secs, "")

## 4. dtplyr / tidytable: grouped median() of an INT column can be TRUNCATED ----
# when GForce is off (another non-GForce expression in the same mutate) the first group's result type wins:
# odd-sized first group -> median is integer -> later x.5 medians are truncated (with a warning only)
small <- tibble(g = c(1, 1, 1, 2, 2), x = c(1L, 2L, 3L, 2L, 3L))
f <- \(df) df |> mutate(n_ok = sum(!is.na(x)), m = median(x), .by = g)
r_dplyr <- f(small)$m
w <- character()
r_dt <- withCallingHandlers(f(dtplyr::lazy_dt(small)) |> as_tibble(), warning = \(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") })$m
r_tt <- suppressWarnings(f(tidytable::as_tidytable(small))$m)
add("4 grouped median of int + another expression in the same mutate", "dplyr", NA, paste(r_dplyr, collapse = ","))
add("4 grouped median of int + another expression in the same mutate", "dtplyr", NA, paste0(paste(r_dt, collapse = ","), if (length(w)) "  (warning: precision lost)"))
add("4 grouped median of int + another expression in the same mutate", "tidytable", NA, paste(r_tt, collapse = ","))
add("4 grouped median of int + another expression in the same mutate", "fix: median(as.numeric(x))", NA,
    paste(f(dtplyr::lazy_dt(small |> mutate(x = as.numeric(x)))) |> as_tibble() |> pull(m), collapse = ","))

## 5. duckplyr: group_by() + ungroup() falls back to dplyr; .by stays in DuckDB ----
Sys.setenv(DUCKPLYR_FALLBACK_INFO = "TRUE", DUCKPLYR_FALLBACK_COLLECT = "0", DUCKPLYR_FALLBACK_AUTOUPLOAD = "0")
dk <- duckplyr::as_duckdb_tibble(p)
fb <- 0L; count_fb <- \(expr) withCallingHandlers(expr, message = \(m) { if (grepl("fallback|falling back", conditionMessage(m))) fb <<- fb + 1L; invokeRestart("muffleMessage") })
a <- tm(p |> summarise(s = sum(income, na.rm = TRUE), m = max(age), .by = id))
# collect() alone leaves lazy ALTREP columns (the query runs on first touch), so touch them inside the timer
done <- \(x) { x <- collect(x); invisible(lapply(x, anyNA)); x }
fb <- 0L; b <- tm(count_fb(dk |> group_by(id) |> summarise(s = sum(income, na.rm = TRUE), m = max(age)) |> ungroup() |> done())); fb_b <- fb
fb <- 0L; c <- tm(count_fb(dk |> summarise(s = sum(income, na.rm = TRUE), m = max(age), .by = id) |> done())); fb_c <- fb
add("5 duckplyr: group_by()/ungroup() vs .by (1.8M groups)", "dplyr .by", a$secs, "reference")
add("5 duckplyr: group_by()/ungroup() vs .by (1.8M groups)", "duckplyr group_by() |> summarise() |> ungroup()", b$secs, sprintf("%d fallback(s) to dplyr", fb_b))
add("5 duckplyr: group_by()/ungroup() vs .by (1.8M groups)", "duckplyr summarise(.by = id)", c$secs, sprintf("%d fallback(s)", fb_c))

## 6. collapse masking reaches YOUR code too ----
set_collapse(mask = "fast-stat-fun")
r_mask <- sum(logical(0)); r_len <- length(r_mask)
set_collapse(mask = NULL)
add("6 set_collapse(mask = 'fast-stat-fun') also replaces sum() in your own helpers", "sum(logical(0))", NA,
    sprintf("base: 0; masked: %s (length %d)", if (r_len) format(r_mask) else "integer(0)", r_len))

## 8. duckplyr: collect() returns lazy columns; the work happens on first touch ----
j <- tibble(id = d$units$id, pc = d$units$postal_code) |> duckplyr::as_duckdb_tibble()
lk <- duckplyr::as_duckdb_tibble(d$geo)
t_collect <- system.time(r <- j |> left_join(lk, by = c(pc = "postal_code")) |> collect())[["elapsed"]]
t_touch   <- system.time(invisible(lapply(r, anyNA)))[["elapsed"]]
add("8 duckplyr collect() is lazy (ALTREP): 1M-row join", "collect()", t_collect, "looks done")
add("8 duckplyr collect() is lazy (ALTREP): 1M-row join", "first use of the columns (anyNA)", t_touch, "the query actually runs here")

## 7. arrow: median() is approximate ----
x <- d$units |> select(prov, inc_sef)
r_dp <- x |> summarise(m = median(inc_sef, na.rm = TRUE), .by = prov) |> arrange(prov)
r_ar <- suppressWarnings(arrow::as_arrow_table(x) |> summarise(m = median(inc_sef, na.rm = TRUE), .by = prov) |> collect() |> arrange(prov))
add("7 arrow median() is approximate (t-digest); income by prov, 1M rows", "dplyr (first 4 provinces)", NA, paste(head(r_dp$m, 4), collapse = ", "))
add("7 arrow median() is approximate (t-digest); income by prov, 1M rows", "arrow", NA,
    sprintf("%s  (%d of %d medians differ)", paste(round(head(r_ar$m, 4), 1), collapse = ", "), sum(r_ar$m != r_dp$m), nrow(r_dp)))

res <- bind_rows(out)
print(as.data.frame(res), right = FALSE)
readr::write_csv(res, "results/03-gotchas.csv")
cat("wrote results/03-gotchas.csv\n")
