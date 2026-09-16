# Command + Option + O (on Mac) to collapse functions

# ===-===-===-===
# (A) Setup
# ===-===-===-===
rm(list = ls())
notes <- function() {

  # CBB Analytics REST API — sample R client
  # https://rest.cbbanalytics.com/api-docs/#/

  # Major versions (response shape is decided by URL prefix — no envelope query param):
  #   /v3/   recommended — all current fields; { response: { meta, data } } envelope.
  #                        meta carries count, limit, offset, nextCursor, hasMore,
  #                        version, time, and the echoed request URL (apikey stripped).
  #   /v2/   legacy      — all current fields; bare JSON array.
  #   /v1/   legacy      — frozen Zod-picked field set; bare JSON array.

  # Cursor pagination
  #   Pass `after=<cursor>` to fetch rows with _id > after.
  #   On /v1/ and /v2/, read the X-Next-Cursor response header.
  #   On /v3/, the cursor is also exposed as meta.nextCursor in the body.
  #   Stop when the cursor is absent (or meta.hasMore is false).
  #   Only compatible with the default sort (omit sortBy).

  # What this file gives you
  #   - api_get / paging_offset / paging_cursor / fetch_data — request helpers
  #     that auto-detect envelope vs bare-array, so the same code works on v1, v2, v3.
  #   - test_versions(table, params)        — same query across versions; field-set diff.
  #   - bench_pagination(table, params)     — same query across (version × mode); timings.
  #   - Section (E) below is a runnable test menu using those helpers.
}

check_libraries <- function() {
  required <- c('httr', 'dplyr', 'purrr', 'tibble', 'readr')
  missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    cat('Installing missing packages:', paste(missing, collapse = ', '), '\n')
    # install.packages(missing) # uncomment to install missing libraries
    cat('Done.\n')
  } else {
    cat('All required libraries already installed:', paste(required, collapse = ', '), '\n')
  }
}
check_libraries()

setup <- function() {
  # load libraries
  library(httr)
  library(dplyr)
  library(purrr)
  library(tibble)
  library(readr)

  # globals (<<- assigns to global env)
  api_key <<- 'YOUR_API_KEY_HERE'
  host <<- 'https://rest.cbbanalytics.com' # or 'http://localhost:8080'

  # 'v3' = envelope + all current fields (recommended)
  # 'v2' = bare array + all current fields (legacy)
  # 'v1' = bare array + frozen Zod-picked schema (legacy)
  api_ver <<- 'v3' # v1, v2, v3
  base_url <<- paste0(host, '/', api_ver)
  paging_mode <<- 'offset' # offset, cursor
  latest_competition_id <<- 41097
  acc_conference_id <<- 53
  
  print(paste0('Fetch from ', base_url, ' using ', paging_mode, ' pagination mode.'))
  if (api_key == 'YOUR_API_KEY_HERE') {
    print('Set a valid API Key for code below to work')
  }
}
setup()


# ===-===-===-===-===
# (B) Low-level request helpers
# ===-===-===-===-===

# tiny null-coalesce helper (used below)
`%||%` <- function(a, b) if (is.null(a)) b else a

# Single GET. Returns list(records, headers, meta, latency_ms).
api_get <- function(url, query_params) {
  # Auto-detects envelope vs bare-array responses, so the same code works against /v1/, /v2/ (bare array) and /v3/ (envelope).
  # No flag needed — the server's response shape is determined by the major URL version.

  # make the request
  t0  <- Sys.time()
  res <- httr::GET(
    url = url,
    httr::add_headers('X-API-Key' = api_key),
    query = query_params,
    httr::timeout(60)
  )
  latency_ms <- as.numeric(difftime(Sys.time(), t0, units = 'secs')) * 1000

  if (httr::status_code(res) != 200) {
    stop(paste(
      'API request failed:',
      httr::status_code(res),
      httr::content(res, 'text', encoding = 'UTF-8')
    ))
  }

  body    <- httr::content(res)
  headers <- httr::headers(res)

  # Auto-detect envelope (v3) vs bare array (v1/v2). v3 wraps in
  # { response: { meta, data } }; v1 and v2 return the array directly.
  is_envelope <- is.list(body) && !is.null(body$response) && !is.null(body$response$data)
  if (is_envelope) {
    records <- body$response$data
    meta    <- body$response$meta
  } else {
    records <- body
    meta    <- NULL
  }

  list(
    records    = records,
    headers    = headers,
    meta       = meta,
    latency_ms = latency_ms
  )
}

