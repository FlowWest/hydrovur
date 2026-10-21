# rhydrovu

Connection-oriented R client for the [HydroVu public API](https://www.hydrovu.com/public-api/docs/), with helpers for incrementally syncing readings into a PostgreSQL backend.

## Installation

```r
# install.packages("devtools")
devtools::install_github("FlowWest/rhydrovu")
```

## Authentication

Create a client ID and secret on the HydroVu People & Permissions page, then set them as environment variables (`.Renviron` recommended):

```
HYDROVU_CLIENT_ID=your_client_id
HYDROVU_CLIENT_SECRET=your_client_secret
```

Or pass them directly to `hv_connect()` for quick testing:

```r
con <- hv_connect(client_id = "...", client_secret = "...")
```

## Quick start

```r
library(rhydrovu)
library(dplyr)

# 1. Connect — authenticates via OAuth2 and caches locations + parameters.
con <- hv_connect()
con
#> <hydrovu_connection>
#>   base_url:   https://hydrovu.com/public-api/v1
#>   token:      *** (expires 2026-06-15 21:00:00)
#>   locations:  20 cached
#>   parameters: 38 cached

# 2. Inspect what's available.
hv_locations(con)    # tibble: location_id, name, gps.latitude, gps.longitude
hv_parameters(con)   # tibble: parameter_id, parameter_name
hv_units(con)        # tibble: unit_id, unit_name

# 3. Fetch readings for selected locations over a time window.
locs <- hv_locations(con) |> filter(grepl("SGMC", name))

readings <- hv_readings(
  con,
  location_ids = locs$location_id,
  start = "2026-06-01",
  end   = "2026-06-15"
)
#> # A tibble: 54,288 × 6
#>   location_id      parameter_id parameter_name unit_id timestamp           value
#>   <chr>            <chr>        <chr>          <chr>   <dttm>              <dbl>
#> 1 4922487325392896 2            Pressure       17      2026-06-01 00:00:00  12.3
#> …
```

`hv_readings()` fetches all pages automatically. Per-location failures are caught and warned rather than aborting the whole batch. All timestamps are UTC.

## Sync to PostgreSQL

The pipeline is three explicit steps so readings stay inspectable before touching the database:

```r
library(DBI)
db <- DBI::dbConnect(RPostgres::Postgres(), host = "...", ...)

locs <- hv_locations(con) |> filter(name %in% my_gages$name)

# 1. Compute per-location fetch windows from existing DB state.
#    Backs off `overlap_days` before each location's last stored timestamp
#    to tolerate late-arriving data; uses `fresh_start_days` for new locations.
windows <- hv_compute_windows(db, locs, table = "gage_readings",
                              overlap_days = 2, fresh_start_days = 14)

# 2. Fetch from HydroVu. Inspect or transform the result before committing.
readings <- hv_readings(con,
                        location_ids = windows$location_id,
                        start        = windows$start_ts,
                        end          = windows$end_ts)

# 3. Validate shape and upsert (INSERT … ON CONFLICT … DO UPDATE).
hv_sync(db, readings, table = "gage_readings")
```

`hv_sync()` validates via `hv_validate_readings()` — required columns, no NAs in
primary-key columns, `timestamp` is POSIXct, `value` is numeric — then upserts.
Re-running the same window is safe (idempotent).

### Without a database

`hv_compute_windows()` and `hv_last_timestamps()` also accept a data frame of
previously fetched readings (anything with `location_id` and `timestamp`) in
place of a DB connection, for file-based workflows:

```r
existing <- readRDS("readings.rds")
windows  <- hv_compute_windows(existing, locs, overlap_days = 2)
new      <- hv_readings(con, windows$location_id, windows$start_ts, windows$end_ts)
saveRDS(dplyr::bind_rows(existing, new) |>
          dplyr::distinct(location_id, parameter_id, timestamp, .keep_all = TRUE),
        "readings.rds")
```

### Database schema

`hv_ensure_table()` creates the target table if it doesn't exist:

```sql
CREATE TABLE gage_readings (
  location_id  TEXT        NOT NULL,
  parameter_id TEXT        NOT NULL,
  unit_id      TEXT,
  timestamp    TIMESTAMPTZ NOT NULL,
  value        DOUBLE PRECISION,
  PRIMARY KEY (location_id, parameter_id, timestamp)
);
```

`location_id` and `parameter_id` are the raw API integer IDs stored as text.
Join against `hv_locations(con)`, `hv_parameters(con)` and `hv_units(con)` to
resolve names.

## Server job

`inst/exec/sync-job.R` is a standalone script for automated syncing. After installing the package, locate it with `system.file("exec/sync-job.R", package = "rhydrovu")`.

```bash
Rscript /path/to/sync-job.R                                # all locations → gage_readings
Rscript /path/to/sync-job.R --table staging --fresh        # ignore existing state
Rscript /path/to/sync-job.R --locations 2025SGMC01,2025SGMC03
```

Required environment variables:

| Variable | Description |
|---|---|
| `HYDROVU_CLIENT_ID` | HydroVu OAuth2 client ID |
| `HYDROVU_CLIENT_SECRET` | HydroVu OAuth2 client secret |
| `SECRET_MANAGER_SECRET_NAME` | AWS Secrets Manager secret name (see below) |

Optional:

| Variable | Default |
|---|---|
| `HYDROVU_TABLE` | database table, e.g. `gage_readings` |
| `HYDROVU_DB_HOST` | hardcoded RDS hostname |

### AWS Secrets Manager

The script resolves DB credentials from Secrets Manager using the `paws` package. The secret should be a JSON object with at minimum `username` and `password` (and optionally `host`, `port`, `dbname`):

```json
{ "username": "...", "password": "..." }
```

Requires standard AWS credential configuration (IAM role, `~/.aws/credentials`, or `AWS_*` environment variables).

### Scheduling

Run as a cron job or systemd timer. Example cron (hourly):

```cron
0 * * * * Rscript /path/to/sync-job.R >> /var/log/rhydrovu-sync.log 2>&1
```

The script logs timestamped lines to stderr and exits non-zero on critical failures, making it compatible with cron, systemd, or any process supervisor.

## Package layout

| File | Responsibility |
|---|---|
| `R/connection.R` | OAuth2 client-credentials flow; connection environment |
| `R/api-internals.R` | Low-level HTTP wrappers (`isi_paginate`, `get_readings`, …) |
| `R/locations.R` | Cached locations accessor (`hv_locations`) |
| `R/parameters.R` | Cached parameter friendly-names (`hv_parameters`) |
| `R/units.R` | Cached unit friendly-names (`hv_units`) |
| `R/readings.R` | Per-location windowed readings fetch (`hv_readings`) |
| `R/sync.R` | PostgreSQL pipeline (`hv_ensure_table`, `hv_compute_windows`, `hv_sync`, `hv_upsert`, …) |
| `R/utils.R` | Internal helpers |
| `inst/exec/sync-job.R` | Standalone server sync script |

## API notes

- **Authentication**: OAuth2 client credentials. Tokens auto-refresh near expiry.
- **Pagination**: header-based (`X-ISI-Next-Page` / `X-ISI-Start-Page`), handled automatically.
- **Date filtering**: `startTime` / `endTime` are Unix epoch integers (seconds). The API ignores ISO 8601 date strings.
- **Timestamps**: VuLink device timestamps are always UTC. Cube/Tube devices may report in local time.
- **Rate limit**: 1,000 requests/minute. Headers `X-ISI-Requests-This-Minute` and `X-ISI-Requests-Timeout` indicate current usage.
- **API spec**: `data-raw/public-api-spec.json`

## Development

```r
devtools::document()   # regenerate man/ and NAMESPACE from roxygen comments
devtools::test()       # run unit tests
devtools::check()      # full R CMD check (cran = FALSE for local)
```

Integration and test scripts are in `data-raw/`. The notebook
`data-raw/test-hydrovu-fetch.Rmd` exercises every public function against the
live API and database; run chunk-by-chunk rather than knitting.
