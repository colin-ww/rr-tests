# Part 7: box::use(base[...]) and the other default packages (issue #3)
# Every import case runs in a FRESH R process (callr) so attachments/loaded modules can't leak between cases.
suppressPackageStartupMessages(library(dplyr))
source("R/harness.R")

# --- root cause, in this session (no box involved) ---
P0 <- "box-base-root"
root <- bind_rows(
  probe(P0, "getNamespaceInfo() refuses the base namespace", getNamespaceInfo(.BaseNamespaceEnv, "lazydata")),
  probe(P0, "...and ls() turns that error into a search-list lookup", ls(getNamespaceInfo(.BaseNamespaceEnv, "lazydata"))),
  probe(P0, "no-check .getNamespaceInfo() just returns NULL for base", .getNamespaceInfo(.BaseNamespaceEnv, "lazydata")),
  probe(P0, "getNamespaceExports() special-cases base (n exports)", length(getNamespaceExports("base"))),
  probe(P0, "box 1.2.3 code that runs for every package import", box:::`mod_export_names.box$pkg_info`)
)

# --- suggested fix: skip the lazydata lookup for base (only change vs box 1.2.3 is the if()) ---
patched <- function (info, mod_ns) {
  exports = getNamespaceExports(mod_ns)
  if (isBaseNamespace(mod_ns)) return(exports)
  c(exports, ls(getNamespaceInfo(mod_ns, 'lazydata')))
}

# child: optionally patch box, then import `use` at top level or inside a module file, then evaluate `check`
child <- function(use, check, ctx, fix) {
  if (!is.null(fix)) {
    environment(fix) <- asNamespace("box")
    utils::assignInNamespace("mod_export_names.box$pkg_info", fix, "box")
  }
  warns <- character(); stage <- "import"
  value <- tryCatch(withCallingHandlers({
    if (ctx == "module") {
      d <- tempfile(); dir.create(file.path(d, "t"), recursive = TRUE)
      writeLines(c(if (!is.na(use)) sprintf("box::use(%s)", use), "#' @export", paste("check <- function()", check)),
                 file.path(d, "t", "m.r"))
      options(box.path = d); box::use(t/m)
      stage <- "call"; v <- m$check()
    } else {
      if (!is.na(use)) eval(str2lang(sprintf("box::use(%s)", use)), globalenv())
      stage <- "call"; v <- eval(str2lang(check), globalenv())
    }
    stage <- "ok"; paste(deparse(v), collapse = "")
  }, warning = \(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") }),
  error = \(e) paste0("ERROR: ", conditionMessage(e)))
  list(value = value, stage = stage, warnings = paste(warns, collapse = " || "))
}

run <- function(part, case, use, check, ctx, fix = FALSE) {
  r <- callr::r(child, list(use, check, ctx, if (fix) patched))
  err <- startsWith(r$value, "ERROR")
  tibble(part = part, case = case, backend = paste0(ctx, if (fix) "+patch"),
         code = paste0(if (!is.na(use)) paste0("box::use(", use, "); "), check),
         outcome = if (err) "error" else if (nzchar(r$warnings)) "warning" else "ok",
         failed_at = if (err) r$stage else NA_character_, value = clip(squish(r$value)), sql = NA_character_,
         warnings = clip(squish(r$warnings)), messages = "")
}

# --- matrix: package x import form x context. `%s` in `call` gets the imported name ---
pkgs <- tribble(
  ~pkg,        ~fn,         ~call,                ~lazydata,
  "base",      "nchar",     "%s('abc')",          FALSE,
  "stats",     "median",    "%s(c(1, 5, 9))",     FALSE,
  "utils",     "head",      "%s(letters, 2)",     FALSE,
  "methods",   "is",        "%s(1, 'numeric')",   FALSE,
  "tools",     "file_ext",  "%s('a.csv')",        FALSE,
  "graphics",  "plot",      "class(%s)",          FALSE,
  "grDevices", "rgb",       "%s(1, 0, 0)",        FALSE,
  "datasets",  "mtcars",    "nrow(%s)",           TRUE,
  "dplyr",     "starwars",  "nrow(%s)",           TRUE,
  "stringr",   "fruit",     "length(%s)",         TRUE
)
forms <- tribble(
  ~form,           ~use,                    ~name,
  "pkg",           "{pkg}",                 "{pkg}${fn}",
  "pkg[fn]",       "{pkg}[{fn}]",           "{fn}",
  "pkg[al = fn]",  "{pkg}[al = {fn}]",      "al",
  "pkg[...]",      "{pkg}[...]",            "{fn}"
)
grid <- tidyr::crossing(pkgs, forms, ctx = c("top-level", "module")) |>
  mutate(use = purrr::pmap_chr(list(use, pkg, fn), \(u, pkg, fn) glue::glue(u)),
         check = purrr::pmap_chr(list(call, name, pkg, fn), \(cl, nm, pkg, fn) sprintf(cl, glue::glue(nm))),
         case = paste0("box::use(", use, ")", if_else(lazydata, "  [lazydata]", "")))

P <- "box-base"
mat <- purrr::pmap(grid, \(case, use, check, ctx, ...) run(P, case, use, check, ctx)) |> purrr::list_rbind()
# same calls with the patched box function: base must work, lazydata packages must still work
fixed <- grid |> filter(pkg %in% c("base", "datasets", "dplyr")) |>
  purrr::pmap(\(case, use, check, ctx, ...) run(paste0(P, "-patched"), case, use, check, ctx, fix = TRUE)) |> purrr::list_rbind()

# --- what a module can see without importing anything ---
chain <- "{ e <- parent.env(environment()); r <- character(); while (!identical(e, emptyenv())) {
  r <- c(r, if (identical(e, baseenv())) 'baseenv()' else if (identical(e, .BaseNamespaceEnv)) 'namespace:base'
         else if (nzchar(environmentName(e))) environmentName(e) else paste0('<', toString(ls(e)), '>'));
  e <- parent.env(e) }; paste(r, collapse = ' > ') }"
