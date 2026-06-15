#' Fetch readings for one or more locations over a time window
#'
#' Iterates over `location_ids`, fetching each location's readings between
#' `start` and `end` and binding them into a single tibble. Per-location
#' failures are caught with [purrr::safely()]: a warning is emitted and the
#' offending location is dropped from the result rather than aborting the
#' whole batch.
#'
#' @param con A `<hydrovu_connection>`.
#' @param location_ids Character vector of HydroVu location IDs (typically
#'   `hv_locations(con)$location_id` or a filtered subset).
#' @param start,end Time bounds. May be a single value (applied to all
#'   locations) or vectors the same length as `location_ids` (per-location
#'   windows). Anything coercible by [as.POSIXct()] is accepted; timezone
#'   defaults to UTC.
#'
#' @return A tibble with columns `location_id`, `parameter_id`,
#'   `parameter_name`, `unit_id`, `timestamp`, `value`.
#' @export
#'
#' @examples
#' \dontrun{
#' con <- hv_connect()
#' locs <- hv_locations(con) |>
#'   dplyr::filter(name %in% c("2025SGMC01", "2025SGMC03"))
#' hv_readings(
#'   con,
#'   location_ids = locs$location_id,
#'   start = "2026-05-01",
#'   end   = "2026-05-18"
#' )
#' }
hv_readings <- function(con, location_ids, start, end) {
  stop_if_not_connection(con)
  if (length(location_ids) == 0L) {
    return(tibble::tibble(
      location_id    = character(),
      parameter_id   = character(),
      parameter_name = character(),
      unit_id        = character(),
      timestamp      = as.POSIXct(character(), tz = "UTC"),
      value          = numeric()
    ))
  }

  loc_ids <- as.character(location_ids)
  start   <- rep_len(as.POSIXct(start, tz = "UTC"), length(loc_ids))
  end     <- rep_len(as.POSIXct(end,   tz = "UTC"), length(loc_ids))

  parms   <- hv_parameters(con)
  base    <- con$base_url
  n       <- length(loc_ids)

  # name lookup from cache for human-readable messages
  name_of <- if (!is.null(con$locations))
    setNames(con$locations$name, as.character(con$locations$location_id))
  else
    character(0)

  rows <- purrr::pmap(
    list(i = seq_len(n), loc = loc_ids, s = start, e = end),
    function(i, loc, s, e) {
      label <- if (loc %in% names(name_of)) name_of[[loc]] else loc
      message(sprintf("[%d/%d] %s  %s -> %s",
                      i, n, label,
                      format(s, "%Y-%m-%d", tz = "UTC"),
                      format(e, "%Y-%m-%d", tz = "UTC")))
      token <- hv_token(con)  # re-check so the token doesn't expire mid-batch
      out <- purrr::safely(get_readings)(token, loc, parms, s, e, base)
      if (!is.null(out$error)) {
        warning("readings fetch failed for location ", label, ": ",
                conditionMessage(out$error), call. = FALSE)
        return(NULL)
      }
      if (is.null(out$result) || nrow(out$result) == 0L) {
        message(sprintf("[%d/%d] %s  0 rows", i, n, label))
        return(NULL)
      }
      nr <- nrow(out$result)
      message(sprintf("[%d/%d] %s  %s rows", i, n, label, format(nr, big.mark = ",")))
      dplyr::mutate(out$result, location_id = loc)
    }
  ) |>
    dplyr::bind_rows()

  if (nrow(rows) == 0L) return(rows)

  dplyr::select(rows, "location_id", "parameter_id", "parameter_name",
                "unit_id", "timestamp", "value")
}