# Offset-based paging. Returns list(records, timings).
paging_offset <- function(url, query_params, quiet = FALSE) {
  # How it works:
  #   - Pass `offset` to skip the first `offset` records and fetch the next `limit` records.
  #   - The server returns the results array and, if more data is available, another page can be fetched by incrementing the offset.
  #   - Common usage: set offset = 0 for the first page, then offset = offset + limit for subsequent pages.
  #   - Paging ends when the number of records returned is less than `limit`.
  #   - This approach may be inefficient for large offsets, as the server must scan/skip records each time.

  # constants
  limit <- query_params$limit %||% 500
  offset <- 0
  page   <- 0
  all_records <- list()
  timings <- list()

  # loop through pages of sized "limit" until all data fetched
  repeat {
    # increment page
    page <- page + 1
    query_params$limit  <- limit
    query_params$offset <- offset

    # fetch data
    output <- api_get(url, query_params)
    n <- length(output$records)
    
    # print logging if not quiet
    if (!quiet) {
      message(sprintf('  offset page %3d  offset=%6d  records=%4d  latency=%7.1f ms',
                      page, offset, n, output$latency_ms))
    }

    # add to timings, add to all records
    timings[[page]] <- tibble(page = page, offset = offset, records = n, latency_ms = round(output$latency_ms, 2))
    all_records <- c(all_records, output$records)

    # handle paging, check if we've reached the limit, else increment offset
    if (n < limit) { break }
    offset <- offset + limit
  }

  # return the records and timings
  return(list(
    records = all_records,
    timings = bind_rows(timings)
  ))
}

# Cursor-based paging (recommended for deep / bulk pulls). Returns list(records, timings).
paging_cursor <- function(url, query_params, quiet = FALSE) {
  # How it works:
  #   - Pass `after` to fetch rows with _id > after.
  #   - On /v1/ and /v2/, the server returns an X-Next-Cursor header.
  #   - On /v3/, the cursor is also exposed as meta.nextCursor in the envelope body.
  #   - When the cursor is absent (or meta.hasMore is false), you've reached the end.
  #   - Treat the cursor as opaque; some collections use string or numeric _id values.
  #   - Only compatible with the default sort (omit sortBy).
  
  # constants
  limit <- query_params$limit %||% 500
  after <- NULL
  page <- 0
  all_records <- list()
  timings <- list()

  # loop through pages of sized "limit" until all data fetched
  repeat {
    # increment page
    page <- page + 1
    query_params$limit  <- limit
    query_params$offset <- NULL  # ignored when `after` is set; keep requests clean
    # set the after cursor
    if (!is.null(after)) query_params$after <- after

    # fetch data
    output <- api_get(url, query_params)
    n <- length(output$records)

    # print logging if not quiet
    if (!quiet) {
      message(sprintf('  cursor page %3d  after=%-26s  records=%4d  latency=%7.1f ms',
                      page, if (is.null(after)) '(none)' else after, n, output$latency_ms))
    }

    # add to timings, add to all records
    timings[[page]] <- tibble(page = page, after = after %||% '', records = n, latency_ms = round(output$latency_ms, 2))
    all_records <- c(all_records, output$records)

    # Prefer meta.nextCursor (envelope) then X-Next-Cursor header (bare).
    next_cursor <- if (!is.null(output$meta) && !is.null(output$meta$nextCursor)) {
      output$meta$nextCursor
    } else {
      output$headers[['x-next-cursor']]
    }

    # handle paging, check if we've reached the end, else set the after cursor
    if (is.null(next_cursor) || identical(next_cursor, '')) { break } # no more data
    if (n == 0) { break } # no data
    after <- next_cursor
  }

  # return the records and timings
  return(list(
    records = all_records,
    timings = bind_rows(timings)
  ))
}


