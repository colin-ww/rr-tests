# Part 4: targets (+ crew) x box::use / library() / packages= : what reaches a crew worker?
# Writes one mini targets project per variant into targets/<variant>/ (from the table below), then
# runs each in a fresh Rscript with a fresh store: no controller, and crew_controller_local(workers = 2).
# Records: outcome/error per target, where it ran, whether a 2nd tar_make() re-runs anything, and
# whether editing the module/function file makes `out` outdated (dependency tracking).
suppressPackageStartupMessages(library(dplyr))
source("R/harness.R")                 # squish(), clip(), compact_df(), save_results()
root <- file.path(getwd(), "targets")

# ---- building blocks -------------------------------------------------------------------------
FN  <- "add_x <- function(d) mutate(d, x = var1 * 2)"
in_fn <- \(use, call) sprintf("add_x <- function(d) {\n  box::use(%s)\n  %s\n}", use, call)
MOD <- c("# box module: its imports live INSIDE the module", "box::use(dplyr[mutate])", "",
         "#' @export", "add_x <- function(d) mutate(d, x = var1 * 2)")
SHARED <- r"(normalizePath("../_shared"))"   # a "team module library" outside the project
mods <- list("mods/tfuns.R" = MOD)
tg <- \(out = "add_x(raw)", deploy = NULL, extra = NULL) {
  dep <- if (is.null(deploy)) "" else sprintf(', deployment = "%s"', deploy)
  c("list(", "  tar_target(raw, data.frame(var1 = 1:3)),", extra,
    sprintf("  tar_target(out, %s%s),", out, dep),
    sprintf('  tar_target(ran_on, Sys.getenv("CREW_CONTROLLER", "main process")%s)', dep), ")")
}
# crew has no "run this on every worker" option, but extra `-e` code in r_arguments runs before crew_worker()
rargs <- \(setup) c(paste("worker_setup <-", setup),
  r"(if (Sys.getenv("USE_CREW") == "true") tar_option_set(controller = crew::crew_controller_local(name = "crew",)",
  r"(  workers = 2, seconds_idle = 10, r_arguments = c("--no-save", "--no-restore", "-e", worker_setup))))")
v <- \(variant, about, setup, tgts = tg(), files = list(), edit = NA_character_, modes = c("none", "crew"))
  tibble(variant, about, setup = list(setup), tgts = list(tgts), files = list(files), edit, modes = list(modes))

