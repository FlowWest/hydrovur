# Internal utilities (not exported).

coalesce_null <- function(x, y) if (is.null(x)) y else x

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
  "parameter_id", "unit_id", "parameter_name",
  "timestamp", "value", "name", "id",
  "last_ts", "start_ts", "end_ts", "location_id"
))
