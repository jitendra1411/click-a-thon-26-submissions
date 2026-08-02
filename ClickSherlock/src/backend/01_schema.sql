-- ============================================================================
-- SOLUTION v2 — ClickHouse-native pipeline (no Python orchestrator)
-- 01_schema.sql : databases, tables, materialized view, serving layer
--
-- Design changes vs v1 (solutions/ + setup/scripts/ingest.py):
--   1. Enrichment is a MATERIALIZED VIEW again (stateless transform: filter +
--      classify + dictGet) — safe here because v2 has a single writer per
--      table (no dual-write, no drop+rebuild competing with the MV).
--   2. Sessionization is a WATERMARK-DRIVEN SQL refresh (backend/03_refresh.sql)
--      that re-derives ONLY touched sessions (events since last watermark),
--      never a whole day. The state machine itself is unchanged from the
--      validated v1 logic (90s gap, 5s flap merge, 6h cap).
--   3. Gold tables carry video_session_id as a key column so a refresh can
--      delete+re-insert ONLY the touched sessions' contributions instead of
--      dropping day partitions.
--   4. Everything is plain SQL run by clickhouse-client (see 05_refresh.sh);
--      the only "orchestration" is parameter substitution + looping.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS sonyliv_v2;

-- ---------------------------------------------------------------------------
-- Bronze: raw events (same shape as v1)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.raw_events
(
    content_id            Int64,
    -- IDs are String, NOT FixedString(64): the unseen day may carry
    -- variable-length session/user ids — the data is the source of truth.
    video_session_id      String,
    user_id               String,
    event_type            LowCardinality(String),
    event                 LowCardinality(String),
    event_time            DateTime64(3) CODEC(Delta, ZSTD),
    platform              LowCardinality(String),
    app_version           LowCardinality(String),
    country               LowCardinality(String),
    audio_language        LowCardinality(String),
    subtitle_language     LowCardinality(String),
    player_version        LowCardinality(String),
    session_start_time    DateTime64(3),
    video_resolution      LowCardinality(Nullable(String))   -- unseen-day (NEW)
)
ENGINE = ReplacingMergeTree(event_time)
PARTITION BY toYYYYMMDD(event_time)
PRIMARY KEY (content_id, event_time)
ORDER BY (content_id, event_time, video_session_id, event_type, event, user_id)
SETTINGS index_granularity = 8192;

-- ---------------------------------------------------------------------------
-- Bronze: content catalog + in-memory dictionary (same as v1)
-- Loaded once at setup (small, read-mostly): the content CSV is copied into
-- ClickHouse user_files and ingested with:
--   INSERT INTO sonyliv_v2.content_metadata
--   SELECT content_id, title, video_type, category
--   FROM file('sonyliv/ch-hackathon-content-data.csv', CSVWithNames);
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.content_metadata
(
    content_id   Int64,
    title        String,
    video_type   LowCardinality(String),
    category     LowCardinality(String),
    show_name    LowCardinality(Nullable(String))            -- unseen-day (NEW)
)
ENGINE = ReplacingMergeTree
ORDER BY content_id;

