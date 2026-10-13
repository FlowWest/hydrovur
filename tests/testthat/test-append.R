make_rdgs <- function(ts, value, loc = "loc1", parm = "1", ...) {
  tibble::tibble(location_id = loc, parameter_id = parm,
                 timestamp = as.POSIXct(ts, tz = "UTC"), value = value, ...)
}

test_that("hv_append combines, dedupes, and lets new rows win", {
  existing <- make_rdgs(c("2026-06-01 00:00", "2026-06-01 00:15"), c(1, 2))
  new      <- make_rdgs(c("2026-06-01 00:15", "2026-06-01 00:30"), c(20, 3))

  out <- hv_append(existing, new)
  expect_equal(nrow(out), 3L)
  expect_equal(out$value, c(1, 20, 3))
  expect_equal(out$timestamp,
               as.POSIXct(c("2026-06-01 00:00", "2026-06-01 00:15",
                            "2026-06-01 00:30"), tz = "UTC"))
})

test_that("hv_append keeps extra columns", {
  existing <- make_rdgs("2026-06-01 00:00", 1, name = "a")
  new      <- make_rdgs("2026-06-01 00:15", 2, name = "a")
  out <- hv_append(existing, new)
  expect_true("name" %in% names(out))
  expect_equal(out$name, c("a", "a"))
})

test_that("hv_append treats NULL existing as empty", {
  new <- make_rdgs(c("2026-06-01 00:00", "2026-06-01 00:00"), c(1, 2))
  out <- hv_append(NULL, new)
  expect_equal(nrow(out), 1L)
  expect_equal(out$value, 1)
})

test_that("hv_append normalises timestamps to UTC", {
  new <- make_rdgs("2026-06-01 00:00", 1)
  new$timestamp <- lubridate::with_tz(new$timestamp, "America/Los_Angeles")
  out <- hv_append(NULL, new)
  expect_equal(attr(out$timestamp, "tzone"), "UTC")
})

test_that("hv_append honours custom unique_cols", {
  new <- make_rdgs(c("2026-06-01 00:00", "2026-06-01 00:00"), c(1, 2),
                   parm = c("1", "2"))
  out <- hv_append(NULL, new, unique_cols = c("location_id", "timestamp"))
  expect_equal(nrow(out), 1L)
})

test_that("hv_append validates its inputs", {
  ok <- make_rdgs("2026-06-01 00:00", 1)
  expect_error(hv_append(ok, list(a = 1)), regexp = "data frame")
  expect_error(hv_append(ok, ok[, c("location_id", "timestamp")]),
               regexp = "parameter_id")
  bad <- ok; bad$location_id <- NA_character_
  expect_error(hv_append(bad, ok), regexp = "existing\\$location_id")
})
