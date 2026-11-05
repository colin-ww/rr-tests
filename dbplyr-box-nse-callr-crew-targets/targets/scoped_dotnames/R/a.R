.helper <- function(x) x + 2
fa <- function(d) { d$a <- .helper(1); d }
