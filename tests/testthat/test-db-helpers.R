# DB helpers are exercised against DBI::ANSI() with dbExecute / dbWriteTable
# mocked, so we can assert on the generated SQL without a live database.

capture_db <- function(env = parent.frame()) {
  calls <- new.env(parent = emptyenv())
  calls$sql    <- character()
  calls$writes <- list()
  local_mocked_bindings(
    dbExecute = function(conn, statement, ...) {
      calls$sql <- c(calls$sql, as.character(statement))
      0L
    },
    dbWriteTable = function(conn, name, value, ...) {
      calls$writes[[length(calls$writes) + 1L]] <- value
      TRUE
    },
    .package = "DBI",
    .env = env
  )
  calls
}

make_rows <- function(n = 5L) {
  tibble::tibble(
    location_id  = "loc1",
    parameter_id = "p1",
    unit_id      = "u1",
    timestamp    = as.POSIXct("2026-01-01", tz = "UTC") + seq_len(n) * 900,
    value        = as.numeric(seq_len(n))
  )
}

key <- c("location_id", "parameter_id", "timestamp")

test_that("hv_ensure_table issues quoted CREATE TABLE IF NOT EXISTS with composite PK", {
  calls <- capture_db()
  hv_ensure_table(DBI::ANSI(), "my table")

  expect_length(calls$sql, 1L)
  expect_match(calls$sql, 'CREATE TABLE IF NOT EXISTS "my table"', fixed = TRUE)
  expect_match(calls$sql, "timestamp    TIMESTAMPTZ NOT NULL", fixed = TRUE)
  expect_match(calls$sql, "PRIMARY KEY (location_id, parameter_id, timestamp)", fixed = TRUE)
})

test_that("hv_upsert with overwrite = TRUE updates only non-key columns", {
  calls <- capture_db()
  n <- hv_upsert(DBI::ANSI(), make_rows(), "readings", key, quiet = TRUE)

  expect_equal(n, 5L)
  insert <- grep("^INSERT", calls$sql, value = TRUE)
  expect_length(insert, 1L)
  expect_match(insert, 'INSERT INTO "readings"', fixed = TRUE)
  expect_match(insert, 'ON CONFLICT ("location_id", "parameter_id", "timestamp") DO UPDATE SET',
               fixed = TRUE)
  expect_match(insert, '"unit_id" = EXCLUDED."unit_id", "value" = EXCLUDED."value"', fixed = TRUE)
  expect_no_match(insert, '"timestamp" = EXCLUDED', fixed = TRUE)
  expect_true(any(grepl("^DROP TABLE IF EXISTS", calls$sql)))
})

test_that("hv_upsert with overwrite = FALSE uses DO NOTHING", {
  calls <- capture_db()
  hv_upsert(DBI::ANSI(), make_rows(), "readings", key,
            overwrite = FALSE, quiet = TRUE)
  insert <- grep("^INSERT", calls$sql, value = TRUE)
  expect_match(insert, "DO NOTHING$")
})

test_that("hv_upsert splits into batches of batch_size", {
  calls <- capture_db()
  hv_upsert(DBI::ANSI(), make_rows(5L), "readings", key,
            batch_size = 2L, quiet = TRUE)
  expect_equal(vapply(calls$writes, nrow, integer(1)), c(2L, 2L, 1L))
  expect_length(grep("^INSERT", calls$sql), 3L)
})

test_that("hv_upsert errors on non-positive batch_size", {
  capture_db()
  expect_error(hv_upsert(DBI::ANSI(), make_rows(), "readings", key,
                         batch_size = 0L, quiet = TRUE),
               regexp = "batch_size")
})

test_that("hv_upsert on zero rows touches nothing", {
  calls <- capture_db()
  expect_message(n <- hv_upsert(DBI::ANSI(), make_rows(0L), "readings", key),
                 regexp = "No rows")
  expect_equal(n, 0L)
  expect_length(calls$sql, 0L)
  expect_length(calls$writes, 0L)
})
