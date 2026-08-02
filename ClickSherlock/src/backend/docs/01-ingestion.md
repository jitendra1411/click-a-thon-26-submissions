# v2 Step 1 — Ingestion: raw events into Bronze

**Goal:** get raw events into ClickHouse fast, safely, and schema-tolerant.

## How rows get in

In v1 the CSV was read by a Python script. In v2 the writer is whatever
ClickHouse-native source you choose:

- **Demo / files:** copy the CSV into the server's `user_files` and use
  `file()` — or `clickhouse-client --query "INSERT ... FORMAT CSVWithNames"`.
- **Production:** a `Kafka` table engine (or `Buffer` table) landing rows into
  `raw_events` — the DDL below doesn't change.

```sql
CREATE TABLE sonyliv_v2.raw_events
(
    content_id            Int64,
    video_session_id      FixedString(64),
    user_id               FixedString(64),
    event_type            LowCardinality(String),
    event                 LowCardinality(String),
    event_time            DateTime64(3) CODEC(Delta, ZSTD),
    platform              LowCardinality(String),
    app_version           LowCardinality(String),
    country               LowCardinality(String),
    audio_language        LowCardinality(String),
    subtitle_language     LowCardinality(String),
    player_version        LowCardinality(String),
    session_start_time    DateTime64(3)
)
ENGINE = ReplacingMergeTree(event_time)
PARTITION BY toYYYYMMDD(event_time)
PRIMARY KEY (content_id, event_time)
ORDER BY (content_id, event_time, video_session_id, event_type, event, user_id);
```

## What each part means

- **`ReplacingMergeTree(event_time)`** — exact-duplicate rows (client retries)
  collapse on merge; `event_time` is the version.
- **`PARTITION BY toYYYYMMDD(event_time)`** — one partition per day: cheap
  TTL/drop, partition pruning for day queries.
- **`PRIMARY KEY (content_id, event_time)`** — content-first clustering so
  "this content, this hour" reads one index range.
- **`LowCardinality(String)`** for `event_type`/`platform`/`country` — these
  repeat constantly; LowCardinality stores them as dictionaries, saving space
  and speeding scans.

## Schema tolerance

v1's `ingest.py` auto-added new CSV columns. v2 keeps that capability but
makes it optional: an unknown column either gets added with
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (scripted), or the writer maps it
explicitly. The important property is the same: a new column never crashes
the pipeline.

## The unseen-day story

Because of `PARTITION BY day`, a fresh day of data is a new partition —
ingest it, let the MV enrich it, bootstrap that day, and it is served without
touching any other partition.

## Key numbers (provided dataset)

| Metric | Value |
|---|---:|
| Raw rows loaded (07-26) | 845,760 |
| Time span | 2026-07-14 21:13 → 2026-07-26 17:01 IST |
