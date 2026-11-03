#### 01-compare-demo.R  -  R vs SAS outputs on small made-up tables, with R/compare.R ####
# Same layout as a real compare script: 1. R, 2. SAS RENAME, 3. SAS RECODE, 4. build, 5. compare.
# Only rename + recode touch SAS, so no numbers are changed on the way.
# Writes results/01-compare-demo-{summ,diffs}.csv. Run from this folder.

box::use(
  dplyr[...],
  purrr[imap, map],
  readr[write_csv],
  stringr[str_ends, str_sub],
  tibble[tribble]
)
source("R/compare.R")


#### 1. R (stand-in for readRDS() of the pipeline's validation target) ####

r <- list(
  "frame$by_prov" = tribble(
    ~prov_code, ~on_tax, ~n,    ~pct,
    "10",       TRUE,   4210L, "84.2",
    "10",       FALSE,  790L,  "15.8",
    "11",       TRUE,   1603L, "80.2",  # SAS 1600: off by 3 -> minor
    "11",       FALSE,  397L,  "19.8",
    "total",    NA,     7000L, "100.0"
  ),
  "frame$by_prov_mail" = tribble(
    ~prov_code, ~flag_mailable, ~flag_email, ~n,
    "10",       TRUE,           TRUE,        3000L,
    "10",       TRUE,           FALSE,       1990L,
    "10",       FALSE,          TRUE,        2L,     # only in R: a known, deliberate difference
    "10",       FALSE,          FALSE,       8L
  ),
  "income$by_grp" = tribble(
    ~inc_grp, ~n,    ~sum_income,
    "1",      2500L, 75000000,
    "2",      3000L, 150010000,  # SAS 150000000: relative diff 0.007% -> minor
    "3",      1500L, 135000000   # SAS 0 rows in group 3, all in group 2 -> RED (eg wrong input year)
  ),
  "info" = tribble(
    ~name,         ~value,
    "frame_version", "202609",
    "admin_version", "202512",  # SAS 20251231: recoded, not a diff
    "on_tax_pct",   "83.0",
    "label",       "2026/2021"  # SAS "2021": text diff
  ),
  "r_only" = tibble(n = 1L)       # no SAS equivalent
)


#### 2. SAS: RENAME ####
# per R table: SAS sheet, keys (r name = "SAS name"), vals. SAS cols not listed are dropped

spec <- list(
  "frame$by_prov"      = list(sheet = "FRAME_PROV", keys = c(prov_code = "PRCODE", on_tax = "flag_tax"),                               vals = c(n = "freq", pct = "ratio")),
  "frame$by_prov_mail" = list(sheet = "MAIL_PROV",  keys = c(prov_code = "PRCODE", flag_mailable = "flag_mail", flag_email = "flag_EA"), vals = c(n = "count")),
  "income$by_grp"      = list(sheet = "INC_GRP",    keys = c(inc_grp = "incomGr"),                                                   vals = c(n = "Freq", sum_income = "sum_income")),
  "info"               = list(sheet = "INFO",       keys = c(name = "item"),                                                         vals = c(value = "value"))
)

known_diffs <- c("frame$by_prov_mail" = "R doesn't use a SAS-only lookup, so a few tiny combos differ")

# stand-in for read_excel(file, sheet)
sas_sheets <- list(
  FRAME_PROV = tribble(
    ~PRCODE, ~flag_tax, ~freq, ~ratio,   ~desc,
    "10",    1,        4210,  0.842,    "x",
    "10",    0,        790,   0.158,    "x",
    "11",    1,        1600,  0.80003,  "x",  # R "80.2" vs 80.003: off by 0.197 pp -> minor (beyond rounding)
    "11",    0,        397,   0.1985,   "x",  # R "19.8" vs 19.85: within rounding of "19.8" (0.05)
    "00",    NA,       7000,  1,        "x"
  ),
  MAIL_PROV = tribble(
    ~PRCODE, ~flag_mail, ~flag_EA, ~count,
    "10",    1,          1,        3000,
    "10",    1,          0,        1990,
    "10",    0,          0,        10
  ),
  INC_GRP = tribble(
    ~incomGr, ~Freq, ~sum_income,
    1,        2500,  75000000,
    2,        4500,  150000000
  ),
  INFO = tribble(
    ~item,         ~value,
    "frame_version", "202609",
    "admin_version", "20251231",
    "on_tax_pct",   "0.83",
    "label",       "2021"
  )
)


#### 3. SAS: RECODE ####

recode_all <- \(sas, r)
  sas |>
    mutate(
      across(any_of("prov_code") & where(is.character), \(x) replace_values(x, "00" ~ "total")),
      across(any_of("pct") & where(is.numeric), \(x) x * 100)                                   # ratio -> pct
    ) |>
    match_types(r)

recode_one <- list(
  "info" = \(d)
    d |>
      mutate(value = case_when(
        name == "admin_version"   ~ str_sub(value, 1, 6),           # 20251231 -> 202512
        str_ends(name, "_pct")  ~ to_chr(as_num(value) * 100),    # ratio -> pct
        .default                = value
      ))
)
# no recode may change a count to make it match: deliberate differences go in known_diffs, with the reason


#### 4. SAS: build ####

sas <-
  spec |>
  imap(\(s, obj)
    sas_sheets[[s$sheet]] |>
      select(all_of(c(s$keys, s$vals))) |>   # rename
      recode_all(r[[obj]]) |>                 # recode
      (recode_one[[obj]] %||% identity)() |>
      sort_like(r[[obj]], names(s$keys))
  )


#### 5. compare ####

out <- compare_all(sas, r, keys = map(spec, \(s) names(s$keys)), known_diffs = known_diffs)

out$summ |> print(n = Inf, width = Inf)
out$diffs |> filter(status != "ok") |> select(obj, key, col, r, sas, diff, kind, bucket, status) |> print(n = Inf, width = Inf)

write_csv(out$summ, "results/01-compare-demo-summ.csv", na = "")
write_csv(out$diffs |> filter(status != "ok"), "results/01-compare-demo-diffs.csv", na = "")
