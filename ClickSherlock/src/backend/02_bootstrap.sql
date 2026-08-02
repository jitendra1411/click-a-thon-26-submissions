-- ============================================================================
-- SOLUTION v2 — bootstrap: load a day's history into the serving layer.
-- 02_bootstrap.sql : run once per day at initial load (or for the unseen
-- day) BEFORE the live refresh takes over. Everything is scoped to {day} and
-- is idempotent (re-running re-inserts identical rows).
--
-- Placeholders substituted by the wrapper:
--   {day}    e.g. 2026-07-26
--   {cycle}  bootstrap cycle id (0 for a fresh load)
-- ============================================================================

-- NOTE (P0.4): events_enriched is owned by mv_events_enriched. The normal
-- flow is: create schema -> load metadata -> insert raw -> MV enriches.
-- The bootstrap below must NOT enrich again (that double-writes). Rows that
-- predate the MV are handled by the explicit 02_backfill_enrichment.sql,
-- which refuses to run twice for the same scope.

-- Intervals for {day} (same state machine as the refresh, day-scoped).
INSERT INTO sonyliv_v2.session_active_intervals
WITH
    90 AS gap_sec,
    raw_states AS
    (
        SELECT
            video_session_id,
            event_time,
            argMin(content_id, event_time) OVER (PARTITION BY video_session_id) AS content_id,
            argMin(user_id, event_time)     OVER (PARTITION BY video_session_id) AS user_id,
            argMin(platform, event_time)    OVER (PARTITION BY video_session_id) AS platform,
            argMin(country, event_time)     OVER (PARTITION BY video_session_id) AS country,
            anyLast(session_transition) OVER (
                PARTITION BY video_session_id ORDER BY event_time
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cur_session,
            anyLast(visibility_transition) OVER (
                PARTITION BY video_session_id ORDER BY event_time
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS _cur_visibility,
            anyLast(playback_transition) OVER (
                PARTITION BY video_session_id ORDER BY event_time
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS _cur_playback,
            is_liveness,
            anyLast(if(is_liveness = 1, event_time, NULL)) OVER (
                PARTITION BY video_session_id ORDER BY event_time
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS last_liveness,
            leadInFrame(event_time) OVER (
                PARTITION BY video_session_id ORDER BY event_time
                ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            ) AS next_event_time,
            row_number() OVER (
                PARTITION BY video_session_id ORDER BY event_time DESC
            ) AS rn_from_end
        FROM (
            SELECT *
            FROM sonyliv_v2.events_enriched
            WHERE toDate(event_time) = toDate('{day}')
            ORDER BY video_session_id, event_time, event_priority, event_key
        )
    ),
    ordered AS
    (
        SELECT
            *,
            coalesce(_cur_visibility, 'foreground') AS cur_visibility,
            coalesce(_cur_playback, 'playing') AS cur_playback
        FROM raw_states
    ),
    segments AS
    (
        SELECT
            video_session_id,
            user_id,
            content_id,
            platform,
            country,
            event_time AS interval_start,
            if(
                rn_from_end = 1,
                if(last_liveness IS NULL,
                   event_time + INTERVAL gap_sec SECOND,
                   last_liveness + INTERVAL gap_sec SECOND),
                next_event_time
            ) AS interval_end,
            toUInt8(rn_from_end = 1) AS is_open
        FROM ordered
        WHERE
            cur_session = 'open'
            AND cur_visibility = 'foreground'
            AND cur_playback = 'playing'
    ),
    islands AS
    (
        SELECT
            *,
            max(interval_end) OVER (
                PARTITION BY video_session_id ORDER BY interval_start
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS prev_max_end
        FROM segments
    ),
    flagged AS
    (
        SELECT
            *,
            if(
                prev_max_end IS NULL
                OR interval_start > prev_max_end + INTERVAL 5 SECOND,
                1, 0
            ) AS new_island
        FROM islands
    ),
    grouped AS
    (
        SELECT
            *,
            sum(new_island) OVER (
                PARTITION BY video_session_id ORDER BY interval_start
            ) AS island_id
        FROM flagged
    )
SELECT
    toDate(island_start) AS event_dt,
    video_session_id,
    user_id,
    content_id,
    platform,
    country,
    dictGet('sonyliv_v2.content_dict', 'video_type', content_id) AS video_type,
    island_start AS interval_start,
    if(
        dateDiff('second', island_start, island_end) > 21600,
        island_start + INTERVAL 21600 SECOND,
        island_end
    ) AS interval_end,
    is_open,
    toUInt8(dateDiff('second', island_start, island_end) > 21600) AS was_capped,
    {cycle} AS version
FROM
(
    SELECT
        video_session_id,
        any(user_id)       AS user_id,
        any(content_id)    AS content_id,
        any(platform)      AS platform,
        any(country)       AS country,
        min(interval_start) AS island_start,
        max(interval_end)   AS island_end,
        any(is_open)        AS is_open
    FROM grouped
    GROUP BY video_session_id, island_id
    HAVING max(interval_end) > min(interval_start)
);

-- Minute facts for {day}.
INSERT INTO sonyliv_v2.session_facts
SELECT
    toStartOfMinute(interval_start) + toIntervalMinute(m) AS minute_bucket,
    video_session_id,
    user_id,
    content_id,
    platform,
    country,
        video_type,
        {cycle} AS version
FROM
(
    SELECT
        video_session_id,
        user_id,
        content_id,
        platform,
        country,
        video_type,
        interval_start,
        interval_end,
        arrayJoin(range(
            toUInt32(dateDiff('minute',
                toStartOfMinute(interval_start),
                toStartOfMinute(interval_end)
                    + toIntervalMinute(if(interval_end > toStartOfMinute(interval_end), 1, 0))
            ))
        )) AS m
    FROM sonyliv_v2.session_active_intervals
    WHERE toDate(interval_start) = toDate('{day}')
)
GROUP BY minute_bucket, video_session_id, user_id, content_id, platform, country, video_type;

-- Record the current version for every session bootstrapped this day.
INSERT INTO sonyliv_v2.session_versions
SELECT DISTINCT video_session_id, {cycle} AS version
FROM sonyliv_v2.session_active_intervals
WHERE toDate(interval_start) = toDate('{day}');

-- NOTE: concurrency_deltas_hour was removed (review decision). Hourly serving
-- must be a finalized KPI snapshot, not net deltas; the UI reads the exact
-- minute_sessions view and buckets on the fly.
