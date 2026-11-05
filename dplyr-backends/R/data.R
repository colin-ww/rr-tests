#### data.R  -  synthetic, frame-shaped data (no real data). Sizes scale with n = number of units ####
# Shaped like the NTS frame pipeline: a dwelling/unit list (BUF-like), person-level tax records (T1-like,
# ~2 per unit), a postal-code geo lookup (GAF/PCCF-like, ~20 units per code -> many groups), a 13-row code table.
# Column types are the "good schema" ones (int/dbl/chr/Date); 04-suggest-types.R plays with bad schemas.
#
#   units    n rows      id dbl (like bu_sn), prov int, postal_code chr (2% NA), type_code chr "01".."13",
#                        status chr A/S, inc_sef int (30% NA), start_date Date, hh_size int, weight dbl
#   tax      0.66 n      id, inc_t1 int (2% NA)
#   persons  2 n         id (90% of units have persons, plus some ids not in units), person_id int, age int, income int (15% NA)
#   geo      n / 20      postal_code, csd chr "1234567", cma chr (~150 values, 20% "000" = not in a CMA)
#   codes    13          type_code, type_desc, excl lgl

suppressPackageStartupMessages(library(dplyr))

make_data <- function(n, seed = 1) {
  set.seed(seed)
  n_pc  <- max(50L, as.integer(n %/% 20))
  pc    <- \(k) paste0(sample(LETTERS, k, TRUE), sample(0:9, k, TRUE), sample(LETTERS, k, TRUE),
                       sample(0:9, k, TRUE), sample(LETTERS, k, TRUE), sample(0:9, k, TRUE))
  pcs   <- unique(pc(round(n_pc * 1.05)))[seq_len(n_pc)]
  provs <- c(10L, 11L, 12L, 13L, 24L, 35L, 46L, 47L, 48L, 59L, 60L, 61L, 62L)
  prov_p <- c(1.4, .4, 2.6, 2.1, 22.5, 38.8, 3.6, 3.1, 11.5, 13.6, .1, .1, .1)

  units <- tibble(
    id          = sample.int(3L * n, n) + 0,                       # double, like bu_sn
    prov        = sample(provs, n, TRUE, prov_p),
    postal_code = sample(c(pcs, NA), n, TRUE, c(rep(.98 / n_pc, n_pc), .02)),
    type_code   = sprintf("%02d", sample.int(13L, n, TRUE, c(60, 10, 8, 6, 4, 3, 3, 2, 1, 1, 1, .5, .5))),
    status      = sample(c("A", "S"), n, TRUE, c(.92, .08)),
    inc_sef     = if_else(runif(n) < .3, NA_integer_, as.integer(round(rlnorm(n, 11, .7)))),
    start_date  = as.Date("1995-01-01") + sample.int(11000L, n, TRUE),
    hh_size     = as.integer(rpois(n, 1.5) + 1L),
    weight      = round(runif(n, 10, 500), 2)
  )
  tax <- units |> slice_sample(prop = .66) |>
    transmute(id, inc_t1 = if_else(runif(n()) < .02, NA_integer_, as.integer(round(rlnorm(n(), 11.2, .8)))))
  n_p <- 2L * n
  persons <- tibble(
    id        = c(sample(units$id[runif(n) < .9], n_p - n %/% 50, TRUE), 3 * n + sample.int(n, n %/% 50, TRUE) + 0),
    person_id = sample.int(10L * n, n_p),
    age       = sample(15:99, n_p, TRUE),
    income    = if_else(runif(n_p) < .15, NA_integer_, as.integer(round(rlnorm(n_p, 10.4, .9))))
  )
  cmas <- c("000", sprintf("%03d", sample(1:999, 150)))
  geo <- tibble(
    postal_code = pcs[runif(n_pc) < .97],                           # 3% of postal codes not in the lookup
    csd = sprintf("%07d", sample.int(9999999L, length(postal_code), TRUE)),
    cma = sample(cmas, length(postal_code), TRUE, c(20, rep(80 / 150, 150)))
  )
  codes <- tibble(type_code = sprintf("%02d", 1:13), type_desc = paste("type", 1:13), excl = 1:13 %in% c(9, 12, 13))
  list(units = units, tax = tax, persons = persons, geo = geo, codes = codes)
}

data_dir <- function() {
  d <- Sys.getenv("BENCH_DATA", file.path(tempdir(), "bench-data"))
  dir.create(d, FALSE, TRUE)
  d
}
data_file <- \(n) file.path(data_dir(), sprintf("data_n%s.qs2", format(n, scientific = FALSE)))

ensure_data <- function(n) {
  f <- data_file(n)
  if (!file.exists(f)) qs2::qs_save(make_data(n), f, nthreads = 4L)
  f
}
load_data <- \(n) qs2::qs_read(ensure_data(n), nthreads = 4L)

data_mb <- \(d) round(sum(vapply(d, \(x) as.numeric(lobstr::obj_size(x)), 1)) / 1e6)
