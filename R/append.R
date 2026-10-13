#' Append new readings to an existing readings data frame
#'
#' File-based counterpart to [hv_sync()]: combines `new` with `existing`,
#' keeping one row per `unique_cols`. Where a reading appears in both, the row
#' from `new` wins (like `hv_sync()`'s `ON CONFLICT ... DO UPDATE`), so values
#' revised upstream within an overlap window replace the stored ones.
#'
#' Unlike [hv_validate_readings()], extra columns (e.g. location names or
#' project-specific site metadata) are kept. `timestamp` is normalised to UTC.
#'
#' @param existing Previously stored readings, or `NULL` if there are none.
#' @param new Newly fetched readings, typically from [hv_readings()] (possibly
#'   with extra columns joined on).
#' @param unique_cols Columns identifying a single reading. Must be present
#'   and non-`NA` in both inputs.
#'
#' @return A tibble of the combined readings, sorted by `unique_cols`.
#' @export
#'
#' @examples
#' \dontrun{
#' existing <- readRDS("readings.rds")
#' windows  <- hv_compute_windows(existing, locs, overlap_days = 2)
#' new      <- hv_readings(con, windows$location_id,
#'                         windows$start_ts, windows$end_ts)
#' saveRDS(hv_append(existing, new), "readings.rds")
#' }
hv_append <- function(existing, new,
                      unique_cols = c("location_id", "parameter_id", "timestamp")) {
  check <- function(df, arg) {
    if (!is.data.frame(df)) {
      stop("`", arg, "` must be a data frame or tibble (got ",
           paste(class(df), collapse = "/"), ").", call. = FALSE)
    }
    missing <- setdiff(unique_cols, names(df))
    if (length(missing) > 0L) {
      stop("`", arg, "` is missing required column(s): ",
           paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    for (col in unique_cols) {
      if (anyNA(df[[col]])) {
        stop("`", arg, "$", col, "` contains NA values.", call. = FALSE)
      }
    }
    if ("timestamp" %in% names(df)) {
      df$timestamp <- as_utc(df$timestamp, paste0(arg, "$timestamp"))
    }
    df
  }

  new <- check(new, "new")
  existing <- if (is.null(existing)) new[0L, ] else check(existing, "existing")

  dplyr::bind_rows(new, existing) |>
    dplyr::distinct(dplyr::across(dplyr::all_of(unique_cols)), .keep_all = TRUE) |>
    dplyr::arrange(dplyr::across(dplyr::all_of(unique_cols))) |>
    tibble::as_tibble()
}
