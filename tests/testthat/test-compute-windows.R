make_locs <- function(ids = c("loc1", "loc2")) {
  tibble::tibble(location_id = ids, name = ids)
}

test_that("hv_compute_windows with start_fresh=TRUE skips DB and assigns fixed window", {
  locs <- make_locs()
  # No source needed when start_fresh = TRUE — the function returns early before any lookup
  out <- hv_compute_windows(NULL, locs, table = "t", fresh_start_days = 14,
                            start_fresh = TRUE)

  expect_named(out, c("location_id", "name", "start_ts", "end_ts"), ignore.order = TRUE)
  expect_equal(nrow(out), 2L)

  now <- lubridate::with_tz(Sys.time(), "UTC")
  expect_true(all(inherits(out$start_ts, "POSIXct")))
  expect_true(all(inherits(out$end_ts,   "POSIXct")))

  # start_ts should be ~14 days ago (within a few seconds of test execution)
  expect_true(all(abs(as.numeric(out$start_ts - (now - lubridate::days(14)), units = "secs")) < 5))
  expect_true(all(abs(as.numeric(out$end_ts   - now,                        units = "secs")) < 5))
})

test_that("hv_compute_windows errors on missing location_id column", {
  bad <- tibble::tibble(name = "x")
  expect_error(hv_compute_windows(NULL, bad, start_fresh = TRUE),
               regexp = "location_id")
})

test_that("hv_compute_windows errors on non-data-frame locations", {
  expect_error(hv_compute_windows(NULL, list(location_id = "x"), start_fresh = TRUE),
               regexp = "data frame")
})

test_that("hv_compute_windows backs off last_ts by overlap_days and falls back for new locations", {
  last <- as.POSIXct("2026-06-01 12:00:00", tz = "UTC")
  local_mocked_bindings(
    hv_last_timestamps = function(source, table, location_ids) {
      tibble::tibble(location_id = "loc1", last_ts = last)
    }
  )
  out <- hv_compute_windows(NULL, make_locs(), table = "t",
                            overlap_days = 2, fresh_start_days = 14)

  expect_named(out, c("location_id", "name", "start_ts", "end_ts"))
  expect_equal(out$start_ts[out$location_id == "loc1"], last - lubridate::days(2))

  now <- lubridate::with_tz(Sys.time(), "UTC")
  fresh <- out$start_ts[out$location_id == "loc2"]
  expect_lt(abs(as.numeric(fresh - (now - lubridate::days(14)), units = "secs")), 5)
})

test_that("hv_last_timestamps short-circuits on empty location_ids", {
  out <- hv_last_timestamps(NULL, "t", character())
  expect_equal(nrow(out), 0L)
  expect_named(out, c("location_id", "last_ts"))
})

test_that("hv_last_timestamps computes per-location max from a data frame source", {
  readings <- tibble::tibble(
    location_id = c("loc1", "loc1", "loc2", "loc3"),
    timestamp   = as.POSIXct(c("2026-06-01 00:00:00", "2026-06-02 00:00:00",
                               "2026-05-01 00:00:00", NA), tz = "UTC")
  )
  out <- hv_last_timestamps(readings)
  expect_named(out, c("location_id", "last_ts"))
  expect_equal(out$location_id, c("loc1", "loc2"))
  expect_equal(out$last_ts, as.POSIXct(c("2026-06-02", "2026-05-01"), tz = "UTC"))
  expect_equal(attr(out$last_ts, "tzone"), "UTC")

  scoped <- hv_last_timestamps(readings, location_ids = "loc2")
  expect_equal(scoped$location_id, "loc2")

  none <- hv_last_timestamps(readings, location_ids = "nope")
  expect_equal(nrow(none), 0L)
  expect_s3_class(none$last_ts, "POSIXct")
})

test_that("hv_last_timestamps errors on a data frame missing required columns", {
  expect_error(hv_last_timestamps(tibble::tibble(location_id = "x")),
               regexp = "timestamp")
})

test_that("hv_compute_windows accepts a data frame of existing readings", {
  readings <- tibble::tibble(
    location_id = "loc1",
    timestamp   = as.POSIXct("2026-06-01 12:00:00", tz = "UTC")
  )
  out <- hv_compute_windows(readings, make_locs(), overlap_days = 2,
                            fresh_start_days = 14)
  expect_equal(out$start_ts[out$location_id == "loc1"],
               as.POSIXct("2026-05-30 12:00:00", tz = "UTC"))
  now <- lubridate::with_tz(Sys.time(), "UTC")
  fresh <- out$start_ts[out$location_id == "loc2"]
  expect_lt(abs(as.numeric(fresh - (now - lubridate::days(14)), units = "secs")), 5)
})
