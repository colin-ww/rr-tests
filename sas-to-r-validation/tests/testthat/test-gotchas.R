# One test per gotcha in ../../README.md, run on the installed versions.
# If a package upgrade changes one, update the README.
suppressPackageStartupMessages(library(dplyr))

units <- tibble(type = c("a", "a", "a", "b"), id = c("1", "1", "2", "3")) # 4 units, 3 (type, id) groups

sqlite <- \() {
  con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  withr::defer(DBI::dbDisconnect(con), envir = parent.frame())
  con
}


## counting ####

test_that("count() on a counted table counts groups, not units: needs wt = n", {
  counted <- units |> count(type, id)
  expect_equal(counted |> count(type) |> pull(n),         c(2, 1))
  expect_equal(counted |> count(type, wt = n) |> pull(n), c(3, 1))
})

test_that("same on a database: COUNT(*) over the grouped subquery, like the SAS PROC SQL version", {
  counted <- copy_to(sqlite(), units) |> count(type, id)
  expect_equal(counted |> count(type) |> pull(n),         c(2, 1))
  expect_equal(counted |> count(type, wt = n) |> pull(n), c(3, 1))
  sql <- counted |> count(type) |> dbplyr::sql_render()
  expect_match(sql, "COUNT(*)", fixed = TRUE)
  expect_match(sql, "FROM (",   fixed = TRUE)
})

test_that("starts_with() also picks up an id col with the same prefix: 1 group per id", {
  d <- tibble(geo_type = c("A", "A", "B"), geo_uid = c("1", "2", "3"))
  expect_equal(nrow(d |> count(across(starts_with("geo")))),                      3)
  expect_equal(nrow(d |> count(across(starts_with("geo") & !ends_with("_uid")))), 2)
})


## types ####

test_that("recode_values() on a factor errors if a key isn't a level; as.character() first works", {
  f <- factor(c("a", "b"))
  expect_error(recode_values(f, "a" ~ "A", "b" ~ "B", "c" ~ "C"), "loss of generality")
  expect_equal(recode_values(as.character(f), "a" ~ "A", "b" ~ "B", "c" ~ "C"), c("A", "B"))
})

test_that("as.logical() on strings: '1', '0' and other text are NA, silently", {
  expect_no_warning(out <- as.logical(c("1", "0", "TRUE", "T", "Reserve")))
  expect_equal(out, c(NA, NA, TRUE, TRUE, NA))
  expect_equal(as.logical(c(1, 0)), c(TRUE, FALSE))
})

test_that("as.character() of numbers can give 1e+05; sprintf('%.15g') doesn't", {
  expect_equal(as.character(c(1e5, 123456)), c("1e+05", "123456"))
  expect_equal(sprintf("%.15g", c(1e5, 123456, 0.1 + 0.2)), c("100000", "123456", "0.3"))
})


## joins / merges ####

test_that("left_join(unmatched = 'error') checks y only; inner_join(unmatched = c('error', 'drop')) checks x", {
  x <- tibble(id = 1:3)
  y <- tibble(id = 1:2, v = 1:2)
  expect_no_error(left_join(x, y, by = "id", unmatched = "error"))                  # x row 3 kept with NA v
  expect_error(left_join(y, x, by = "id", unmatched = "error"), "Each row of `y` must be matched")
  expect_error(inner_join(x, y, by = "id", unmatched = c("error", "drop")), "Each row of `x` must have a match")
})

test_that("SAS MERGE vs UPDATE in R: a missing value in the later table overwrites (rows_update), coalesce() keeps the old", {
  old <- tibble(id = 1:2, v = c(1, 2))
  new <- tibble(id = 1:2, v = c(NA, 20))
  expect_equal(rows_update(old, new, by = "id")$v, c(NA, 20))                                          # ~ SAS MERGE, 1:1
  expect_equal(old |> left_join(new, by = "id") |> mutate(v = coalesce(v.y, v.x)) |> pull(v), c(1, 20)) # ~ SAS UPDATE
})

test_that("waldo compares by position: 1 extra row and both columns 'differ'; compare_tbl() finds the 1 row", {
  sas <- tibble(k = c("a", "c"), n = c(1, 3))
  r   <- tibble(k = c("a", "b", "c"), n = c(1, 2, 3))
  expect_true(any(grepl("old$n", waldo::compare(sas, r), fixed = TRUE)))
  expect_equal(compare_tbl(sas, r, "k") |> filter(status != "ok") |> pull(key), "k=b")
})


## local test databases ####

test_that("SQLite: ATTACH ':memory:' AS a schema, then schema.table names work like on the server", {
  con <- sqlite()
  DBI::dbExecute(con, "ATTACH ':memory:' AS myschema")
  DBI::dbWriteTable(con, DBI::Id(schema = "myschema", table = "units"), units)
  for (nm in list(I("myschema.units"), dbplyr::in_schema("myschema", "units"), DBI::Id(schema = "myschema", table = "units")))
    expect_equal(tbl(con, nm) |> collect() |> nrow(), 4)
})

test_that("duckdb 2.0.0: CREATE SCHEMA works, but only DBI::Id() reads it; I() and in_schema() error", {
  skip_if(packageVersion("duckdb") < "2.0.0")
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  withr::defer(DBI::dbDisconnect(con))
  DBI::dbExecute(con, "CREATE SCHEMA myschema")
  DBI::dbWriteTable(con, DBI::Id(schema = "myschema", table = "units"), units)
  expect_equal(tbl(con, DBI::Id(schema = "myschema", table = "units")) |> collect() |> nrow(), 4)
  expect_error(tbl(con, I("myschema.units")),                  "AsIs")
  expect_error(tbl(con, dbplyr::in_schema("myschema", "units")), "single name")
})
