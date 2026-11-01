# Building data ingestion pipelines on the CBB Analytics REST API

- How to keep the current season in sync with daily ingests.
- How to sync during the off-season for whose in the transfer portal.
- How to backfill past seasons.

This page goes over each of the three ingestion patterns, and [`scripts/cbb_sync.py`](scripts/cbb_sync.py) is working python code for each. The paragraphs below reference the functions in [`scripts/cbb_sync.py`](scripts/cbb_sync.py) that handle each ingestion pattern. It writes to a local SQLite file so it runs with no setup. SQLite stands in for your own database: keep the delete-then-insert logic and swap the storage calls.

```bash
# install requests library, export your API Key
pip install requests
export CBB_API_KEY=your-key

# 2025-26 men's and women's, stats via bulk export
python scripts/cbb_sync.py backfill --competitions 41097 41098 --export

# in-season, current seasons; add --since 2026-11-10 after an outage
python scripts/cbb_sync.py daily

# portal changes on the season that just ended
python scripts/cbb_sync.py offseason
```

## The calendar

| When | What to run |
|---|---|
| Initial setup | **Backfill** the seasons you want. |
| Early October - early April | **Daily sync**, each morning. The new season becomes `isCurrent` in early October, when new rosters are available and exhibitions start. |
| After the season ends | **Reload the season that just ended** once, then stop the daily sync. Stats do not change in the off-season. |
| April - early October | **Off-season portal tracking**, every afternoon. No stats fetching. |
| Once a year, before the season | **Reload past seasons** you keep, from bulk exports. That picks up fixes on our side that don't move `updated`. |

## When our data updates

| Period | Our refresh | Schedule your job |
|---|---|---|
| Season | Once a day, starting 4:00am ET. Finished by about 5:30am ET. | 6:00am ET or later |
| Off-season | Portal data 3x a day at 5:00am, 11:00am, 5:00pm ET. Season stats don't change. | 30 minutes after each of our runs |

Times are fixed in Eastern time year-round.

## Requests and limits

- Each page is one request against your key's monthly and yearly limits. Use `limit=1000` (the max) so a 20,000-row pull only costs 20 requests.
- The rate limit is 180 requests per minute. A `429` means slow down and retry. A 1 second sleep timer between API calls is advised. A `429` whose body says `Monthly API limit exceeded` or `Yearly API limit exceeded` means you're out of quota until the limit resets, so retrying won't help. If this happens, email your primary contact at CBB Analytics.
- Stats endpoints currently return Division I only. Pass `divisionIds=1` on `games`, `competition-teams` and `competition-team-players` to match.
- On aggregate endpoints, always pass `splits`. Without it you get every split (home, away, conference, last 5, and many more), which can be many times the rows you wanted.

Approximate cost for one gender, one D1 season, at `limit=1000`:

| Endpoint | Rows | Requests |
|---|---|---|
| `games` | ~6,500 | 7 |
| `stats/team/game-box` | ~26,000 | 26 |
| `stats/player/game-box` | ~132,000 | 133 |
| `stats/player/agg-box?splits=season` | ~5,000 | 5 |
| `competition-team-players?divisionIds=1` | ~5,600 | 6 |

The pbp, lineup, possession and chance endpoints are larger. Add them one at a time and check your usage.

## Use v3 and cursor pagination

- Call `https://rest.cbbanalytics.com/v3/...` with your key in the `X-API-Key` header. v3 wraps every response as `{ response: { meta, data } }`. v1 and v2 stay up but are legacy and may be deprecated in the future.
- Page with cursors: send the first request without `after`, then send each response's `meta.nextCursor` back unchanged as `after`, and stop when it's missing. Cursor pages stay fast at any depth. `offset` slows down as it goes deeper.
- Don't build or edit cursors yourself, and don't send `sortBy` (v3 rejects it). `iter_all()` in the script is the whole loop.

## Bulk exports

`GET /v3/exports?endpoint=<stats endpoint>&competitionIds=<ids>` returns a link to one gzipped NDJSON file with every row of one stats endpoint (one JSON row per line, same fields as the v3 response). Use it for large backfills instead of paging through hundreds of requests.

