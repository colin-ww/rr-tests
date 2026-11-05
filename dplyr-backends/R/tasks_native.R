#### tasks_native.R  -  the same tasks rewritten for data.table and collapse, plus a dplyr+collapse hybrid ####
# Not backends: different code. Here to show the ceiling, and what a rewrite of a hot spot buys.
# "dplyr+collapse" = keep the dplyr pipe, swap only the slow grouped bits for collapse fast functions
# (fmedian(x, g, TRA = "fill") etc.). Tasks with no grouped bit are identical to dplyr and are skipped.
# Outputs must equal TASKS$<task>$f() up to column types and row order (checked by run_one.R).
# collapse is ATTACHED for these (run_one.R) and fast functions are called BARE (fsum, not collapse::fsum):
# inside fsummarise()/fmutate() only bare names are vectorised over groups; collapse::fsum or a box alias
# cl$fsum gives the same answer ~35x slower (evaluated group by group; 03-gotchas.R).

NATIVE <- list()

## data.table ----
NATIVE$data.table <- list(
  join = function(d) {
    x <- d$tax[d$units, on = "id"]                   # X[Y] = left join of Y with X
    x <- d$geo[x, on = "postal_code"]
    d$codes[x, on = "type_code"]
  },
  summarise_few = function(d) {
    d$units[status == "A", .(n = .N, w = sum(weight), inc_mean = mean(inc_sef, na.rm = TRUE)), by = .(prov, type_code)]
  },
  summarise_many = function(d) {
    # sum(!is.na(x)) is not GForce-optimised (it is an expression, not a column): pre-compute the flag
    x <- d$persons[, .(id, income, has = !is.na(income), age)]
    x <- x[, .(n_pers = .N, n_inc = sum(has), inc_sum = sum(income, na.rm = TRUE), age_max = max(age)), by = id]
    x[n_inc == 0, inc_sum := NA]
    x
  },
  median_many = function(d) {
    x <- d$units[, .(id, postal_code, inc_sef, has = !is.na(inc_sef))]
    x[, `:=`(n_pc = sum(has), med_pc = median(inc_sef, na.rm = TRUE)), by = postal_code]
    x[, income := data.table::fcoalesce(as.numeric(inc_sef), data.table::fifelse(n_pc >= 5, as.numeric(med_pc), NA_real_))]
    x[, .(id, postal_code, n_pc, income)]
  },
  case_when = function(d) {
    u <- d$units
    u[, .(id,
          inc_grp = data.table::fcase(is.na(inc_sef), "missing", inc_sef < 20000, "low", inc_sef < 60000, "mid",
                                      inc_sef < 120000, "high", default = "top"),
          big_hh  = data.table::fifelse(hh_size >= 4, "yes", "no"),
          w_adj   = weight * data.table::fifelse(status == "A", 1, 0.5),
          inc_any = data.table::fcoalesce(inc_sef, 0L) + hh_size)]
  },
  strings_dates = function(d) {
    d$units[, .(id,
                id_chr = sprintf("BU%010d", as.integer(id)),
                fsa    = toupper(substr(postal_code, 1, 3)),
                pc_ok  = nchar(postal_code) == 6,
                key    = paste0(prov, "_", type_code),
                yr     = data.table::year(start_date),
                days   = as.numeric(as.Date("2026-01-01") - start_date))]
  },
  first_per_id = function(d) {
    # the data.table idiom for SAS first.: sort, then unique() keeps the first row per id
    x <- data.table::setorder(data.table::copy(d$persons), id, -age, person_id)
    unique(x, by = "id")
  },
  filter_arrange = function(d) {
    x <- d$units[status == "A" & hh_size >= 2 & !is.na(postal_code) & weight > 50, .(id, prov, weight, postal_code)]
    data.table::setorder(x, prov, -weight, id)
  },
  distinct_count = function(d) {
    d$units[!is.na(postal_code), .(n_pc = data.table::uniqueN(postal_code), n = .N), by = .(prov, status)]
  },
  pipeline = function(d) {
    # GForce-friendly: plain sum(col) per group; the flag and as.numeric() outside the grouped j
    hh <- d$persons[, .(id, income, has = !is.na(income))][, .(n_inc = sum(has), inc_t1 = sum(income, na.rm = TRUE)), by = id]
    hh[, inc_t1 := as.numeric(inc_t1)][n_inc == 0, inc_t1 := NA]
    x <- hh[d$units, on = "id"]
    x <- d$geo[x, on = "postal_code"]
    x <- d$codes[x, on = "type_code"][excl == FALSE & status == "A"]
    x[, inc_pre := data.table::fcoalesce(inc_t1, as.numeric(inc_sef))]
    x[, has := !is.na(inc_pre)]
    x[, `:=`(n_pc = sum(has), med_pc = median(inc_pre, na.rm = TRUE)), by = postal_code]
    x[, med_cma := median(inc_pre, na.rm = TRUE), by = cma]
    x[, income := data.table::fcase(!is.na(inc_pre), inc_pre, !is.na(postal_code) & n_pc >= 5, med_pc, default = med_cma)]
    x[, inc_grp := data.table::fcase(income < 20000, "low", income < 80000, "mid", income >= 80000, "high", default = "missing")]
    x[, .(n = .N, w = sum(weight), inc_mean = mean(income)), by = .(prov, cma, inc_grp)]
  }
)

