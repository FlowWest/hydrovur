test_that("hv_connect rejects missing credentials", {
  expect_error(
    hv_connect(client_id = "", client_secret = ""),
    regexp = "client_id"
  )
})

test_that("hv_token / hv_refresh_token reject non-connection inputs", {
  expect_error(hv_token(list()),         regexp = "hydrovu_connection")
  expect_error(hv_refresh_token(list()), regexp = "hydrovu_connection")
  expect_error(hv_locations(list()),     regexp = "hydrovu_connection")
  expect_error(hv_parameters(list()),    regexp = "hydrovu_connection")
  expect_error(hv_readings(list(), character(), Sys.time(), Sys.time()),
               regexp = "hydrovu_connection")
})

test_that("hv_readings short-circuits on empty location_ids", {
  # Use a fake-but-class-valid connection so we never reach the network.
  con <- new.env(parent = emptyenv())
  class(con) <- "hydrovu_connection"
  expect_equal(nrow(hv_readings(con, character(), Sys.time(), Sys.time())), 0)
})
