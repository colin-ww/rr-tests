#### backends.R  -  one place that knows how to put a data frame INTO a backend and get a tibble OUT ####
# Two kinds of backend:
#   "same code"  the task functions in tasks.R run unchanged. Either dplyr dispatches on the object's class
#                (dtplyr, duckplyr, dbplyr, arrow, tidypolars, multidplyr), or the bare verb names are re-bound
#                to another package's versions (tidytable, poorman, fastplyr, collapse masking).
#   "native"     hand-written data.table / collapse code (tasks_native.R). Not a backend: a rewrite.

suppressPackageStartupMessages({ library(dplyr) })

# every bare name the task functions use; re-bound per backend by with_verbs()
VERBS <- c("mutate", "summarise", "group_by", "ungroup", "filter", "left_join", "inner_join", "arrange", "desc",
           "select", "distinct", "count", "n", "n_distinct", "if_else", "case_when", "coalesce", "row_number",
           "transmute", "rename", "slice_max", "across", "pull", "tally")

BACKENDS <- c(
  # same code, dispatch on class
  "dplyr", "dtplyr", "duckplyr", "dbplyr_duckdb", "arrow", "tidypolars", "multidplyr",
  # same code, verbs re-bound
  "tidytable", "fastplyr", "collapse_mask", "poorman",
  # native rewrites / hybrid
  "data.table", "collapse", "dplyr+collapse"
)
SAME_CODE <- BACKENDS[1:11]

# grouping style the "same code" tasks are run in. tasks.R is written with group_by() ... ungroup();
# ".by" rewrites that to verb(..., .by = ) (the user's own style). duckplyr ONLY stays in DuckDB with .by.
# poorman and collapse's fsummarise() do not error on .by: they silently add a column called ".by" (01-semantics.R),
# so they get group_by; multidplyr needs group_by() to partition.
STYLE <- c(multidplyr = "group_by", poorman = "group_by", collapse_mask = "group_by")
style_for <- \(bk) Sys.getenv("BENCH_STYLE", if (bk %in% names(STYLE)) STYLE[[bk]] else ".by")

# ungroup(V2(V1(group_by(D, G1, G2), a1), a2))  ->  V2(V1(D, a1, .by = c(G1, G2)), a2, .by = c(G1, G2))
to_by <- function(e) {
  if (!is.call(e)) return(e)
  if (identical(e[[1]], quote(ungroup))) {
    chain <- list(); x <- e[[2]]
    while (is.call(x) && !identical(x[[1]], quote(group_by))) { chain <- c(list(x), chain); x <- x[[2]] }
    if (is.call(x)) {
      data <- to_by(x[[2]]); keys <- as.list(x)[-(1:2)]
      by <- if (length(keys) == 1) keys[[1]] else as.call(c(quote(c), keys))
      for (v in chain) { v <- as.call(lapply(v, to_by)); v[[2]] <- data; v$.by <- by; data <- v }
      return(data)
    }
  }
  as.call(lapply(e, to_by))
}
task_fun <- function(f, bk, style = style_for(bk)) {
  if (style == ".by") body(f) <- to_by(body(f))
  with_verbs(f, bk)
}
backend_kind <- \(bk) if (bk %in% SAME_CODE) "same dplyr code" else if (bk == "dplyr+collapse") "dplyr + collapse fns" else "native rewrite"

threads <- function() as.integer(Sys.getenv("BENCH_THREADS", parallel::detectCores()))

# start the engine once per process (threads, connections, clusters, masks)
setup_backend <- function(bk) {
  nt <- threads()
  switch(bk,
    dtplyr = , data.table = , tidytable = data.table::setDTthreads(nt),
    duckplyr = {
      # NOT library(duckplyr): attaching it overwrites dplyr's methods for every data frame.
      # Env vars instead of fallback_config(), which writes a file under ~/.config.
      Sys.setenv(DUCKPLYR_FALLBACK_INFO = "TRUE", DUCKPLYR_FALLBACK_COLLECT = "0", DUCKPLYR_FALLBACK_AUTOUPLOAD = "0")
      duckplyr::db_exec(sprintf("SET threads = %d", nt))
    },
    dbplyr_duckdb = { .bk$con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); DBI::dbExecute(.bk$con, sprintf("SET threads = %d", nt)) },
    arrow = { arrow::set_cpu_count(nt); arrow::set_io_thread_count(max(2L, nt)) },
    tidypolars = {
      # polars reads POLARS_MAX_THREADS at load time only
      Sys.setenv(POLARS_MAX_THREADS = nt)
      suppressPackageStartupMessages({ library(polars); library(tidypolars) })
    },
    multidplyr = {
      .bk$cl <- multidplyr::new_cluster(nt)
      suppressMessages(multidplyr::cluster_library(.bk$cl, c("dplyr", "stringr", "lubridate")))
    },
    collapse = , `dplyr+collapse` = collapse::set_collapse(nthreads = nt),
    collapse_mask = {
      # mask only works on the ATTACHED package (it re-attaches collapse at the top of the search path)
      suppressPackageStartupMessages(library(collapse, warn.conflicts = FALSE))
      collapse::set_collapse(nthreads = nt, mask = c("manip", "helper", "special", "fast-stat-fun"))
    },
    NULL
  )
  invisible(bk)
}
.bk <- new.env()

