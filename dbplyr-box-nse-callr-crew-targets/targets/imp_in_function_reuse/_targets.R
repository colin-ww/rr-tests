library(targets)
tar_option_set(error = "continue")
tar_option_set(controller = crew::crew_controller_local(workers = 1, seconds_idle = 10))
tar_source()
list(
  tar_target(raw, data.frame(v = 1:2)),
  tar_target(out_a, fa(raw)),
  tar_target(out_b, fb(raw)),
  tar_target(out_c, fc(raw))
)
