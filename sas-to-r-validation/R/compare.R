# Compare R outputs with SAS outputs (SAS = the spec), table by table, joined on key columns.
#   compare_all(sas, r, keys) -> list(summ = 1 row per table with a verdict, diffs = 1 row per cell)
#   compare_tbl(sas, r, keys) -> 1 row per cell: r, sas, diff, kind (n/pct/amt/text), bucket, status
#   match_types(sas, r)       -> recode helper: each SAS col gets the type of the R col with the same name
#   sort_like(sas, r, keys)   -> SAS rows in R's order, SAS-only rows last (for eyeballing, or waldo)
# How and why: ../README.md

box::use(
  dplyr[...],
  purrr[map, map_int, map2_chr, pmap],
  stringr[str_detect, str_extract, str_remove, str_starts],
  tidyr[pivot_longer, unite, unnest],
  tibble[tibble],
  vctrs[vec_match]
)

# RED if > this.  n: |diff| of counts,  pct: pct points,  amt ($ sums): relative,
#   rows: share of rows only in R or only in SAS,  unmatched: share of the table's units in those rows
red_default <- c(n = 1000, pct = 1, amt = 0.01, rows = 0.01, unmatched = 0.001)

to_chr <- \(x) if (is.numeric(x)) if_else(is.na(x), NA, sprintf("%.15g", x)) else as.character(x) # %.15g: 100000, not 1e+05
as_num <- \(x) suppressWarnings(as.numeric(str_remove(x, "%$")))


## recode helpers ####

match_types <- function(sas, r) {
  r_cols <- \(p) r |> select(where(p)) |> names()

  sas |>
    mutate(
      across(any_of(r_cols(is.logical)) & where(is.numeric), as.logical), # 0/1 -> FALSE/TRUE. numeric only: as.logical("1") is NA
      across(any_of(r_cols(\(x) is.factor(x) | is.character(x))), to_chr),
      across(any_of(r_cols(is.integer)), as.integer),
      across(any_of(r_cols(is.double)),  as.numeric)
    )
}

sort_like <- \(sas, r, keys) sas |> arrange(vec_match(pick(all_of(keys)), r[keys]))


## compare ####

# n_cols:    count cols. In rows only in R or only in SAS, the missing side counts as 0
# pct_regex: pct cols. Tolerance = rounding of R's string, eg "97.8" -> 0.05, so pass R pcts as formatted strings
# amt_regex: $ sum cols. Tolerance 0.01, RED on relative diff
compare_tbl <- function(sas, r, keys, red = red_default, n_cols = c("n", "total"), pct_regex = "pct|percent", amt_regex = "amt|income") {
  vals <- intersect(names(sas), names(r)) |> setdiff(keys)
  prep <- \(d) d |> select(all_of(c(keys, vals))) |> mutate(across(everything(), to_chr))

  full_join(
    prep(r)   |> mutate(in_r   = TRUE),
    prep(sas) |> mutate(in_sas = TRUE),
    by = keys, suffix = c("..r", "..sas"), relationship = "one-to-one" # error if keys don't identify rows
  ) |>
    mutate(
      row = case_when(is.na(in_sas) ~ "only in r", is.na(in_r) ~ "only in sas", .default = "both"),
      across(all_of(keys), \(x) paste0(cur_column(), "=", x))
    ) |>
    unite("key", all_of(keys), sep = ", ") |>
    select(-in_r, -in_sas) |>
    pivot_longer(-c(key, row), names_to = c("col", ".value"), names_sep = "\\.\\.") |>
    mutate(
      r_num   = as_num(r),
      sas_num = as_num(sas),
      diff    = if_else(row != "both" & col %in% n_cols, coalesce(r_num, 0) - coalesce(sas_num, 0), r_num - sas_num),
      rel     = diff / sas_num,
      kind    = case_when(
        !is.na(r) & is.na(r_num) | !is.na(sas) & is.na(sas_num) ~ "text",
        col %in% n_cols                                          ~ "n",
        str_detect(col, amt_regex)                               ~ "amt",
        str_detect(col, pct_regex) | str_detect(r, "\\.\\d")     ~ "pct", # also R values with decimals, eg a checklist "value" col
        .default                                                 = "n"
      ),
      tol     = case_when(
        kind == "pct" ~ 0.5 * 10^-coalesce(nchar(str_extract(r, "(?<=\\.)\\d+")), 0L),
        kind == "amt" ~ 0.01,
        .default      = 0
      ) + 1e-9,
      bucket  = if_else(kind == "n", as.character(cut(abs(diff), c(-Inf, 0, 100, red[["n"]], Inf), labels = c("0", "1-100", "101-1000", ">1000"))), NA),
      status  = case_when(
        row != "both"                                       ~ row,
        kind == "text"                                      ~ if_else(coalesce(r, "") == coalesce(sas, ""), "ok", "text"),
        is.na(r_num) & is.na(sas_num)                       ~ "ok",
        is.na(r_num)                                        ~ "na in r",
        is.na(sas_num)                                      ~ "na in sas",
        abs(diff) <= tol                                    ~ "ok",
        abs(if_else(kind == "amt", rel, diff)) > red[kind]  ~ "RED",
        .default                                            = "minor"
      )
    )
}

