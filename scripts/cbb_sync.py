# cbb_sync.py keeps a local SQLite copy of CBB Analytics REST API data in sync, following PIPELINE_GUIDE.md
# modes: backfill (whole seasons, optionally via bulk export), daily (in-season sync), offseason (portal changes)
# usage: CBB_API_KEY=... python scripts/cbb_sync.py daily

# system imports
import argparse
import gzip
import json
import os
import sqlite3
import sys
import tempfile
import time
from datetime import date, timedelta
from itertools import islice

# third party
import requests

# connection settings; the key and database path come from the environment
HOST = 'https://rest.cbbanalytics.com/v3'
API_KEY = os.environ.get('CBB_API_KEY', 'YOUR_API_KEY_HERE')
DB_PATH = os.environ.get('CBB_DB_PATH', 'cbb.sqlite')

# page size (the API max), rows per insert batch, and the default daily lookback
PAGE_SIZE = 1000
INSERT_BATCH = 5000
LOOKBACK_DAYS = 3

# the games table is re-pulled whole every day; divisionIds=1 keeps any game with a D1 team, matching the stats endpoints
GAMES_ENDPOINT = 'games'
GAMES_FILTERS = {'divisionIds': 1}

# game-level stats endpoints: every row belongs to one game, so a changed game is replaced whole by gameId
GAME_ENDPOINTS = {
    'stats/team/game-box': {},
    'stats/player/game-box': {}
}

# season-aggregate endpoints and the splits to keep; rows are recomputed after every game, so the season is replaced whole
AGG_ENDPOINTS = {
    'stats/team/agg-box': {'splits': 'season'},
    'stats/player/agg-box': {'splits': 'season'}
}

# roster endpoints; small enough to replace whole for each competition
ROSTER_ENDPOINTS = {
    'competition-teams': {'divisionIds': 1},
    'competition-team-players': {'divisionIds': 1}
}

# portal fields compared in offseason mode, read from competition-team-players rows keyed by team and player
PORTAL_ENDPOINT = 'competition-team-players'
PORTAL_FIELDS = ['inPortalAfterSeason', 'portalStatus']


# one GET with retries on rate limits, server errors and dropped connections; a used-up monthly or yearly quota stops the run
def api_get(
    endpoint,  # path under /v3, e.g. 'stats/player/game-box'
    params     # dict of query params; lists are sent comma-separated
):
    # returns the v3 envelope's {meta, data}

    # send lists comma-separated, which every id filter accepts
    query = {k: ','.join(map(str, v)) if isinstance(v, (list, tuple, set)) else v for k, v in params.items()}

    # retry with backoff; quota errors and other 4xx fail right away
    for attempt in range(5):
        try:
            res = requests.get(f'{HOST}/{endpoint}', headers={'X-API-Key': API_KEY}, params=query, timeout=120)
        except requests.RequestException as err:
            print(f'  {type(err).__name__} on {endpoint}, retrying')
            time.sleep(2 ** attempt * 5)
            continue
        if res.status_code == 200:
            return res.json()['response']
        if res.status_code == 429 and 'API limit exceeded' in res.text:
            raise RuntimeError(f'Quota used up: {res.text}')
        if res.status_code == 429 or res.status_code >= 500:
            time.sleep(2 ** attempt * 5)
            continue
        raise RuntimeError(f'{res.status_code} on {endpoint} {query}: {res.text}')
    raise RuntimeError(f'Gave up on {endpoint} {query} after 5 tries')


# page through every row matching params with cursor pagination, one page in memory at a time
def iter_all(
    endpoint,  # path under /v3
    params     # dict of filters; limit and after are managed here
):
    # yields row dicts

    # follow meta.nextCursor until the server says there is no more
    after, pages, rows = None, 0, 0
    while True:
        page_params = {**params, 'limit': PAGE_SIZE, **({'after': after} if after else {})}
        resp = api_get(endpoint, page_params)
        yield from resp['data']
        pages += 1
        rows += len(resp['data'])
        after = resp['meta'].get('nextCursor')
        if not after or not resp['data']:
            break

    # log what the pull cost
    print(f'  {endpoint} {params}: {rows} rows, {pages} requests')


# page through every row matching params into a list; for pulls small enough to hold in memory
def fetch_all(
    endpoint,  # path under /v3
    params     # dict of filters
):
    # returns a list of row dicts
    return list(iter_all(endpoint, params))