# ===-===-===-===-===
# (C) Top-level fetcher — handles version + mode selection
# ===-===-===-===-===
fetch_data <- function(table, query_params = list(), mode = paging_mode, version = NULL, return_as = 'df', quiet = FALSE) {
  #   table:        path under base URL, e.g. 'stats/team/game-box' or 'teams'
  #   query_params: list of API filters
  #   mode:         'offset' (default) or 'cursor'
  #   version:      override the default major version for this call only.
  #                 NULL (default) => use base_url. 'v1' / 'v2' / 'v3' => override.
  #   return_as:    'df' (default, tibble) or 'list' (raw records + per-page timings)
  #   quiet:        suppress per-page logging
  
  start_time <- Sys.time()  # Start measuring time

  # handle version
  url <- if (is.null(version)) {
    paste0(base_url, '/', table)
  } else {
    paste0(host, '/', version, '/', table)
  }

  result <- switch(
    mode,
    offset = paging_offset(url, query_params, quiet = quiet),
    cursor = paging_cursor(url, query_params, quiet = quiet),
    stop("mode must be 'offset' or 'cursor'")
  )

  # return as list
  if (return_as == 'list') return(result)

  #
  #   1. Array fields (e.g. `womensTeamIds`, `featuredTournamentIds`,
  #      `careerCompetitionIds`) — parsed by httr as bare R vectors. Combined
  #      with size-1 scalar fields, bind_rows hits a recycling error
  #      ("Can't recycle `_id` (size 1) to match `womensTeamIds` (size 10)").
  #
  #   2. JSON nulls / missing fields (e.g. `nextCompetitionId`, `conferenceAbb`
  #      on some rows) — parsed as NULL. If we list-wrap those but leave other
  #      records' scalars alone, bind_rows complains about mixed types
  #      ("Can't combine <integer> and <list>").
  #
  # Two-pass normalization handles both:
  #   Pass 1 — find fields that ever hold a multi-element value or nested list.
  #   Pass 2 — list-wrap those fields *consistently* in every record; for the
  #            remaining (scalar) fields, replace length-0 values with NA so
  #            bind_rows sees a uniform atomic column.
  # flatten to 
  needs_list <- function(v) is.list(v) || length(v) > 1
  multi_fields <- unique(unlist(lapply(result$records, function(rec) {
    names(rec)[vapply(rec, needs_list, logical(1))]
  })))
  records_safe <- lapply(result$records, function(rec) {
    for (nm in names(rec)) {
      v <- rec[[nm]]
      if (nm %in% multi_fields) {
        rec[[nm]] <- list(v)            # consistent list-column
      } else if (length(v) == 0) {
        rec[[nm]] <- NA                  # NULL / empty -> NA for atomic cols
      }
    }
    rec
  })
  df <- suppressMessages(
    bind_rows(records_safe) %>%
      type_convert(guess_integer = TRUE)
  )

  total_time <- as.numeric(difftime(Sys.time(), start_time, units = "secs")) * 1000  # Total time in ms

  if (!quiet) {
    message(sprintf('  fetched %d rows x %d cols from %s in %.1f ms', nrow(df), ncol(df), table, total_time))
  }

  # sleep 1s and return
  Sys.sleep(1)
  attr(df, 'timings') <- result$timings
  df
}


# ===-===-===-===-===
# (D) Realistic example fetches — common backfill workflows
# ===-===-===-===-===

# D1) entities
all_competitions <- fetch_data('competitions')
d1_conferences <- fetch_data('conferences', list(divisionIds = 1))
d1_teams <- fetch_data('competition-teams', list(competitionIds = latest_competition_id, divisionIds = 1))
acc_teams <- fetch_data('competition-teams', list(competitionIds = latest_competition_id, conferenceIds = acc_conference_id))
d1_players <- fetch_data('competition-team-players', list(competitionIds = latest_competition_id, divisionIds = 1))
acc_players <- fetch_data('competition-team-players', list(competitionIds = latest_competition_id, conferenceIds = acc_conference_id))


# D2) team stats for all of D1, current competition
team_game_box <- fetch_data('stats/team/game-box', list(competitionIds = latest_competition_id))
team_agg_box <- fetch_data('stats/team/agg-box', list(competitionIds = latest_competition_id, splits = 'season', teamOrOpponent = 'team'))
team_agg_pbp <- fetch_data('stats/team/agg-pbp', list(competitionIds = latest_competition_id, splits = 'season', teamOrOpponent = 'team'))


