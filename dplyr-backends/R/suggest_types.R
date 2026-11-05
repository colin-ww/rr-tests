#### suggest_types.R  -  "is my schema wasteful?" Report, never convert behind your back ####
# Nothing in dplyr or its backends warns about a wasteful schema (01-semantics.R, 04-schema.R). Type guessers exist
# (utils::type.convert, readr::type_convert, hablar::retype, fread, DuckDB/arrow/polars CSV readers), but they
# CONVERT, and "01" -> 1 loses the leading zero of a code. This helper only reports, per column:
#   current class, % NA, n distinct, MB now, a suggested class + why, MB after, and the line of code to do it.
# Prints NO values (safe to share for real data; same idea as the frame repo's dev/speed-up schema_report.R).
#
#   suggest_types(df)                 # tibble, one row per column, biggest savings first
#   suggest_types(df, code = TRUE)    # also prints a mutate() call with the suggested conversions
#
# Rules (deliberately conservative):
#   chr, all digits, some with a leading zero  -> keep chr (a code: "01", postal/SIN-like ids); factor if few distinct
#   chr, all digits, no leading zero, fits int -> integer      (> int range -> double)
#   chr, decimal numbers                       -> double
#   chr, all YYYY-MM-DD                        -> Date
#   chr, exactly 2 values like Y/N, T/F, 0/1   -> logical
#   chr, few distinct (<= max_levels)          -> factor
#   dbl, all whole numbers within int range    -> integer
#   int/dbl, only 0/1                          -> logical

suggest_types <- function(df, max_levels = 1000, sample_n = 1e5, code = FALSE) {
  df <- as.data.frame(df)
  n <- nrow(df)
  mb <- \(x) as.numeric(lobstr::obj_size(x)) / 1e6
  int_ok <- \(x) all(abs(x) <= .Machine$integer.max, na.rm = TRUE)

  one <- function(x, nm) {
    cls <- class(x)[1]
    nd  <- collapse::fndistinct(x)
    v   <- x[!is.na(x)]
    s   <- if (length(v) > sample_n) v[sample.int(length(v), sample_n)] else v   # rules checked on a sample, then confirmed on all
    sug <- cls; why <- ""; conv <- NULL
    if (is.character(x) && length(v)) {
      all_on <- \(re) all(grepl(re, s)) && all(grepl(re, v))
      if (all_on("^-?[0-9]+$")) {
        if (any(grepl("^-?0[0-9]", v))) {
          sug <- if (nd <= max_levels) "factor" else "character"
          why <- "digits WITH leading zeros: a code, not a number (as.integer would drop the zeros)"
          conv <- if (sug == "factor") "factor({nm})"
        } else if (int_ok(as.numeric(v))) {
          sug <- "integer"; why <- "all digits, fits integer"; conv <- "as.integer({nm})"
        } else {
          sug <- "double"; why <- "all digits, too big for integer (an id? keep chr if it is never used as a number)"; conv <- "as.numeric({nm})"
        }
      } else if (all_on("^-?[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?$")) {
        sug <- "double"; why <- "decimal numbers"; conv <- "as.numeric({nm})"
      } else if (all_on("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") && !anyNA(as.Date(v, optional = TRUE))) {
        sug <- "Date"; why <- "all YYYY-MM-DD"; conv <- "as.Date({nm})"
      } else if (nd == 2 && all(toupper(unique(v)) %in% c("Y", "N", "YES", "NO", "T", "F", "TRUE", "FALSE", "0", "1"))) {
        sug <- "logical"; why <- sprintf("2 values: %s", "Y/N-like"); conv <- "toupper({nm}) %in% c('Y', 'YES', 'T', 'TRUE', '1')"
      } else if (nd <= max_levels) {
        sug <- "factor"; why <- sprintf("%d distinct values", nd); conv <- "factor({nm})"
      }
    } else if (is.double(x) && !inherits(x, c("Date", "POSIXt", "difftime")) && length(v)) {
      if (all(v %in% c(0, 1))) { sug <- "logical"; why <- "only 0/1"; conv <- "{nm} == 1" }
      else if (all(v == trunc(v)) && int_ok(v)) { sug <- "integer"; why <- "whole numbers within integer range"; conv <- "as.integer({nm})" }
    } else if (is.integer(x) && !is.factor(x) && length(v) && all(v %in% 0:1)) {
      sug <- "logical"; why <- "only 0/1"; conv <- "{nm} == 1L"
    }
    conv <- if (!is.null(conv)) gsub("{nm}", if (make.names(nm) == nm) nm else sprintf("`%s`", nm), conv, fixed = TRUE)
    after <- if (!is.null(conv)) mb(eval(str2lang(conv), list2env(stats::setNames(list(x), nm)))) else mb(x)
    tibble::tibble(column = nm, class = cls, pct_na = round(100 * mean(is.na(x)), 1), n_distinct = nd,
                   mb_now = round(mb(x), 1), suggest = sug, mb_after = round(after, 1), why = why,
                   code = if (is.null(conv)) NA_character_ else sprintf("%s = %s", nm, conv))
  }
  out <- purrr::imap(df, one) |> purrr::list_rbind()
  out <- out[order(out$mb_after - out$mb_now), ]
  if (code) {
    todo <- out$code[!is.na(out$code)]
    cat(if (length(todo)) paste0("mutate(\n  ", paste(todo, collapse = ",\n  "), "\n)\n") else "# nothing to convert\n")
    cat(sprintf("# %.1f MB -> %.1f MB\n", sum(out$mb_now), sum(out$mb_after)))
  }
  out
}
