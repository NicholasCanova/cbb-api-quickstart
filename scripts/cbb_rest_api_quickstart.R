# CBB Analytics REST API: sample R client. Docs: https://rest.cbbanalytics.com/api-docs/
# Building a scheduled pipeline (backfill, daily sync, portal tracking)? Read PIPELINE_GUIDE.md and see scripts/cbb_sync.py.
# Run it section by section: section (D) pulls real data, and each page counts against your key's request limits.

# ===-===-===-===
# (A) Setup
# ===-===-===-===

# rm(list = ls()) # deletes every object in your R session; uncomment only if you want a blank slate

# API versions: v3 (recommended) wraps responses as { response: { meta, data } }; legacy v1 and v2 return a bare array
# cursor pagination: send meta.nextCursor back unchanged as `after` until it's missing; don't build or edit cursors yourself
# don't send sortBy: v3 rejects it, and on v1/v2 it can't be combined with `after`

# list any missing packages and how to install them
required <- c('httr', 'dplyr', 'tibble', 'readr')
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  message('Missing packages; run: install.packages(c(', paste0("'", missing, "'", collapse = ', '), '))')
}

# load libraries
library(httr)
library(dplyr)
library(tibble)
library(readr)

# connection settings; set your key here
api_key <- 'YOUR_API_KEY_HERE'
host <- 'https://rest.cbbanalytics.com'
api_ver <- 'v3' # v3 (recommended), v2, v1
base_url <- paste0(host, '/', api_ver)
paging_mode <- 'cursor' # cursor (recommended), offset
page_size <- 1000 # the API max; fewer, larger pages cost fewer requests

# ids used by the examples; find others at /v3/competitions and /v3/conferences
competition_id <- 41097 # 2025-26 men's
acc_conference_id <- 53

# warn when the key hasn't been set
if (api_key == 'YOUR_API_KEY_HERE') {
  message('Set api_key above before running the requests below.')
}


# ===-===-===-===-===
# (B) Request helpers
# ===-===-===-===-===

# null-coalesce: b when a is NULL
`%||%` <- function(a, b) if (is.null(a)) b else a

# one GET; reads the v3 envelope or a v1/v2 bare array, so the same code works on every version
api_get <- function(
  url,           # full endpoint url
  query_params   # list of query params
) {
  # returns list(records, headers, meta); meta is NULL on v1/v2

  # make the request, failing on any non-200
  res <- GET(url, add_headers('X-API-Key' = api_key), query = query_params, timeout(60))
  if (status_code(res) != 200) {
    stop(paste('API request failed:', status_code(res), content(res, 'text', encoding = 'UTF-8')))
  }

  # unwrap the v3 envelope; v1 and v2 return the records directly
  body <- content(res)
  is_envelope <- is.list(body) && !is.null(body$response$data)
  list(
    records = if (is_envelope) body$response$data else body,
    headers = headers(res),
    meta = if (is_envelope) body$response$meta else NULL
  )
}

# page through every row with offset; slows down on deep pages, so prefer paging_cursor for big pulls
paging_offset <- function(
  url,            # full endpoint url
  query_params,   # list of filters
  quiet = FALSE   # TRUE hides the per-page log
) {
  # returns a list of records

  # request page after page, stopping at the first short page
  records <- list()
  offset <- 0
  repeat {
    out <- api_get(url, c(query_params, list(limit = page_size, offset = offset)))
    records <- c(records, out$records)
    if (!quiet) message(sprintf('  offset=%d  records=%d', offset, length(out$records)))
    if (length(out$records) < page_size) break
    offset <- offset + page_size
  }

  # return the records
  records
}

# page through every row with cursors; each page stays fast at any depth
paging_cursor <- function(
  url,            # full endpoint url
  query_params,   # list of filters
  quiet = FALSE   # TRUE hides the per-page log
) {
  # returns a list of records

  # request page after page, sending back each cursor until there isn't one
  records <- list()
  after <- NULL
  repeat {
    out <- api_get(url, c(query_params, list(limit = page_size, after = after)))
    records <- c(records, out$records)
    if (!quiet) message(sprintf('  after=%s  records=%d', after %||% '(first page)', length(out$records)))

    # v3 puts the cursor in meta.nextCursor; v1/v2 in the X-Next-Cursor header
    after <- out$meta$nextCursor %||% out$headers[['x-next-cursor']]
    if (is.null(after) || after == '' || length(out$records) == 0) break
  }

  # return the records
  records
}


