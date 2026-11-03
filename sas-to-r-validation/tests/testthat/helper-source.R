# source the code under test (test_dir() runs from tests/testthat/, hence test_path())
source(test_path("..", "..", "R", "compare.R"))

# fixtures/*.csv: all cols read as chr (compare_tbl() compares strings anyway). `note` col = what the row tests, for humans only
read_fixture <- \(name)
  readr::read_csv(test_path("fixtures", paste0(name, ".csv")), col_types = readr::cols(.default = "c"), na = "") |>
    dplyr::select(!dplyr::any_of("note"))
