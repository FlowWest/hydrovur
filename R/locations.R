#' Fetch and cache HydroVu locations
#'
#' Returns every location the connected account can read. The result is cached
#' on the connection after the first call; pass `refresh = TRUE` to force a
#' re-fetch from the API.
#'
#' The HydroVu `id` field is renamed to `location_id` and coerced to character
#' for consistency with the rest of the package and the recommended database
#' schema.
#'
#' @param con A `<hydrovu_connection>`.
#' @param refresh If `TRUE`, force a re-fetch from the API.
#'
#' @return A tibble of locations including (at minimum) `location_id` and
#'   `name`. Other HydroVu fields (e.g. GPS coordinates) are included if
#'   present.
#' @export
#'
#' @examples
#' \dontrun{
#' con <- hv_connect()
#' hv_locations(con)
#' }
hv_locations <- function(con, refresh = FALSE) {
  stop_if_not_connection(con)
  if (refresh || is.null(con$locations)) {
    con$locations <- get_locations(hv_token(con), con$base_url) |>
      dplyr::rename(location_id = "id") |>
      dplyr::mutate(location_id = as.character(.data$location_id))
  }
  con$locations
}
