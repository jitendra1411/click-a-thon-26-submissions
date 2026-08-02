# SonyLIV Concurrency KPI UI + Ingestion Pipeline

## UI (custom, replaces the Grafana dashboard)

```bash
python3 ui/server.py --port 8085
```

**Two solutions, side by side** (the server routes by URL prefix):

| URL | Backed by | Coverage (loaded data) |
|---|---|---|
| `http://127.0.0.1:8085/v1/` | v1 · `sonyliv` (Python day-scoped rebuild) | 2026-07-14 → 07-26 |
| `http://127.0.0.1:8085/v2/` | v2 · `sonyliv_v2` (ClickHouse-native, session-scoped refresh) | bootstrapped days |
| `http://127.0.0.1:8085/` | default (`CH_DB`) | same as v1 |

Each page shows a badge with the active solution; the same frontend serves
both. Switch `CH_DB` to change the unprefixed default.

Dependency-free (Python stdlib + vanilla JS/canvas). Filters: time range
(from/to), granularity with units (e.g. 1/5/15/30/60 minutes, hours, days),
platform, country, video type, content. KPIs shown: peak concurrency
(sessions), peak unique users, time-weighted average concurrency, peak minute,
as-of value, open sessions.
Charts: sessions vs users over time, peak by platform, peak by video type,
top contents. All queries read the exact serving layer (`minute_sessions`)
with content-first ordering; nothing scans raw events.

Env overrides: `CH_HTTP` (default `http://127.0.0.1:8123`), `CH_USER`
(default `sonyliv_metrics` — see `setup/clickhouse-users.d/`), `CH_DB`
(default `sonyliv`; the primary solution runs `CH_DB=sonyliv_v2`, see
[`backend/`](../backend/README.md)).

**Timezone:** the dashboard displays and buckets in `Asia/Kolkata` (IST) by
default, per the problem statement's default display timezone for business
users. Raw events are stored in UTC; the serving queries convert with
`toTimeZone(..., 'Asia/Kolkata')` so every label, the heatmap's hour/day
grouping, and the KPI peak minutes are IST. The footer shows the data
coverage bounds (`cov_min → cov_max` in IST) — if a selected window is
empty, check the coverage label: the source file itself ends there.

## Ingestion pipeline (real data, no humans in the loop)

```bash
# one file
python3 setup/scripts/ingest.py --input events.csv --replace-day --telemetry

# watch a directory: new CSVs are auto-ingested and moved to <dir>/processed/
python3 setup/scripts/ingest.py --watch --dir /data/in --interval 30 --telemetry
```

Each cycle does: schema evolution (unknown CSV columns are auto-added to
`raw_events` as nullable low-cardinality), batched idempotent load, dictionary
enrichment + classification, partition-scoped serving refresh
(`06b_scoped_partition_refresh.sql`), a `pipeline_runs` audit row, and
ClickStack telemetry. Re-runs are deterministic: serving partitions for the
affected days are rebuilt, and raw duplicates collapse via
`ReplacingMergeTree`. `--replace-day` also resets the raw partition for strict
re-ingestion.

## ClickStack integration

ClickStack's OTLP receiver is protobuf-only over HTTP, so telemetry is written
directly into its bundled ClickHouse `default.otel_metrics_gauge` /
`default.otel_logs` tables — the exact tables the HyperDX UI reads. Metrics
emitted per cycle: ingestion lag, ingested events, serving query latency and
rows read, peak concurrency (last hour), open sessions, plus an INFO log
record. The `sonyliv_metrics` user is installed in both ClickHouse instances
via `setup/clickhouse-users.d/`.
