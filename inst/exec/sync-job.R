#!/usr/bin/env Rscript
#
# sync-job.R — Sync HydroVu readings to AWS RDS
#
# Usage:
#   Rscript sync-job.R [--table <name>] [--fresh] [--locations <loc1,loc2,...>]
#
# Required env vars:
#   HYDROVU_CLIENT_ID       HydroVu OAuth2 client ID
#   HYDROVU_CLIENT_SECRET   HydroVu OAuth2 client secret
#   SECRET_MANAGER_SECRET_NAME  AWS Secrets Manager secret (DB credentials)
#
# Optional env vars:
#   HYDROVU_TABLE   Target table name (default: gage_readings)
#   HYDROVU_DB_HOST Override host if not in the secret
#
# Flags:
#   --fresh         Ignore existing DB state; fetch last 14 days for all locations
#   --table NAME    Override the target table (takes precedence over HYDROVU_TABLE)
#   --locations L   Comma-separated HydroVu location names to sync (default: all)

suppressPackageStartupMessages({
  library(hydrovur)
  library(dplyr)
  library(lubridate)
  library(paws)
  library(RPostgres)
  library(pool)
  library(jsonlite)
})

coalesce_null <- function(x, y) if (is.null(x)) y else x

# ── Logging ──────────────────────────────────────────────────────────────────

log_ts <- function(...) {
  message(format(Sys.time(), "[%Y-%m-%d %H:%M:%S UTC]", tz = "UTC"), " ", ...)
}

# ── Main ─────────────────────────────────────────────────────────────────────

main <- function() {

  # -- Parse args -------------------------------------------------------------
  argv        <- commandArgs(trailingOnly = TRUE)
  start_fresh <- "--fresh" %in% argv
  table_name  <- {
    idx <- which(argv == "--table")
    if (length(idx) > 0L) argv[idx + 1L]
    else if (nzchar(Sys.getenv("HYDROVU_TABLE"))) Sys.getenv("HYDROVU_TABLE")
    else "gage_readings"
  }
  filter_locs <- {
    idx <- which(argv == "--locations")
    if (length(idx) > 0L) strsplit(argv[idx + 1L], ",")[[1L]] else NULL
  }

  log_ts("hydrovur sync-job starting")
  log_ts("  table       = ", table_name)
  log_ts("  start_fresh = ", start_fresh)
  log_ts("  locations   = ", if (is.null(filter_locs)) "(all)"
                              else paste(filter_locs, collapse = ", "))

  # -- Validate required env vars ---------------------------------------------
  for (v in c("HYDROVU_CLIENT_ID", "HYDROVU_CLIENT_SECRET",
              "SECRET_MANAGER_SECRET_NAME")) {
    if (!nzchar(Sys.getenv(v))) stop("Required env var ", v, " is not set")
  }

  # -- Connect to HydroVu -----------------------------------------------------
  log_ts("Connecting to HydroVu API...")
  con      <- hv_connect()
  all_locs <- hv_locations(con)
  log_ts("HydroVu connected: ", nrow(all_locs), " locations available")

  # -- Filter locations -------------------------------------------------------
  sync_locs <- if (!is.null(filter_locs)) {
    matched <- all_locs |> filter(name %in% filter_locs)
    missing <- setdiff(filter_locs, matched$name)
    if (length(missing) > 0L)
      warning("Locations not found in HydroVu: ", paste(missing, collapse = ", "))
    matched
  } else {
    all_locs
  }
  if (nrow(sync_locs) == 0L) stop("No locations to sync")
  log_ts("Syncing ", nrow(sync_locs), " location(s)")

  # -- Connect to DB ----------------------------------------------------------
  log_ts("Fetching DB credentials from Secrets Manager...")
  secret <- paws::secretsmanager()$get_secret_value(
    SecretId = Sys.getenv("SECRET_MANAGER_SECRET_NAME")
  )$SecretString |> fromJSON()

  fallback_host <- Sys.getenv("HYDROVU_DB_HOST",
    unset = "interoperable-flows-db.ctfqkslimkx4.us-west-2.rds.amazonaws.com")

  log_ts("Connecting to PostgreSQL...")
  db <- pool::dbPool(
    drv      = RPostgres::Postgres(),
    host     = coalesce_null(secret$host,   fallback_host),
    port     = as.integer(coalesce_null(secret$port, 5432L)),
    dbname   = coalesce_null(secret$dbname, "postgres"),
    user     = secret$username,
    password = secret$password,
    sslmode  = "require",
    timezone = "UTC"   # session + returned POSIXct both UTC
  )
  on.exit(pool::poolClose(db), add = TRUE)
  log_ts("DB connected")

  # -- Ensure table -----------------------------------------------------------
  hv_ensure_table(db, table_name)

  # -- Compute fetch windows --------------------------------------------------
  log_ts("Computing fetch windows (overlap_days=2, fresh_start_days=14)...")
  windows <- hv_compute_windows(db, sync_locs, table = table_name,
                                overlap_days = 2, fresh_start_days = 14,
                                start_fresh  = start_fresh)

  # -- Fetch readings ----------------------------------------------------------
  log_ts("Fetching readings for ", nrow(windows), " location(s)...")
  t_fetch  <- proc.time()[["elapsed"]]
  readings <- hv_readings(con,
                          location_ids = windows$location_id,
                          start        = windows$start_ts,
                          end          = windows$end_ts)
  fetch_secs <- round(proc.time()[["elapsed"]] - t_fetch, 1L)
  log_ts("Fetched ", nrow(readings), " row(s) in ", fetch_secs, "s")

  if (nrow(readings) == 0L) {
    log_ts("No new readings to write — exiting")
    return(invisible(NULL))
  }

  # -- Sync to DB -------------------------------------------------------------
  log_ts("Upserting to ", table_name, "...")
  hv_sync(db, readings, table = table_name)

  # -- Coverage summary -------------------------------------------------------
  coverage <- hv_last_timestamps(db, table_name,
                                  location_ids = windows$location_id) |>
    left_join(sync_locs[, c("location_id", "name")], by = "location_id") |>
    arrange(name)

  log_ts("Coverage after sync:")
  for (i in seq_len(nrow(coverage))) {
    log_ts("  ", coverage$name[i], " -> ", format(coverage$last_ts[i]))
  }

  log_ts("Sync complete")
}

main()
