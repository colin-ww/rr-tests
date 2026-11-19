# Part 5: after collect(), write the data to a file and read it back. Which format?
# Data: bm_mix_<n> collected from duckdb (10 typed columns, same values as on the servers), and two
# 1-column tables (all zeros / random 1-2 million) to see what compressibility does.
# Files go to BENCH_DIR/io: at StatCan run it once per disk (home PVC, /tmp, the filers).
# Per format: write_s, read_s (file in the OS page cache: "warm"), read_cold_s (file evicted from the
# page cache first with `dd iflag=nocache count=0`, no root needed), file size, which column types survive.
# Reads are timed until every value is a real R vector: arrow and vroom can hand back lazy (ALTREP)
# columns that are only filled in when touched, so `touch()` forces that inside the timing.
suppressPackageStartupMessages(library(dplyr))
for (f in c("R/connect.R", "R/make-data.R", "R/bench.R")) source(f)

spec <- readr::cols(id = "i", age = "i", income = "d", wgt = "d", ref_date = "D", flag = "l", amount = "d", .default = "c")
fmts <- tibble::tribble(
  ~format,                  ~ext,       ~write,                                                     ~read,
  "rds (gzip, default)",    "rds",      \(d, f) saveRDS(d, f),                                       \(f) readRDS(f),
  "rds (compress = FALSE)", "rds",      \(d, f) saveRDS(d, f, compress = FALSE),                     \(f) readRDS(f),
  "qs2 (1 thread)",         "qs2",      \(d, f) qs2::qs_save(d, f),                                  \(f) qs2::qs_read(f),
  "qs2 (4 threads)",        "qs2",      \(d, f) qs2::qs_save(d, f, nthreads = 4),                    \(f) qs2::qs_read(f, nthreads = 4),
  "parquet arrow (snappy)", "parquet",  \(d, f) arrow::write_parquet(d, f),                          \(f) arrow::read_parquet(f),
  "parquet arrow (zstd)",   "parquet",  \(d, f) arrow::write_parquet(d, f, compression = "zstd"),    \(f) arrow::read_parquet(f),
  "parquet nanoparquet",    "parquet",  \(d, f) nanoparquet::write_parquet(d, f),                    \(f) nanoparquet::read_parquet(f),
  "feather arrow (lz4)",    "feather",  \(d, f) arrow::write_feather(d, f),                          \(f) arrow::read_feather(f),
  "feather (uncompressed)", "feather",  \(d, f) arrow::write_feather(d, f, compression = "uncompressed"), \(f) arrow::read_feather(f),
  "csv readr",              "csv",      \(d, f) readr::write_csv(d, f),                              \(f) readr::read_csv(f, col_types = spec, progress = FALSE),
  "csv readr (guess types)","csv",      \(d, f) readr::write_csv(d, f),                              \(f) readr::read_csv(f, show_col_types = FALSE, progress = FALSE),
  "csv data.table",         "csv",      \(d, f) data.table::fwrite(d, f),                            \(f) data.table::fread(f),
  "csv.gz readr",           "csv.gz",   \(d, f) readr::write_csv(d, f),                              \(f) readr::read_csv(f, col_types = spec, progress = FALSE),
  "csv.gz data.table",      "csv.gz",   \(d, f) data.table::fwrite(d, f, compress = "gzip"),         \(f) data.table::fread(f))

datasets <- c(mix_1e6 = "bm_mix_1e6", mix_1e7 = "bm_mix_1e7", int_zero_1e7 = "bm_int_zero_1e7_1", int_rand_1e7 = "bm_int_rand_1e7_1")
io_dir <- fs::dir_create(file.path(bench_dir(), "io"))

load_data <- \(con, table, ...) { d <- bench_con("duckdb"); on.exit(DBI::dbDisconnect(d)); tbl(d, table) |> collect() }
touch <- \(d) { for (j in seq_along(d)) d[[j]] <- d[[j]][seq_len(nrow(d))]; d }
evict <- \(con, file, ...) invisible(system2("dd", c(paste0("if=", file), "iflag=nocache", "count=0", "status=none")))
class1 <- \(d) purrr::map_chr(d, \(v) class(v)[1])

res <- purrr::imap(datasets, \(table, ds) {
  orig <- load_data(NULL, table) |> class1()
  purrr::pmap(fmts, \(format, ext, write, read) {
    file <- file.path(io_dir, paste0(ds, "-", gsub("\\W+", "_", format), ".", ext))
    g <- list(write = write, read = read, touch = touch, spec = spec)
    w <- run_case("none", \(con, data, file, table) write(data, file), list(file = file, table = table), setup = load_data,
                  globals = g, iterations = 3, dataset = ds, format = format, step = "write")
    if (!file.exists(file)) return(w)
    size <- file.size(file) / 1e6
    r_warm <- run_case("none", \(con, file, table) touch(read(file)), list(file = file, table = table), globals = g,
                       iterations = 3, dataset = ds, format = format, step = "read (warm cache)")
    r_cold <- run_case("none", \(con, file, table) touch(read(file)), list(file = file, table = table), globals = g,
                       before = evict, iterations = 3, dataset = ds, format = format, step = "read (cold cache)")
    got <- class1(read(file))
    lost <- names(orig)[orig != got[names(orig)]]
    unlink(file)
    bind_rows(w, r_warm, r_cold) |>
      mutate(size_mb = size, types_changed = if (length(lost)) paste0(lost, ": ", orig[lost], "->", got[lost], collapse = "; ") else "")
  }) |> purrr::list_rbind()
}) |> purrr::list_rbind()
save_results(res, "05-io.csv")