# D3) player stats for the ACC, current competition
d1_player_game_box <- fetch_data('stats/player/game-box', list(competitionIds = latest_competition_id))
d1_player_game_box <- fetch_data('stats/player/game-pbp', list(competitionIds = latest_competition_id, conferenceIds = 53))
d1_player_agg_box <- fetch_data('stats/player/agg-box', list(competitionIds = latest_competition_id, splits = 'season'))


# D4) Incremental fetches via the `updated` filter, for nightly syncs.
# Server applies `updated >= <date>` (gte), and accepts 'YYYY-MM-DD' / 'YYYY-M-D' / 'YYYY-MM-DDTHH:mm:ssZ' (UTC).
since_date <- format(Sys.Date() - 7, '%Y-%m-%d')   # last 7 days
since_date <- format(as.Date('2026-03-28'), '%Y-%m-%d')   # since 3/28
recent_games <- fetch_data('games', list(competitionIds = latest_competition_id, updated = since_date))
recent_team_game_box <- fetch_data('stats/team/game-box', list(competitionIds = latest_competition_id, updated = since_date))
recent_player_game_box <- fetch_data('stats/player/game-box', list(competitionIds = latest_competition_id, updated = since_date))



# ===-===-===-===-===
# (E) Test helpers — versatile, layer on top of fetch_data()
# ===-===-===-===-===
# Nick building these to test performance differences across API versions, across offset vs cursor pagination

# Run the same query across multiple versions and report field count / names.
  # for confirming v1's frozen schema is a strict subset of v2/v3, and for spotting newly-added v3 fields.
test_versions <- function(table,
                          query_params = list(),
                          versions = c('v1', 'v2', 'v3')) {

  # Field-set inspection only needs ONE page per version — we're reading
  # column names, not pulling data. Calling fetch_data() here would page
  # through the entire filtered result set (and at limit=1 that means one
  # HTTP round-trip per record, which on a multi-hundred-row endpoint
  # looks like a hang). Call api_get directly, one request per version.
  t0_total <- Sys.time()
  query_params$limit <- query_params$limit %||% 1

  message(sprintf('test_versions: %s  versions=[%s]  filters=%s',
                  table,
                  paste(versions, collapse = ', '),
                  paste(names(query_params), unlist(query_params), sep = '=', collapse = ' ')))

  rows <- lapply(versions, function(v) {
    url <- paste0(host, '/', v, '/', table)
    message(sprintf('  -> /%s/%s ...', v, table), appendLF = FALSE)
    out <- api_get(url, query_params)

    df <- if (length(out$records) == 0) {
      tibble()
    } else {
      out$records %>%
        map(unlist) %>%
        map(t) %>%
        map(as_tibble, .name_repair = ~make.names(., unique = TRUE)) %>%
        bind_rows()
    }

    message(sprintf(' %d fields, %d records, %.0f ms',
                    ncol(df), nrow(df), out$latency_ms))

    tibble(version   = v,
           n_records = nrow(df),
           n_fields  = ncol(df),
           fields    = list(sort(names(df))))
  })
  result <- bind_rows(rows)

  if (all(c('v1', 'v3') %in% result$version)) {
    v1_fields  <- result$fields[[which(result$version == 'v1')]]
    v3_fields  <- result$fields[[which(result$version == 'v3')]]
    only_in_v3 <- setdiff(v3_fields, v1_fields)
    only_in_v1 <- setdiff(v1_fields, v3_fields)
    message(sprintf('\n  field diff for %s — v1: %d, v3: %d (delta = %d):',
                    table, length(v1_fields), length(v3_fields), length(only_in_v3) - length(only_in_v1)))
    message(sprintf('    v3 only: %d  %s', length(only_in_v3),
                    if (length(only_in_v3)) paste(only_in_v3, collapse = ', ') else '(none)'))
    message(sprintf('    v1 only: %d  %s', length(only_in_v1),
                    if (length(only_in_v1)) paste(only_in_v1, collapse = ', ') else '(none)'))
  }

  total_elapsed <- as.numeric(difftime(Sys.time(), t0_total, units = 'secs'))
  message(sprintf('\n  total wall: %.1fs\n', total_elapsed))
  invisible(result)
}


