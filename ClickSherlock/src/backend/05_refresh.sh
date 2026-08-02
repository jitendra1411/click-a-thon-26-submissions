#!/usr/bin/env bash
# ============================================================================
# SOLUTION v2 — refresh loop (the only "orchestration" left)
#
# Runs one incremental cycle of 03_refresh.sql against the live ClickHouse.
# The state machine, enrichment, and gold rebuilds are all SQL inside
# ClickHouse; this script only substitutes two placeholders ({wm}, {cycle})
# and calls clickhouse-client. Run it from cron / a systemd timer:
#
#     */1 * * * *  /path/to/backend/05_refresh.sh >> /var/log/sonyliv-v2.log 2>&1
#
# Options:
#   --load-content FILE   load the content metadata CSV (e.g. unseen-day
#                         ch-hackathon-content-data_surprise.csv); handles
#                         the new show_name column
#   --load-raw FILE       load the raw events CSV via file() (unseen-day
#                         ch-hackathon-raw-data_surprise.csv); handles the
#                         new video_resolution column; the MV enriches
#   --bootstrap DAY   run 02_bootstrap.sql for DAY (initial load / unseen day)
#   --snapshots DAY   build finalized hourly KPI snapshots for DAY
#   --once            run a single refresh cycle and exit
#   --loop            run forever, every $INTERVAL seconds (default 30)
# ============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CH="${CLICKHOUSE_CLIENT:-docker exec sonyliv-ch clickhouse-client}"
CH_HOST="${CH_HOST:-localhost}"
INTERVAL="${REFRESH_INTERVAL:-30}"
DB="${SONYLIV_DB:-sonyliv_v2}"

cycle_id() {
  # Portable epoch-millis: %N is GNU-only (breaks on macOS).
  python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null \
    || perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

watermark() {
  # NULL on first run => full bootstrap first (see README).
  $CH --host "$CH_HOST" --query \
    "SELECT toString(max(watermark)) FROM $DB.pipeline_watermark FINAL" 2>/dev/null || true
}

run_refresh() {
  local wm cycle
  wm="$(watermark)"
  if [[ -z "$wm" || "$wm" == "\\N" ]]; then
    echo "[v2] no watermark yet — run --bootstrap first (or seed a watermark)."
    return 2
  fi
  cycle="$(cycle_id)"
  sed -e "s/{wm}/$wm/g" -e "s/{cycle}/$cycle/g" "$DIR/03_refresh.sql" \
    | $CH --host "$CH_HOST" --multiquery
  echo "[v2] cycle $cycle ok (watermark $wm)"
}

bootstrap() {
  local day="$1" cycle
  cycle="$(cycle_id)"
  sed -e "s/{day}/$day/g" -e "s/{cycle}/$cycle/g" "$DIR/02_bootstrap.sql" \
    | $CH --host "$CH_HOST" --multiquery
  # Seed the watermark from the ACTUAL loaded data (never wall-clock): the
  # review's P0.5 fix — an empty/historical load must not advance to "now".
  $CH --host "$CH_HOST" --query \
    "INSERT INTO $DB.pipeline_watermark (id, watermark, updated_at)
     SELECT 0, max(event_time), now64(3) FROM $DB.events_enriched
     WHERE toDate(event_time) = toDate('$day')"
  echo "[v2] bootstrap $day ok"
}

load_content() {
  local file="$1"
  # Copy into ClickHouse user_files so file() can read it, then load.
  # show_name is a NEW column in the unseen-day content file; the table
  # already has it (01_schema.sql), so this is a straight load.
  $CH --host "$CH_HOST" --query "
    INSERT INTO $DB.content_metadata (content_id, title, video_type, category, show_name)
    SELECT content_id, title, video_type, category, show_name
    FROM file('$file', 'CSVWithNames')
  "
  $CH --host "$CH_HOST" --query "SYSTEM RELOAD DICTIONARY $DB.content_dict"
  echo "[v2] content loaded: $file"
}

load_raw() {
  local file="$1" day="${2:-}"
  local day_filter=""
  if [[ -n "$day" ]]; then
    day_filter="WHERE toDate(fromUnixTimestamp64Milli(toInt64(event_timestamp))) = toDate('$day')"
  fi
  $CH --host "$CH_HOST" --query "
    INSERT INTO $DB.raw_events
      (content_id, video_session_id, user_id, event_type, event, event_time,
       platform, app_version, country, audio_language, subtitle_language,
       player_version, session_start_time, video_resolution)
    SELECT
      toInt64(content_id),
      video_session_id,
      user_id,
      event_type, event,
      fromUnixTimestamp64Milli(toInt64(event_timestamp)),
      platform, app_version, country, audio_language, subtitle_language,
      player_version,
      fromUnixTimestamp64Milli(toInt64(session_start_epoch)),
      video_resolution
    FROM file('$file', 'CSVWithNames')
    $day_filter
  "
  echo "[v2] raw loaded: $file${day:+ (day $day)} (MV enriches on insert)"
}

snapshots() {
  local day="$1" wm run
  wm="$(watermark)"
  run="$(cycle_id)"
  if [[ -z "$wm" || "$wm" == "\\N" ]]; then
    echo "[v2] no watermark — run --bootstrap DAY first."
    return 2
  fi
  sed -e "s/{wm}/$wm/g" -e "s/{day}/$day/g" -e "s/{run_id}/$run/g" \
    "$DIR/04_hourly_snapshots.sql" | $CH --host "$CH_HOST" --multiquery
  echo "[v2] hourly snapshots built for $day"
}

case "${1:-}" in
  --load-content) load_content "${2:?usage: 05_refresh.sh --load-content FILE}";;
  --load-raw)     load_raw "${2:?usage: 05_refresh.sh --load-raw FILE [DAY]}" "${3:-}";;
  --bootstrap) bootstrap "${2:?usage: 05_refresh.sh --bootstrap DAY}";;
  --snapshots)    snapshots "${2:?usage: 05_refresh.sh --snapshots DAY}";;
  --once)      run_refresh;;
  --loop)
    while true; do run_refresh || true; sleep "$INTERVAL"; done;;
  *)
    echo "usage: 05_refresh.sh {--load-content FILE | --load-raw FILE [DAY] | --bootstrap DAY | --snapshots DAY | --once | --loop}"
    exit 1;;
esac
