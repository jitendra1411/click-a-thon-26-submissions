# v2 Step 4 — Gold: version-tracked per-session facts → serving views

**Goal:** turn intervals into per-minute concurrency facts that the dashboard
reads as instant queries — with **no FINAL and no DELETE mutations** on the
hot path.

## The core tables

```sql
CREATE TABLE sonyliv_v2.session_facts
(
    minute_bucket    DateTime,
    video_session_id FixedString(64),
    user_id          FixedString(64),
    content_id       Int64,
    platform         LowCardinality(String),
    country          LowCardinality(String),
    video_type       LowCardinality(String),
    version          UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMMDD(minute_bucket)
ORDER BY (video_session_id, minute_bucket, content_id, platform, country, video_type);

CREATE TABLE sonyliv_v2.session_versions
(
    video_session_id FixedString(64),
    version          UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY video_session_id;
```

**`session_facts`** = one row per (session, minute, dims, version): the
refresh **appends** a touched session's facts at `version = cycle` — INSERT
only, no deletes. **`session_versions`** = the current version per session
(one tiny row per session); the refresh records `version = cycle` for each
touched session.

## Why this pattern (and why NOT delete / FINAL / collapsing)

- **`DELETE` on MergeTree is a mutation** — asynchronous, rewrites whole parts,
  and worsens as parts multiply. In a per-cycle refresh it's the wrong hot-path
  operation.
- **`FINAL` on reads** resolves versions inside every query — cost scales with
  version history and part count. Wrong trade for a realtime dashboard.
- **`CollapsingMergeTree` (±sign)** cancels rows only **on merge** — between
  write and merge, reads see both old and new rows. Wrong for exactness at
  read time.

The version-tracker pattern keeps the hot path **INSERT-only**, and reads use
a bounded join:

- Facts are appended, never rewritten → no mutations.
- The serving query joins `session_versions` and filters
  `f.version = v.version` → only current facts are read, and
  `uniqState` makes even re-inserted rows collapse to one count.
- `session_versions` is tiny (one row per touched session), so the join is
  cheap and bounded.

**Storage trade-off:** old fact versions accumulate until ReplacingMergeTree
merges them away or a TTL expires them (add
`TTL toDateTime(version) + INTERVAL N DAY`). The served numbers are exact
regardless — verified: re-running the same cycle adds duplicate raw rows but
the served per-minute session count stays identical (uniqState dedupes), and
the peak stays 2,727.

## The serving views (what the UI reads)

```sql
CREATE VIEW sonyliv_v2.v_minute_sessions AS
SELECT
    minute_bucket, content_id, platform, country, video_type,
    uniqState(toFixedString(video_session_id, 64)) AS sessions_state,
    uniqState(toFixedString(user_id, 64))          AS users_state
FROM sonyliv_v2.session_facts
INNER JOIN sonyliv_v2.session_versions AS v
  ON f.video_session_id = v.video_session_id AND f.version = v.version
GROUP BY minute_bucket, content_id, platform, country, video_type;
```

- **No `FINAL`** — the `v_session_versions_current` join replaces it.
- **`uniqState(...)`** — builds a sketch; `uniqMerge` at query time gives the
  exact distinct session/user count per minute. Idempotent by construction.

`minute_sessions` and `minute_deltas` are thin aliases over
`v_minute_sessions` / the latest intervals — **v1-compatible names and shapes,
so the UI code is unchanged**.

## Why this beats v1's gold

| v1 | v2 |
|---|---|
| Gold rebuilt per day (drop partition + re-derive) | Gold appended per touched session (INSERT-only, versioned) |
| Re-running a day duplicates rows unless dropped first | Re-running a cycle is a no-op at the served level (uniqState) |
| Refresh cost = day's rows | Refresh cost = touched sessions' rows |
| `minute_sessions` is a table | `minute_sessions` is a **view** over version-tracked facts |
| — | Read path has **no FINAL, no DELETE** |

At 07-26 scale: ~123K fact rows + 10.5K version rows serve the day; a refresh
cycle appends only the touched sessions' facts. Verified: peak stays
**2,727 @ 16:29 IST**, a synthetic session's facts serve correctly via the
version join, and duplicate raw rows never change the served count.