variants <- bind_rows(
  # --- packages (dplyr::mutate used inside a function defined in _targets.R) ---
  v("pkg_box_top",        "box::use(dplyr[mutate]) at top of _targets.R", c("box::use(dplyr[mutate])", FN)),
  v("pkg_box_alias_top",  "box::use(dplyr) at top, dplyr$mutate() in fn", c("box::use(dplyr)", "add_x <- function(d) dplyr$mutate(d, x = var1 * 2)")),
  v("pkg_box_in_fn",      "box::use(dplyr[mutate]) inside the function", in_fn("dplyr[mutate]", "mutate(d, x = var1 * 2)")),
  v("pkg_library_top",    "library(dplyr) at top of _targets.R", c("library(dplyr)", FN)),
  v("pkg_packages_opt",   'tar_option_set(packages = "dplyr")', c('tar_option_set(packages = "dplyr")', FN)),
  v("pkg_qualified",      "dplyr::mutate() in fn, no imports", "add_x <- function(d) dplyr::mutate(d, x = var1 * 2)"),
  v("pkg_box_top_main",   'box::use top + deployment = "main" on the target', c("box::use(dplyr[mutate])", FN), tg(deploy = "main")),
  v("pkg_box_top_imports", 'box::use top + tar_option_set(imports = "dplyr")',
    c("box::use(dplyr[mutate])", 'tar_option_set(imports = "dplyr")', FN)),
  v("pkg_imports_qualified", 'tar_option_set(imports = "dplyr") + dplyr::mutate() (no box): is imports= itself usable?',
    c('tar_option_set(imports = "dplyr")', "add_x <- function(d) dplyr::mutate(d, x = var1 * 2)")),
  v("pkg_box_top_hook",   "box::use top + tarchetypes::tar_hook_before(hook = box::use(dplyr[mutate]))",
    c("box::use(dplyr[mutate])", FN),
    c("tarchetypes::tar_hook_before(", "  hook = box::use(dplyr[mutate]), names = tidyselect::starts_with(\"out\"),",
      "  targets = list(", "    tar_target(raw, data.frame(var1 = 1:3)),",
      "    tar_target(out, add_x(raw)),                     # mutate() called inside a function",
      "    tar_target(out_direct, mutate(raw, x = var1 * 2)) # mutate() called in the command itself",
      "  )", ")")),
  v("pkg_tar_source",     "tar_source() of R/functions.R that starts with box::use(dplyr[mutate])", "tar_source()",
    files = list("R/functions.R" = c("box::use(dplyr[mutate])", "", FN)), edit = "R/functions.R"),
  v("pkg_custom_envir",   "box::use + fn inside a custom env, tar_option_set(envir = that env)",
    c("pipeline_env <- new.env()", "local(envir = pipeline_env, {", "  box::use(dplyr[mutate])", paste0("  ", FN), "})",
      "tar_option_set(envir = pipeline_env)")),
  v("pkg_rprofile",       "box::use(dplyr[mutate]) in the project .Rprofile (runs in every R process)", FN,
    files = list(".Rprofile" = "box::use(dplyr[mutate])")),
  v("pkg_box_top_rargs",  "box::use top + same line run on every crew worker via crew_controller_local(r_arguments = c(..., '-e', setup))",
    c("box::use(dplyr[mutate])", rargs('"box::use(dplyr[mutate])"'), FN)),
  # --- box modules (mods/tfuns.R, itself doing box::use(dplyr[mutate])) ---
  v("mod_alias_top_nopath", "box::use(mods/tfuns) at top, box.path NOT set", "box::use(mods/tfuns)", tg("tfuns$add_x(raw)"),
    mods, modes = c("none", "crew", "in-process")),
  v("mod_alias_top_relative", "box::use(./mods/tfuns) at top (relative), box.path NOT set", "box::use(./mods/tfuns)",
    tg("tfuns$add_x(raw)"), mods),
  v("mod_setscript_top",  "box::set_script_path() + box::use(./mods/tfuns) at top",
    c(r"(box::set_script_path(file.path(getwd(), "_targets.R")))", "box::use(./mods/tfuns)"), tg("tfuns$add_x(raw)"), mods),
  v("mod_alias_top",      "options(box.path = getwd()) + box::use(mods/tfuns) at top, tfuns$add_x()",
    c("options(box.path = getwd())", "box::use(mods/tfuns)"), tg("tfuns$add_x(raw)"), mods, "mods/tfuns.R"),
  v("mod_attach_top",     "options(box.path = getwd()) + box::use(mods/tfuns[add_x]) at top (attach style)",
    c("options(box.path = getwd())", "box::use(mods/tfuns[add_x])"), tg(), mods, "mods/tfuns.R"),
  v("mod_attach_top_rargs", "as mod_attach_top + box.path and the same box::use run on every crew worker via r_arguments '-e'",
    c("options(box.path = getwd())", "box::use(mods/tfuns[add_x])",
      rargs(r"{sprintf("options(box.path = %s); box::use(mods/tfuns[add_x])", deparse(getwd()))}")), tg(), mods, "mods/tfuns.R"),
  v("mod_in_fn",          "box::use(mods/tfuns) inside the function, box.path NOT set",
    in_fn("mods/tfuns", "tfuns$add_x(d)"), files = mods, edit = "mods/tfuns.R"),
  v("mod_in_fn_boxpath",  "options(box.path = getwd()) at top + box::use(mods/tfuns) inside the function",
    c("options(box.path = getwd())", in_fn("mods/tfuns", "tfuns$add_x(d)")), files = mods, edit = "mods/tfuns.R"),
  v("mod_in_fn_tracked",  "as mod_in_fn_boxpath + module file declared as a format = \"file\" target",
    c("options(box.path = getwd())", in_fn("mods/tfuns", "tfuns$add_x(d)")),
    tg("{ tfuns_file; add_x(raw) }", extra = r"(  tar_target(tfuns_file, "mods/tfuns.R", format = "file"),)"),
    mods, "mods/tfuns.R"),
  # --- module library OUTSIDE the project (targets/_shared/teamlib/shmod.R) ---
  v("shared_option_in_fn", "options(box.path = <shared>) at top + box::use(teamlib/shmod) inside fn",
    c(sprintf("options(box.path = %s)", SHARED), in_fn("teamlib/shmod", "shmod$add_x(d)")), edit = "../_shared/teamlib/shmod.R"),
  v("shared_envvar_in_fn", "Sys.setenv(R_BOX_PATH = <shared>) at top + box::use(teamlib/shmod) inside fn",
    c(sprintf("Sys.setenv(R_BOX_PATH = %s)", SHARED), in_fn("teamlib/shmod", "shmod$add_x(d)"))),
  v("shared_rprofile_in_fn", "options(box.path = <shared>) in project .Rprofile + box::use inside fn",
    in_fn("teamlib/shmod", "shmod$add_x(d)"), files = list(".Rprofile" = sprintf("options(box.path = %s)", SHARED))),
  v("shared_alias_top",   "options(box.path = <shared>) + box::use(teamlib/shmod) at top, shmod$add_x()",
    c(sprintf("options(box.path = %s)", SHARED), "box::use(teamlib/shmod)"), tg("shmod$add_x(raw)"),
    edit = "../_shared/teamlib/shmod.R"),
  # --- what does the worker actually see? ---
  v("mechanism_view",     "box::use pkg + module at top; target reports globals / search path / envir where it runs",
    c("options(box.path = getwd())", "box::use(dplyr[mutate])", "box::use(mods/tfuns)", FN),
    c("list(", "  tar_target(out, paste(", r"[    "ran on:", Sys.getenv("CREW_CONTROLLER", "main process"),]",
      r"[    "| globals:", toString(ls(globalenv())),]",
      r"[    "| search() has:", toString(grep("^mod:|dplyr", search(), value = TRUE)),]",
      r"[    "| envir:", environmentName(tar_option_get("envir"))))]", ")"), mods)
)

