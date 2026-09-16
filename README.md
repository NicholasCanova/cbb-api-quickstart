# CBB Analytics REST API Quickstart

Sample clients for the [CBB Analytics REST API](https://rest.cbbanalytics.com/api-docs/). Each one pages through an endpoint, handles cursor and offset pagination, and returns a tidy data frame.

| File | What it is |
|---|---|
| `scripts/cbb_rest_api_quickstart.ipynb` | Python notebook (pandas + requests) |
| `scripts/cbb_rest_api_quickstart.R` | R script (httr + dplyr) |
| `cbb-analytics-api.postman_collection.json` | Postman collection, one request per endpoint |

You need an API key for any of these. Contact CBB Analytics if you don't have one yet.

## Clone the repo

```bash
git clone https://github.com/NicholasCanova/cbb-api-quickstart.git
cd cbb-api-quickstart
```

## Set up the Python environment

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Python

**Run in the browser (no install):**
[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/NicholasCanova/cbb-api-quickstart/blob/master/scripts/cbb_rest_api_quickstart.ipynb)

**Run locally:**

```bash
jupyter notebook scripts/cbb_rest_api_quickstart.ipynb
```

Set `API_KEY` in the Setup cell and run the cells in order. Sections A-D fetch data. Sections E-F are optional benchmarks that pull large result sets.

## R

```r
install.packages(c('httr', 'dplyr', 'purrr', 'tibble', 'readr'))
```

Open `scripts/cbb_rest_api_quickstart.R` in RStudio, set `api_key` in `setup()`, and source the file or run it section by section. `fetch_data(table, params)` is the function you'll use most.

## Postman

1. Import `cbb-analytics-api.postman_collection.json` (Postman > Import > Upload Files).
2. Open the collection's Variables tab and set `apiKey`.
3. Save, then send any request. Filter params are pre-filled and disabled; enable the ones you want.

## API basics

- Base URL: `https://rest.cbbanalytics.com/v3`. Auth with an `X-API-Key` header.
- v3 responses are wrapped: `{ response: { meta, data } }`. `meta.nextCursor` drives cursor pagination.
- Use cursor pagination (`after=<cursor>`) for bulk pulls. `limit` maxes out at 1000.
- Full endpoint and parameter reference: https://rest.cbbanalytics.com/api-docs/
- Field definitions: https://cbbanalytics.com/resources/glossary
- API Changelog: https://cbbanalytics.com/resources/api-changelog

## Problems?

Open an issue in this repo or email nick@cbbanalytics.com.
