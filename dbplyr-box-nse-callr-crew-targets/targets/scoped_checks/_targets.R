library(targets)
tar_option_set(envir = new.env(parent = globalenv()))
# Like targets::tar_source(), but each file gets its own scope: its top-of-file box::use() imports are seen by that file only.
# The file's functions and other objects still all land in `envir`, where targets fingerprints them one by one
# and sends them (with the imports, as parents) to crew workers. See docs/10-recommendation.md.
source_scoped <- function(files = list.files("R", "\\.[rR]$", full.names = TRUE, recursive = TRUE),
                          envir = targets::tar_option_get("envir")) {
  for (f in files) {
    file_env <- new.env(parent = envir)
    sys.source(f, envir = file_env, keep.source = TRUE)
    list2env(as.list(file_env, all.names = TRUE), envir)
  }
  invisible(envir)
}
e <- source_scoped()
stopifnot(is.function(e$fa))
list(tar_target(raw, data.frame(v = 1:3)), tar_target(out_a, fa(raw)), tar_target(out_b, fb(raw)), tar_target(out_c, fc(raw)))
