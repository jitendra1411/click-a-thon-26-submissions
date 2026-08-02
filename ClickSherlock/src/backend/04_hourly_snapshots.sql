-- ============================================================================
-- SOLUTION v2 — FINALIZED hourly KPI snapshots (long-range serving)
--
-- Replaces the removed concurrency_deltas_hour with what the review demands:
-- peak / time-weighted average / end concurrency per APPROVED dimension set,
-- built only after the lateness watermark passes the hour. An hourly net
-- delta cannot recover the within-hour peak or average — this table can.
--
-- Finality rule: hour H is final when
--   event_watermark - late_window >= end_of(H)
-- (no late event can arrive that would change H's minutes).
-- Buckets are IST hours (stored as UTC wall-clock equal to the IST hour
-- start, matching the dashboard), e.g. hour_bucket 2026-07-26 15:30:00
-- = 15:30-16:29 IST.
-- Placeholders: {wm} (event watermark, UTC), {day}, {run_id}.
-- ============================================================================

INSERT INTO sonyliv_v2.hourly_kpis
SELECT hour_bucket, dimension_set_id, country, platform, video_type, content_id,
       'session' AS entity_type,
       'foreground_active' AS metric_definition, 1 AS definition_version,
       max(v) AS peak_concurrency,
       max(uv) AS peak_users,
       sum(v * minutes) / sum(minutes) AS average_concurrency,
       sum(uv * minutes) / sum(minutes) AS average_users,
       argMax(v, minute_bucket) AS end_concurrency,
       1 AS is_final,
       now64(3, 'UTC') AS data_as_of,
       {run_id} AS source_run_id
FROM (
    -- dimension set 1: global (no grouping)
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 1 AS dimension_set_id,
           NULL AS country, NULL AS platform, NULL AS video_type, NULL AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket

    UNION ALL
    -- dimension set 2: country
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 2 AS dimension_set_id,
           country AS country, NULL AS platform, NULL AS video_type, NULL AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, country

    UNION ALL
    -- dimension set 3: platform
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 3 AS dimension_set_id,
           NULL AS country, platform AS platform, NULL AS video_type, NULL AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, platform

    UNION ALL
    -- dimension set 4: video_type
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 4 AS dimension_set_id,
           NULL AS country, NULL AS platform, video_type AS video_type, NULL AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, video_type

    UNION ALL
    -- dimension set 5: content
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 5 AS dimension_set_id,
           NULL AS country, NULL AS platform, NULL AS video_type, content_id AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, content_id

    UNION ALL
    -- dimension set 6: country x platform
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 6 AS dimension_set_id,
           country AS country, platform AS platform, NULL AS video_type, NULL AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, country, platform

    UNION ALL
    -- dimension set 7: platform x video_type
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 7 AS dimension_set_id,
           NULL AS country, platform AS platform, video_type AS video_type, NULL AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, platform, video_type

    UNION ALL
    -- dimension set 8: content x platform
    SELECT toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') AS hour_bucket, 8 AS dimension_set_id,
           NULL AS country, platform AS platform, NULL AS video_type, content_id AS content_id,
           minute_bucket, uniqExactMerge(sessions_state) AS v, uniqExactMerge(users_state) AS uv, 1.0 AS minutes
    FROM sonyliv_v2.minute_sessions
    WHERE toDate(minute_bucket) = toDate('{day}')
      AND toDateTime64('{wm}', 3, 'UTC') - INTERVAL 10 MINUTE >= toTimeZone(toStartOfHour(toTimeZone(minute_bucket, 'Asia/Kolkata')), 'UTC') + INTERVAL 1 HOUR
    GROUP BY hour_bucket, minute_bucket, content_id, platform
) AS m
GROUP BY hour_bucket, dimension_set_id, country, platform, video_type, content_id;

-- Audit the build.
INSERT INTO sonyliv_v2.hourly_build_runs
SELECT {run_id}, hour_bucket, dimension_set_id, count(),
       now64(3, 'UTC'), 'ok'
FROM sonyliv_v2.hourly_kpis
WHERE source_run_id = {run_id}
GROUP BY hour_bucket, dimension_set_id;