## collapse ----
# fast statistical functions take a grouping argument and are vectorised over groups in C:
#   fmedian(x, g)              one value per group
#   fmedian(x, g, TRA = "fill") one value per row (= grouped mutate)
NATIVE$collapse <- list(
  join = function(d) {
    d$units |>
      collapse::join(d$tax, on = "id", verbose = 0) |>
      collapse::join(d$geo, on = "postal_code", verbose = 0) |>
      collapse::join(d$codes, on = "type_code", verbose = 0)
  },
  summarise_few = function(d) {
    d$units |>
      collapse::fsubset(status == "A") |>
      collapse::fgroup_by(prov, type_code) |>
      collapse::fsummarise(n = GRPN(), w = fsum(weight), inc_mean = fmean(inc_sef))
  },
  summarise_many = function(d) {
    d$persons |>
      collapse::fgroup_by(id) |>
      collapse::fsummarise(n_pers = GRPN(), n_inc = fnobs(income),
                           inc_sum = fsum(income), age_max = fmax(age))   # fsum: all-NA group -> NA, like SQL
  },
  median_many = function(d) {
    u <- d$units
    g <- collapse::GRP(u$postal_code)
    n_pc <- fnobs(u$inc_sef, g, TRA = "fill")
    med  <- fmedian(u$inc_sef, g, TRA = "fill")
    tibble::tibble(id = u$id, postal_code = u$postal_code, n_pc = n_pc,
                   income = data.table::fcoalesce(as.numeric(u$inc_sef), data.table::fifelse(n_pc >= 5, as.numeric(med), NA_real_)))
  },
  case_when = function(d) {
    u <- d$units
    tibble::tibble(
      id = u$id,
      inc_grp = data.table::fcase(is.na(u$inc_sef), "missing", u$inc_sef < 20000, "low", u$inc_sef < 60000, "mid",
                                  u$inc_sef < 120000, "high", default = "top"),
      big_hh = data.table::fifelse(u$hh_size >= 4, "yes", "no"),
      w_adj = u$weight * data.table::fifelse(u$status == "A", 1, 0.5),
      inc_any = collapse::replace_na(u$inc_sef, 0L) + u$hh_size
    )
  },
  strings_dates = function(d) {
    u <- d$units
    tibble::tibble(id = u$id, id_chr = sprintf("BU%010d", as.integer(u$id)), fsa = toupper(substr(u$postal_code, 1, 3)),
                   pc_ok = nchar(u$postal_code) == 6, key = paste0(u$prov, "_", u$type_code),
                   yr = as.integer(format(u$start_date, "%Y")), days = as.numeric(as.Date("2026-01-01") - u$start_date))
  },
  first_per_id = function(d) {
    # sort, then drop duplicated ids = SAS first.  (NB grouped ffirst() would skip NAs by default: na.rm = TRUE)
    d$persons |>
      collapse::roworder(id, -age, person_id) |>
      collapse::fsubset(!collapse::fduplicated(id))
  },
  filter_arrange = function(d) {
    d$units |>
      collapse::fsubset(status == "A" & hh_size >= 2 & !is.na(postal_code) & weight > 50, id, prov, weight, postal_code) |>
      collapse::roworder(prov, -weight, id)
  },
  distinct_count = function(d) {
    d$units |>
      collapse::fsubset(!is.na(postal_code)) |>
      collapse::fgroup_by(prov, status) |>
      collapse::fsummarise(n_pc = fndistinct(postal_code), n = GRPN())
  },
  pipeline = function(d) {
    hh <- d$persons |> collapse::fgroup_by(id) |> collapse::fsummarise(inc_t1 = as.numeric(fsum(income)))
    x <- d$units |>
      collapse::join(hh, on = "id", verbose = 0) |>
      collapse::join(d$geo, on = "postal_code", verbose = 0) |>
      collapse::join(d$codes, on = "type_code", verbose = 0) |>
      collapse::fsubset(!excl & status == "A")
    inc_pre <- data.table::fcoalesce(x$inc_t1, as.numeric(x$inc_sef))
    g_pc  <- collapse::GRP(x$postal_code); g_cma <- collapse::GRP(x$cma)
    n_pc  <- fnobs(inc_pre, g_pc, TRA = "fill")
    med_pc  <- fmedian(inc_pre, g_pc, TRA = "fill")
    med_cma <- fmedian(inc_pre, g_cma, TRA = "fill")
    income <- data.table::fcase(!is.na(inc_pre), inc_pre, !is.na(x$postal_code) & n_pc >= 5, med_pc, default = med_cma)
    tibble::tibble(prov = x$prov, cma = x$cma, weight = x$weight, income = income,
                   inc_grp = data.table::fcase(income < 20000, "low", income < 80000, "mid", income >= 80000, "high", default = "missing")) |>
      collapse::fgroup_by(prov, cma, inc_grp) |>
      collapse::fsummarise(n = GRPN(), w = fsum(weight), inc_mean = fmean(income))
  }
)

