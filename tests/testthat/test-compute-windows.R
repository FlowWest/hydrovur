make_locs <- function(ids = c("loc1", "loc2")) {
  tibble::tibble(location_id = ids, name = ids)
}

test_that("hv_compute_windows with start_fresh=TRUE skips DB and assigns fixed window", {
  locs <- make_locs()
  # No db_con needed when start_fresh = TRUE — the function returns early before any DB call
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
    hv_last_timestamps = function(db_con, table, location_ids) {
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
