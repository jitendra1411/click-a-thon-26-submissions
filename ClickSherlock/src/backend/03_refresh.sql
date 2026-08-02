-- ============================================================================
-- SOLUTION v2 — live incremental refresh (the 100x path)
-- 03_refresh.sql : one cycle, run every 30-60s by 05_refresh.sh.
--
-- What makes this different from v1's drop-the-day rebuild:
--   * Reads only events SINCE the watermark (minus a 10-min late window).
--   * Re-derives intervals for ONLY the sessions touched by those events
--     (never the whole day, never the whole history).
--   * Appends the touched sessions' intervals and facts at version = {cycle},
--     and records that version in session_versions. The serving queries
--     filter facts by the recorded version — no FINAL, no DELETE mutations,
--     and the hot path is INSERT-only.
--
-- Placeholders substituted by 05_refresh.sh:
--   {wm}       watermark (UTC DateTime64) of the previous cycle
--   {cycle}    monotonically increasing cycle id (epoch millis)
-- ============================================================================

-- 1) Touched sessions: sessions with any event after watermark - 10 min.
--    Materialized as a real table because ClickHouse CTEs do not persist
--    across separate statements in a --multiquery run.
TRUNCATE TABLE sonyliv_v2.touched_sessions;

INSERT INTO sonyliv_v2.touched_sessions
SELECT DISTINCT video_session_id
FROM sonyliv_v2.events_enriched
WHERE event_time > toDateTime64('{wm}', 3) - INTERVAL 10 MINUTE;

INSERT INTO sonyliv_v2.pipeline_runs
    (run_id, started_at, finished_at, events_processed, sessions_touched, facts_written, status)
SELECT {cycle}, now64(3), now64(3), 0, 0, 0, 'started';

-- 2) Re-derive the touched sessions' intervals (the same validated state
--    machine as v1: 90s gap, 5s flap merge, 6h cap). Scoped to the sessions
--    above — bounded by "sessions that moved", not by the day's total.
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
            WHERE video_session_id IN (SELECT video_session_id FROM sonyliv_v2.touched_sessions)
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
                -- open session tail: last liveness + 90s
                if(last_liveness IS NULL,
                   event_time + INTERVAL gap_sec SECOND,
                   last_liveness + INTERVAL gap_sec SECOND),
                -- closed by the next event (a pause/background/end event is
                -- itself filtered out of the active rows, so its arrival time
                -- is exactly when the interval ends). The 90s liveness gap
                -- applies only to the final row of an open session.
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

-- 3) Append the touched sessions' minute facts at the new version.
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
    WHERE version = {cycle}
      AND video_session_id IN (SELECT video_session_id FROM sonyliv_v2.touched_sessions)
)
GROUP BY minute_bucket, video_session_id, user_id, content_id, platform, country, video_type;

-- 4) Record the current version per touched session.
INSERT INTO sonyliv_v2.session_versions
SELECT video_session_id, {cycle} AS version
FROM sonyliv_v2.touched_sessions;

-- 5) Advance the watermark to the max event time seen this cycle.
INSERT INTO sonyliv_v2.pipeline_watermark (id, watermark, updated_at)
SELECT
    0,
    max(event_time),
    now64(3)
FROM sonyliv_v2.events_enriched
WHERE event_time > toDateTime64('{wm}', 3) - INTERVAL 10 MINUTE;

-- 6) Close the run record.
INSERT INTO sonyliv_v2.pipeline_runs
    (run_id, started_at, finished_at, events_processed, sessions_touched, facts_written, status)
SELECT
    {cycle}, now64(3), now64(3),
    (SELECT count() FROM sonyliv_v2.events_enriched WHERE event_time > toDateTime64('{wm}', 3) - INTERVAL 10 MINUTE),
    (SELECT count() FROM (SELECT DISTINCT video_session_id FROM sonyliv_v2.events_enriched WHERE event_time > toDateTime64('{wm}', 3) - INTERVAL 10 MINUTE)),
    0,
    'ok';
