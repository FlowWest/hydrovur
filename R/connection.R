#' Open a connection to the HydroVu API
#'
#' Authenticates with HydroVu via OAuth2 client-credentials and returns a
#' connection environment used by all other `hv_*` functions.
#'
#' When `prime = TRUE` (default), the connection eagerly fetches the locations
#' list and parameter friendly-names so they are ready to use without further
#' network round-trips.
#'
#' The returned object is a (reference-semantic) environment so internal
#' caches and refreshed tokens are visible across calls without reassignment.
#'
#' @param client_id,client_secret HydroVu API credentials. Default to the
#'   `HYDROVU_CLIENT_ID` and `HYDROVU_CLIENT_SECRET` environment variables.
#' @param base_url HydroVu REST base URL.
#' @param token_url HydroVu OAuth2 token endpoint.
#' @param prime If `TRUE`, fetch and cache locations and parameters during
#'   construction.
#'
#' @return A `<hydrovu_connection>` object.
#' @export
#'
#' @examples
#' \dontrun{
#' con <- hv_connect()
#' con
#' hv_locations(con)
#' }
hv_connect <- function(client_id     = Sys.getenv("HYDROVU_CLIENT_ID"),
                       client_secret = Sys.getenv("HYDROVU_CLIENT_SECRET"),
                       base_url      = "https://hydrovu.com/public-api/v1",
                       token_url     = "https://hydrovu.com/public-api/oauth/token",
                       prime         = TRUE) {
  if (!nzchar(client_id) || !nzchar(client_secret)) {
    stop("Both `client_id` and `client_secret` must be supplied ",
         "(or set HYDROVU_CLIENT_ID / HYDROVU_CLIENT_SECRET).",
         call. = FALSE)
  }

  con <- new.env(parent = emptyenv())
  con$client_id        <- client_id
  con$client_secret    <- client_secret
  con$base_url         <- base_url
  con$token_url        <- token_url
  con$token            <- NULL
  con$token_expires_at <- as.POSIXct(NA)
  con$locations        <- NULL
  con$parameters       <- NULL
  class(con) <- "hydrovu_connection"

  hv_refresh_token(con)
  if (isTRUE(prime)) {
    hv_locations(con)
    hv_parameters(con)
  }

  con
}

#' @export
print.hydrovu_connection <- function(x, ...) {
  cat("<hydrovu_connection>\n")
  cat("  base_url:   ", x$base_url, "\n", sep = "")
  cat("  token:      ",
      if (is.null(x$token)) "(unauthenticated)" else
        sprintf("*** (expires %s)", format(x$token_expires_at, tz = "UTC")),
      "\n", sep = "")
  cat("  locations:  ",
      if (is.null(x$locations)) "(not fetched)" else
        sprintf("%d cached", nrow(x$locations)),
      "\n", sep = "")
  cat("  parameters: ",
      if (is.null(x$parameters)) "(not fetched)" else
        sprintf("%d cached", nrow(x$parameters)),
      "\n", sep = "")
  invisible(x)
}

#' Force-refresh the HydroVu OAuth2 access token
#'
#' Most callers will not need this directly; [hv_token()] lazily refreshes
#' near expiry. Use this if you suspect the cached token has been invalidated
#' server-side.
#'
#' @param con A `<hydrovu_connection>`.
#' @return The connection, invisibly.
#' @export
hv_refresh_token <- function(con) {
  stop_if_not_connection(con)
  res <- httr::POST(
    con$token_url,
    httr::authenticate(con$client_id, con$client_secret),
    body = list(grant_type = "client_credentials"),
    encode = "form"
  )
  httr::stop_for_status(res)
  body <- httr::content(res, "parsed", type = "application/json")
  con$token            <- body$access_token
  con$token_expires_at <- Sys.time() + as.difftime(
    coalesce_null(body$expires_in, 3600), units = "secs"
  )
  invisible(con)
}

#' Get the current HydroVu access token, refreshing if near expiry
#'
#' @param con A `<hydrovu_connection>`.
#' @return A character access-token string.
#' @export
hv_token <- function(con) {
  stop_if_not_connection(con)
  expired_soon <- is.na(con$token_expires_at) ||
    as.numeric(con$token_expires_at - Sys.time(), units = "secs") < 60
  if (expired_soon) hv_refresh_token(con)
  con$token
}