- The reply is `{ file: { url, rows, bytes, expiresAt }, snapshots: [{ competitionId, snapshotDate }] }`. Download `file.url` within 15 minutes; downloading it again in that window is free.
- Files are built from our nightly snapshots, so the data is as of each competition's `snapshotDate` (`YYYYMMDD`). A competition with no snapshot returns `404`.
- One call covers as many competitions as you list, so one export per endpoint can load every season you want.
- Paid keys include 10 exports a month, on their own monthly limit; each export call also counts as one regular request. The `X-Exports-Used` and `X-Exports-Limit` response headers show where you stand. An export is charged when the link comes back; an error before that costs nothing. For more, email nick@cbbanalytics.com.
- Stats endpoints only (anything under `stats/`, including `stats/possessions` and `stats/chances`). Page through `games`, `competition-teams` and `competition-team-players`; they're small.
- Filters the endpoint accepts work here too (`splits`, `teamIds`, `conferenceIds`, `updated`). Paging and sorting params (`limit`, `after`, `offset`, `sortBy`, `sortOrder`) return `400`.
- `iter_export()` in the script requests one, downloads it and reads it. In pandas: `pd.read_json(path, lines=True, compression='gzip')`. In R: `jsonlite::stream_in(gzfile(path))`.

Exports are for backfills and reloads. Don't use them for the daily sync.

## Backfill past seasons

`backfill()` in the script.

1. Get competition ids from `/v3/competitions`. There's one per season per gender, and `isCurrent` marks the live ones per gender.
2. For stats endpoints, use one bulk export per endpoint covering all the seasons you want. If you're out of exports, page through `competitionIds=<id>` instead (plus `splits` on aggregates).
3. Page through `games` and the roster endpoints for each competition.
4. Replace each competition's rows whole: delete that competition's rows, then insert the fresh ones, in one transaction. A failed run then never leaves a season half old and half new.

## Stay current during the season

`daily()` in the script. Every morning after 6:00am ET, for each current competition:

1. **Games:** re-pull the full `games` table (`competitionIds=<id>&divisionIds=1`, about 7 requests per gender) and replace it for the entire current competitionId each day. If it comes back empty, skip this step and the next; a current season always has games, so an empty pull is an error, and replacing with it would wipe the season.
2. **Clear dead games:** this is why we recommend re-pulling games daily. In every game-level table, we then delete rows for that competition whose `gameId` is no longer in `games`. This drops games that were cancelled, removed or re-keyed, which `updated` filters can never return.
3. **Other game-level endpoints** (`stats/team/game-box`, `stats/player/game-box`, the `game-pbp` endpoints, `stats/possessions`, `stats/chances`, `stats/lineups/game`): fetch `competitionIds=<id>&updated=<since>`. For each `gameId` that comes back, delete your copy of that game and insert the new rows. Don't upsert by rowId: if a correction leaves a game with 172 possessions instead of 173, an upsert keeps the stale 173rd possession.
4. **Aggregate endpoints** (`stats/team/agg-box`, `stats/player/agg-box`, the `agg-pbp` endpoints, and others): every game changes season totals, and in-season nearly every team plays within a few days. Re-pull the current season for the splits you use, and replace it whole.
5. **Rosters** (`competition-teams`, `competition-team-players`): small. Re-pull the current season daily and replace it whole.

Picking `since`, either works:
- **Fixed window:** today minus 3 days. Simple, and it covers a missed day or two. If your job is down longer than that, run once with an earlier date by hand (`--since` in the script).
- **From your last good run:** save the date of each successful sync and use that date minus 1 day. Nothing is missed after an outage, but you have to store the date.

How `updated` works:
- It matches by UTC day. `updated=2026-11-14` returns rows changed on or after Nov 14 UTC. A time part is accepted but ignored.
- All of one game's stat rows share the game's `updated`, so a filtered pull returns whole games. That's what makes replace-by-`gameId` safe.
- On `games`, `updated` also moves for schedule, venue and status changes. `gameDataUpdated` on `games` is when the box score or play-by-play last changed.