# ---- write the projects ------------------------------------------------------------------------
header <- \(about) c(paste("#", about),
  "# Generated by ../../04-targets.R. Run here: Rscript -e 'targets::tar_make()'  (USE_CREW=true for crew)",
  "library(targets)",
  r"(if (Sys.getenv("USE_CREW") == "true"))",
  r"(  tar_option_set(controller = crew::crew_controller_local(name = "crew", workers = 2, seconds_idle = 10)))",
  r"(tar_option_set(error = "continue")   # every target reports its own outcome)", "")
write_file <- \(path, lines) { dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE); writeLines(lines, path) }
write_file(file.path(root, "_shared/teamlib/shmod.R"), MOD)
write_file(file.path(root, ".gitignore"), "_targets/")
purrr::pwalk(variants, \(variant, about, setup, tgts, files, ...) {
  dir <- file.path(root, variant); unlink(dir, recursive = TRUE)
  write_file(file.path(dir, "_targets.R"), c(header(about), setup, "", tgts))
  purrr::iwalk(files, \(lines, f) write_file(file.path(dir, f), lines))
})

# ---- run ---------------------------------------------------------------------------------------
# fresh Rscript per call; "in-process" = tar_make(callr_function = NULL) from `Rscript -e`.
# TESTTHAT=true or R_BOX_PATH would change where box looks for modules -> neutralise both.
rscript <- \(dir, code, mode = "none") processx::run(file.path(R.home("bin"), "Rscript"), c("-e", code), wd = dir,
  error_on_status = FALSE, env = c("current", USE_CREW = tolower(mode == "crew"), TESTTHAT = "false", R_BOX_PATH = ""))
tar_make_in <- \(dir, mode) rscript(dir, sprintf("targets::tar_make(reporter = 'silent'%s)",
  if (mode == "in-process") ", callr_function = NULL" else ""), mode)
