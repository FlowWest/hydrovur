#' Create the readings table if it does not exist
#'
#' Writes the recommended schema:
#'   `(location_id, parameter_id, unit_id, timestamp, value)`
#' with a composite primary key on `(location_id, parameter_id, timestamp)`.
#'
#' Location names and parameter friendly-names are intentionally not stored
#' here; resolve them by joining against a lookup table maintained elsewhere
#' in the database (see [hv_locations()] and [hv_parameters()] for sources
#' you can derive one from).
#'
#' Postgres-specific (uses `TIMESTAMPTZ` and `DOUBLE PRECISION`).
#'
#' @param db_con A DBI connection or `pool::Pool` to PostgreSQL.
#' @param table Target table name. Default `"gage_readings"`.
#'
#' @return Number of statements executed, invisibly.
#' @export
hv_ensure_table <- function(db_con, table = "gage_readings") {
  qtable <- as.character(DBI::dbQuoteIdentifier(db_con, table))
  ddl <- glue::glue("
    CREATE TABLE IF NOT EXISTS {qtable} (
      location_id  TEXT        NOT NULL,
      parameter_id TEXT        NOT NULL,
      unit_id      TEXT,
      timestamp    TIMESTAMPTZ NOT NULL,
      value        DOUBLE PRECISION,
      PRIMARY KEY (location_id, parameter_id, timestamp)
    );
  ")
  invisible(DBI::dbExecute(db_con, ddl))
}

#' Per-location latest timestamp in a readings table
#'
#' @param source Where existing readings live: either a DBI connection /
#'   `pool::Pool` to PostgreSQL, or a data frame of readings with (at least)
#'   `location_id` and `timestamp` columns -- e.g. a previously saved RDS of
#'   [hv_readings()] output, for file-based workflows without a database.
#' @param table Target table name. Ignored when `source` is a data frame.
#' @param location_ids Optional character vector to scope the query. If `NULL`
#'   (default), the query covers every location present in the table.
#'
#' @return Tibble with `location_id` and `last_ts` (POSIXct, UTC) columns.
#' @export
hv_last_timestamps <- function(source, table = "gage_readings",
                               location_ids = NULL) {
  empty <- tibble::tibble(
    location_id = character(),
    last_ts     = as.POSIXct(character(), tz = "UTC")
  )
  if (!is.null(location_ids) && length(location_ids) == 0L) return(empty)

  if (is.data.frame(source)) {
    missing <- setdiff(c("location_id", "timestamp"), names(source))
    if (length(missing) > 0L) {
      stop("`source` data frame is missing required column(s): ",
           paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    ids  <- as.character(source$location_id)
    ts   <- as_utc(source$timestamp, "source$timestamp")
    keep <- !is.na(ids) & !is.na(ts)
    if (!is.null(location_ids)) keep <- keep & ids %in% as.character(location_ids)
    if (!any(keep)) return(empty)
    return(
      tibble::tibble(location_id = ids[keep], timestamp = ts[keep]) |>
        dplyr::group_by(.data$location_id) |>
        dplyr::summarise(last_ts = max(.data$timestamp), .groups = "drop")
    )
  }

  sql <- if (is.null(location_ids)) {
    glue::glue_sql("
      SELECT location_id, MAX(timestamp) AS last_ts
      FROM {`table`}
      GROUP BY location_id
    ", .con = source)
  } else {
    glue::glue_sql("
      SELECT location_id, MAX(timestamp) AS last_ts
      FROM {`table`}
      WHERE location_id IN ({ids*})
      GROUP BY location_id
    ", ids = as.character(location_ids), .con = source)
  }

  DBI::dbGetQuery(source, sql) |>
    tibble::as_tibble() |>
    dplyr::mutate(last_ts = as_utc(.data$last_ts))
}

#' Upsert a data frame into a PostgreSQL table
#'
#' Stages `df` to a temporary table, then runs
#' `INSERT ... ON CONFLICT (<unique_cols>) DO UPDATE` (or `DO NOTHING`) against
#' the target. Postgres-specific.
#'
#' If `db_con` is a `pool::Pool`, a single underlying connection is checked
#' out for the duration so the temporary table is visible to the INSERT.
#'
#' @param db_con A DBI connection or `pool::Pool` to PostgreSQL.
#' @param df Data frame to upsert.
#' @param table Target table name.
#' @param unique_cols Columns making up the conflict target (typically the
#'   primary key or a `UNIQUE` constraint).
#' @param overwrite If `TRUE` (default), `DO UPDATE`; otherwise `DO NOTHING`.
#' @param batch_size If non-NULL, split the upsert into batches of this size.
#' @param quiet If `TRUE`, suppress the completion message (used by [hv_sync()]).
#'
#' @return The number of rows upserted, invisibly.
#' @export
hv_upsert <- function(db_con, df, table, unique_cols,
                      overwrite = TRUE, batch_size = NULL, quiet = FALSE) {
  if (nrow(df) == 0L) {
    if (!quiet) message("No rows to upsert into ", table, ".")
    return(invisible(0L))
  }
  
  is_pool <- requireNamespace("pool", quietly = TRUE) &&
    inherits(db_con, "Pool")
  conn <- if (is_pool) pool::poolCheckout(db_con) else db_con
  if (is_pool) on.exit(pool::poolReturn(conn), add = TRUE)
  
  cols    <- names(df)
  qid     <- function(x) as.character(DBI::dbQuoteIdentifier(conn, x))
  qid_csv <- function(x) paste(vapply(x, qid, character(1)), collapse = ", ")
  
  conflict <- if (isTRUE(overwrite)) {
    upd <- setdiff(cols, unique_cols)
    sets <- vapply(upd, function(col)
      sprintf("%s = EXCLUDED.%s", qid(col), qid(col)),
      character(1))
    sprintf("DO UPDATE SET %s", paste(sets, collapse = ", "))
  } else {
    "DO NOTHING"
  }
  
  tmp <- sprintf("tmp_upsert_%d_%d",
                 as.integer(Sys.time()),
                 sample.int(.Machine$integer.max, 1L))
  
  do_batch <- function(chunk) {
    DBI::dbWriteTable(conn, tmp, chunk, temporary = TRUE, overwrite = TRUE)
    sql <- sprintf(
      "INSERT INTO %s (%s) SELECT %s FROM %s ON CONFLICT (%s) %s",
      qid(table), qid_csv(cols), qid_csv(cols),
      qid(tmp), qid_csv(unique_cols), conflict
    )
    DBI::dbExecute(conn, sql)
    DBI::dbExecute(conn, sprintf("DROP TABLE IF EXISTS %s", qid(tmp)))
  }
  
  if (is.null(batch_size)) {
    do_batch(df)
  } else if (batch_size > 0L) {
    for (i in seq.int(1L, nrow(df), by = batch_size)) {
      do_batch(df[i:min(i + batch_size - 1L, nrow(df)), , drop = FALSE])
    }
  } else {
    stop("`batch_size` must be > 0 if supplied.", call. = FALSE)
  }
  
  if (!quiet) message("Upserted ", nrow(df), " rows into ", table, ".")
  invisible(nrow(df))
}

#' Compute per-location fetch windows from existing readings
#'
#' Looks up the most recent stored timestamp for each location and returns a
#' tibble of `[location_id, start_ts, end_ts]` suitable for passing to
#' [hv_readings()].
#'
#' For each location: `start_ts = MAX(timestamp) - overlap_days`. If a
#' location has no stored readings yet, `start_ts` falls back to
#' `now - fresh_start_days`. `end_ts` is always "now" (UTC).
#'
#' When `start_fresh = TRUE`, the lookup is skipped and every location
#' gets the same `fresh_start_days` window.
#'
#' @inheritParams hv_last_timestamps
#' @param locations Tibble with at least a `location_id` column (typically
#'   a filtered copy of `hv_locations(con)`). Any other columns are passed
#'   through unchanged.
#' @param table Readings table to read `MAX(timestamp)` from. Ignored when
#'   `source` is a data frame.
#' @param overlap_days Days to back off the last-seen timestamp by, to
#'   tolerate late-arriving boundary points.
#' @param fresh_start_days Days back to fetch when no prior data exists for
#'   a location.
#' @param start_fresh If `TRUE`, ignore existing timestamps and assign every
#'   location the same `fresh_start_days` window.
#'
#' @return `locations` with two added columns: `start_ts` and `end_ts` (both
#'   POSIXct, UTC).
#' @export
#'
#' @examples
#' \dontrun{
#' locs <- hv_locations(con) |> dplyr::filter(name %in% my_gages$name)
#' windows <- hv_compute_windows(db, locs, table = "gage_readings",
#'                               overlap_days = 2)
#' windows
#'
#' # File-based: compute windows from a previously saved readings tibble
#' existing <- readRDS("readings.rds")
#' windows  <- hv_compute_windows(existing, locs, overlap_days = 2)
#' }
hv_compute_windows <- function(source, locations,
                               table            = "gage_readings",
                               overlap_days     = 2,
                               fresh_start_days = 14,
                               start_fresh      = FALSE) {
  if (!is.data.frame(locations)) {
    stop("`locations` must be a data frame.", call. = FALSE)
  }
  if (!"location_id" %in% names(locations)) {
    stop("`locations` must include a `location_id` column.", call. = FALSE)
  }
  
  now         <- lubridate::with_tz(Sys.time(), "UTC")
  fresh_start <- now - lubridate::days(fresh_start_days)
  
  if (isTRUE(start_fresh)) {
    return(dplyr::mutate(locations, start_ts = fresh_start, end_ts = now))
  }
  
  locations |>
    dplyr::left_join(
      hv_last_timestamps(source, table, locations$location_id),
      by = "location_id"
    ) |>
    dplyr::mutate(
      start_ts = dplyr::coalesce(
        .data$last_ts - lubridate::days(overlap_days),
        fresh_start
      ),
      end_ts = now
    ) |>
    dplyr::select(-last_ts)
}

#' Validate a readings data frame against the target schema
#'
#' Checks that `readings` is well-formed for `hv_sync()` / `hv_upsert()`:
#' it must be a data frame, contain every column in `schema_cols`, have no
#' NAs in `unique_cols`, and have a POSIXct `timestamp` and numeric `value`.
#'
#' `timestamp` is normalised to UTC (same instant, UTC label), so a readings
#' frame built in local time is safe to pass through.
#'
#' Extra (non-schema) columns are dropped with a message. Duplicate rows on
#' `unique_cols` are deduplicated (first wins via `dplyr::distinct(..., .keep_all = TRUE)`).
#'
#' This is the same check `hv_sync()` runs internally; exposed so you can
#' validate ad-hoc readings before committing to an upsert.
#'
#' @param readings A data frame or tibble of readings.
#' @param unique_cols Columns whose values must be non-`NA` (typically the
#'   target table's primary key).
#' @param schema_cols Columns the result is projected onto, in order.
#'
#' @return A tibble with exactly `schema_cols`, deduplicated on `unique_cols`,
#'   with `timestamp` in UTC.
#' @export
hv_validate_readings <- function(
    readings,
    unique_cols = c("location_id", "parameter_id", "timestamp"),
    schema_cols = c("location_id", "parameter_id", "unit_id", "timestamp", "value")) {
  
  if (!is.data.frame(readings)) {
    stop("`readings` must be a data frame or tibble (got ",
         paste(class(readings), collapse = "/"), ").", call. = FALSE)
  }
  
  missing <- setdiff(schema_cols, names(readings))
  if (length(missing) > 0L) {
    stop("`readings` is missing required column(s): ",
         paste(missing, collapse = ", "),
         ".\n  Expected: ", paste(schema_cols, collapse = ", "),
         "\n  Got:      ", paste(names(readings), collapse = ", "),
         call. = FALSE)
  }
  
  for (col in unique_cols) {
    if (anyNA(readings[[col]])) {
      stop("`readings$", col, "` contains NA values.", call. = FALSE)
    }
  }
  
  if (!inherits(readings$timestamp, "POSIXct")) {
    stop("`readings$timestamp` must be POSIXct (got ",
         paste(class(readings$timestamp), collapse = "/"), ").",
         call. = FALSE)
  }
  
  if ("value" %in% schema_cols && !is.numeric(readings$value)) {
    stop("`readings$value` must be numeric (got ",
         paste(class(readings$value), collapse = "/"), ").", call. = FALSE)
  }
  
  extras <- setdiff(names(readings), schema_cols)
  if (length(extras) > 0L) {
    message("Dropping ", length(extras), " non-schema column(s): ",
            paste(extras, collapse = ", "))
  }
  
  readings |>
    dplyr::mutate(timestamp = lubridate::with_tz(.data$timestamp, "UTC")) |>
    dplyr::select(dplyr::all_of(schema_cols)) |>
    dplyr::distinct(dplyr::across(dplyr::all_of(unique_cols)),
                    .keep_all = TRUE) |>
    tibble::as_tibble()
}

#' Validate a readings data frame and upsert it into the target table
#'
#' Thin wrapper that runs [hv_validate_readings()] on `readings` and then
#' [hv_upsert()] into `table`. The HydroVu pull is deliberately not part of
#' this function — fetch with [hv_readings()] (optionally after computing
#' windows with [hv_compute_windows()]), inspect or transform the result,
#' then hand it off here.
#'
#' @param db_con A DBI connection or `pool::Pool` to PostgreSQL.
#' @param readings A data frame of readings; see [hv_validate_readings()]
#'   for the required shape.
#' @param table Target readings table.
#' @param unique_cols Conflict target for the upsert. Default
#'   `c("location_id", "parameter_id", "timestamp")`.
#' @param batch_size Optional batch size for the upsert.
#' @param ensure_table If `TRUE` (default), call [hv_ensure_table()] first.
#'
#' @return The validated, projected readings (invisibly).
#' @export
#'
#' @examples
#' \dontrun{
#' con <- hv_connect()
#' db  <- DBI::dbConnect(RPostgres::Postgres(), ...)
#'
#' locs    <- hv_locations(con) |> dplyr::filter(name %in% my_gages$name)
#' windows <- hv_compute_windows(db, locs, table = "gage_readings",
#'                               overlap_days = 2)
#' rdgs    <- hv_readings(con, windows$location_id,
#'                        windows$start_ts, windows$end_ts)
#'
#' # inspect rdgs here -- it's just a tibble
#'
#' hv_sync(db, rdgs, table = "gage_readings")
#' }
hv_sync <- function(db_con, readings, table = "gage_readings",
                    unique_cols  = c("location_id", "parameter_id", "timestamp"),
                    batch_size   = 5000L,
                    ensure_table = TRUE) {
  if (isTRUE(ensure_table)) hv_ensure_table(db_con, table)

  to_upsert <- hv_validate_readings(readings, unique_cols = unique_cols)

  if (nrow(to_upsert) == 0L) {
    message("hv_sync: 0 rows after validation -- nothing written to ", table, ".")
    return(invisible(to_upsert))
  }

  n_locs <- dplyr::n_distinct(to_upsert$location_id)
  ts_min <- format(min(to_upsert$timestamp), "%Y-%m-%d %H:%M:%S", tz = "UTC")
  ts_max <- format(max(to_upsert$timestamp), "%Y-%m-%d %H:%M:%S", tz = "UTC")
  message(sprintf(
    "hv_sync: writing %s rows to '%s'  [%s -> %s]  (%d location(s))",
    format(nrow(to_upsert), big.mark = ","), table, ts_min, ts_max, n_locs
  ))

  t0 <- proc.time()[["elapsed"]]
  hv_upsert(db_con, to_upsert, table, unique_cols,
            batch_size = batch_size, quiet = TRUE)
  dt <- round(proc.time()[["elapsed"]] - t0, 1L)

  message(sprintf("hv_sync: done  (%ss)", dt))
  invisible(to_upsert)
}