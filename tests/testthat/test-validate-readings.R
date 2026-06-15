make_readings <- function(n = 3L) {
  tibble::tibble(
    location_id    = rep("loc1", n),
    parameter_id   = rep("param1", n),
    unit_id        = rep("unit1", n),
    timestamp      = as.POSIXct("2026-01-01", tz = "UTC") + seq_len(n),
    value          = as.numeric(seq_len(n))
  )
}

test_that("hv_validate_readings returns the expected schema on valid input", {
  out <- hv_validate_readings(make_readings())
  expect_s3_class(out, "tbl_df")
  expect_named(out, c("location_id", "parameter_id", "unit_id", "timestamp", "value"))
  expect_equal(nrow(out), 3L)
})

test_that("hv_validate_readings errors on non-data-frame input", {
  expect_error(hv_validate_readings(list(a = 1)), regexp = "data frame")
  expect_error(hv_validate_readings("not a df"),  regexp = "data frame")
})

test_that("hv_validate_readings errors on missing required columns", {
  bad <- make_readings()
  bad$timestamp <- NULL
  expect_error(hv_validate_readings(bad), regexp = "missing required column")
})

test_that("hv_validate_readings errors on NA in unique_cols", {
  bad <- make_readings()
  bad$location_id[1] <- NA_character_
  expect_error(hv_validate_readings(bad), regexp = "NA values")
})

test_that("hv_validate_readings errors when timestamp is not POSIXct", {
  bad <- make_readings()
  bad$timestamp <- as.character(bad$timestamp)
  expect_error(hv_validate_readings(bad), regexp = "POSIXct")
})

test_that("hv_validate_readings errors when value is not numeric", {
  bad <- make_readings()
  bad$value <- as.character(bad$value)
  expect_error(hv_validate_readings(bad), regexp = "numeric")
})

test_that("hv_validate_readings drops extra columns with a message", {
  extra <- dplyr::mutate(make_readings(), extra_col = "x")
  expect_message(out <- hv_validate_readings(extra), regexp = "extra_col")
  expect_false("extra_col" %in% names(out))
})

test_that("hv_validate_readings deduplicates on unique_cols (first wins)", {
  dup <- dplyr::bind_rows(make_readings(1L), make_readings(1L))
  dup$value <- c(1, 99)
  out <- hv_validate_readings(dup)
  expect_equal(nrow(out), 1L)
  expect_equal(out$value, 1)
})