Some fields on team game rows describe the season as of today, not the game, and change without moving `updated`: `teamGameRecency`, `netRankAgst`, `quadAgst`, and the win-loss record columns. On games older than your lookback they go stale. If you use them, recompute them yourself or re-pull the current season's game-box once a week.

## Off-season: track the transfer portal

`offseason()` in the script. Once the season-end reload is done, stop fetching stats. Portal activity changes daily from late March into the summer, and `competition-team-players` is the source of truth for it.

1. Once a day after 1:00pm ET, re-pull `competition-team-players?competitionIds=<season that just ended>&divisionIds=1` in full. It's about 6 requests per gender.
2. Compare `inPortalAfterSeason` and `portalStatus` against yesterday's copy. Portal changes don't move `updated`, so a diff is the only way to catch them.
3. Also pull `competition-team-players?competitionIds=<next season>&divisionIds=1`, where the next season's id is `nextCompetitionId` on `/v3/competitions`. That id appears before rosters do; the pull comes back empty until next season's rosters load, usually early October. Then `isTransfer` and `priorTeamId` mark the arrivals.

`willTransfer`, `nextTeamMarket` and `nextConferenceId` on the season that just ended come from next season's rosters, not the portal. They stay empty or false until those rosters load in October.

The same portal fields also appear on `stats/player/agg-box` and other player stats endpoints. **We suggest not re-pulling stats just to keep these portal fields fresh;** let them go stale in your stats tables and read portal status from `competition-team-players`.

The season that just ended stays `isCurrent` until early October, so the script's default competitions work all summer.

## Storing rows

- **Replace by unit, don't upsert by row.** The unit is a game for game-level endpoints and a competition for aggregates and rosters. Delete the unit, then insert the fresh rows. Replacing whole units handles corrections, removed rows and duplicates the same way. `replace_rows()` in the script.
- **Don't rely on `_id` across days.** It's stable on some endpoints and regenerated nightly on others. Use it only as the pagination cursor.
- **Keep the raw row.** Storing the whole JSON row, as the script does, means a field we add is already in your copy the next time that row is pulled.

## When fields change

We add new fields to v2 and v3 during the season, usually many at once a few times a season. All new fields are listed in the [API Changelog](https://cbbanalytics.com/resources/api-changelog). Your pipeline should not break when new fields are added.

**Build for it:**
- Don't fail on a field you haven't seen. Store the raw row, or drop columns you don't know, but never reject the row.
- Read fields by name, never by position. New fields can appear anywhere in a row, not just at the end.
- Treat a missing field as null, not an error. Fail only when an id you key on (`competitionId`, `gameId`, `teamId`, `playerId`) is missing.
- If you load into typed tables, add new columns automatically, or log them and carry on.

**Getting a new field into the rows you already have:**
- Adding a field does not move `updated`, so the daily sync won't pick it up on old games by itself.
- Current season: re-page the current competition once for the endpoints that gained fields. Aggregates and rosters already refresh daily.
- Past seasons: only if you need the new field there. Fields usually arrive in batches, so wait for a batch and reload with exports once, rather than after every new field. Yearly reloads catch the rest.

**If a field is renamed or removed:** we do our best to avoid this, but it can happen, and the API Changelog will say so.
- With the rules above, a removed field becomes null in new rows and nothing breaks.
- Keep any rename mapping (old name to new name) in one place in your code, so a rename is a one-line change.
- Rows you stored before a rename still carry the old name until you reload them. Either reload those seasons, or read the old name when the new one is missing.
- Check the changelog before reporting a missing field. If it isn't listed there, email nick@cbbanalytics.com.

## Links

- Endpoint and parameter reference: https://rest.cbbanalytics.com/api-docs/
- Field definitions: https://cbbanalytics.com/resources/glossary
- API Changelog: https://cbbanalytics.com/resources/api-changelog
- Technical questions: nick@cbbanalytics.com
- Sales and API access: tim@cbbanalytics.com

## Conclusion

Linking this guide or the links above to your LLMs is not a bad idea. For any questions or issues with this guide or with the [`scripts/cbb_sync.py`](scripts/cbb_sync.py) script, please email me at nick@cbbanalytics.com. Happy building!
