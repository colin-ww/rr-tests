#### run_one.R  -  run ONE (backend, task, n) in THIS process; called in a fresh callr process by 02-bench.R ####
# fresh process per combination: no state leaks between backends (duckplyr methods, collapse masks, threads),
# and the peak RAM (VmHWM, reset after loading the data) belongs to that combination alone.

options(dplyr.summarise.inform = FALSE)
FALLBACK_RE <- "fallback|falling back|pulling data into R|not supported in Arrow"
rss_mb  <- \(field = "VmRSS") as.numeric(sub("\\D*(\\d+).*", "\\1", grep(field, readLines("/proc/self/status"), value = TRUE))) / 1024
reset_peak <- \() try(writeLines("5", "/proc/self/clear_refs"), silent = TRUE)

# backend-neutral copy for comparing values: plain data.frame, columns by name, factors -> chr,
# int/int64/Date/difftime -> double, rows sorted unless order matters
normalize <- function(x, key = NULL, ordered = FALSE) {
  x <- as.data.frame(x)
  x <- x[sort(names(x))]
  x[] <- lapply(x, \(v) {
    if (is.factor(v)) v <- as.character(v)
    if (inherits(v, c("integer64", "Date", "difftime")) || is.integer(v)) v <- as.numeric(unclass(v))
    attributes(v) <- NULL
    v
  })
  if (!ordered) x <- x[do.call(order, c(unname(as.list(x[if (length(key)) key else names(x)])), method = "radix")), , drop = FALSE]
  rownames(x) <- NULL
  x
}
# column by column: identical() is fast (strings are compared by pointer); doubles get a 1e-9 tolerance
same_df <- function(a, b) {
  identical(names(a), names(b)) && nrow(a) == nrow(b) &&
    all(vapply(names(a), \(nm) {
      x <- a[[nm]]; y <- b[[nm]]
      identical(x, y) || (is.double(x) && is.double(y) && isTRUE(all.equal(x, y, tolerance = 1e-9)))
    }, NA))
}
col_types <- \(x) vapply(x, \(v) class(v)[1], "")
type_diff <- function(ref, new) {
  common <- intersect(names(ref), names(new))
  d <- common[ref[common] != new[common]]
  c(if (length(d)) sprintf("%s: %s->%s", d, ref[d], new[d]),
    if (length(setdiff(names(ref), names(new)))) paste("missing:", toString(setdiff(names(ref), names(new)))),
    if (length(setdiff(names(new), names(ref)))) paste("extra:", toString(setdiff(names(new), names(ref))))) |>
    paste(collapse = "; ")
}

run_one <- function(bk, task, n, reps = 3, budget = 30, root = ".") {
  for (f in c("data.R", "backends.R", "tasks.R", "tasks_native.R")) source(file.path(root, "R", f))
  if (bk %in% c("collapse", "dplyr+collapse")) suppressPackageStartupMessages(library(collapse, warn.conflicts = FALSE))
  tk  <- TASKS[[task]]
  style <- if (bk %in% SAME_CODE) style_for(bk) else "native"
  out <- list(backend = bk, kind = backend_kind(bk), style = style, task = task, n = n, threads = threads(), status = NA_character_,
              convert_s = NA_real_, secs = NA_real_, secs_all = NA_character_, base_mb = NA_real_, peak_mb = NA_real_,
              rows = NA_integer_, same_values = NA, type_diffs = NA_character_, fallbacks = 0L, note = NA_character_)

  has_impl <- if (bk %in% SAME_CODE) !(bk == "multidplyr" && is.null(tk$part)) else !is.null(NATIVE[[bk]][[task]])
  if (!has_impl) {
    out$status <- "n/a"
    out$note <- if (bk == "multidplyr") "needs one table partitioned by the group key" else "no grouped step: identical to dplyr"
    return(out)
  }

  setup_backend(bk)
  f <- if (bk %in% SAME_CODE) task_fun(tk$f, bk, style) else NATIVE[[bk]][[task]]   # after setup: collapse masks exist now
  raw <- load_data(n)[tk$needs]
  invisible(gc()); out$base_mb <- round(rss_mb()); reset_peak()

  msgs <- character()
  catch <- \(expr) withCallingHandlers(expr,
    warning = \(w) { msgs <<- c(msgs, paste("W:", conditionMessage(w))); invokeRestart("muffleWarning") },
    message = \(m) { msgs <<- c(msgs, paste("M:", conditionMessage(m))); invokeRestart("muffleMessage") })

  res <- tryCatch({
    t0 <- Sys.time()
    d <- catch(purrr::imap(raw, \(df, nm) {
      part <- if (bk == "multidplyr" && nm == tk$part[["table"]]) tk$part[["key"]]
      to_backend(df, bk, name = nm, partition_by = part)
    }))
    out$convert_s <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    times <- numeric()
    for (i in seq_len(reps)) {
      invisible(gc())
      t0 <- Sys.time()
      r <- catch(to_tibble(f(d)))
      times <- c(times, as.numeric(difftime(Sys.time(), t0, units = "secs")))
      if (base::sum(times) > budget) break
    }
    out$secs <- base::min(times); out$secs_all <- paste(round(times, 3), collapse = ";")
    r
  }, error = \(e) { out$status <<- "error"; out$note <<- substr(gsub("\\s+", " ", conditionMessage(e)), 1, 300); NULL })
  out$peak_mb <- round(rss_mb("VmHWM"))
  out$fallbacks <- base::sum(grepl(FALLBACK_RE, msgs, ignore.case = TRUE))
  if (length(msgs)) out$note <- paste(c(out$note[!is.na(out$note)], substr(unique(gsub("\\s+", " ", msgs)), 1, 160)) |> head(4), collapse = " | ")
  if (is.null(res)) return(out)

  # compare with the dplyr result for this (task, n); dplyr writes it
  out$rows <- nrow(res)
  ref_file <- file.path(data_dir(), sprintf("ref_n%s_%s.qs2", format(n, scientific = FALSE), task))   # dplyr's, either style
  nres <- normalize(res, tk$key, tk$ordered)
  if (bk == "dplyr" && style == ".by") {
    qs2::qs_save(list(values = nres, types = col_types(res)), ref_file)
    out$same_values <- TRUE; out$type_diffs <- ""
  } else if (file.exists(ref_file)) {
    ref <- qs2::qs_read(ref_file)
    eq <- same_df(ref$values, nres)
    out$same_values <- eq
    out$type_diffs <- type_diff(ref$types, col_types(res))
    if (!eq) {
      why <- if (!identical(names(ref$values), names(nres))) "different columns"
             else if (nrow(ref$values) != nrow(nres)) sprintf("%d rows vs dplyr %d", nrow(nres), nrow(ref$values))
             else paste(utils::head(all.equal(ref$values, nres, tolerance = 1e-9, check.attributes = FALSE), 2), collapse = "; ")
      out$note <- paste(c(paste("DIFFERS:", why), out$note[!is.na(out$note)]), collapse = " | ")
    }
  }
  out$status <- if (isFALSE(out$same_values)) "WRONG" else if (out$fallbacks > 0) "ok (fallback)" else "ok"
  out
}