# download one bulk export (gzipped NDJSON, every row of one stats endpoint) and read it line by line; costs one export
def iter_export(
    endpoint,         # stats endpoint under /v3, e.g. 'stats/player/game-box'
    competition_ids,  # list of competitionIds; one export covers all of them
    params            # other filters the endpoint accepts, e.g. {'splits': 'season'}
):
    # yields row dicts

    # stream the file to disk; a 429 here is the monthly export limit or another export still running on this key
    query = {'endpoint': endpoint, 'competitionIds': ','.join(map(str, competition_ids)), **params}
    with tempfile.TemporaryFile() as f:
        with requests.get(f'{HOST}/exports', headers={'X-API-Key': API_KEY}, params=query, stream=True, timeout=600) as res:
            if res.status_code != 200:
                raise RuntimeError(f'{res.status_code} on export {query}: {res.text}')
            used, limit = res.headers.get('X-Exports-Used'), res.headers.get('X-Exports-Limit')
            for chunk in res.iter_content(chunk_size=1 << 20):
                f.write(chunk)
        f.seek(0)

        # one JSON row per line
        rows = 0
        with gzip.open(f, 'rt') as lines:
            for line in lines:
                if line.strip():
                    rows += 1
                    yield json.loads(line)

    # log the export count
    print(f'  export {endpoint} {competition_ids}: {rows} rows, exports used {used} of {limit}')


# make sure the endpoint's table exists
def table_for(
    db,       # sqlite3 connection
    endpoint  # path under /v3; slashes and dashes become underscores
):
    # returns the table name

    # one table per endpoint: key columns for replacing rows, plus the full row as JSON
    name = endpoint.replace('/', '_').replace('-', '_')
    db.execute(f'create table if not exists {name} (competitionId integer, gameId integer, teamId integer, doc text)')
    db.execute(f'create index if not exists {name}_comp on {name} (competitionId)')
    db.execute(f'create index if not exists {name}_game on {name} (gameId)')
    return name


# delete the rows matching a key, then insert the fresh rows in batches, in one transaction
# rows may be a generator still paging the API; if it fails partway, the transaction rolls back and the old copy stays
def replace_rows(
    db,        # sqlite3 connection
    endpoint,  # path under /v3
    rows,      # fresh rows from the API, a list or a generator
    key,       # 'competitionId' or 'gameId'; the unit being replaced
    values     # the key values to clear before inserting
):
    # returns nothing

    # clear the old copy of every unit being replaced
    table = table_for(db, endpoint)
    values = list(values)
    with db:
        for i in range(0, len(values), 500):
            chunk = values[i:i + 500]
            db.execute(f'delete from {table} where {key} in ({",".join("?" * len(chunk))})', chunk)

        # insert the fresh rows with their key columns pulled out, a batch at a time
        rows = iter(rows)
        while batch := list(islice(rows, INSERT_BATCH)):
            db.executemany(
                f'insert into {table} (competitionId, gameId, teamId, doc) values (?, ?, ?, ?)',
                [(r.get('competitionId'), r.get('gameId'), r.get('teamId'), json.dumps(r)) for r in batch]
            )


# full pull of every configured endpoint for each competition, replaced whole by competitionId
def backfill(
    db,               # sqlite3 connection
    competition_ids,  # list of competitionIds to load
    use_export        # True pulls stats endpoints with one bulk export each; games and rosters are always paged
):
    # returns nothing

    # stats endpoints: one export covers every competition, or page through one competition at a time
    for endpoint, extra in {**GAME_ENDPOINTS, **AGG_ENDPOINTS}.items():
        if use_export:
            replace_rows(db, endpoint, iter_export(endpoint, competition_ids, extra), 'competitionId', competition_ids)
            continue
        for comp_id in competition_ids:
            replace_rows(db, endpoint, iter_all(endpoint, {'competitionIds': comp_id, **extra}), 'competitionId', [comp_id])

    # games and rosters aren't exportable, and are small enough to page
    for endpoint, extra in {GAMES_ENDPOINT: GAMES_FILTERS, **ROSTER_ENDPOINTS}.items():
        for comp_id in competition_ids:
            replace_rows(db, endpoint, iter_all(endpoint, {'competitionIds': comp_id, **extra}), 'competitionId', [comp_id])


# in-season sync: full games table, dead games cleared, changed games replaced by gameId, aggregates and rosters whole
def daily(
    db,               # sqlite3 connection
    competition_ids,  # list of competitionIds; usually the current men's and women's seasons
    since             # 'YYYY-MM-DD'; game rows updated on or after this UTC day are re-pulled
):
    # returns nothing

    # re-pull each season's games whole, so cancelled, removed or re-keyed games drop out
    # an empty pull is a bad response or a wrong id, never a real season, so skip it rather than wipe the season
    for comp_id in competition_ids:
        games = fetch_all(GAMES_ENDPOINT, {'competitionIds': comp_id, **GAMES_FILTERS})
        if not games:
            print(f'  WARNING: no games for competition {comp_id}; skipped the games replace and dead-game cleanup')
            continue
        replace_rows(db, GAMES_ENDPOINT, games, 'competitionId', [comp_id])

        # clear game-level rows whose gameId is no longer in that season's games
        with db:
            db.execute('create temp table if not exists keep_games (gameId integer primary key)')
            db.execute('delete from keep_games')
            db.executemany('insert or ignore into keep_games values (?)', [(g['gameId'],) for g in games])
            for endpoint in GAME_ENDPOINTS:
                table = table_for(db, endpoint)
                sql = f'delete from {table} where competitionId = ? and gameId not in (select gameId from keep_games)'
                gone = db.execute(sql, [comp_id]).rowcount
                if gone:
                    print(f'  {endpoint}: removed {gone} rows from games no longer in competition {comp_id}')

    # game-level rows changed since the lookback date; all of a game's rows share its updated, so whole games come back
    for endpoint, extra in GAME_ENDPOINTS.items():
        rows = fetch_all(endpoint, {'competitionIds': competition_ids, 'updated': since, **extra})
        replace_rows(db, endpoint, rows, 'gameId', {r['gameId'] for r in rows})

    # aggregates and rosters are small for one split, so re-pull them whole each day
    for endpoint, extra in {**AGG_ENDPOINTS, **ROSTER_ENDPOINTS}.items():
        for comp_id in competition_ids:
            replace_rows(db, endpoint, iter_all(endpoint, {'competitionIds': comp_id, **extra}), 'competitionId', [comp_id])


