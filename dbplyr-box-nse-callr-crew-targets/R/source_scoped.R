# Like targets::tar_source(), but each file gets its own scope for what it box::use()s:
#   - imports (box::use(dplyr[filter]) and aliases like box::use(stringr)) stay with that file
#   - everything the file defines (functions, constants) is copied into `envir`, the pipeline env,
#     where every file and target command can use it, and targets tracks each function on its own
# crew workers get the imports too: each function carries its file's env with it. See docs/10-recommendation.md.
source_scoped <- function(files = list.files("R", "\\.[rR]$", full.names = TRUE, recursive = TRUE),
                          envir = targets::tar_option_get("envir")) {
  for (f in files) {
    file_env <- new.env(parent = envir)                     # box puts attached imports in a new env between file_env and envir
    sys.source(f, envir = file_env, keep.source = TRUE)     # run the file there. keep.source: file + line numbers in errors
    objs <- as.list(file_env, all.names = TRUE)             # all.names: .dot names too, so targets tracks them
    list2env(objs[!vapply(objs, inherits, logical(1), what = "box$mod")], envir) # box aliases stay with their file
  }
  invisible(envir)
}
