# [CBB Analytics REST API](https://rest.cbbanalytics.com/api-docs/), v3 Migration Guide

All changes are **backward-compatible.** `/v1/` and `/v2/` will continue to work as they did previously, so you do not need to make changes immediately. That said, we recommend moving to `/v3/` at your convenience. `/v1/` and `/v2/` will be deprecated only after all users have migrated to `/v3/`.

## 1. What changed in /v3/

`/v3/` is now the recommended API version. `/v3/` returns the same data fields as `/v2/`, but the response is wrapped in a small structure that also includes paging details and request information. In `/v2/`, the data array was returned directly. In `/v3/`, the data array is now at `response.data`, and paging details are at `response.meta`, example below:

```json
{
  "response": {
    "meta": {
      "version": "v3",
      "code": 200,
      "status": "success",
      "request": "https://rest.cbbanalytics.com/v3/games?competitionIds=41097&limit=1000",
      "time": 1734567890,
      "count": 1000,
      "limit": 1000,
      "offset": 0,
      "nextCursor": "507f1f77bcf86cd799439011",
      "hasMore": true
    },
    "data": [ ... ]
  }
}
```

- `count` is the number of rows on this page, not the total for your query.
- `time` is when the response was built, in Unix seconds.
- `request` echoes the URL you called.
- Errors return a status code with a plain-text message, not the envelope, so check the status before reading `response.data`.

## 2. How to migrate to /v3/

To move from `/v2/` to `/v3/`:
- Change the URL prefix from `/v2/` to `/v3/`.
- Read the returned data from `response.data`.
- Read paging information from `response.meta`.
- Remove the `sortBy` and `sortOrder` parameters. `/v3/` returns `400` if either is sent.
- Review your process for handling new fields.

One important note: `/v2/` and `/v3/` automatically receive new fields as we add new stats. `/v1/` stays frozen and does not receive new fields. If you are migrating from `/v1/`, make sure your pipeline doesn't break on a field it hasn't seen; see [When fields change](PIPELINE_GUIDE.md#when-fields-change) in the pipeline guide.

## 3. Faster pagination with cursors

Cursor pagination is now available on `/v1/`, `/v2/`, and `/v3/`. We recommend using cursor pagination for large data pulls and daily update jobs because it is much faster than offset pagination.

To use cursor pagination:
- Send a request with a `limit` (1000 is the max).
- Use the returned cursor as the `after` value in your next request. Send it back unchanged; don't build or edit cursors yourself.
- Continue until there is no next cursor.

Example request:

```
/v3/games?competitionIds=41097&limit=1000&after=<cursor>
```

Where to find the next cursor:
- In `/v1/` and `/v2/`: use the `X-Next-Cursor` response header.
- In `/v3/`: use `response.meta.nextCursor`.
- In `/v3/`, you can also stop when `"hasMore": false`.

Pagination notes:
- When `after` is used, `offset` is ignored.
- Cursor pagination uses the default sort order.
  - On `/v1/` and `/v2/`, `sortBy` cannot be used with `after`.
  - `sortBy` and `sortOrder` are not accepted on `/v3/`.
- If you rely on custom sorting, stay on `/v1/` or `/v2/` for now, or contact us so we can better understand how you are ingesting the data.

Offset pagination will continue to work for smaller queries, but we recommend cursor pagination for recurring data pulls.

## 4. New game date filters

We added two new filters for game-level endpoints:
- `gameDateFrom`
- `gameDateTo`

These are available on:
- `/games`
- `/stats/team/game-box`
- `/stats/team/game-pbp`
- `/stats/team/period-box`
- `/stats/team/game-by-qualifier`
- `/stats/player/game-box`
- `/stats/player/game-pbp`
- `/stats/lineups/game`
- `/stats/possessions`

Date format: `YYYY-MM-DD`.

Inclusive on both ends (>= date, <= date). You can send either one alone for an open-ended range. To pull data for one day, use the same date for both:

```
gameDateFrom=2025-01-15&gameDateTo=2025-01-15
```

## 5. Updated resources

The API docs have been updated for this release: https://rest.cbbanalytics.com/api-docs/. They now cover `/v3/`, cursor pagination, the new game date filters, and the new envelope response format.

This repo has the rest:
- [Python quickstart](scripts/cbb_rest_api_quickstart.ipynb) and [R quickstart](scripts/cbb_rest_api_quickstart.R), both on `/v3/` with cursor pagination by default.
- [Postman collection](cbb-analytics-api.postman_collection.json), one `/v3/` request per endpoint.
- [Pipeline guide](PIPELINE_GUIDE.md): backfills, daily syncs, transfer portal tracking, and bulk exports (`/v3/` only).

For help migrating or with large backfills, email nick@cbbanalytics.com.