CREATE DICTIONARY IF NOT EXISTS sonyliv_v2.content_dict
(
    content_id  Int64,
    title       String,
    video_type  String,
    category    String,
    show_name   Nullable(String)
)
PRIMARY KEY content_id
SOURCE(CLICKHOUSE(TABLE 'content_metadata' DB 'sonyliv_v2'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- ---------------------------------------------------------------------------
-- Silver: enriched events (MV-fed — the stateless transform lives in SQL)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.events_enriched
(
    content_id         Int64,
    title              String,
    video_type         LowCardinality(String),
    category           LowCardinality(String),
    video_session_id   String,
    user_id            String,
    event_type         LowCardinality(String),
    event              LowCardinality(String),
    event_time         DateTime64(3, 'UTC') CODEC(Delta, ZSTD),
    -- Independent state transitions (P0.1): each dimension changes on its own.
    -- NULL = this event does not change that state; the state machine fills
    -- the last non-NULL value per session (anyLast window skips NULLs).
    session_transition    LowCardinality(Nullable(String)),  -- 'open' | 'ended'
    visibility_transition LowCardinality(Nullable(String)),  -- 'foreground' | 'background'
    playback_transition   LowCardinality(Nullable(String)),  -- 'playing' | 'paused' | 'blocked'
    buffer_transition     LowCardinality(Nullable(String)),  -- 'buffering' | 'normal'
    video_resolution      LowCardinality(Nullable(String)),  -- passthrough (NEW)
    show_name             LowCardinality(Nullable(String)),  -- dict-enriched (NEW)
    is_liveness           UInt8,                             -- 1 = extends liveness window
    event_priority        UInt8,                             -- deterministic same-timestamp order
    event_key             String,                            -- stable dedup key (hex(sipHash128))
    batch_id              String,                            -- ingestion lineage
    ingested_at           DateTime64(3, 'UTC'),
    platform           LowCardinality(String),
    app_version        LowCardinality(String),
    country            LowCardinality(String),
    audio_language     LowCardinality(String),
    subtitle_language  LowCardinality(String),
    player_version     LowCardinality(String),
    session_start_time DateTime64(3)
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(event_time)
ORDER BY (video_session_id, event_time, event_priority, event_key);

-- Same-timestamp ordering is encoded as event_priority in the MV below:
-- session start (10) < foreground (20) < play (30) < heartbeat (40) <
-- pause/resume (50) < background (60) < error (70) < end (80).

CREATE MATERIALIZED VIEW IF NOT EXISTS sonyliv_v2.mv_events_enriched
TO sonyliv_v2.events_enriched
AS
SELECT
    content_id,
    dictGet('sonyliv_v2.content_dict', 'title', content_id)      AS title,
    dictGet('sonyliv_v2.content_dict', 'video_type', content_id) AS video_type,
    dictGet('sonyliv_v2.content_dict', 'category', content_id)   AS category,
    dictGet('sonyliv_v2.content_dict', 'show_name', content_id)  AS show_name,
    video_session_id,
    user_id,
    event_type,
    event,
    event_time,
    multiIf(
        event_type = 'VideoSessionStart', 'open',
        event_type = 'VideoSessionEnd',   'ended',
        NULL
    ) AS session_transition,
    multiIf(
        event_type = 'AppForegrounded', 'foreground',
        event_type = 'AppBackgrounded', 'background',
        NULL
    ) AS visibility_transition,
    multiIf(
        event_type = 'VideoSessionStart', 'playing',
        event_type = 'VideoPlay',         'playing',
        event_type = 'VideoError',        'blocked',
        event_type = 'VideoHeartbeat' AND event IN ('pause', 'AdPause'),   'paused',
        event_type = 'VideoHeartbeat' AND event IN ('resume', 'AdResume'), 'playing',
        NULL
    ) AS playback_transition,
    multiIf(
        event_type = 'VideoHeartbeat' AND event IN ('BufferStart'), 'buffering',
        event_type = 'VideoHeartbeat' AND event IN ('BufferEnd'),   'normal',
        NULL
    ) AS buffer_transition,
    toUInt8(
        event_type = 'VideoHeartbeat'
        AND event IN ('pause', 'resume', 'AdPause', 'AdResume', 'BufferStart', 'BufferEnd', 'Seek', 'network-activity')
    ) AS is_liveness,
    multiIf(
        event_type = 'VideoSessionStart', 10,
        event_type = 'AppForegrounded',   20,
        event_type = 'VideoPlay',         30,
        event_type = 'VideoHeartbeat',    40,
        event_type = 'AppBackgrounded',   60,
        event_type = 'VideoError',        70,
        event_type = 'VideoSessionEnd',   80,
        50
    ) AS event_priority,
    hex(sipHash128(content_id, video_session_id, event_type, event, event_time)) AS event_key,
    toString(toStartOfMinute(event_time)) AS batch_id,
    now64(3, 'UTC') AS ingested_at,
    platform,
    app_version,
    country,
    audio_language,
    subtitle_language,
    player_version,
    session_start_time,
    video_resolution
FROM sonyliv_v2.raw_events
WHERE
    event_type IN ('VideoSessionStart', 'VideoSessionEnd', 'VideoPlay', 'AppBackgrounded', 'AppForegrounded', 'VideoError')
    OR (
        (event_type = 'VideoHeartbeat')
        AND (event IN ('pause', 'resume', 'AdPause', 'AdResume', 'BufferStart', 'BufferEnd', 'Seek', 'network-activity'))
    );

-- ---------------------------------------------------------------------------
-- Silver/Gold: session active intervals — ReplacingMergeTree(version).
-- The refresh appends a touched session's intervals at version = cycle;
-- session_versions tracks the current version, so reads filter by it
-- (no FINAL, no DELETE).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.session_active_intervals
(
    event_dt         Date,
    video_session_id String,
    user_id          String,
    content_id       Int64,
    platform         LowCardinality(String),
    country          LowCardinality(String),
    video_type       LowCardinality(String),
    interval_start   DateTime64(3),
    interval_end     DateTime64(3),
    is_open          UInt8,
    was_capped       UInt8 DEFAULT 0,
    version          UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY event_dt
ORDER BY (video_session_id, interval_start);

-- ---------------------------------------------------------------------------
-- Gold: per-session minute facts — ReplacingMergeTree(version).
-- The refresh appends a touched session's facts at version = cycle.
-- `session_versions` (below) tracks the current version per session, so the
-- serving query filters facts by that version — reads never need FINAL and
-- the hot path is INSERT-only (no DELETE mutations).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.session_facts
(
    minute_bucket    DateTime,
    video_session_id String,
    user_id          String,
    content_id       Int64,
    platform         LowCardinality(String),
    country          LowCardinality(String),
    video_type       LowCardinality(String),
    version          UInt64
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMMDD(minute_bucket)
ORDER BY (video_session_id, minute_bucket, content_id, platform, country, video_type);
-- Note: version deliberately NOT in ORDER BY — re-inserting the same
-- (session, minute, dims) facts at the same cycle must replace, not duplicate.

-- Current version per session (one row per session; tiny). The refresh
-- INSERTs the new cycle version; ReplacingMergeTree keeps the latest.
CREATE TABLE IF NOT EXISTS sonyliv_v2.session_versions
(
    video_session_id String,
    version          UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY video_session_id;

-- Canonical current version per session (P0.2): max(version) is deterministic
-- BEFORE any background merge, because cycle ids are monotonic. All serving
-- joins use THIS view, never the raw ReplacingMergeTree table.
CREATE VIEW IF NOT EXISTS sonyliv_v2.v_session_versions_current AS
SELECT video_session_id, max(version) AS version
FROM sonyliv_v2.session_versions
GROUP BY video_session_id;

-- ---------------------------------------------------------------------------
-- Ops: watermark + run log (ClickHouse-native state; no Python memory)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.pipeline_watermark
(
    id         UInt8,
    watermark  DateTime64(3),
    updated_at DateTime64(3)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY id;

-- Sessions touched by events since the last watermark (rebuilt each cycle).
CREATE TABLE IF NOT EXISTS sonyliv_v2.touched_sessions
(
    video_session_id String
)
ENGINE = MergeTree
ORDER BY video_session_id;

CREATE TABLE IF NOT EXISTS sonyliv_v2.pipeline_runs
(
    run_id            UInt64,
    started_at        DateTime64(3),
    finished_at       DateTime64(3),
    events_processed  UInt64,
    sessions_touched  UInt64,
    facts_written     UInt64,
    status            LowCardinality(String),
    note              String DEFAULT ''
)
ENGINE = MergeTree ORDER BY run_id;

-- ---------------------------------------------------------------------------
-- Serving views (what the UI queries — same column shapes as v1)
-- NO FINAL anywhere: each view joins session_versions and filters by the
-- session's current version. Reads are bounded by the current facts.
-- ---------------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS sonyliv_v2.v_latest_intervals AS
SELECT
    i.event_dt, i.video_session_id, i.user_id, i.content_id, i.platform,
    i.country, i.video_type, i.interval_start, i.interval_end, i.is_open,
    i.was_capped
FROM sonyliv_v2.session_active_intervals AS i
INNER JOIN sonyliv_v2.v_session_versions_current AS v
  ON i.video_session_id = v.video_session_id AND i.version = v.version;

-- Per-session minute facts, aggregated into v1-shaped sketch rows.
CREATE VIEW IF NOT EXISTS sonyliv_v2.v_minute_sessions AS
SELECT
    f.minute_bucket,
    f.content_id,
    f.platform,
    f.country,
    f.video_type,
    uniqState(f.video_session_id) AS sessions_state,
    uniqState(f.user_id)          AS users_state
FROM sonyliv_v2.session_facts AS f
INNER JOIN sonyliv_v2.v_session_versions_current AS v
  ON f.video_session_id = v.video_session_id AND f.version = v.version
GROUP BY minute_bucket, content_id, platform, country, video_type;

-- EXACT cardinality (P0.3): benchmark-facing view. uniqExactState/uniqExactMerge
-- are exact (memory-backed sets); the approximate uniqState view above remains
-- for exploratory dashboards. Names make the guarantee obvious.
CREATE VIEW IF NOT EXISTS sonyliv_v2.v_minute_sessions_exact AS
SELECT
    f.minute_bucket,
    f.content_id,
    f.platform,
    f.country,
    f.video_type,
    uniqExactState(f.video_session_id) AS sessions_state,
    uniqExactState(f.user_id)          AS users_state
FROM sonyliv_v2.session_facts AS f
INNER JOIN sonyliv_v2.v_session_versions_current AS v
  ON f.video_session_id = v.video_session_id AND f.version = v.version
GROUP BY minute_bucket, content_id, platform, country, video_type;

-- Open sessions deltas (live provisional tails), v1-shaped.
CREATE VIEW IF NOT EXISTS sonyliv_v2.v_open_sessions_deltas AS
SELECT
    toStartOfMinute(interval_start) AS minute_bucket,
    content_id, platform, country, video_type,
    CAST(1 AS Int32) AS delta
FROM sonyliv_v2.v_latest_intervals
WHERE is_open = 1
UNION ALL
SELECT
    toStartOfMinute(interval_end)
        + toIntervalMinute(if(interval_end > toStartOfMinute(interval_end), 1, 0))
        AS minute_bucket,
    content_id, platform, country, video_type,
    CAST(-1 AS Int32) AS delta
FROM sonyliv_v2.v_latest_intervals
WHERE is_open = 1;

-- v1-compatible names for the UI. minute_sessions / minute_deltas are VIEWS
-- (not tables) over the canonical facts / latest intervals — the same shapes
-- as v1's gold tables.
-- EXACT by default (P0.3): benchmark-facing KPIs use uniqExactState. The
-- approximate variant is explicitly named.
CREATE VIEW IF NOT EXISTS sonyliv_v2.minute_sessions AS
SELECT * FROM sonyliv_v2.v_minute_sessions_exact;

CREATE VIEW IF NOT EXISTS sonyliv_v2.minute_sessions_approx AS
SELECT * FROM sonyliv_v2.v_minute_sessions;

CREATE VIEW IF NOT EXISTS sonyliv_v2.minute_deltas AS
SELECT
    toStartOfMinute(interval_start) AS minute_bucket,
    content_id, platform, country, video_type,
    CAST(1 AS Int32) AS delta
FROM sonyliv_v2.v_latest_intervals
WHERE is_open = 0
UNION ALL
SELECT
    toStartOfMinute(interval_end)
        + toIntervalMinute(if(interval_end > toStartOfMinute(interval_end), 1, 0))
        AS minute_bucket,
    content_id, platform, country, video_type,
    CAST(-1 AS Int32) AS delta
FROM sonyliv_v2.v_latest_intervals
WHERE is_open = 0
  AND interval_end > interval_start;

CREATE VIEW IF NOT EXISTS sonyliv_v2.open_sessions_deltas AS
SELECT * FROM sonyliv_v2.v_open_sessions_deltas;

-- ---------------------------------------------------------------------------
-- Long-range serving: FINALIZED hourly KPI snapshots (review decision).
-- An hour is built only after the lateness watermark passes its end; the
-- snapshot stores peak / time-weighted average / end concurrency — values a
-- net-delta rollup can never recover. See 04_hourly_snapshots.sql.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sonyliv_v2.dimension_sets
(
    dimension_set_id UInt8,
    name             String,
    dims             Array(String)
)
ENGINE = MergeTree ORDER BY dimension_set_id;

INSERT INTO sonyliv_v2.dimension_sets VALUES
    (1, 'global',            []),
    (2, 'country',           ['country']),
    (3, 'platform',          ['platform']),
    (4, 'video_type',        ['video_type']),
    (5, 'content',           ['content_id']),
    (6, 'country_platform',  ['country','platform']),
    (7, 'platform_video_type', ['platform','video_type']),
    (8, 'content_platform',  ['content_id','platform']);

CREATE TABLE IF NOT EXISTS sonyliv_v2.metric_definitions
(
    metric_definition String,
    definition_version UInt8
)
ENGINE = MergeTree ORDER BY metric_definition;

INSERT INTO sonyliv_v2.metric_definitions VALUES
    ('foreground_active', 1);

CREATE TABLE IF NOT EXISTS sonyliv_v2.hourly_kpis
(
    hour_bucket         DateTime,
    dimension_set_id    UInt8,
    country             LowCardinality(Nullable(String)),
    platform            LowCardinality(Nullable(String)),
    video_type          LowCardinality(Nullable(String)),
    content_id          Nullable(Int64),
    entity_type         LowCardinality(String),   -- 'session' | 'user'
    metric_definition   String,
    definition_version  UInt8,
    peak_concurrency    UInt64,
    peak_users          UInt64,
    average_concurrency Float64,
    average_users       Float64,
    end_concurrency     UInt64,
    is_final            UInt8,
    data_as_of          DateTime64(3, 'UTC'),
    source_run_id       UInt64
)
ENGINE = ReplacingMergeTree(data_as_of)
PARTITION BY toYYYYMMDD(hour_bucket)
ORDER BY (hour_bucket, dimension_set_id, country, platform, video_type, content_id,
          entity_type, metric_definition, definition_version)
SETTINGS allow_nullable_key = 1;

-- Audit trail of which hours were built, by which run.
CREATE TABLE IF NOT EXISTS sonyliv_v2.hourly_build_runs
(
    run_id        UInt64,
    hour_bucket   DateTime,
    dimension_set_id UInt8,
    rows_written  UInt64,
    built_at      DateTime64(3, 'UTC'),
    status        LowCardinality(String)
)
ENGINE = MergeTree ORDER BY (run_id, hour_bucket);
