-- ============================================================================
-- ClickSherlock — benchmark queries (run against sonyliv_v2, unseen day
-- 2026-07-31). These are the exact queries that produced the numbers in
-- evidence/unseen_results/BENCHMARK_RESULTS.md. Query IDs from
-- system.query_log are listed alongside; export the matching rows for
-- full pipeline evidence.
-- ============================================================================

-- B1 · Concurrency curve (exact, Track B) — the mandatory curve query.
-- Peak / average / per-minute curve at minute grain, IST-labelled.
-- Fresh run: peak 16,877 @ 2026-07-31 16:46 IST (16,080 users),
-- 698 points, 718 ms, 866,425 rows read — query_id 611efe3f-4c68-42de-a117-6a569a3396c1
SELECT toTimeZone(toStartOfMinute(minute_bucket), 'Asia/Kolkata') AS bucket,
       uniqExactMerge(sessions_state) AS concurrency,
       uniqExactMerge(users_state)    AS unique_users
FROM sonyliv_v2.minute_sessions
WHERE toDate(minute_bucket) = toDate('2026-07-31')
  [AND platform = {platform:String}]      -- optional: platform filter
  [AND country  = {country:String}]       -- optional: country filter
  [AND video_type = {video_type:String}]  -- optional: video_type filter
  [AND content_id = {content_id:Int64}]   -- optional: content filter
GROUP BY bucket
ORDER BY bucket;

-- B2 · Long-range hourly path (finalized snapshots) — 35x faster.
-- Fresh run: peak 16,877 @ 2026-07-31 16:00 IST, ~28 ms.
SELECT toTimeZone(hour_bucket, 'Asia/Kolkata') AS hour,
       peak_concurrency, average_concurrency, end_concurrency
FROM sonyliv_v2.hourly_kpis
WHERE dimension_set_id = 1
  AND toDate(toTimeZone(hour_bucket, 'Asia/Kolkata')) = toDate('2026-07-31')
ORDER BY hour_bucket;

-- B3 · Peak by platform (each platform's own peak minute)
SELECT platform, max(c) AS peak
FROM (SELECT platform, minute_bucket, uniqExactMerge(sessions_state) AS c
      FROM sonyliv_v2.minute_sessions
      WHERE toDate(minute_bucket) = toDate('2026-07-31')
      GROUP BY platform, minute_bucket)
GROUP BY platform ORDER BY peak DESC;
-- ANDROID_PHONE 5,489 · JIO_ANDROID_TV 4,473 · SONY_ANDROID_TV 2,498 · ...

-- B4 · Pipeline evidence — the queries above, with their query IDs
SELECT query_id, query_duration_ms, read_rows, read_bytes, memory_usage
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_start_time >= now() - INTERVAL 30 MINUTE
  AND query ILIKE '%uniqExactMerge%'
ORDER BY query_start_time DESC;