# off-season sync: no stats; re-pull competition-team-players for the season that ended and report portal changes
def offseason(
    db,               # sqlite3 connection
    competition_ids,  # the season that just ended, one id per gender
    next_ids          # the upcoming season's ids, for incoming transfers; may be empty
):
    # returns nothing

    # load the stored roster rows so changes can be reported
    table = table_for(db, PORTAL_ENDPOINT)
    for comp_id in competition_ids:
        old = {}
        for (doc,) in db.execute(f'select doc from {table} where competitionId = ?', [comp_id]):
            r = json.loads(doc)
            old[(r.get('teamId'), r.get('playerId'))] = r

        # re-pull the season's rosters; portal fields don't move updated, so this is a full pull every time
        rows = fetch_all(PORTAL_ENDPOINT, {'competitionIds': comp_id, **ROSTER_ENDPOINTS[PORTAL_ENDPOINT]})
        replace_rows(db, PORTAL_ENDPOINT, rows, 'competitionId', [comp_id])

        # the first run only stores the baseline
        if not old:
            print(f'  competition {comp_id}: stored {len(rows)} roster rows; changes are reported from the next run')
            continue

        # print every player whose portal fields changed since the last run
        for r in rows:
            prev = old.get((r.get('teamId'), r.get('playerId')))
            changed = {f: (prev.get(f), r.get(f)) for f in PORTAL_FIELDS if prev and prev.get(f) != r.get(f)}
            if changed:
                print(f'  portal change: {r.get("fullName")} ({r.get("teamMarket")}): {changed}')

        # count roster rows added or dropped since the last run
        new_keys = {(r.get('teamId'), r.get('playerId')) for r in rows}
        added, dropped = len(new_keys - old.keys()), len(old.keys() - new_keys)
        if added or dropped:
            print(f'  competition {comp_id}: {added} roster rows added, {dropped} dropped since the last run')

    # refresh next-season rosters; empty until they load, then isTransfer and priorTeamId mark the arrivals
    for comp_id in next_ids:
        for endpoint, extra in ROSTER_ENDPOINTS.items():
            replace_rows(db, endpoint, iter_all(endpoint, {'competitionIds': comp_id, **extra}), 'competitionId', [comp_id])


# parse the mode and competitions, then run it
def main():
    # returns nothing

    # command-line options
    parser = argparse.ArgumentParser(description='Sync CBB Analytics REST API data into SQLite.')
    parser.add_argument('mode', choices=['backfill', 'daily', 'offseason'])
    parser.add_argument('--competitions', type=int, nargs='*', help='competitionIds; defaults to the current seasons')
    parser.add_argument('--since', help='daily mode: YYYY-MM-DD to re-pull changes from; defaults to 3 days ago')
    parser.add_argument('--export', action='store_true', help='backfill mode: pull stats endpoints with bulk exports')
    args = parser.parse_args()
    since = args.since or (date.today() - timedelta(days=LOOKBACK_DAYS)).isoformat()

    # default to the competitions flagged current; an empty list would drop the competition filter, so stop instead
    competitions = fetch_all('competitions', {})
    competition_ids = args.competitions or [c['competitionId'] for c in competitions if c.get('isCurrent') == '1']
    if not competition_ids:
        sys.exit('No competitions to sync: none are flagged current, and --competitions was not given')

    # next seasons of the competitions being synced, for offseason mode
    synced = [c for c in competitions if c['competitionId'] in competition_ids]
    next_ids = [c['nextCompetitionId'] for c in synced if c.get('nextCompetitionId')]

    # run the mode against the local database
    start_time = time.time()
    db = sqlite3.connect(DB_PATH)
    print(f'{args.mode}: competitions {competition_ids} -> {DB_PATH}')
    if args.mode == 'backfill':
        backfill(db, competition_ids, args.export)
    elif args.mode == 'daily':
        daily(db, competition_ids, since)
    else:
        offseason(db, competition_ids, next_ids)

    # close up and print the run time
    db.close()
    print(f'Execution time: {time.time() - start_time:.2f} seconds')


if __name__ == '__main__':
    main()
