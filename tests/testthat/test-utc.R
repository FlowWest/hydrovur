test_that("as_utc keeps the instant and relabels to UTC", {
  pdt <- as.POSIXct("2026-05-01 08:00:00", tz = "America/Los_Angeles")
  out <- as_utc(pdt)
  expect_equal(attr(out, "tzone"), "UTC")
  expect_equal(as.numeric(out), as.numeric(pdt))
  expect_equal(format(out, "%H:%M"), "15:00")

  expect_equal(as_utc(as.POSIXlt(pdt)), out)
})

test_that("as_utc reads offset-less character and Date input as UTC", {
  expect_equal(as_utc("2026-05-01"), as.POSIXct("2026-05-01", tz = "UTC"))
  expect_equal(as_utc("2026-05-01 08:00:00"),
               as.POSIXct("2026-05-01 08:00:00", tz = "UTC"))
  expect_equal(as_utc(as.Date("2026-05-01")), as.POSIXct("2026-05-01", tz = "UTC"))
  expect_equal(as_utc(1764794700),
               as.POSIXct("2025-12-03 20:45:00", tz = "UTC"))
})

test_that("as_utc honours explicit offsets in character input", {
  expect_equal(as_utc("2026-05-01T08:00:00-07:00"),
               as.POSIXct("2026-05-01 15:00:00", tz = "UTC"))
})

test_that("as_utc errors on unparseable input but passes NA through", {
  expect_error(as_utc("not a date", "start"), regexp = "`start`.*not a date")
  expect_true(is.na(as_utc(NA)))
})

fake_con <- function() {
  con <- new.env(parent = emptyenv())
  con$base_url <- "https://example.invalid"
  class(con) <- "hydrovu_connection"
  con
}

test_that("hv_readings sends UTC windows and returns UTC timestamps", {
  seen <- new.env(parent = emptyenv())
  local_mocked_bindings(
    hv_parameters = function(con, ...) tibble::tibble(parameter_id = character(),
                                                      parameter_name = character()),
    hv_token      = function(con) "tok",
    get_readings  = function(token, location_id, parameter_df, start_ts, end_ts, base_url) {
      seen$start <- start_ts
      seen$end   <- end_ts
      tibble::tibble(parameter_id = "1", parameter_name = "Temp", unit_id = "1",
                     # simulate a non-UTC label coming back
                     timestamp = lubridate::with_tz(start_ts, "America/Los_Angeles"),
                     value = 1)
    }
  )
  start <- as.POSIXct("2026-05-01 08:00:00", tz = "America/Los_Angeles")
  out <- suppressMessages(hv_readings(fake_con(), "123", start, "2026-05-02"))

  expect_equal(attr(seen$start, "tzone"), "UTC")
  expect_equal(seen$start, as.POSIXct("2026-05-01 15:00:00", tz = "UTC"))
  expect_equal(seen$end,   as.POSIXct("2026-05-02 00:00:00", tz = "UTC"))
  expect_equal(attr(out$timestamp, "tzone"), "UTC")
})

test_that("hv_readings rejects NA and unparseable windows", {
  con <- fake_con()
  expect_error(hv_readings(con, "123", NA, Sys.time()), regexp = "NA")
  expect_error(hv_readings(con, "123", "yesterday-ish", Sys.time()), regexp = "`start`")
})

test_that("hv_validate_readings normalises timestamp to UTC without shifting it", {
  rd <- tibble::tibble(
    location_id = "loc1", parameter_id = "p1", unit_id = "u1",
    timestamp = as.POSIXct("2026-05-01 08:00:00", tz = "America/Los_Angeles"),
    value = 1
  )
  out <- hv_validate_readings(rd)
  expect_equal(attr(out$timestamp, "tzone"), "UTC")
  expect_equal(as.numeric(out$timestamp), as.numeric(rd$timestamp))
})
