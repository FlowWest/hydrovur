#' Fetch and cache HydroVu unit friendly-names
#'
#' Returns the lookup table mapping internal unit IDs to human-readable
#' names (e.g. "C", "psi"). The result is cached on the connection after the
#' first call.
#'
#' @param con A `<hydrovu_connection>`.
#' @param refresh If `TRUE`, force a re-fetch from the API.
#'
#' @return A tibble with `unit_id` and `unit_name`.
#' @export
#'
#' @examples
#' \dontrun{
#' con <- hv_connect()
#' hv_units(con)
#' }
hv_units <- function(con, refresh = FALSE) {
  stop_if_not_connection(con)
  if (refresh || is.null(con$units)) {
    con$units <- get_unit_names(hv_token(con), con$base_url)
  }
  con$units
}
