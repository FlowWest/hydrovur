# Low-level HydroVu HTTP wrappers.
#
# These functions are not exported. The user-facing `hv_*` functions
# in the other files wrap them with the connection object's token + base URL.

# Walk X-ISI-Next-Page headers, parse each body, bind the pages.
#
# stop_when: optional function(parsed_page) -> logical. Called after each page;
#   if it returns TRUE, pagination stops before fetching the next page. Used by
#   get_readings() to stop once timestamps exceed end_ts.
isi_paginate <- function(token, url, query = NULL, parse_as = "text",
                         body_parse = function(x) x,
                         stop_when  = NULL) {
  verbose <- isTRUE(getOption("rhydrovu.verbose", FALSE))

  out       <- list()
  next_page <- NULL
  page_n    <- 0L
  t0        <- Sys.time()

  repeat {
    page_n <- page_n + 1L
    hdrs <- c(Authorization = paste("Bearer", token))
    if (!is.null(next_page)) hdrs["X-ISI-Start-Page"] <- next_page

    if (verbose) {
      q_str <- if (length(query) > 0L)
        paste0("?", paste(names(query), unlist(query), sep = "=", collapse = "&"))
      else ""
      message(sprintf("[isi_paginate] page %d  GET %s%s", page_n, url, q_str))
    }

    res <- httr::GET(url, httr::add_headers(.headers = hdrs), query = query)
    httr::stop_for_status(res)
    parsed <- body_parse(httr::content(res, parse_as, encoding = "UTF-8"))
    out[[length(out) + 1]] <- parsed

    if (verbose) {
      n <- if (is.data.frame(parsed)) nrow(parsed) else length(parsed)
      message(sprintf("[isi_paginate]   <- %s rows, status %d",
                      format(n, big.mark = ","), httr::status_code(res)))
    }

    next_page <- httr::headers(res)[["x-isi-next-page"]]
    if (is.null(next_page) || next_page == "") break
    if (!is.null(stop_when) && isTRUE(stop_when(parsed))) {
      if (verbose) message("[isi_paginate] stop_when triggered -- stopping early")
      break
    }
  }

  if (verbose) {
    dt <- as.numeric(Sys.time() - t0, units = "secs")
    message(sprintf("[isi_paginate] done: %d page(s) in %.2fs", page_n, dt))
  }

  dplyr::bind_rows(out)
}

# GET /locations/list (paginated).
get_locations <- function(token, base_url) {
  isi_paginate(
    token,
    paste0(base_url, "/locations/list"),
    parse_as = "text",
    body_parse = function(body) {
      jsonlite::fromJSON(body, flatten = TRUE) |> tibble::as_tibble()
    }
  ) |>
    janitor::clean_names()
}

# GET /sispec/friendlynames (single page; no pagination header).
get_parameter_names <- function(token, base_url) {
  res <- httr::GET(
    paste0(base_url, "/sispec/friendlynames"),
    httr::add_headers(Authorization = paste("Bearer", token))
  )
  httr::stop_for_status(res)

  jsonlite::fromJSON(
    httr::content(res, "text", encoding = "UTF-8"), flatten = TRUE
  )$parameters |>
    tibble::enframe(name = "parameter_id", value = "parameter_name") |>
    tidyr::unnest(parameter_name) |>
    dplyr::mutate(parameter_id = as.character(parameter_id))
}

# GET /locations/<id>/data for [start_ts, end_ts] (paginated).
#
# startTime and endTime are Unix epoch seconds integers (not ISO strings).
# The API seeks to the first block at or after startTime and stops at endTime.
get_readings <- function(token, location_id, parameter_df,
                         start_ts, end_ts, base_url) {
  loc_int <- format(as.numeric(location_id), scientific = FALSE, trim = TRUE)
  isi_paginate(
    token,
    paste0(base_url, "/locations/", loc_int, "/data"),
    query     = list(startTime = as.integer(as.numeric(start_ts)),
                     endTime   = as.integer(as.numeric(end_ts))),
    parse_as  = "parsed",
    body_parse = function(body) {
      parms <- body$parameters
      if (length(parms) == 0) return(NULL)
      parms |>
        tibble::enframe() |>
        tidyr::unnest_wider(value) |>
        dplyr::select(parameter_id = parameterId,
                      unit_id      = unitId,
                      readings) |>
        dplyr::mutate(parameter_id = as.character(parameter_id),
                      unit_id      = as.character(unit_id)) |>
        dplyr::left_join(parameter_df, by = "parameter_id") |>
        tidyr::unnest(readings) |>
        tidyr::unnest_wider(readings) |>
        dplyr::mutate(timestamp = lubridate::as_datetime(
          as.numeric(timestamp), tz = "UTC"
        ))
    }
  )
}

# GET /sispec/friendlynames, units section (single page; no pagination header).
get_unit_names <- function(token, base_url) {
  res <- httr::GET(
    paste0(base_url, "/sispec/friendlynames"),
    httr::add_headers(Authorization = paste("Bearer", token))
  )
  httr::stop_for_status(res)

  jsonlite::fromJSON(
    httr::content(res, "text", encoding = "UTF-8"), flatten = TRUE
  )$units |>
    tibble::enframe(name = "unit_id", value = "unit_name") |>
    tidyr::unnest(unit_name) |>
    dplyr::mutate(unit_id = as.character(unit_id))
}