# Run the same query under multiple (version × mode) combos and return per-combo timing summary.
# Default is /v3/, pass versions = c('v1','v2','v3') to compare all.
# both pagination modes - the most common A/B you actually care about. 
bench_pagination <- function(table,
                             query_params = list(),
                             modes = c('offset', 'cursor'),
                             versions = c('v3'),
                             quiet = TRUE) {
  
  # Returns a tibble: version, mode, pages, records, wall_ms, mean_page_ms, max_page_ms.
  
  # set some time constants
  t0_total <- Sys.time()
  combos <- expand.grid(version = versions, mode = modes, stringsAsFactors = FALSE)
  rows <- lapply(seq_len(nrow(combos)), function(i) {
    v <- combos$version[i]
    m <- combos$mode[i]
    message(sprintf('--- bench: %s + %s on /%s/%s ---', v, m, v, table))

    # Wrap the fetch in tryCatch so a single (mode, version) timeout/error
    # doesn't abort the whole bench. Failed combos return a row with status =
    # 'timeout' or 'error' and NA timings; the loop continues to the next combo.
    t0_combo <- Sys.time()
    run <- tryCatch(
      fetch_data(table, query_params, mode = m, version = v,
                 return_as = 'list', quiet = quiet),
      error = function(e) {
        structure(list(error_msg = conditionMessage(e)), class = 'bench_error')
      }
    )
    elapsed_combo_ms <- as.numeric(difftime(Sys.time(), t0_combo, units = 'secs')) * 1000

    if (inherits(run, 'bench_error')) {
      status <- if (grepl('timeout|timed? out', run$error_msg, ignore.case = TRUE)) 'timeout' else 'error'
      message(sprintf('  -> %s after %.1fs: %s', status, elapsed_combo_ms / 1000, run$error_msg))
      tibble(version      = v,
             mode         = m,
             status       = status,
             pages        = NA_integer_,
             records      = NA_integer_,
             wall_ms      = round(elapsed_combo_ms, 1),
             mean_page_ms = NA_real_,
             max_page_ms  = NA_real_)
    } else {
      tibble(version      = v,
             mode         = m,
             status       = 'ok',
             pages        = nrow(run$timings),
             records      = length(run$records),
             wall_ms      = round(sum(run$timings$latency_ms), 1),
             mean_page_ms = round(mean(run$timings$latency_ms), 1),
             max_page_ms  = round(max(run$timings$latency_ms), 1))
    }
  })
  result <- bind_rows(rows)
  total_elapsed <- as.numeric(difftime(Sys.time(), t0_total, units = 'secs'))

  # --- Summary block ---
  message(sprintf('\nbench_pagination(%s) — total wall %.1fs:', table, total_elapsed))
  print(result)

  # Headline cursor vs offset comparison, one line per version (only when both modes ran).
  # If either side timed out or errored, we surface that instead of computing a misleading ratio.
  if (all(c('offset', 'cursor') %in% modes)) {

    # Format one side's stats — either full numbers or a DNF marker on failure.
    fmt_side <- function(row) {
      if (nrow(row) == 0) return('(missing)')
      if (row$status != 'ok') return(sprintf('DNF [%s after %.1fs]', row$status, row$wall_ms / 1000))
      sprintf('%.1fs (mean %.0f / max %.0f ms)', row$wall_ms / 1000, row$mean_page_ms, row$max_page_ms)
    }

    # loop the version
    for (v in versions) {
      off <- result[result$version == v & result$mode == 'offset', ]
      cur <- result[result$version == v & result$mode == 'cursor', ]
      both_ok <- nrow(off) && nrow(cur) && off$status == 'ok' && cur$status == 'ok'
      if (both_ok) {
        message(sprintf('  /%s/  offset %s  vs  cursor %s  |  max-page ratio %.1fx',
                        v, fmt_side(off), fmt_side(cur),
                        off$max_page_ms / cur$max_page_ms))
      } else {
        message(sprintf('  /%s/  offset %s  vs  cursor %s',
                        v, fmt_side(off), fmt_side(cur)))
      }
    }
  }
  message('')

  invisible(result)
}


