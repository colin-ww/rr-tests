# R/compare.R: cell statuses (fixtures) and table verdicts (inline tables)

tbl_n <- \(k, n) tibble::tibble(k = k, n = n)

test_that("compare_tbl(): kind, bucket and status per cell", {
  expect_equal(
    compare_tbl(sas = read_fixture("sas_tbl"), r = read_fixture("r_tbl"), keys = "grp") |> dplyr::select(key, col, kind, bucket, status),
    read_fixture("expected/compare_tbl")
  )
})

test_that("compare_tbl(): keys must identify rows", {
  expect_error(compare_tbl(sas = tbl_n(c("a", "a"), 1:2), r = tbl_n("a", 1), keys = "k"), "one-to-one|multiple")
})

test_that("compare_tbl(): text cells, and NA on one side", {
  out <- compare_tbl(
    sas = tibble::tibble(k = c("v", "w", "x"), value = c("2021", "1", NA)),
    r   = tibble::tibble(k = c("v", "w", "x"), value = c("2026/2021", NA, "1")),
    keys = "k"
  )
  expect_equal(out$status, c("text", "na in r", "na in sas"))
})

test_that("compare_all(): verdict rules", {
  big   <- tbl_n(letters[1:10], rep(10000, 10))                 # 100,000 units in 10 rows
  plus1 <- \(n) dplyr::bind_rows(big, tbl_n("z", n))            # + 1 row only in R: 9% of rows
  out <- compare_all(
    sas = list(same = big, off = big |> dplyr::mutate(n = n - (k == "a") * 1001), rows = big, rows_known = big, units = big, no_r = big),
    r   = list(same = big, off = big,                                             rows = plus1(1), rows_known = plus1(1), units = plus1(500), no_sas = big),
    keys = "k",
    known_diffs = c(rows_known = "why", units = "why")
  )
  expect_equal(
    out$summ |> dplyr::select(obj, verdict),
    tibble::tibble(
      obj     = c("same", "off", "rows", "rows_known", "units", "no_sas", "no_r"),
      verdict = c("ok",   "RED", "RED",  "minor",      "RED",   "no SAS", "missing in R") # units: 500 / 100,000 = 0.5% > 0.1%, known or not
    )
  )
})

test_that("compare_all(): total rows aren't counted as units", {
  sas <- tbl_n(c("a", "b", "total"), c(600, 400, 1000))
  out <- compare_all(sas = list(t = sas), r = list(t = dplyr::bind_rows(sas, tbl_n("c", 1))), keys = "k")
  expect_equal(out$summ$unmatched_pct, 100 * 1 / 1000)
})

test_that("match_types(): SAS cols get R's types; 0/1 -> lgl for numeric cols only", {
  out <- match_types(
    sas = tibble::tibble(flag = c(0, 1), code = c(1, 23), n = c(5, 6), lbl = c("Reserve", NA)),
    r   = tibble::tibble(flag = TRUE,    code = "01",     n = 1L,      lbl = TRUE)
  )
  expect_equal(out, tibble::tibble(flag = c(FALSE, TRUE), code = c("1", "23"), n = c(5L, 6L), lbl = c("Reserve", NA)))
})

test_that("sort_like(): SAS rows in R's order, SAS-only rows last", {
  expect_equal(sort_like(sas = tbl_n(c("x", "b", "a"), 1:3), r = tbl_n(c("a", "b"), 1:2), keys = "k")$k, c("a", "b", "x"))
})
