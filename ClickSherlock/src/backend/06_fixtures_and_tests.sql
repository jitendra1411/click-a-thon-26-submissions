-- ============================================================================
-- SOLUTION v2 — acceptance fixtures & tests (run against sonyliv_v2)
--
-- Reproduces every P0 failure BEFORE the fix, then verifies the fixed
-- behavior. Run the test queries and confirm the expected results.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Fixture A (P0.1): pause -> AppForegrounded must NOT reactivate.
-- The single activity_delta latch (+1 on AppForegrounded) wrongly reactivates
-- a session whose playback is still paused.
-- ---------------------------------------------------------------------------
-- Events (session FXA1, content 9001):
--   00:00 VideoSessionStart        -> state ON
--   00:10 VideoHeartbeat/pause     -> state OFF  (playback paused)
--   00:20 AppForegrounded          -> activity_delta +1 => state ON  <-- BUG
--   00:30 VideoSessionEnd          -> state OFF
--
-- Expected after fix: the AppForegrounded must change VISIBILITY only;
-- the session stays INACTIVE between 00:10 and 00:30 (playback still paused),
-- so the active interval is [00:00, 00:10) only.

-- ---------------------------------------------------------------------------
-- Fixture B (P0.1): background -> heartbeat must NOT reactivate.
--   01:00 VideoSessionStart
--   01:10 VideoHeartbeat (network-activity)
--   01:20 AppBackgrounded          -> visibility background
--   01:30 VideoHeartbeat           -> activity_delta 0 in v1; must stay inactive
-- Expected: interval [01:00, 01:20) only.

-- ---------------------------------------------------------------------------
-- Fixture C (P0.2): version pre-merge correctness.
--   1) bootstrap day D at version 1 -> facts v1
--   2) insert a new version (cycle 2) for ONE session with a SHRUNK interval
--   3) WITHOUT OPTIMIZE, the serving view must show the shrunk facts only.
-- Expected: served minutes reflect version 2 immediately (max(version) join).

-- ---------------------------------------------------------------------------
-- Fixture D (P0.4): bootstrap double-write.
--   1) create schema (MV exists), 2) insert raw, 3) run 02_bootstrap.sql
-- Expected AFTER fix: events_enriched count == raw rows passing the filter
-- (single write). BEFORE fix it is 2x (MV fired + bootstrap backfill).

-- ============================================================================
-- TEST QUERIES (run after the fix)
-- ============================================================================

-- T1 (P0.1-A): intervals for FXA1 must be exactly [00:00, 00:10) and nothing
-- after the pause.
-- SELECT video_session_id, interval_start, interval_end
-- FROM sonyliv_v2.session_active_intervals
-- WHERE video_session_id = toFixedString('FXA1' || repeat('0', 60), 64)
-- ORDER BY interval_start;

-- T2 (P0.1-B): intervals for FXB1 must end at the AppBackgrounded, and the
-- 01:30 heartbeat must not reopen an interval.

-- T3 (P0.2): insert cycle-2 facts for one session, then WITHOUT OPTIMIZE:
-- SELECT uniqMerge(sessions_state) FROM sonyliv_v2.minute_sessions
--   WHERE ... -- must reflect version 2 immediately.

-- T4 (P0.4): count() of events_enriched for the fixture day must equal the
-- single-write expectation (no 2x).
