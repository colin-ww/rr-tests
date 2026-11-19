# Connections. One environment variable per engine, holding a full ODBC connection string.
# Put them in ~/.Renviron (never in git). An engine whose variable is unset is skipped.
#   BENCH_MSSQL  = "Driver={ODBC Driver 18 for SQL Server};Server=myhost,1433;Database=mydb;Trusted_Connection=yes"
#   BENCH_ORACLE = "Driver={Oracle 21 ODBC driver};DBQ=myhost:1521/myservice;UID=me;PWD=..."
#   (or "DSN=my_dsn" for either)
#   BENCH_RORACLE = "username=me;password=...;dbname=myhost:1521/myservice"   (ROracle: Oracle without ODBC,
#   reads the same tables as `oracle`; needs the ROracle package + Oracle Instant Client)
# Oracle (odbc and ROracle): set NLS_LANG=AMERICAN_AMERICA.AL32UTF8 (in ~/.Renviron). Without it the
#   Instant Client converts text to ASCII: odbc returns "Quebec" for 'Québec', ROracle "Qu??bec".
# duckdb (in-process: no driver, no network) is always on. It is the floor: what R itself costs.
# BENCH_DIR = folder for the duckdb file and the files written in part 04 (default ./bench-data).
#   At StatCan point it at the disk you want to test: home PVC, /tmp (pod-local), the filers.

bench_dir <- \() Sys.getenv("BENCH_DIR", "bench-data") |> fs::dir_create()

conn_vars <- c(mssql = "BENCH_MSSQL", oracle = "BENCH_ORACLE", roracle = "BENCH_RORACLE")
# BENCH_ENGINES = "mssql,oracle" to run only some of them
engines <- \() conn_vars |> purrr::keep(\(v) nzchar(Sys.getenv(v))) |> names() |> c("duckdb") |>
  intersect(strsplit(Sys.getenv("BENCH_ENGINES", "mssql,oracle,roracle,duckdb"), ",")[[1]])
# engines that hold their own tables (roracle reads oracle's)
db_engines <- \() setdiff(engines(), "roracle")
dialect_of <- \(engine) if (engine == "roracle") "oracle" else engine

# extra = more "key=value;" pairs appended to the connection string (e.g. Oracle "FBS=1000000;").
# ... = passed to dbConnect() (e.g. odbc interruptible = TRUE, ROracle bulk_read = 10000L)
bench_con <- function(engine, extra = "", ...) {
  if (engine == "duckdb") return(DBI::dbConnect(duckdb::duckdb(dbdir = file.path(bench_dir(), "bench.duckdb"), shared_home = FALSE)))
  if (engine == "roracle") {
    kv <- strsplit(strsplit(Sys.getenv("BENCH_RORACLE"), ";")[[1]], "=", fixed = TRUE) |>
      purrr::map(\(x) setNames(list(paste(x[-1], collapse = "=")), trimws(x[1]))) |> purrr::list_flatten()
    return(DBI::dbConnect(ROracle::Oracle(), username = kv$username, password = kv$password, dbname = kv$dbname, ...))
  }
  cs <- Sys.getenv(conn_vars[[engine]])
  DBI::dbConnect(odbc::odbc(), .connection_string = paste0(cs, if (nzchar(extra) && !endsWith(cs, ";")) ";", extra), ...)
}

# NB odbc::dbConnect(interruptible = interactive()) is TRUE in RStudio, FALSE in Rscript/callr.
# 00-method.R checks whether that changes collect speed.