clean_err <- \(x) x |> sub(pattern = "(?s)^.*Error in tar_\\w+\\(\\):", replacement = "", perl = TRUE) |>
  sub(pattern = "(?s)See https.*$", replacement = "", perl = TRUE) |> squish() |> clip(250)
store <- \(dir) file.path(dir, "_targets")
safe <- \(expr, alt = NA) tryCatch(expr, error = \(e) alt)
read_val <- \(dir, name) safe({ x <- targets::tar_read_raw(name, store = store(dir)); if (is.data.frame(x)) compact_df(x) else paste(x, collapse = " ") }, NA_character_)

run_variant <- function(variant, about, edit, modes, ...) {
  dir <- file.path(root, variant)
  purrr::map(modes, \(mode) {
    unlink(store(dir), recursive = TRUE)
    r <- tar_make_in(dir, mode)
    meta <- safe(targets::tar_meta(fields = any_of(c("type", "error")), store = store(dir)) |> filter(type == "stem"),
                 tibble(name = character(), error = character()))   # tar_meta() also lists imported functions/objects
    tgts <- setdiff(meta$name, c("raw", "ran_on", "tfuns_file")); if (!length(tgts)) tgts <- "out"
    res <- tibble(part = "targets", variant, mode, target = tgts, about) |>
      mutate(error = purrr::map_chr(target, \(t) { e <- meta$error[meta$name == t]
               if (length(e) && !is.na(e)) clean_err(e) else if (r$status != 0) clean_err(r$stderr) else NA_character_ }),
             value = purrr::map_chr(target, \(t) read_val(dir, t)),
             outcome = if_else(is.na(error) & !is.na(value), "ok", "error"),
             ran_on = read_val(dir, "ran_on"), rerun_2nd = NA_integer_, outdated_after_edit = NA)
    if (mode == "none" && all(res$outcome == "ok")) {      # tracking checks (done in the main process anyway)
      tar_make_in(dir, mode)
      res$rerun_2nd <- safe(sum(targets::tar_progress(store = store(dir))$progress != "skipped"), NA_integer_)
      if (!is.na(edit)) {
        f <- file.path(dir, edit); old <- readLines(f); on.exit(writeLines(old, f))
        writeLines(sub("var1 * 2", "var1 * 3", old, fixed = TRUE), f)
        od <- rscript(dir, "cat(targets::tar_outdated(reporter = 'silent'), sep = '\\n')")$stdout
        res$outdated_after_edit <- "out" %in% strsplit(od, "\n")[[1]]
        writeLines(old, f)
      }
    }
    unlink(store(dir), recursive = TRUE)
    res
  }) |> purrr::list_rbind()
}

t0 <- Sys.time()
res <- purrr::pmap(variants, run_variant, .progress = "variants") |> purrr::list_rbind()

# ---- cost of box::use() inside a function (modules/packages are cached after the 1st call) ------
per_call <- \(f, n = 2000) { f(); 1e6 * system.time(for (i in seq_len(n)) f())[["elapsed"]] / n }
timing <- callr::r(\(per_call, mod_dir) {
  options(box.path = mod_dir)
  c(pkg = per_call(\() { box::use(dplyr[mutate]); 1 }), mod = per_call(\() { box::use(mods/tfuns); 1 }),
    qualified = per_call(\() { dplyr::mutate; 1 }))
}, args = list(per_call, file.path(root, "mod_alias_top")))
res <- bind_rows(res, tibble(part = "timing", variant = c("box::use(dplyr[mutate]) per call", "box::use(mods/tfuns) per call",
  "dplyr::mutate lookup per call"), mode = "-", outcome = "ok", value = sprintf("%.1f microseconds", timing)))

save_results(res, "04-targets.csv")
cat("rows:", nrow(res), " runtime:", format(round(Sys.time() - t0)), "\n")
res |> filter(part == "targets") |> select(variant, mode, target, outcome, error, ran_on, rerun_2nd, outdated_after_edit) |>
  print(n = Inf, width = 250)
