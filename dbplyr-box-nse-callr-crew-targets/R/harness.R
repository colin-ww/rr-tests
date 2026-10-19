# probe(): evaluate an expression, capture value/SQL + warnings + messages + errors
# Records WHERE it failed: build (verb call) / render (SQL gen) / execute (DB run)
options(cli.num_colors = 1, width = 200)

squish <- \(x) x |> paste(collapse = " ") |> gsub(pattern = "\\s+", replacement = " ") |> trimws()
clip <- \(x, n = 300) if (!is.na(x) && nchar(x) > n) paste0(substr(x, 1, n), "...") else x
err_txt <- \(e) tryCatch(rlang::cnd_message(e, prefix = FALSE), error = \(.) conditionMessage(e)) |>
  cli::ansi_strip() |> squish()

compact_df <- \(df) {
  df <- if ("x" %in% names(df)) df["x"] else df
  df |> as.list() |> purrr::imap_chr(\(v, n) paste0(n, "=", paste(format(v), collapse = ","))) |>
    paste(collapse = "; ")
}

# NB: substitute(), not enexpr(): enexpr would eagerly process !! and {{ }} inside the probed code
probe <- function(part, case, expr, backend = "-", env = parent.frame())
  probe_expr(part, case, substitute(expr), backend, env)

probe_expr <- function(part, case, expr, backend = "-", env = parent.frame()) {
  warns <- msgs <- character()
  stage <- "build"; sql <- NA_character_
  value <- tryCatch(
    withCallingHandlers({
      res <- eval(expr, env)
      if (inherits(res, "tbl_lazy")) {
        stage <- "render"
        sql <- dbplyr::sql_render(res) |> squish()
        stage <- "execute"
        res <- dplyr::collect(res)
      }
      stage <- "ok"
      if (is.data.frame(res)) compact_df(res) else paste(deparse(res), collapse = "")
    },
    warning = \(w) { warns <<- c(warns, err_txt(w)); invokeRestart("muffleWarning") },
    message = \(m) { msgs <<- c(msgs, squish(cli::ansi_strip(conditionMessage(m)))); invokeRestart("muffleMessage") }),
    error = \(e) paste0("ERROR: ", err_txt(e))
  )
  tibble::tibble(
    part = part, case = case, backend = backend,
    code = clip(squish(deparse(expr)), 200),
    outcome = dplyr::case_when(startsWith(value, "ERROR") ~ "error", length(warns) > 0 ~ "warning", TRUE ~ "ok"),
    failed_at = if (startsWith(value, "ERROR")) stage else NA_character_,
    value = clip(value), sql = clip(sql, 400),
    warnings = clip(paste(warns, collapse = " || ")), messages = clip(paste(msgs, collapse = " || "))
  )
}

# run the same `d`-based expression against tibble / duckdb / sqlite
probe_bk <- function(part, case, expr, env = parent.frame()) {
  expr <- substitute(expr)
  purrr::imap(backends(), \(d, bk)
    probe_expr(part, case, expr, bk, rlang::new_environment(list(d = d), parent = env))
  ) |> purrr::list_rbind()
}

setup_backends <- function() {
  df <- tibble::tibble(var1 = c(1, 2, 3), name = c("alpha", "beta", "gamma"),
                       dt = as.Date("2024-01-01") + 0:2)
  con_d <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE)); con_s <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  dplyr::copy_to(con_d, df, "df"); dplyr::copy_to(con_s, df, "df")
  function() list(tibble = df, duckdb = dplyr::tbl(con_d, "df"), sqlite = dplyr::tbl(con_s, "df"))
}

save_results <- \(res, file) readr::write_csv(res, file.path("results", file))
