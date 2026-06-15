#' Fetch and cache HydroVu parameter friendly-names
#'
#' Returns the lookup table mapping internal parameter IDs to human-readable
#' names (e.g. "Temperature", "Pressure"). The result is cached on the
#' connection after the first call.
#'
#' @param con A `<hydrovu_connection>`.
#' @param refresh If `TRUE`, force a re-fetch from the API.
#'
#' @return A tibble with `parameter_id` and `parameter_name`.
#' @export
#'
#' @examples
#' \dontrun{
#' con <- hv_connect()
#' hv_parameters(con)
#' }
hv_parameters <- function(con, refresh = FALSE) {
  stop_if_not_connection(con)
  if (refresh || is.null(con$parameters)) {
    con$parameters <- get_parameter_names(hv_token(con), con$base_url)
  }
  con$parameters
}
