#### tasks.R  -  the work being timed, written ONCE in plain dplyr ####
# Each task is the kind of step a SAS-to-R ETL port does: chained left joins, few-group and many-group
# summaries, a grouped median used for imputation (the expensive bit of join_income()), case_when recodes,
# string/date fixes, a "SAS first." pick, filter + sort, and one end-to-end chain.
#
# Rules so every backend CAN give the same answer (the traps are in 01-semantics.R, not here):
#   - joins by character `by = "id"` (poorman has no join_by())
#   - group_by() ... ungroup() instead of .by (not every backend has .by)
#   - no NA join keys on the lookup side; n_distinct() after dropping NA; "sum of an all-NA group" made explicit
#   - row order only matters where `ordered = TRUE`
#
# TASKS$<name> = list(f = function(d), needs = tables, part = multidplyr partition (table + key) or NULL,
#                     key = columns that identify a row (rows are sorted by them before comparing),
#                     ordered = compare row order as is?, what = description)

TASKS <- list(

  join = list(
    what = "3 chained left joins: units + tax (by id) + geo (by postal_code) + codes (by type_code)",
    needs = c("units", "tax", "geo", "codes"), part = NULL, key = "id", ordered = FALSE,
    f = function(d) {
      d$units |>
        left_join(d$tax, by = "id") |>
        left_join(d$geo, by = "postal_code") |>
        left_join(d$codes, by = "type_code")
    }
  ),

  summarise_few = list(
    what = "filter + summarise by prov x type_code (~170 groups): n, sum, mean",
    needs = "units", part = NULL, key = c("prov", "type_code"), ordered = FALSE,
    f = function(d) {
      d$units |>
        filter(status == "A") |>
        group_by(prov, type_code) |>
        summarise(n = n(), w = sum(weight), inc_mean = mean(inc_sef, na.rm = TRUE)) |>
        ungroup()
    }
  ),

  summarise_many = list(
    what = "persons -> households: summarise by id (~0.9 n groups): n, sum (NA if all NA), max",
    needs = "persons", part = c(table = "persons", key = "id"), key = "id", ordered = FALSE,
    f = function(d) {
      d$persons |>
        group_by(id) |>
        summarise(n_pers = n(), n_inc = sum(!is.na(income)), inc_sum = sum(income, na.rm = TRUE), age_max = max(age)) |>
        ungroup() |>
        mutate(inc_sum = if_else(n_inc > 0, inc_sum, NA))
    }
  ),

  median_many = list(
    what = "grouped mutate: median income by postal_code (~n/20 groups), used only if >= 5 donors (imputation)",
    needs = "units", part = c(table = "units", key = "postal_code"), key = "id", ordered = FALSE,
    f = function(d) {
      d$units |>
        group_by(postal_code) |>
        mutate(n_pc = sum(!is.na(inc_sef)), med_pc = median(inc_sef, na.rm = TRUE)) |>
        ungroup() |>
        mutate(income = coalesce(as.numeric(inc_sef), if_else(n_pc >= 5, as.numeric(med_pc), NA))) |>
        select(id, postal_code, n_pc, income)
    }
  ),

  case_when = list(
    what = "row-wise recodes: case_when (5 branches), if_else, coalesce, arithmetic; no groups",
    needs = "units", part = NULL, key = "id", ordered = FALSE,
    f = function(d) {
      d$units |>
        mutate(
          inc_grp = case_when(
            is.na(inc_sef)   ~ "missing",
            inc_sef < 20000  ~ "low",
            inc_sef < 60000  ~ "mid",
            inc_sef < 120000 ~ "high",
            .default         = "top"
          ),
          big_hh  = if_else(hh_size >= 4, "yes", "no"),
          w_adj   = weight * if_else(status == "A", 1, 0.5),
          inc_any = coalesce(inc_sef, 0L) + hh_size
        ) |>
        select(id, inc_grp, big_hh, w_adj, inc_any)
    }
  ),

  strings_dates = list(
    what = "string + date fixes: zero-padded id, substr/toupper, nchar, paste0, year(), date difference",
    needs = "units", part = NULL, key = "id", ordered = FALSE,
    f = function(d) {
      d$units |>
        mutate(
          id_chr  = paste0("BU", stringr::str_pad(as.character(as.integer(id)), 10, pad = "0")),
          fsa     = toupper(substr(postal_code, 1, 3)),
          pc_ok   = nchar(postal_code) == 6,
          key     = paste0(prov, "_", type_code),
          yr      = lubridate::year(start_date),
          days    = as.numeric(as.Date("2026-01-01") - start_date)
        ) |>
        select(id, id_chr, fsa, pc_ok, key, yr, days)
    }
  ),

  first_per_id = list(
    what = "SAS 'first.id': keep the oldest person per id (ties -> lowest person_id) via grouped filters",
    needs = "persons", part = c(table = "persons", key = "id"), key = "id", ordered = FALSE,
    f = function(d) {
      d$persons |>
        group_by(id) |>
        filter(age == max(age)) |>
        filter(person_id == min(person_id)) |>
        ungroup()
    }
  ),

  filter_arrange = list(
    what = "filter on 4 conditions + arrange by 3 keys (order checked)",
    needs = "units", part = NULL, key = NULL, ordered = TRUE,
    f = function(d) {
      d$units |>
        filter(status == "A", hh_size >= 2, !is.na(postal_code), weight > 50) |>
        arrange(prov, desc(weight), id) |>
        select(id, prov, weight, postal_code)
    }
  ),

  distinct_count = list(
    what = "n_distinct postal codes + n by prov (NA dropped first), and count() by 2 columns",
    needs = "units", part = NULL, key = c("prov", "status"), ordered = FALSE,
    f = function(d) {
      d$units |>
        filter(!is.na(postal_code)) |>
        group_by(prov, status) |>
        summarise(n_pc = n_distinct(postal_code), n = n()) |>
        ungroup()
    }
  ),

  pipeline = list(
    what = "end-to-end chain, collected once: household income -> 3 joins -> exclusions -> 2 grouped medians -> impute -> recode -> summary",
    needs = c("units", "persons", "geo", "codes"), part = NULL, key = c("prov", "cma", "inc_grp"), ordered = FALSE,
    f = function(d) {
      hh <- d$persons |>
        group_by(id) |>
        summarise(n_inc = sum(!is.na(income)), inc_t1 = sum(income, na.rm = TRUE)) |>
        ungroup() |>
        mutate(inc_t1 = if_else(n_inc > 0, as.numeric(inc_t1), NA))
      d$units |>
        left_join(hh, by = "id") |>
        left_join(d$geo, by = "postal_code") |>
        left_join(d$codes, by = "type_code") |>
        filter(!excl, status == "A") |>
        mutate(inc_pre = coalesce(inc_t1, as.numeric(inc_sef))) |>
        group_by(postal_code) |>
        mutate(n_pc = sum(!is.na(inc_pre)), med_pc = median(inc_pre, na.rm = TRUE)) |>
        ungroup() |>
        group_by(cma) |>
        mutate(med_cma = median(inc_pre, na.rm = TRUE)) |>
        ungroup() |>
        mutate(
          income  = case_when(!is.na(inc_pre) ~ inc_pre, !is.na(postal_code) & n_pc >= 5 ~ med_pc, .default = med_cma),
          inc_grp = case_when(income < 20000 ~ "low", income < 80000 ~ "mid", income >= 80000 ~ "high", .default = "missing")
        ) |>
        group_by(prov, cma, inc_grp) |>
        summarise(n = n(), w = sum(weight), inc_mean = mean(income)) |>
        ungroup()
    }
  )
)
