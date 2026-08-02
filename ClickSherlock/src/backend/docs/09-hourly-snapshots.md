# v2 — Finalized hourly KPI snapshots (long-range serving)

**Why this exists:** the problem statement's constraint — *"exploding every
session into per-minute rows is prohibitively large, and recomputing overlap
from raw session history on every dashboard query is far too slow"* — means
long ranges (weeks/months) must not scan minutes, and a net-delta rollup
cannot answer "what was the peak inside that hour?" The answer is a
**precomputed, finalized hourly snapshot** of peak / time-weighted average /
end concurrency, per approved dimension set.

## What the table stores (`hourly_kpis`)

```text
hour_bucket          -- IST hour (stored as UTC wall-clock = IST hour start)
dimension_set_id     -- approved combination (see dimension_sets registry)
country / platform / video_type / content_id  -- the set's dimension values
entity_type          -- 'session' (user variant future)
metric_definition, definition_version
peak_concurrency     -- max per-minute concurrency inside the hour
average_concurrency  -- TIME-WEIGHTED (sum(v*1min)/count), not (start+end)/2
end_concurrency      -- concurrency at the hour's last minute
is_final             -- always 1: only finalized hours are published
data_as_of, source_run_id
```

## Why finalized and why only past the watermark

An hour is built only when
`event_watermark - late_window >= end_of(hour)` — after that, no late event
can change the hour's minutes, so the snapshot is **immutable**. The same
rule that makes near-now curves provisional makes published hours final.

## Approved dimension sets (registry)

Concurrency is **non-additive** across dimensions, so only these combinations
are promised (the review's cuboid list):

| id | set |
|---|---|
| 1 | global |
| 2 | country |
| 3 | platform |
| 4 | video_type |
| 5 | content |
| 6 | country × platform |
| 7 | platform × video_type |
| 8 | content × platform |

## Build semantics

- **One UNION ALL per set** — each computes its own per-minute exact counts
  (`uniqExactMerge`) then aggregates peak / weighted average / end.
- **Idempotent:** rows are keyed by
  `(hour_bucket, dimension_set_id, dims, metric, version)` in a
  `ReplacingMergeTree(data_as_of)` — replaying the build with a newer
  `data_as_of` replaces, never duplicates. `hourly_build_runs` audits each
  publish.
- **Partition per day** for cheap retention/atomic rebuilds.

## Validated on 07-26

With the watermark past all of 07-26, the 16:00 IST hour snapshot is:
peak **2,745**, time-weighted average **1,893.7**, end **211** — verified
against the exact minute-level view (peak 2,745, avg 1,893.7 over 60
minutes). The 17:00 hour is intentionally partial/unbuilt because the
dataset ends there.

## The ladder (why each layer exists)

| Range | Reads | Why |
|---|---|---|
| minutes–hours (dashboard) | `minute_sessions` exact view | exact, bounded by the range |
| days–weeks | `hourly_kpis` (finalized) | 12 rows per set per day instead of 1,440 |
| months+ | `hourly_kpis` + TTL/archival | same, plus retention |

Nothing on this ladder touches raw events — every layer is a pre-aggregate of
the layer below.
