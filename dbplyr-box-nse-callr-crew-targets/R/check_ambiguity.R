# Opt-in "strict mode" for data masking: warn when a bare name in a dplyr/dbplyr expression is BOTH
# a column and a (non-function) object visible from where the code was written.
# Neither dplyr, dbplyr, rlang nor lintr does this (see 06-escape-hatches.R / README).
#   check_ambiguity(d, x = var1)          # warns, returns d invisibly
#   d |> mutate_chk(x = var1)             # check, then dplyr::mutate(); .error = TRUE errors instead
# Fix the warning by saying what you mean: .data$var1 (column) or .env$var1 / !!var1 (object).

is_pronoun <- \(x, nms = c(".data", ".env")) rlang::is_call(x, c("$", "[["), n = 2) && rlang::is_symbol(x[[2]], nms)
# env_get() forces a lazy fn argument (dplyr never would): if that errors, count it as a value, don't crash
binds_value <- \(env, nm) rlang::env_has(env, nm, inherit = TRUE) &&
  tryCatch(!is.function(rlang::env_get(env, nm, inherit = TRUE)), error = \(e) TRUE)
drop_names <- \(df, nms) if (NROW(df)) df[!df$name %in% nms, , drop = FALSE]

# walk one expression; returns a data frame (name, local) of ambiguous symbols.
# local = TRUE: the symbol sits inside local(), sql() or a call whose head is not a plain name (lst$f(), (\(x) x)(), ...),
# which dbplyr evaluates in R (tidyeval.R:225-236, 257-262) -> there the OBJECT is used, not the column.
ambiguous_syms <- function(x, env, cols, local = FALSE) {
  rec <- \(y, e = env, l = local) ambiguous_syms(y, e, cols, l)
  if (rlang::is_quosure(x)) return(rec(rlang::quo_get_expr(x), rlang::quo_get_env(x)))   # {{ }} keeps its own env
  if (rlang::is_symbol(x)) {
    nm <- rlang::as_string(x)
    return(if (nm %in% cols && binds_value(env, nm)) data.frame(name = nm, local = local))
  }
  if (!rlang::is_call(x) || rlang::is_call(x, c("::", ":::", "pick", "c_across", "remote")) || is_pronoun(x)) return(NULL)
  if (rlang::is_call(x, c("$", "@"))) return(rec(x[[2]]))                       # `lst$a`: `a` is a field name
  if (rlang::is_call(x, "function")) return(drop_names(rec(x[[3]]), names(x[[2]])))     # lambda formals
  if (rlang::is_call(x, c("across", "if_any", "if_all"))) { x <- rlang::call_match(x, dplyr::across); x$.cols <- NULL }
  head <- x[[1]]
  plain <- rlang::is_symbol(head) || rlang::is_call(head, "::") || is_pronoun(head, ".sql")
  parts <- if (plain) as.list(x)[-1] else as.list(x)
  purrr::map(parts, rec, l = local || !plain || rlang::is_call(x, c("local", "sql"))) |> purrr::list_rbind()
}

check_ambiguity <- function(.data, ..., .error = FALSE) {
  qs <- rlang::enquos(...)
  qs <- qs[!names(qs) %in% c(".by", ".keep", ".before", ".after", ".groups", ".preserve", ".locale")]
  # a name defined earlier in the same call (mutate(y = 1, z = y)) also counts as a column
  cols <- \(i) c(colnames(.data), names(qs)[seq_len(i - 1)])
  hits <- purrr::imap(unname(qs), \(q, i) ambiguous_syms(q, rlang::quo_get_env(q), cols(i))) |> purrr::list_rbind()
  if (!NROW(hits)) return(invisible(.data))
  nms <- unique(hits$name); loc <- unique(hits$name[hits$local])
  msg <- c("{.var {nms}} {?is/are} both a column and an object in the calling environment.",
           i = "The column wins in dplyr. Say which one you mean: {.code .data${nms[1]}} (column) or {.code .env${nms[1]}} (object).")
  if (inherits(.data, "tbl_lazy") && length(loc))
    msg <- c(msg, "!" = "dbplyr runs {.code lst$f(...)}-style calls, {.code local()} and {.code sql()} arguments in R, so here {.var {loc}} is the OBJECT, not the column (silent wrong result).")
  (if (.error) cli::cli_abort else cli::cli_warn)(msg, class = "ambiguous_name", call = NULL)
  invisible(.data)
}

# checked verbs: same arguments as the dplyr verb
checked <- \(verb) \(.data, ..., .error = FALSE) { check_ambiguity(.data, ..., .error = .error); verb(.data, ...) }
mutate_chk <- checked(dplyr::mutate)
filter_chk <- checked(dplyr::filter)
summarise_chk <- checked(dplyr::summarise)
