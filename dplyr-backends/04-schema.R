#### 04-schema.R  -  "everything is a string" data: what do the type guessers do, and what does suggest_types() say? ####
# The schema question: does any backend warn about / fix chr columns that could be int, factor, Date ...?
#   1. In-memory guessers on an all-chr data frame: utils::type.convert, readr::type_convert, hablar::retype
#   2. CSV readers with type guessing: readr, data.table::fread, arrow, DuckDB (duckplyr), polars
#   4. suggest_types() (R/suggest_types.R): reports only, keeps codes with leading zeros as codes
# For each: the class it gives each column, and whether codes with leading zeros SURVIVE ("01" stays "01").
# Output: results/04-schema.csv, results/04-suggest-types.csv
#   Rscript 04-schema.R      # ~20 s

suppressPackageStartupMessages({ library(dplyr); library(polars) })
source("R/suggest_types.R")
set.seed(4)
n <- 1e6

# the StatCan classic: every column read as character "to avoid parser guessing"
chr_df <- tibble(
  sin_like  = sprintf("%09d", sample.int(999999999L, n)),           # id with leading zeros (some start with 0)
  type_code = sprintf("%02d", sample.int(13L, n, TRUE)),             # code "01".."13"
  prov      = as.character(sample(c(10L, 24L, 35L, 48L, 59L), n, TRUE)),
  count     = as.character(rpois(n, 2)),
  amount    = sprintf("%.2f", runif(n, 0, 5000)),
  flag      = sample(c("Y", "N"), n, TRUE),
  ref_date  = format(as.Date("2020-01-01") + sample.int(2000L, n, TRUE)),
  status    = sample(c("A", "S", "T"), n, TRUE),
  big_id    = sprintf("%.0f", 1e10 + sample.int(1e9, n)),              # > integer max, no leading zero. NB as.character() gives "1.0377e+10" for round values
  weight    = as.character(sample.int(500L, n, TRUE))
)
# and two numeric-but-wasteful ones
num_df <- tibble(whole_dbl = as.numeric(sample.int(500L, n, TRUE)), dummy_dbl = as.numeric(sample(0:1, n, TRUE)))

## 1-3. what the guessers make of it ----
csv <- tempfile(fileext = ".csv"); readr::write_csv(chr_df, csv)
tools <- list(
  `utils::type.convert`      = \() utils::type.convert(chr_df, as.is = TRUE),
  `readr::type_convert`      = \() readr::type_convert(chr_df),
  `hablar::retype`           = \() hablar::retype(chr_df),
  `readr::read_csv`          = \() readr::read_csv(csv, show_col_types = FALSE),
  `data.table::fread`        = \() data.table::fread(csv),
  `arrow::read_csv_arrow`    = \() arrow::read_csv_arrow(csv),
  `duckplyr::read_csv_duckdb` = \() duckplyr::read_csv_duckdb(csv) |> collect(),
  `polars read_csv`          = \() pl$read_csv(csv) |> as.data.frame(),
  `suggest_types (report)`   = \() suggest_types(chr_df)    # a report: one row per column, "suggest" = the class it proposes
)
kept <- \(orig, new) { new <- as.character(if (is.factor(new)) as.character(new) else new); isTRUE(all(new == orig, na.rm = TRUE)) && length(new) == length(orig) }
guess <- purrr::imap(tools, \(f, tool) {
  r <- tryCatch(suppressMessages(suppressWarnings(f())), error = \(e) e)
  if (inherits(r, "error")) { message(tool, ": ", conditionMessage(r)); return(tibble(tool = tool, column = names(chr_df), class = "ERROR", zeros_kept = NA)) }
  if (tool == "suggest_types (report)")
    return(tibble(tool = tool, column = r$column, class = r$suggest, zeros_kept = ifelse(r$column %in% c("sin_like", "type_code"), TRUE, NA)) |>
             slice(match(names(chr_df), column)))
  r <- as.data.frame(r)
  zk <- if (tool == "suggest_types (report)") c(sin_like = TRUE, type_code = TRUE)[names(chr_df)]   # it never converts; it keeps codes as codes
        else vapply(names(chr_df), \(nm) if (nm %in% c("sin_like", "type_code")) kept(chr_df[[nm]], r[[nm]]) else NA, NA)
  tibble(tool = tool, column = names(chr_df), class = vapply(r[names(chr_df)], \(v) class(v)[1], ""), zeros_kept = unname(zk))
}) |> purrr::list_rbind()
guess_wide <- guess |>
  mutate(cell = if_else(!is.na(zeros_kept) & !zeros_kept, paste0(class, " (zeros LOST)"), class)) |>
  select(tool, column, cell) |> tidyr::pivot_wider(names_from = column, values_from = cell)
cat("\n== what each tool turns an all-character table into ==\n"); print(as.data.frame(guess_wide), right = FALSE)

# (py-polars has Expr.shrink_dtype() to downcast numerics; r-polars 2.0 does not have it)

## 4. suggest_types() on the all-chr table + the wasteful numerics ----
cat("\n== suggest_types() ==\n")
sug <- suggest_types(bind_cols(chr_df, num_df), code = TRUE)
print(as.data.frame(sug |> select(-code)), right = FALSE)

readr::write_csv(guess, "results/04-schema.csv")
readr::write_csv(sug, "results/04-suggest-types.csv")
cat("\nwrote results/04-schema.csv, results/04-suggest-types.csv\n")
