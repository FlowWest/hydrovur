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