# ===-===-===-===-===-===-===
# (F) Speed Tests
# exercise the helpers above
# ===-===-===-===-===-===-===

# ===  Test 1: field-set comparison across v1, v2, v3
test1_notes <- function() {
  # Confirms v1's frozen schema is a strict subset of v2/v3, and surfaces any
  # fields that have been added to the underlying collection since v1 was frozen.
}
test_versions('stats/team/game-box', list(competitionIds = latest_competition_id, conferenceIds = acc_conference_id))
test_versions('stats/player/game-pbp', list(competitionIds = latest_competition_id, conferenceIds = acc_conference_id))
test_versions('stats/player/agg-pbp', list(competitionIds = latest_competition_id, conferenceIds = acc_conference_id))
test_versions('competition-teams', list(divisionIds = 1))
test_versions('competition-team-players', list(divisionIds = 1))


# === Test 2: cursor vs offset on a small endpoint, default version (v3)
test2_notes <- function() {
  # Quick sanity check; both modes should return the same record count.
}
bench_pagination(table = 'games',
                 query_params = list(competitionIds = latest_competition_id, limit = 500),
                 quiet = FALSE)


# Test 3: cursor vs offset on another small endpoint
test3 <- function() {
  # competition-team-players for a full competition is ~25k rows — where offset
  # pagination starts to slow down (database scans + skips); cursor stays flat.
  # Watch max_page_ms: offset's max grows with depth, cursor's stays constant.
}
bench_pagination('competition-team-players',
                 list(competitionIds = latest_competition_id, limit = 1000))


# === Test 4: cursor vs offset on a bigger endpoint
test4 <- function() {
  # at limit 1000, should return ~140 pages to get 140K player-game stats for competitionId
}
bench_pagination('/stats/player/game-box',
                 list(competitionIds = latest_competition_id, limit = 1000),
                 quiet = FALSE)


# === Test 5: envelope shape demo
test5 <- function() {
  # /v3/ returns { response: { meta, data } }; api_get unwraps records and
  # exposes meta. /v1/ and /v2/ return bare arrays; meta is NULL.
}
v3_page <- api_get(paste0(host, '/v3/games'), list(competitionIds = latest_competition_id, limit = 3))
message('v3 envelope meta:'); str(v3_page$meta)

v2_page <- api_get(paste0(host, '/v2/games'), list(competitionIds = latest_competition_id, limit = 3))
message('v2 bare-array meta (NULL expected):'); str(v2_page$meta)


# === Test 6: incremental fetch via `updated` filter — cursor vs offset benchmark
test6 <- function() {
  # The `updated` filter is the common pattern for incremental ingestion: fetch
  # only records modified on or after a given UTC date. Use this for nightly
  # syncs instead of full backfills.
  #
  # Server format: 'YYYY-MM-DD', 'YYYY-M-D', or 'YYYY-MM-DDTHH:mm:ssZ' (UTC).
  # Server applies `updated >= <value>` (gte). Pass your last-successful-sync
  # date as the cursor.
  #
  # Benchmarks each common ingestion target under both cursor and offset modes
  # so you can see which mode wins for an `updated` window. For tiny windows
  # (one day) where everything fits in one page, both are equivalent. For
  # bigger windows that span many pages, cursor pulls ahead.
}
since <- format(as.Date('2026-03-28'), '%Y-%m-%d')   # before march madness
recent_params <- list(competitionIds = latest_competition_id, updated = since)
incremental_endpoints <- c('games', 'stats/team/game-box', 'stats/player/game-box')

# bench_pagination prints per-endpoint cursor-vs-offset comparison and returns
# the per-(mode, version) tibble. mutate(table = ..., .before = 1) tags each
# row with its endpoint so the cross-endpoint summary at the bottom is readable.
incremental_summary <- lapply(incremental_endpoints, function(table) {
  bench_pagination(table, recent_params) %>%
    mutate(table = table, .before = 1)
}) %>% bind_rows()

message('\nTest 6 cross-endpoint summary (each endpoint x each mode):')
print(incremental_summary)


