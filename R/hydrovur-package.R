#' hydrovur: HydroVu public API client for R
#'
#' Connection-oriented R client for the HydroVu public REST API. Provides
#' cached access to locations and parameter friendly-names, fetches sensor
#' readings over arbitrary time windows, and offers helpers for windowed
#' upserts into a PostgreSQL backend.
#'
#' @keywords internal
#' @importFrom dplyr bind_rows coalesce distinct left_join mutate rename select
#' @importFrom tidyr unnest unnest_wider
#' @importFrom tibble as_tibble enframe tibble
#' @importFrom purrr pmap safely
#' @importFrom lubridate as_datetime days with_tz
#' @importFrom httr POST GET add_headers authenticate content headers stop_for_status
#' @importFrom jsonlite fromJSON
#' @importFrom rlang .data
#' @importFrom DBI dbExecute dbGetQuery dbWriteTable dbQuoteIdentifier
"_PACKAGE"
