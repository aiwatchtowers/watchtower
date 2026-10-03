# A tiny R fixture for the full grammar set.

#' Doubles a number.
#'
#' @param n A number.
#' @return Twice n.
double <- function(n) {
  local <- function(x) x
  local(n) * 2
}

# A plain comment is not a doc.
helper = function(a, b) a + b

#' Adds a value under a key.
"add_value" <- function(store, key, value) {
  store[[key]] <- value
  store
}

max_size <- 64

stack <- list(
  push = function(x) x
)

utils::head
