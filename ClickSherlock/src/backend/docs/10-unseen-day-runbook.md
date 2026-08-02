# v2 — Unseen-day runbook (SEALED dataset, Jul 31 2026)

The unseen day is a **7M-event single day** with two schema changes:

- raw events add **`video_resolution`**
- content metadata adds **`show_name`**

Everything below runs through `backend/` only (ClickHouse-native, no Python
orchestrator). The pipeline was adapted so the **data is the source of
truth**:

1. **IDs are `String`, not `FixedString(64)`** — the unseen day may carry
   variable-length session/user ids; forcing 64-char fixed strings would
   break the load. Verified: a 66-char id flows through the MV unchanged.
2. **`video_resolution`** added to `raw_events` + `events_enriched`
   (passthrough, nullable) — the MV carries it automatically.
3. **`show_name`** added to `content_metadata`, the content dictionary, and
   `events_enriched` (dict-enriched, nullable) — the MV resolves it via
   `dictGet` with no join.

## Step 0 — download (outside the pipeline)

Get both files from the sealed Google Drive link, then copy them into the
container's `user_files` (so `file()` can read them):

```bash
docker cp ~/Downloads/ch-hackathon-raw-data_surprise.csv \
  sonyliv-ch:/var/lib/clickhouse/user_files/raw_surprise.csv
docker cp ~/Downloads/ch-hackathon-content-data_surprise.csv \
  sonyliv-ch:/var/lib/clickhouse/user_files/content_surprise.csv
```

## Step 1 — load content metadata (new `show_name` column)

```bash
./backend/05_refresh.sh --load-content /var/lib/clickhouse/user_files/content_surprise.csv
```

Inserts into `content_metadata` (including `show_name`) and reloads the
dictionary. Sanity: ~33K rows.

## Step 2 — load raw events (new `video_resolution` column)

```bash
./backend/05_refresh.sh --load-raw /var/lib/clickhouse/user_files/raw_surprise.csv
```

Loads 7M rows into `raw_events`; the materialized view enriches them
**during insert** (independent state transitions + `video_resolution`
passthrough + `show_name` via dict). No backfill needed — the MV owns
enrichment. Sanity: `SELECT count() FROM events_enriched WHERE toDate(event_time)='2026-07-31'`
≈ the filtered subset of 7M.

## Step 3 — bootstrap the day

```bash
./backend/05_refresh.sh --bootstrap 2026-07-31
```

Builds intervals, minute facts, and versions for the day; seeds the
watermark from the **actual loaded max event time** (never wall-clock — the
P0.5 fix).

## Step 4 — finalize hourly snapshots

```bash
./backend/05_refresh.sh --snapshots 2026-07-31
```

Publishes finalized hourly KPIs (peak / time-weighted average / end) per
approved dimension set, only for hours past the lateness watermark.

## Step 5 — benchmark queries + evidence (the judged deliverable)

Run the benchmark queries against `sonyliv_v2`, capture latencies, and keep
`system.query_log` evidence:

```sql
-- 1) Global peak + peak minute for the day (exact view)
SELECT toTimeZone(minute_bucket, 'Asia/Kolkata') AS peak_minute,
       uniqExactMerge(sessions_state) AS peak
FROM sonyliv_v2.minute_sessions
WHERE toDate(minute_bucket) = '2026-07-31'
GROUP BY minute_bucket ORDER BY peak DESC LIMIT 1;

-- 2) Peak by platform / country / video_type (each combination's own peak)
SELECT platform, max(c) AS peak
FROM (SELECT platform, minute_bucket, uniqExactMerge(sessions_state) AS c
      FROM sonyliv_v2.minute_sessions WHERE toDate(minute_bucket) = '2026-07-31'
      GROUP BY platform, minute_bucket)
GROUP BY platform ORDER BY peak DESC;

-- 3) Hourly snapshots (long-range path)
SELECT toTimeZone(hour_bucket, 'Asia/Kolkata') AS h, peak_concurrency
FROM sonyliv_v2.hourly_kpis WHERE dimension_set_id = 1 ORDER BY h;

-- 4) Evidence: capture reads/latency for each query
SELECT query, read_rows, read_bytes, query_duration_ms
FROM system.query_log
WHERE query_start_time >= now() - INTERVAL 10 MINUTE
  AND query ILIKE '%minute_sessions%'
ORDER BY query_start_time DESC LIMIT 20;
```

Run each query with timing, and record `pipeline_runs` (the refresh writes a
row per cycle) as the pipeline-evidence trail. Save the outputs + timings to
`backend/unseen_results/` before the deadline.

## Why this generalizes (the 100× / unseen-day story)

- **No schema assumptions**: String IDs, nullable new columns, dict-driven
  enrichment — the CSV shape drives the load.
- **No rebuilds**: enrichment is a MV; bootstrap is day-scoped; refresh is
  session-scoped; hourly snapshots are finalized once past the watermark.
- **7M events ≈ 10× the provided file**: the same bounded-cost properties
  apply — touched-session refresh, exact sketch serving, 12 snapshot rows per
  hour per dimension set.

## Validation already done (with synthetic unseen-day files)

- 66-char variable-length IDs load and enrich without truncation.
- `video_resolution` and `show_name` flow raw → enriched correctly.
- Full-week re-bootstrap after the String-ID change reproduces the serving
  layer (25,976 intervals / 130,498 facts).
