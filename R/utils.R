# Internal utilities (not exported).

coalesce_null <- function(x, y) if (is.null(x)) y else x

# Coerce anything datetime-like to POSIXct in UTC. POSIXct/POSIXlt inputs
# keep their instant (only the tz label changes); character and Date inputs
# without an explicit offset are read as UTC; numerics are epoch seconds.
# Non-NA input that fails to parse is an error rather than a silent NA.
as_utc <- function(x, arg = "x") {
  out <- as.POSIXct(suppressWarnings(lubridate::as_datetime(x, tz = "UTC")))
  bad <- is.na(out) & !is.na(x)
  if (any(bad)) {
    stop("`", arg, "` could not be parsed as a datetime: ",
         paste(utils::head(as.character(x[bad]), 3L), collapse = ", "),
         call. = FALSE)
  }
  out
}

stop_if_not_connection <- function(con) {
  if (!inherits(con, "hydrovu_connection")) {
    stop("`con` must be a <hydrovu_connection> created by `hv_connect()`.",
         call. = FALSE)
  }
  invisible(con)
}

# Silence R CMD check for bare column-name references inside dplyr / tidyr
# pipelines. These are not true globals.
utils::globalVariables(c(
  ".", "parameterId", "unitId", "readings",
  "parameter_id", "unit_id", "parameter_name", "unit_name",
  "timestamp", "value", "name", "id",
  "last_ts", "start_ts", "end_ts", "location_id"
))
