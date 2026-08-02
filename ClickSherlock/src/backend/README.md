# Solution v2 — ClickHouse-native pipeline (PRIMARY)

v2 moves the pipeline **into ClickHouse**: no Python orchestrator, no
drop-the-day-and-rebuild loop. The stateless transforms are materialized
views; the stateful sessionization is a watermark-driven SQL refresh that
re-derives only the sessions that moved.

> **Status: PRIMARY (2026-08-02, review-implemented).** Independent-state
> enrichment (session/visibility/playback/buffer + liveness), deterministic
> event ordering, version-tracked facts with a current-version view (no
> FINAL, no DELETE), **exact** cardinality for benchmark views, and
> bootstrap enrichment owned by the MV (backfill is a separate guarded
> script). Validated on 07-26: peak **2,745 sessions @ 16:26 IST** (exact
> view); the delta vs v1's 2,727 is the P0.1 fix — 23,091 event rows where
> the old single latch counted paused/backgrounded time as active are now
> correctly inactive, and 0 rows are wrongly excluded.

## Why this is the 100x story

| v1 (hackathon path) | v2 (primary) |
|---|---|
| Python loops over rows, classifies, drives refreshes | All logic is SQL; scheduler only substitutes `{wm}` / `{cycle}` and calls `clickhouse-client` |
| Enrichment as a day-scoped INSERT | Enrichment is a **materialized view** with independent state transitions + deterministic ordering |
| Drop day partitions + rebuild for refresh | Watermark + touched-session re-derivation; **history partitions never touched** |
| Gold = day rebuild | Gold = version-tracked facts; refresh appends at new version + current-version join on read (no FINAL, no DELETE) |
| `session_state` held in Python memory | Watermark + interval versions live in tables |
| Approximate `uniqState` called "exact" | **Exact** `uniqExactState` for benchmark views (`minute_sessions`), approximate kept as `minute_sessions_approx` |

## Files

| File | Role |
|---|---|
| `01_schema.sql` | DB, raw/events/state/gold tables, enrichment MV, serving views |
| `02_bootstrap.sql` | Day-scoped initial load (`{day}`, `{cycle}`) — intervals/facts/versions only (enrichment is the MV's job) |
| `02_backfill_enrichment.sql` | **Recovery-only**: enrich raw rows that predate the MV; refuses to double-run |
| `03_refresh.sql` | One live cycle: touched sessions → re-derive intervals → append versioned facts → record versions → advance watermark |
| `04_hourly_snapshots.sql` | Finalized hourly KPI snapshots (peak / time-weighted avg / end) per approved dimension set — built only after the lateness watermark passes |
| `05_refresh.sh` | Scheduler: `--bootstrap DAY`, `--once`, `--loop` |
| `06_fixtures_and_tests.sql` | Acceptance fixtures (P0.1 latch bugs, P0.2 version pre-merge, P0.4 double-write) |

**Unseen-day ready (Jul 31 2026 sealed dataset):** IDs are `String` (not
`FixedString(64)`) — variable-length ids load unchanged; `video_resolution`
and `show_name` flow raw → enriched via the MV/dictionary; `05_refresh.sh`
now has `--load-content FILE`, `--load-raw FILE`, and `--snapshots DAY`.
See [`docs/10-unseen-day-runbook.md`](docs/10-unseen-day-runbook.md).

Step-by-step docs (same format as the v1 guides): see
[`docs/`](docs/00-overview-and-schema-map.md) — ingestion, MV enrichment,
state machine, gold views, the refresh cycle, and dashboard serving.

## Runbook

```bash
# 1. Create schema (idempotent), load content metadata (one-time)
clickhouse-client --multiquery < backend/01_schema.sql

# 2. Ingest the raw CSV (any standard mechanism — file(), Kafka, clickhouse-client)
#    into sonyliv_v2.raw_events, then:
./backend/05_refresh.sh --bootstrap 2026-07-26

# 3. Go live
./backend/05_refresh.sh --loop          # every 30s, or via cron
```

## The refresh cycle (03_refresh.sql), one pass

1. Read events with `event_time > watermark - 10min` (late window).
2. Touched sessions = `DISTINCT video_session_id` of those events.
3. Re-derive ONLY those sessions' maximal intervals from the independent
   states (session open AND foreground AND playing; 90s liveness tail for
   open sessions, 5s flap merge, 6h cap).
4. Append the touched sessions' intervals and facts at `version = cycle` and
   record the version in `session_versions` — INSERT-only, no mutations.
   Serving queries join the version table (no FINAL, no DELETE).
5. Advance the watermark; record `pipeline_runs`.

## Review items implemented (2026-08-02)

- **P0.1** independent state transitions (no single activity latch);
  `AppForegrounded` changes visibility only; fixture-validated.
- **P0.2** `v_session_versions_current` (max(version) join) — served rows
  reflect a new version immediately, before merges.
- **P0.3** exact cardinality (`uniqExactState`) for benchmark views.
- **P0.4** bootstrap no longer enriches (MV owns it); recovery backfill is a
  separate guarded script.
- **concurrency_deltas_hour** removed (was write-only/stale in live refresh).
- **Hourly long-range serving** implemented as finalized KPI snapshots
  (`04_hourly_snapshots.sql`): peak / time-weighted average / end concurrency
  per approved dimension set, built only for hours past the lateness
  watermark. Validated on 07-26: 16:00 IST hour peak 2,745, average 1,893.7 —
  exact match to the minute-level view. Replaying the build is idempotent
  (ReplacingMergeTree(data_as_of), keyed rows).

**Remaining (documented next steps):** P0.5 ingestion-watermark split (late
event detection, no permanent 10-min overlap), P1 run-scoped touched set,
truthful pipeline_runs, expiry/finality crossing, session-oriented read
benchmarks, and finalized hourly KPI snapshots.

Cost is proportional to **sessions that emitted new events** — not the day's
total rows. At 100x, a 1M-viewer live event = 1M touched sessions re-derived
per cycle, while history stays untouched.

## Serving views (same shapes as v1, so the UI is unchanged)

- `minute_sessions` — view over latest per-session facts, `uniqState` per
  (minute × dims) → `uniqMerge` gives exact distinct sessions/users.
- `minute_deltas` — +1/−1 change points from the latest intervals.
- `v_open_sessions_deltas` — live provisional tails.

The UI reads the same table/view names (`minute_sessions`, `minute_deltas`,
`open_sessions_deltas`) in the configured database, so switching the demo to
v2 is a one-line database-name change — done: `CH_DB=sonyliv_v2` in the
running UI server.

## Validation (what we prove before pointing the UI at it)

- Bootstrap `2026-07-26` in `sonyliv_v2` → peak = **2,727 sessions @ 10:59 IST**
  (matches v1 exactly) — done.
- Re-run bootstrap (same day) → identical numbers (idempotent) — done.
- A refresh cycle with no new events → no changes (no-op) — done.
- A synthetic event append → only affected sessions change (3-min session →
  3 fact minutes, peak unchanged); re-running the same cycle adds no served
  rows — done.
