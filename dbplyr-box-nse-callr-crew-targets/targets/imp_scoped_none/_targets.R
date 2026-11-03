library(targets)
tar_option_set(error = "continue")
tar_option_set(envir = new.env(parent = globalenv()))
source_scoped <- function(dir = "R", envir = tar_option_get("envir")) {
  for (f in list.files(dir, "\\.[rR]$", full.names = TRUE, recursive = TRUE)) {
    file_env <- new.env(parent = envir)
    sys.source(f, envir = file_env, keep.source = FALSE)
    list2env(as.list(file_env), envir)
  }
}
source_scoped()
list(
  tar_target(raw, data.frame(v = 1:2)),
  tar_target(out_a, fa(raw)),
  tar_target(out_b, fb(raw)),
  tar_target(out_c, fc(raw))
)