# sas, r:      named lists of tables (names = table ids)
# keys:        named list of key cols per table, or 1 character vector for all
# known_diffs: c(table id = "why"): deliberate differences, the rows rule is skipped for these (cell + units rules still apply)
# total:       key value of total rows, left out of the table's unit count
compare_all <- function(sas, r, keys, known_diffs = character(), red = red_default, n_cols = c("n", "total"), total = "total", ...) {
  keys_of  <- \(o) if (is.list(keys)) keys[[o]] else keys
  total_re <- paste0("=", total, "(,|$)")

  res <-
    tibble(obj = union(names(r), names(sas))) |>
    mutate(
      r_tbl   = map(obj, \(o) r[[o]]),
      sas_tbl = map(obj, \(o) sas[[o]]),
      diff    = pmap(list(sas_tbl, r_tbl, obj), \(s, r, o) if (!is.null(s) && !is.null(r)) compare_tbl(s, r, keys_of(o), red = red, n_cols = n_cols, ...))
    )

  diffs <- res |> select(obj, diff) |> unnest(diff)

  summ <-
    res |>
    transmute(
      obj,
      rows_r       = map_int(r_tbl,   \(x) if (is.null(x)) NA else nrow(x)),
      rows_sas     = map_int(sas_tbl, \(x) if (is.null(x)) NA else nrow(x)),
      not_compared = map2_chr(r_tbl, sas_tbl, \(r, s) if (is.null(s)) "" else setdiff(names(r), names(s)) |> toString()) # R cols without a SAS col
    ) |>
    left_join(
      diffs |>
        summarize(
          rows_unmatched  = n_distinct(key[row != "both"]),
          units_unmatched = sum(abs(diff[row != "both" & col %in% n_cols])),
          units           = sum(sas_num[col %in% n_cols & !str_detect(key, total_re)], na.rm = TRUE),
          unmatched_pct   = if (units > 0) 100 * units_unmatched / units else NA_real_,
          n_0             = sum(bucket == "0",        na.rm = TRUE), # count cells by |diff|, unmatched rows included
          n_1_100         = sum(bucket == "1-100",    na.rm = TRUE),
          n_101_1000      = sum(bucket == "101-1000", na.rm = TRUE),
          n_gt_1000       = sum(bucket == ">1000",    na.rm = TRUE),
          pct_ok          = sum(status == "ok"    & kind %in% c("pct", "amt")),
          pct_minor       = sum(status == "minor" & kind %in% c("pct", "amt")),
          pct_RED         = sum(status == "RED"   & kind %in% c("pct", "amt")),
          text            = sum(status == "text"),
          na              = sum(str_starts(status, "na in")),
          .by = obj
        ),
      by = join_by(obj)
    ) |>
    mutate(
      rows_pct   = 100 * rows_unmatched / pmax(rows_r, rows_sas),
      known_diff = unname(known_diffs[obj]),
      verdict    = case_when(
        is.na(rows_sas)                                                   ~ "no SAS",
        is.na(rows_r)                                                     ~ "missing in R",
        n_gt_1000 + pct_RED > 0                                           ~ "RED",
        rows_pct > 100 * red[["rows"]] & is.na(known_diff)                ~ "RED",
        coalesce(unmatched_pct, 0) > 100 * red[["unmatched"]]             ~ "RED",
        n_1_100 + n_101_1000 + pct_minor + text + na + rows_unmatched > 0 ~ "minor",
        .default                                                          = "ok"
      ),
      .after = obj
    ) |>
    relocate(rows_pct, .after = rows_unmatched) |>
    select(-units) |>
    relocate(known_diff, not_compared, .after = last_col())

  list(summ = summ, diffs = diffs)
}
