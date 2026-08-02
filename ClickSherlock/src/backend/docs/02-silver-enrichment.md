# v2 Step 2 — Silver: enrichment as a materialized view

**Goal:** from raw rows, keep only what carries signal, attach metadata, and
classify each event as +1 / −1 / 0.

## Why v2 can use an MV (and v1 could not)

A materialized view transforms rows **as they are inserted**, per block, with
no visibility into other blocks. That makes it perfect for stateless
transforms and useless for stateful sessionization.

v1 disabled the enrichment MV because the batch refresh *also* wrote
`events_enriched`, causing double-writes. v2 has a **single writer per
table**, so the MV is safe again:

```sql
CREATE MATERIALIZED VIEW sonyliv_v2.mv_events_enriched
TO sonyliv_v2.events_enriched
AS
SELECT
    content_id,
    dictGet('sonyliv_v2.content_dict', 'title', content_id)      AS title,
    dictGet('sonyliv_v2.content_dict', 'video_type', content_id) AS video_type,
    dictGet('sonyliv_v2.content_dict', 'category', content_id)   AS category,
    video_session_id, user_id, event_type, event, event_time,
    multiIf(
        event_type IN ('VideoSessionStart', 'VideoPlay', 'AppForegrounded'),  1,
        event_type IN ('AppBackgrounded', 'VideoSessionEnd', 'VideoError'),  -1,
        event_type = 'VideoHeartbeat' AND event IN ('resume', 'AdResume'),    1,
        event_type = 'VideoHeartbeat' AND event IN ('pause', 'AdPause'),     -1,
        0
    ) AS activity_delta,
    platform, app_version, country, audio_language,
    subtitle_language, player_version, session_start_time
FROM sonyliv_v2.raw_events
WHERE event_type IN ('VideoSessionStart','VideoSessionEnd','VideoPlay',
                     'AppBackgrounded','AppForegrounded','VideoError')
   OR (event_type = 'VideoHeartbeat'
       AND event IN ('pause','resume','AdPause','AdResume',
                     'BufferStart','BufferEnd','Seek','network-activity'));
```

## What it does

1. **Filters to signal** — drops the 93%-heartbeat noise that carries no
   state/liveness meaning (~49% volume cut).
2. **Enriches with `dictGet`** — the content catalog lives in an in-memory
   HASHED dictionary; lookups are O(1) per row, no joins.
3. **Classifies independent state transitions** (review P0.1) — instead of a
   single +1/−1/0 latch, each event declares what it changes:
   `session_transition` (open/ended), `visibility_transition`
   (foreground/background), `playback_transition` (playing/paused/blocked),
   `buffer_transition` (buffering/normal), plus `is_liveness` and a
   deterministic `event_priority` for same-timestamp ordering.

## Why each event is classified as it is (the reasoning)

The classification answers, per dimension: **"does this event change the
state?"** A NULL transition means "no change"; the state machine fills the
last non-NULL value per session (an `anyLast` window skips NULLs).

**Session transition:**

| Event | Why |
|---|---|
| `VideoSessionStart` → `open` | A new playback session begins. |
| `VideoSessionEnd` → `ended` | The session is over (terminal for that session). |

**Visibility transition:**

| Event | Why |
|---|---|
| `AppForegrounded` → `foreground` | App visible again — **visibility only**, never resumes playback. |
| `AppBackgrounded` → `background` | App hidden — by definition not foreground-watching, even if playback continues. |

**Playback transition:**

| Event | Why |
|---|---|
| `VideoSessionStart`, `VideoPlay` → `playing` | Playback started/resumed (idempotent — already playing is a no-op). |
| `VideoHeartbeat/pause`, `AdPause` → `paused` | Playback explicitly paused. |
| `VideoHeartbeat/resume`, `AdResume` → `playing` | Playback explicitly resumed. |
| `VideoError` → `blocked` | Playback died — the viewer is not watching; a later `VideoPlay` unblocks. |

**Buffer transition + liveness:**

| Event | Why |
|---|---|
| `BufferStart` → `buffering` | Playback stalled — the viewer is still there (buffering counts as watching in the primary metric). |
| `BufferEnd` → `normal` | Back to playing. |
| retained heartbeats (`pause`, `resume`, `AdPause`, `AdResume`, `BufferStart`, `BufferEnd`, `Seek`, `network-activity`) → `is_liveness = 1` | They prove the player is alive; they extend the 90 s liveness window without toggling state. |

**The key design principles:** (1) dimensions are **independent** —
`AppForegrounded` must never resurrect a paused session, and a heartbeat must
never resurrect a backgrounded one. (2) **state vs liveness** — transitions
change state; liveness extends it. The active definition is the conjunction
`session open AND foreground AND playing` (see `03-state-machine.md`).

## The one-time backfill gotcha

An MV only processes rows inserted **after** it exists. Rows already sitting
in `raw_events` (e.g. the unseen day dropped in early) need a one-time
day-scoped backfill (in `02_bootstrap.sql`, guarded so it runs only when raw
predates the MV). Fresh setups: schema → insert raw → MV fires automatically
→ bootstrap (skip the backfill).

## Output check (07-26)

```sql
SELECT activity_delta, count() FROM sonyliv_v2.events_enriched
WHERE toDate(event_time) = '2026-07-26' GROUP BY activity_delta;
--   −1 → 51,088
--    0 → 316,794
--   +1 →  65,543
--  total 433,425 (exact match to v1)
```
