readRenviron("c:/Users/skylerlewis/Github/hydrovur/.Renviron")
devtools::load_all("c:/Users/skylerlewis/Github/hydrovur", quiet = TRUE)
library(dplyr)
library(lubridate)
library(paws)
library(RPostgres)
library(pool)

TEST_TABLE <- "test_hydrovu_readings"

# ── DB connection ────────────────────────────────────────────────────────────
cat("Connecting to database via Secrets Manager...\n")
secret <- paws::secretsmanager()$get_secret_value(
  SecretId = Sys.getenv("SECRET_MANAGER_SECRET_NAME")
)$SecretString |> jsonlite::fromJSON()

db <- pool::dbPool(
  drv      = RPostgres::Postgres(),
  host     = if (!is.null(secret$host)) secret$host
              else "interoperable-flows-db.ctfqkslimkx4.us-west-2.rds.amazonaws.com",
  port     = 5432,
  dbname   = if (!is.null(secret$dbname)) secret$dbname else "postgres",
  user     = secret$username,
  password = secret$password,
  sslmode  = "require",
  timezone = "UTC"
)
# No top-level on.exit(): under source() it fires immediately and closes the
# pool. The pool is closed explicitly at the end instead.
cat("Connected to DB\n\n")

# ── Ensure / inspect table ───────────────────────────────────────────────────
cat("=== hv_ensure_table ===\n")
hv_ensure_table(db, TEST_TABLE)
cat("Table ready\n\n")

cat("=== hv_last_timestamps (empty table) ===\n")
ts0 <- hv_last_timestamps(db, TEST_TABLE)
cat("Rows:", nrow(ts0), "(expect 0)\n\n")

# ── HydroVu fetch ────────────────────────────────────────────────────────────
cat("=== HydroVu: fetch yesterday for 2 stage-gage locations ===\n")
con <- hv_connect()

stage_locs <- hv_locations(con) |>
  filter(grepl("^2025SGMC0[13]$", name))  # MC-01 and MC-03 trolls only
cat("Locations:\n")
print(stage_locs[, c("location_id", "name")])

windows <- hv_compute_windows(
  db, stage_locs, table = TEST_TABLE,
  fresh_start_days = 1, overlap_days = 0
)
cat("\nWindows:\n")
print(windows[, c("name", "start_ts", "end_ts")])

readings <- hv_readings(con,
                        location_ids = windows$location_id,
                        start        = windows$start_ts,
                        end          = windows$end_ts)
cat("\nFetched", nrow(readings), "rows\n")
cat("Timestamp range:",
    format(min(readings$timestamp)), "->", format(max(readings$timestamp)), "\n\n")

stopifnot(
  nrow(readings) > 0L,
  identical(attr(readings$timestamp, "tzone"), "UTC"),
  identical(attr(windows$start_ts, "tzone"), "UTC"),
  identical(attr(windows$end_ts, "tzone"), "UTC"),
  all(readings$timestamp >= min(windows$start_ts)),
  all(readings$timestamp <= max(windows$end_ts))
)
cat("UTC labels + window bounds OK\n\n")

# ── First sync ───────────────────────────────────────────────────────────────
cat("=== hv_sync (first write) ===\n")
hv_sync(db, readings, table = TEST_TABLE)

row_count <- function() {
  DBI::dbGetQuery(
    db, glue::glue_sql("SELECT COUNT(*) AS n FROM {`TEST_TABLE`}", .con = db)
  )$n |> as.integer()  # COUNT(*) is integer64
}

n1 <- row_count()
cat("Rows in table after first sync:", n1, "\n\n")
stopifnot(n1 > 0L)

# ── Idempotency ──────────────────────────────────────────────────────────────
cat("=== Idempotency: re-sync same window ===\n")
hv_sync(db, readings, table = TEST_TABLE)
n2 <- row_count()
cat("Rows after second sync:", n2, "(expect same as", n1, ")\n")
stopifnot(n1 == n2)
cat("Idempotency OK\n\n")

# ── Round-trip: DB timestamps match fetched instants ─────────────────────────
cat("=== Round-trip timestamps ===\n")
ts_db <- hv_last_timestamps(db, TEST_TABLE)
ts_mem <- readings |>
  group_by(location_id) |>
  summarise(last_mem = max(timestamp), .groups = "drop")
rt <- inner_join(ts_db, ts_mem, by = "location_id")
print(rt)
stopifnot(
  identical(attr(ts_db$last_ts, "tzone"), "UTC"),
  nrow(rt) == n_distinct(readings$location_id),
  all(rt$last_ts == rt$last_mem)
)
cat("Round-trip OK (no timezone shift on write/read)\n\n")

# ── hv_compute_windows with existing data ────────────────────────────────────
cat("=== hv_compute_windows with existing DB state ===\n")
windows2 <- hv_compute_windows(db, stage_locs, table = TEST_TABLE, overlap_days = 2)
cat("start_ts should be ~(last_ts - 2 days):\n")
print(windows2[, c("name", "start_ts", "end_ts")])
stopifnot(
  all(!is.na(windows2$start_ts)),
  identical(attr(windows2$start_ts, "tzone"), "UTC"),
  all(windows2$start_ts ==
        rt$last_ts[match(windows2$location_id, rt$location_id)] - days(2))
)

# ── Per-location coverage ────────────────────────────────────────────────────
cat("\n=== Coverage ===\n")
hv_last_timestamps(db, TEST_TABLE) |>
  left_join(stage_locs[, c("location_id", "name")], by = "location_id") |>
  select(name, last_ts) |>
  print()

# ── Cleanup ──────────────────────────────────────────────────────────────────
cat("\n=== Cleanup ===\n")
DBI::dbExecute(db, glue::glue_sql("DROP TABLE {`TEST_TABLE`}", .con = db))
cat("Test table dropped\n")
pool::poolClose(db)

cat("\nAll DB integration checks passed.\n")
