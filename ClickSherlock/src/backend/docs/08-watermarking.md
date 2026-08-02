# v2 — Watermarking: what it solves and why it is needed

## The problem in one sentence

A streaming pipeline must answer: **"which events have I already processed?"**
Without a precise answer, every cycle either reprocesses everything
(idempotence becomes the only safety net — expensive and wrong under
late-arriving data) or silently skips events (data loss). A **watermark** is
the single number that answers that question: *the pipeline has seen
everything with event time ≤ watermark*.

## Why event time, not arrival time?

Events carry two clocks:

- **ingested_at / arrival time** — when the event reached the pipeline
  (monotonic, reliable, but meaningless for business logic);
- **event_time** — when the playback event actually happened (what
  concurrency is defined over).

Concurrency is defined on `event_time`. But events **arrive out of order**:
heartbeats queue on the device, retries re-send old rows, a killed app flushes
late. So "I read everything since my last cycle" (arrival-time progress) does
not mean "I have everything for the last minute" (event-time completeness).
The watermark reconciles the two: it is event-time progress, advanced only
after the pipeline is confident it has seen the relevant events.

## What the watermark buys us

| Property | Without watermark | With watermark |
|---|---|---|
| Work discovery | Re-derive everything (or guess) | Touched set = sessions with events after `watermark − late window` |
| Idempotence | Depends on merge-time dedup everywhere | Re-reading the same window is a no-op (state guard) |
| Finality | Can't say when a session/interval is settled | Session finalizes when `watermark > last signal + 90 s + lateness` |
| Late events | Missed or duplicated | Caught inside the late window, then the window advances past them |
| Crash safety | Restart = unknown state | Restart resumes from the persisted watermark |

## How the current v2 pipeline uses it

### Bootstrap seeding

`05_refresh.sh --bootstrap DAY` runs the day-scoped build, then seeds:

```sql
INSERT INTO sonyliv_v2.pipeline_watermark (id, watermark, updated_at)
VALUES (0, now64(3), now64(3));
```

`pipeline_watermark` is a one-row `ReplacingMergeTree(updated_at)` — the
latest write wins. The refresh reads it with `FINAL` (one row; cheap).

### The refresh cycle (`03_refresh.sql`)

1. **Read the watermark** (`{wm}` = previous cycle's value).
2. **Discover work**:
   ```sql
   INSERT INTO sonyliv_v2.touched_sessions
   SELECT DISTINCT video_session_id
   FROM sonyliv_v2.events_enriched
   WHERE event_time > toDateTime64('{wm}', 3) - INTERVAL 10 MINUTE;
   ```
   The **10-minute late window** exists because event-time progress lags
   arrival: an event stamped 11:59 that arrives at 12:05 must still be
   processed. The window is the contract "we tolerate up to 10 minutes of
   lateness".
3. **Re-derive only the touched sessions** (state machine → versioned
   intervals → versioned facts).
4. **Advance the watermark** to the max event time seen this cycle.

### Event-time finality (the other half of the watermark)

The same watermark drives liveness/finality, not just work discovery. A
session's open interval carries a provisional tail (`last signal + 90 s`).
It is **finalized** once the watermark passes
`last signal + 90 s + late window` — at that point no late event can arrive
that would change the interval. This is why the curve near "now" is
provisional and settles after the lateness horizon — the as-of/finality
semantics the dashboard displays.

## Known limitations of the current single-watermark design

These are the review's P0.5 findings — documented here so the design intent
is explicit:

1. **The 10-minute overlap is reprocessed every cycle.** Work discovery uses
   `event_time > watermark − 10 min`, so each cycle re-scans the same last ten
   minutes even when nothing new arrived. Correct (the state guard makes it a
   no-op) but wasteful.
2. **Events older than the window are never detected.** A one-hour-late event
   falls outside `watermark − 10 min` and is missed. The contract is explicit:
   lateness > window is out of scope for the incremental path (it needs a
   targeted repair, not the live loop).
3. **Bootstrap seeds with wall-clock `now()`**, not the max source event time.
   For pure historical replay this is unsafe — the first cycle would think
   nothing is new. The runbook must seed from the loaded data.
4. **One watermark conflates two meanings:** *how far ingestion has
   progressed* (which rows are new) and *how far event-time completeness has
   advanced* (what can be finalized).

## The reviewed design: two watermarks

The fix separates the two meanings:

| Watermark | Meaning | Drives |
|---|---|---|
| `ingestion_watermark` | rows already canonicalized/processed (identified by batch/offset, not event time) | touched-session discovery — **no permanent overlap** |
| `event_watermark` | event-time completeness (max event time observed) | liveness finality + allowed-lateness decisions |

Touched sessions come from **newly ingested rows** (a `(batch_id,
source_row_number)` lineage, monotonic), so an empty cycle finds zero new
rows. The event watermark is advanced only after the batch's facts are
published, so a failed run never advances progress — replaying a failed batch
is a true no-op. Bootstrap seeds both watermarks from the actual loaded data's
max `event_time`, never wall-clock.

## Watermarking rules of thumb (for the demo answer)

1. **Never advance on failure.** Watermark = "committed", so it advances only
   after successful publication.
2. **Late window is a contract, not a bug.** It bounds how late events are
   caught; beyond it, correctness needs a repair path.
3. **Finality trails the watermark.** Curves near "now" are provisional by
   design; they settle after `lateness + liveness`.
4. **History replay needs seeded watermarks.** An empty watermark means "no
   progress", not "start from now".

The one-liner for judges: *"the watermark is the pipeline's commit point —
it tells us what event-time prefix is complete, so we process only what moved
and never call a session final before it can be."*
