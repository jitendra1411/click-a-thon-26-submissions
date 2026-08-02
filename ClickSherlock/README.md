# ClickSherlock

## Track
SonyLIV

## Project
**Foreground-only concurrency at streaming scale** — a ClickHouse-native,
medallion-architected pipeline that counts *genuinely active* viewers per
minute from raw playback events, with a live dashboard and a conversational
analytics agent.

## Team Members
- Sachidananda Maharana (Github: `oo007`)
- Shruti Jain (Github: `CybernetTech`)
- Saurabh (GitHub: `saurabhojha`)
- Jitendra (GitHub: `jitendra1411`)

## What it does

`backend` ingests raw SonyLIV playback events (7M events on the unseen day)
and derives **foreground-only concurrency**: how many sessions/users were
genuinely watching in each minute — excluding backgrounded, paused, or
silent sessions. It serves exact per-minute peaks/averages, finalized hourly
KPIs for long ranges, multi-dimensional filters, and answers the same
questions conversationally through a LibreChat agent backed by a ClickHouse
MCP server.

## Hosted Demo

> ⏳ **Link coming soon** — the live dashboard will be hosted here (drive
> link acceptable). Demo will cover: the concurrency curve, filters, and the
> LibreChat agent in action.

## Demo Video

> ⏳ Link to the recorded 2–3 minute demo (placeholder).

## Architecture

ClickHouse-native medallion pipeline (no Python orchestrator):

```mermaid
flowchart TB
    RAW[("raw_events — Bronze")] -->|"materialized view"| ENR[("events_enriched — Silver")]
    ENR -->|"watermark-driven state machine"| INT[("session_active_intervals")]
    INT -->|"version-tracked facts"| MIN[("minute_sessions — EXACT")]
    INT -->|"finalized snapshots"| HOUR[("hourly_kpis")]
    MIN --> UI["Custom UI (filters + curve + KPIs)"]
    HOUR --> UI
    UI --> LC["LibreChat + ClickHouse MCP — conversational analytics"]
```

Full detail: [architecture_overview.md](architecture_overview.md) and the
10 step-by-step guides in [`src/backend/docs/`](src/backend/docs/).

## How we built it

- **ClickHouse as the only datastore and engine** — enrichment is a
  materialized view; sessionization is watermark-driven SQL (touched
  sessions only, never a history rescan); serving is version-tracked
  `uniqExact` sketches (exact, no FINAL/deletes on the read path).
- **Correctness**: independent state transitions (session/visibility/
  playback/buffer/liveness), 90s liveness gap, 5s flap merge — state before
  overlap. The single-latch draft overcounted 23,091 paused/backgrounded
  event-rows that this design correctly excludes.
- **Scale**: day-scoped load + MV enrichment of 6.9M events in ~16s;
  finalized hourly snapshots make long-range queries ~35x faster
  (0.04s vs 1.4s).
- **OSS stack**: ClickStack (pipeline telemetry) + LibreChat with a custom
  ClickHouse MCP server (integration committed with redacted secrets).
- **UI**: dependency-free (Python stdlib + vanilla canvas), clickpy-inspired
  yellow/black theme, IST timezone throughout.

## Concurrency curve (SonyLIV track requirement)

The curve is rendered live in the dashboard UI (not a static image). The
exact query, fresh benchmark numbers, and `system.query_log` query IDs are
in [`evidence/benchmark_queries.sql`](evidence/benchmark_queries.sql) and
[`evidence/query_log/2026-08-02_benchmark_queries.md`](evidence/query_log/2026-08-02_benchmark_queries.md)
(full trace with query IDs), the complete dashboard surface (series, KPIs,
breakdown, heatmap, filters) in
[`evidence/query_log/dashboard_benchmark.md`](evidence/query_log/dashboard_benchmark.md),
plus
[`evidence/unseen_results/BENCHMARK_RESULTS.md`](evidence/unseen_results/BENCHMARK_RESULTS.md).
Headline: **peak 16,877 sessions @ 2026-07-31 16:46 IST (16,080 users)**.

Dataset filters: see
[`evidence/filters_documentation.md`](evidence/filters_documentation.md) —
platform, country, video type, content, time range, granularity (+ the
unseen-day `video_resolution` / `show_name`).

## How to run it

Requirements: Docker (or Colima), a ClickHouse server (local container or
ClickHouse Cloud).

```bash
# 1. Create the schema (all tables, views, dictionary, materialized view)
clickhouse-client --multiquery < src/backend/01_schema.sql

# 2. Load content metadata + raw events (unseen-day ready: handles the
#    video_resolution / show_name columns and variable-length IDs)
./src/backend/05_refresh.sh --load-content content.csv
./src/backend/05_refresh.sh --load-raw raw.csv 2026-07-31

# 3. Bootstrap the day + build finalized hourly snapshots
./src/backend/05_refresh.sh --bootstrap 2026-07-31
./src/backend/05_refresh.sh --snapshots 2026-07-31

# 4. Run the dashboard (defaults to sonyliv_v2, port 8085)
python3 ui/server.py --port 8085

# 5. (Optional) Conversational layer: LibreChat + MCP servers
cd src/integrations/librechat-mcp
cp .env.example .env.portable   # fill CLICKHOUSE_* and DEEPSEEK_API_KEY
make -f Makefile.portable secrets
make -f Makefile.portable up    # LibreChat on :3080; enable MCP tools in an Agent
```

See [`src/backend/docs/10-unseen-day-runbook.md`](src/backend/docs/10-unseen-day-runbook.md)
for the end-to-end runbook, including benchmark + evidence capture.
