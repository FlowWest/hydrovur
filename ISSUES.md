# rhydrovu — Issues & TODO

## Critical

- [x] **`startDate`/`endDate` → `startTime`/`endTime` date filter completely broken** (`R/api-internals.R`)  
  Code passed ISO 8601 strings (`startDate`, `endDate`) which the API silently ignores — every call downloaded all historical data regardless of the requested window. Root cause confirmed from API spec: correct params are `startTime`/`endTime` as Unix epoch integer seconds.  
  _Fixed: `get_readings()` now passes `startTime = as.integer(as.numeric(start_ts))` and `endTime = as.integer(as.numeric(end_ts))`. Verified live: Test with 30-day window returned first ts `2026-05-16 20:30:00`; test with 1-day window returned only that day's readings. See `data-raw/public-api-spec.json` for authoritative API spec._

- [x] **`janitor` not listed in DESCRIPTION Imports** (`R/api-internals.R:61`)  
  `get_locations()` calls `janitor::clean_names()` but `janitor` is absent from `Imports:`.  
  Package fails at runtime on first `hv_locations()` call.  
  _Fix: add `janitor` to `Imports:` in DESCRIPTION._

## High

- [x] **BugReports URL typo in DESCRIPTION**  
  Points to `FlowWest/hydrovu/issues` — should be `FlowWest/rhydrovu/issues`.

- [x] **`.Renviron` not in `.gitignore`**  
  `.Renviron` holds live API credentials and an AWS Secrets Manager secret name.  
  If the repo is ever pushed, these are exposed. `.gitignore` currently only ignores `.Rhistory`, `.RData`, `.Ruserdata`, `*.Rproj`.  
  _Fix: add `.Renviron` (and `.Renviron.local`) to `.gitignore`._

- [ ] **Placeholder author in DESCRIPTION**  
  `Authors@R` still contains `"First", "Last", "you@example.com"`.  
  _Action needed: fill in real author name and email._

## Medium

- [x] **`hv_ensure_table` table name not SQL-quoted**  
  Uses bare `glue::glue("{table} ...")` instead of `DBI::dbQuoteIdentifier()`.  
  _Fixed: wrapped with `DBI::dbQuoteIdentifier(db_con, table)`._

- [x] **Token fetched once per `hv_readings()` batch**  
  `hv_token(con)` is called once at the top of `hv_readings()` and reused for all per-location fetches. If the batch is large or slow, the token can expire mid-run; subsequent locations fail silently via `purrr::safely()`.  
  _Fixed: moved `hv_token(con)` inside the per-location closure._

- [x] **`hv_last_timestamps` timezone label inconsistency**  
  RPostgres returned `last_ts` in the session's local timezone, so `start_ts` in `hv_compute_windows` could have a mixed-timezone column (`start_ts` in local, `end_ts` in UTC). Arithmetic was always correct because `format(..., tz = "UTC")` in `get_readings` guarded the API calls, but the labels were confusing.  
  _Fixed: added `lubridate::with_tz(last_ts, "UTC")` in `hv_last_timestamps`._

- [x] **Force UTC for all timestamps**  
  _Fixed: internal `as_utc()` (`R/utils.R`) normalises every datetime entry point. `hv_readings()` `start`/`end` accept POSIXct in any tz (instant kept), Date, epoch seconds, or character (offset-less strings read as **UTC**, explicit offsets honoured); NA/unparseable windows now error instead of silently hitting the API. Returned `timestamp`, `hv_last_timestamps()$last_ts`, `hv_validate_readings()` output, and `token_expires_at` are all UTC-labelled. DB pools in `sync-job.R` and the notebook pass `timezone = "UTC"` explicitly._  
  _Behaviour change: `hv_readings(start = "2026-05-01 08:00")` has always meant 08:00 UTC; now documented._

- [ ] **`parameter_name` silently `NA` when parameter not cached**  
  `get_readings()` left-joins against `parameter_df`. If `parameter_id` is unknown, `parameter_name` is silently `NA` rather than warned about.

## Low / Polish

- [ ] **R CMD check WARNING: `inst/exec` is reserved by R**  
  `sync-job.R` lives in `inst/exec/`, a subdirectory R itself uses. Moving it to e.g. `inst/scripts/` clears the warning but changes the `system.file("exec/sync-job.R", ...)` path in README and anywhere it's deployed from.

- [ ] **`hv_sync` emits two near-identical messages**  
  Prints `"Upserting N records..."` then `hv_upsert()` prints `"Upserted N rows..."`.  
  Mildly redundant; both are intentional (pre-op and post-op) but could be consolidated.

- [x] **`hv_readings()` returns empty tibble with no columns on short-circuit**  
  _Fixed: now returns a zero-row tibble with the full expected schema._

## Tests

- [x] `hv_connect` rejects missing credentials
- [x] `hv_token` / `hv_refresh_token` / `hv_locations` / `hv_parameters` / `hv_readings` reject non-connection input
- [x] `hv_readings` short-circuits on empty `location_ids`
- [x] `hv_validate_readings` — happy path and all error branches (pure function, no network/DB needed)
- [x] `hv_compute_windows` with `start_fresh = TRUE` (no DB needed)
- [x] `hv_compute_windows` input validation (`locations` not a data frame, missing `location_id`)
- [x] `hv_compute_windows` with mocked `hv_last_timestamps` result
- [x] `hv_upsert` SQL generation (DO UPDATE / DO NOTHING, batching, zero rows) — `DBI::dbExecute`/`dbWriteTable` mocked against `DBI::ANSI()`; no SQLite needed
- [x] `hv_ensure_table` DDL generation (string check only)
- [x] UTC normalisation: `as_utc()`, `hv_readings` windows + output, `hv_validate_readings`

## Notes

- The package is not a git repo yet — credentials in `.Renviron` are not currently at risk, but should be cleaned up before `git init`.
- The integration notebook in `data-raw/test-hydrovu-fetch.Rmd` contains hardcoded site names (Manning Creek, Piezometers).
- `hv_upsert` correctly handles `pool::Pool` by checking out/returning a single connection so the temp table is visible to the INSERT. This is a non-obvious but important correctness detail.