# data frame -> backend object (timed separately as "convert")
to_backend <- function(df, bk, name = "t", partition_by = NULL) {
  switch(bk,
    dtplyr        = dtplyr::lazy_dt(df),
    duckplyr      = duckplyr::as_duckdb_tibble(df),
    dbplyr_duckdb = { dplyr::copy_to(.bk$con, df, name, temporary = TRUE, overwrite = TRUE); dplyr::tbl(.bk$con, name) },
    arrow         = arrow::as_arrow_table(df),
    tidypolars    = polars::as_polars_lf(df),
    multidplyr    = if (is.null(partition_by)) NULL else df |> group_by(across(all_of(partition_by))) |> multidplyr::partition(.bk$cl),
    tidytable     = tidytable::as_tidytable(df),
    data.table    = data.table::as.data.table(df),
    poorman       = as.data.frame(df),
    df            # dplyr, fastplyr, collapse*, dplyr+collapse: a plain tibble
  )
}

# backend object -> plain tibble (always part of the timed task: downstream code wants a tibble)
to_tibble <- function(x) {
  # duckplyr hands back lazy ALTREP columns (DUCKDB_ALTREP_REL_VECTOR): the query only runs when a column is first
  # touched. Touch them all here, or the timing leaves out the actual work (10M-row join: 2 s "done", +10 s on first use).
  if (inherits(x, "duckplyr_df")) { x <- dplyr::collect(x); invisible(lapply(x, anyNA)) }
  if (inherits(x, c("tbl_lazy", "dtplyr_step", "multidplyr_party_df", "ArrowTabular", "arrow_dplyr_query")))
    x <- dplyr::collect(x)
  if (inherits(x, c("polars_lazy_frame", "polars_data_frame"))) x <- tibble::as_tibble(x)
  if (inherits(x, "grouped_df")) x <- dplyr::ungroup(x)
  tibble::as_tibble(as.data.frame(x))
}

# re-bind the bare verb names a task function uses, without touching the function body
verbs_for <- function(bk) {
  pick <- \(ns, names) { ex <- getNamespaceExports(ns); names <- intersect(names, ex); mget(names, envir = asNamespace(ns)) }
  base <- mget(VERBS, envir = asNamespace("dplyr"))
  # collapse masking: names collapse now exports (mutate, summarise, group_by, n, count, sum, mean, ...) must be
  # found on the search path, so don't bind them; the rest (filter, arrange, joins, case_when) stay dplyr's
  if (bk == "collapse_mask") return(base[setdiff(names(base), getNamespaceExports("collapse"))])
  over <- switch(bk,
    tidytable = pick("tidytable", VERBS),
    poorman   = pick("poorman", VERBS),
    fastplyr  = {
      f <- pick("fastplyr", paste0("f_", VERBS)); names(f) <- sub("^f_", "", names(f)); f
    },
    list()
  )
  utils::modifyList(base, over)
}
with_verbs <- function(f, bk) {
  e <- list2env(verbs_for(bk), parent = environment(f))
  environment(f) <- e
  f
}

pkg_versions <- function() {
  pk <- c("dplyr", "dtplyr", "data.table", "duckplyr", "duckdb", "dbplyr", "arrow", "polars", "tidypolars",
          "multidplyr", "tidytable", "fastplyr", "collapse", "poorman", "qs2", "callr")
  v <- vapply(pk, \(p) tryCatch(as.character(utils::packageVersion(p)), error = \(e) "-"), "")
  tibble::tibble(package = c("R", pk), version = c(paste(R.version$major, R.version$minor, sep = "."), v))
}