## dplyr + collapse fast functions (only the grouped tasks; the rest would be identical to dplyr) ----
NATIVE$`dplyr+collapse` <- list(
  summarise_many = function(d) {
    # no way to make dplyr's summarise() vectorise over groups: swap the two verbs for collapse's
    d$persons |>
      fgroup_by(id) |>
      fsummarise(n_pers = GRPN(), n_inc = fnobs(income), inc_sum = fsum(income), age_max = fmax(age))
  },
  median_many = function(d) {
    d$units |>
      mutate(n_pc   = fnobs(inc_sef, postal_code, TRA = "fill"),
             med_pc = fmedian(inc_sef, postal_code, TRA = "fill")) |>
      mutate(income = coalesce(as.numeric(inc_sef), if_else(n_pc >= 5, as.numeric(med_pc), NA))) |>
      select(id, postal_code, n_pc, income)
  },
  first_per_id = function(d) {
    d$persons |>
      filter(age == fmax(age, id, TRA = "fill")) |>
      filter(person_id == fmin(person_id, id, TRA = "fill"))
  },
  distinct_count = function(d) {
    d$units |>
      filter(!is.na(postal_code)) |>
      collapse::fgroup_by(prov, status) |>
      collapse::fsummarise(n_pc = fndistinct(postal_code), n = GRPN())
  },
  pipeline = function(d) {
    hh <- d$persons |> collapse::fgroup_by(id) |> collapse::fsummarise(inc_t1 = as.numeric(fsum(income)))
    d$units |>
      collapse::join(hh, on = "id", verbose = 0) |>
      collapse::join(d$geo, on = "postal_code", verbose = 0) |>
      collapse::join(d$codes, on = "type_code", verbose = 0) |>
      filter(!excl, status == "A") |>
      mutate(inc_pre = coalesce(inc_t1, as.numeric(inc_sef)),
             n_pc    = fnobs(inc_pre, postal_code, TRA = "fill"),
             med_pc  = fmedian(inc_pre, postal_code, TRA = "fill"),
             med_cma = fmedian(inc_pre, cma, TRA = "fill"),
             income  = case_when(!is.na(inc_pre) ~ inc_pre, !is.na(postal_code) & n_pc >= 5 ~ med_pc, .default = med_cma),
             inc_grp = case_when(income < 20000 ~ "low", income < 80000 ~ "mid", income >= 80000 ~ "high", .default = "missing")) |>
      collapse::fgroup_by(prov, cma, inc_grp) |>
      collapse::fsummarise(n = GRPN(), w = fsum(weight), inc_mean = fmean(income))
  }
)