P2 <- "box-base-visibility"
vis <- bind_rows(
  run(P2, "module, no import: base nchar() visible", NA, "nchar('abc')", "module"),
  run(P2, "module, no import: stats median() NOT visible", NA, "median(c(1, 5, 9))", "module"),
  run(P2, "module, no import: utils head() NOT visible", NA, "head(letters, 2)", "module"),
  run(P2, "module, no import: datasets mtcars NOT visible", NA, "nrow(mtcars)", "module"),
  run(P2, "module, box::use(r/core[...]) gives stats/utils/... (not datasets)", "r/core[...]", "median(c(1, 5, 9))", "module"),
  run(P2, "module env chain (fn env -> ... -> emptyenv)", NA, squish(chain), "module"),
  run(P2, "module: base aliasing via plain R works today", NA, "{ nch <- base::nchar; nch('abc') }", "module"),
  run(P2, "top-level: base::nchar alias works today", NA, "{ nch <- base::nchar; nch('abc') }", "top-level"),
  # the one real use: pin a base fn after a wildcard import masked it (base::intersect does the same today)
  run(P2, "module: dplyr[...] masks base intersect", "dplyr[...]", "environmentName(environment(intersect))", "module"),
  run(P2, "module: dplyr[...], base[intersect] to pin base's", "dplyr[...], base[intersect]",
      "environmentName(environment(intersect))", "module"),
  run(P2, "module: dplyr[...], base[intersect] to pin base's", "dplyr[...], base[intersect]",
      "environmentName(environment(intersect))", "module", fix = TRUE),
  # harm check for the wildcard after the fix: top-level base[...] puts ~1400 COPIES of base objects on the search path
  run(P2, "patched top-level base[...]: where/how many copies", "base[...]",
      "c(pos = match('mod:base', search()), n = length(ls('mod:base', all.names = TRUE)))", "top-level", fix = TRUE),
  # ...and, sitting at position 2, those copies re-mask packages attached earlier that override base (dplyr's intersect)
  run(P2, "patched top-level base[...] after library(dplyr): intersect comes from", NA,
      "{ suppressPackageStartupMessages(library(dplyr)); box::use(base[...]); environmentName(environment(intersect)) }",
      "top-level", fix = TRUE),
  # .Last.value only updates at the REPL top level, so this one is a real Rscript file, not callr::r()
  local({
    f <- tempfile(fileext = ".R")
    writeLines(c(paste("fix <-", paste(deparse(patched), collapse = "\n")), "environment(fix) <- asNamespace('box')",
                 "utils::assignInNamespace('mod_export_names.box$pkg_info', fix, 'box')", "box::use(base[...])", "40 + 2",
                 "cat(sprintf('.Last.value=%s base::.Last.value=%s found_in=%s', deparse(.Last.value), base::.Last.value, toString(find('.Last.value'))))"), f)
    out <- system2(file.path(R.home("bin"), "Rscript"), shQuote(f), stdout = TRUE, stderr = TRUE) |> squish()
    tibble(part = P2, case = "patched top-level base[...]: the .Last.value copy is frozen", backend = "Rscript+patch",
           code = "box::use(base[...]); 40 + 2; .Last.value", outcome = "ok", failed_at = NA_character_,
           value = out, sql = NA_character_, warnings = "", messages = "")
  })
)

res <- bind_rows(root, mat, fixed, vis)
save_results(res, "07-box-base.csv")
cat("rows:", nrow(res), "\n")
res |> count(part, backend, outcome) |> print(n = Inf)