# ===-===-===-===-===
# (C) fetch_data: every row of one endpoint as a tibble
# ===-===-===-===-===

# fetch every row of an endpoint matching the filters, as a tibble
fetch_data <- function(
  table,                  # path under the base url, e.g. 'stats/team/game-box'
  query_params = list(),  # list of filters, e.g. list(competitionIds = 41097)
  mode = paging_mode,     # 'cursor' or 'offset'
  quiet = FALSE           # TRUE hides the per-page log
) {
  # returns a tibble, one row per record

  # page through the endpoint
  start_time <- Sys.time()
  url <- paste0(base_url, '/', table)
  records <- switch(
    mode,
    cursor = paging_cursor(url, query_params, quiet),
    offset = paging_offset(url, query_params, quiet),
    stop("mode must be 'cursor' or 'offset'")
  )

  # array fields become list-columns in every row, and nulls become NA, so bind_rows sees one type per column
  is_array <- function(v) is.list(v) || length(v) > 1
  list_fields <- unique(unlist(lapply(records, function(rec) names(rec)[vapply(rec, is_array, logical(1))])))
  records <- lapply(records, function(rec) {
    for (field in names(rec)) {
      if (field %in% list_fields) rec[[field]] <- list(rec[[field]])
      else if (length(rec[[field]]) == 0) rec[[field]] <- NA
    }
    rec
  })
  df <- suppressMessages(type_convert(bind_rows(records), guess_integer = TRUE))

  # log the size and time, and return
  seconds <- as.numeric(Sys.time() - start_time, units = 'secs')
  if (!quiet) message(sprintf('  fetched %d rows x %d cols from %s in %.1fs', nrow(df), ncol(df), table, seconds))
  df
}


# ===-===-===-===-===
# (D) Example fetches
# ===-===-===-===-===

# D1) entities: competitions, conferences, teams, players
all_competitions <- fetch_data('competitions')
d1_conferences <- fetch_data('conferences', list(divisionIds = 1))
d1_teams <- fetch_data('competition-teams', list(competitionIds = competition_id, divisionIds = 1))
acc_teams <- fetch_data('competition-teams', list(competitionIds = competition_id, conferenceIds = acc_conference_id))
d1_players <- fetch_data('competition-team-players', list(competitionIds = competition_id, divisionIds = 1))
acc_players <- fetch_data('competition-team-players', list(competitionIds = competition_id, conferenceIds = acc_conference_id))

# D2) team stats for all of D1; always pass splits on aggregate endpoints
team_game_box <- fetch_data('stats/team/game-box', list(competitionIds = competition_id))
team_agg_box <- fetch_data('stats/team/agg-box', list(competitionIds = competition_id, splits = 'season', teamOrOpponent = 'team'))
team_agg_pbp <- fetch_data('stats/team/agg-pbp', list(competitionIds = competition_id, splits = 'season', teamOrOpponent = 'team'))

# D3) player stats: game-level for the ACC, season totals for all of D1
acc_player_game_box <- fetch_data('stats/player/game-box', list(competitionIds = competition_id, conferenceIds = acc_conference_id))
acc_player_game_pbp <- fetch_data('stats/player/game-pbp', list(competitionIds = competition_id, conferenceIds = acc_conference_id))
d1_player_agg_box <- fetch_data('stats/player/agg-box', list(competitionIds = competition_id, splits = 'season'))

# D4) rows changed on or after a UTC day, for daily syncs; PIPELINE_GUIDE.md explains how to pick the date
since_date <- format(Sys.Date() - 3, '%Y-%m-%d')
recent_games <- fetch_data('games', list(competitionIds = competition_id, divisionIds = 1, updated = since_date))
recent_team_game_box <- fetch_data('stats/team/game-box', list(competitionIds = competition_id, updated = since_date))
recent_player_game_box <- fetch_data('stats/player/game-box', list(competitionIds = competition_id, updated = since_date))
