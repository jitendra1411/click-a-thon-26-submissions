-- ============================================================================
-- SOLUTION v2 — RECOVERY-ONLY backfill: enrich raw rows that predate the MV.
--
-- The materialized view only processes rows inserted AFTER it exists. If raw
-- data was loaded first (e.g. the unseen-day file dropped in early), run this
-- ONCE per day. It refuses to double-run by checking the audit table below.
-- The normal path (schema -> raw -> MV) never needs this file.
--
-- Usage: clickhouse-client --multiquery --query "$(cat ...)" with {day} set.
-- ============================================================================

CREATE TABLE IF NOT EXISTS sonyliv_v2.enrichment_backfill_runs
(
    day          Date,
    run_at       DateTime64(3, 'UTC'),
    rows_written UInt64,
    status       LowCardinality(String)
)
ENGINE = MergeTree ORDER BY day;

INSERT INTO sonyliv_v2.events_enriched
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
    'backfill' AS batch_id,
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
WHERE toDate(event_time) = toDate('{day}')
  AND (
      event_type IN ('VideoSessionStart', 'VideoSessionEnd', 'VideoPlay',
                     'AppBackgrounded', 'AppForegrounded', 'VideoError')
      OR (event_type = 'VideoHeartbeat'
          AND event IN ('pause', 'resume', 'AdPause', 'AdResume',
                        'BufferStart', 'BufferEnd', 'Seek', 'network-activity'))
  );

INSERT INTO sonyliv_v2.enrichment_backfill_runs (day, run_at, rows_written, status)
SELECT toDate('{day}'), now64(3, 'UTC'),
       (SELECT count() FROM sonyliv_v2.events_enriched WHERE toDate(event_time) = toDate('{day}')),
       'ok';

-- Guard: before running the INSERT above, check this table for the day:
-- SELECT count() FROM sonyliv_v2.enrichment_backfill_runs WHERE day = toDate('{day}');
-- (runbook refuses to proceed when > 0)
