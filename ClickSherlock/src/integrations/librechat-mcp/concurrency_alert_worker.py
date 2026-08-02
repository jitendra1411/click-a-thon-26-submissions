"""
Concurrency-decline alert worker.

Run on a schedule (every 60s, matched to the interval-derivation worker's
cadence in your solution guide). Each cycle:

  1. Computes a concurrency curve per (content_id, platform) over a
     baseline window + current window, from Tier 2 (concurrency_deltas_minute)
     plus the open-session live union -- same shape as get_concurrency,
     never touches raw_events.
  2. Flags a decline when current avg concurrency has dropped more than
     DECLINE_THRESHOLD vs. baseline, and requires the drop to persist for
     CONSECUTIVE_CHECKS cycles before firing (avoids alerting on one noisy
     minute).
  3. Classifies the probable cause DETERMINISTICALLY in SQL/Python:
       - system_issue        : concurrency is also dropping globally
       - asset_ended         : isolated to this content, and most of its
                                sessions closed (VideoSessionEnd) in-window
       - engagement_decline  : isolated to this content, sessions still open,
                                people are just tuning out
  4. Calls Claude ONLY to phrase a one-sentence alert from the already-
     verified numbers -- the model never decides what happened, only how
     to say it.
  5. Writes the alert to concurrency_alerts, which the get_recent_alerts
     MCP tool exposes to LibreChat.

Install:
    pip install clickhouse-connect anthropic

Env vars:
    CLICKHOUSE_HOST, CLICKHOUSE_PORT, CLICKHOUSE_USER, CLICKHOUSE_PASSWORD,
    CLICKHOUSE_DATABASE, CLICKHOUSE_SECURE, ANTHROPIC_API_KEY
"""

import os
import time
import uuid
from datetime import datetime, timezone

import clickhouse_connect
import anthropic

# ---- Tunables. Log whatever you land on and defend it in the write-up. ----
DECLINE_THRESHOLD = 0.5        # 50% drop in avg concurrency triggers a candidate alert
MIN_BASELINE_CONCURRENCY = 20  # ignore tiny/noisy content below this concurrency
BASELINE_MINUTES = 15
CURRENT_MINUTES = 5
CONSECUTIVE_CHECKS = 2         # must exceed threshold on 2 consecutive cycles
CHECK_INTERVAL_SEC = 60

_pending = {}  # (content_id, platform) -> consecutive-check counter


def get_ch_client():
    return clickhouse_connect.get_client(
        host=os.environ["CLICKHOUSE_HOST"],
        port=int(os.environ.get("CLICKHOUSE_PORT", "8443")),
        username=os.environ["CLICKHOUSE_USER"],
        password=os.environ.get("CLICKHOUSE_PASSWORD", ""),
        database=os.environ.get("CLICKHOUSE_DATABASE", "default"),
        secure=os.environ.get("CLICKHOUSE_SECURE", "true").lower() == "true",
    )


claude = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from env


PER_CONTENT_CURVE_SQL = """
WITH bounds AS (
    SELECT {now:DateTime} - INTERVAL {baseline:UInt32} MINUTE
                          - INTERVAL {current:UInt32} MINUTE AS win_start
),
deltas AS (
    SELECT minute_bucket, content_id, platform, sumMerge(delta) AS d
    FROM concurrency_deltas_minute
    WHERE minute_bucket >= (SELECT win_start FROM bounds)
      AND minute_bucket <= {now:DateTime}
    GROUP BY minute_bucket, content_id, platform

    UNION ALL
    SELECT toStartOfMinute(toDateTime(interval_start)), content_id, platform, 1
    FROM session_intervals FINAL
    WHERE is_open = 1 AND interval_start <= {now:DateTime}

    UNION ALL
    SELECT toStartOfMinute(toDateTime(interval_end)) + INTERVAL 1 MINUTE,
           content_id, platform, -1
    FROM session_intervals FINAL
    WHERE is_open = 1 AND interval_end <= {now:DateTime}
),
merged AS (
    SELECT minute_bucket, content_id, platform, sum(d) AS net_delta
    FROM deltas GROUP BY minute_bucket, content_id, platform
),
curve AS (
    SELECT minute_bucket, content_id, platform,
           sum(net_delta) OVER (
               PARTITION BY content_id, platform ORDER BY minute_bucket
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS concurrency
    FROM merged
)
SELECT
    content_id, platform,
    avgIf(concurrency, minute_bucket < {now:DateTime} - INTERVAL {current:UInt32} MINUTE) AS baseline_c,
    avgIf(concurrency, minute_bucket >= {now:DateTime} - INTERVAL {current:UInt32} MINUTE) AS current_c
FROM curve
GROUP BY content_id, platform
HAVING baseline_c >= {min_baseline:UInt32}
"""

SESSION_END_RATIO_SQL = """
SELECT content_id, platform,
    countIf(interval_end BETWEEN {now:DateTime} - INTERVAL {current:UInt32} MINUTE
                              AND {now:DateTime}) AS ended_now,
    uniqExactIf(video_session_id,
        interval_start BETWEEN {now:DateTime} - INTERVAL {baseline:UInt32} MINUTE
                                                - INTERVAL {current:UInt32} MINUTE
                            AND {now:DateTime} - INTERVAL {current:UInt32} MINUTE
    ) AS active_in_baseline
FROM session_intervals FINAL
WHERE is_open = 0
GROUP BY content_id, platform
"""


def classify_cause(global_pct_drop, session_end_ratio):
    if global_pct_drop >= DECLINE_THRESHOLD * 0.7:
        return "system_issue"
    if session_end_ratio >= 0.6:
        return "asset_ended"
    return "engagement_decline"


def phrase_alert(content_id, platform, baseline_c, current_c, pct_drop, cause):
    prompt = f"""You are writing a one-sentence alert for a streaming-platform
ops dashboard. These facts are already verified -- do not second-guess or
reinterpret them, just phrase them clearly:
- content_id: {content_id}, platform: {platform}
- baseline concurrency (last {BASELINE_MINUTES} min before the drop window): {baseline_c:.0f}
- current concurrency (last {CURRENT_MINUTES} min): {current_c:.0f}
- drop: {pct_drop * 100:.0f}%
- probable cause (already classified -- state it as given): {cause}

Write ONE short, plain-English sentence an on-call engineer can read at a
glance. No preamble, no markdown, just the sentence."""
    resp = claude.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=100,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.content[0].text.strip()


def run_cycle(client):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    params = {
        "now": now, "baseline": BASELINE_MINUTES, "current": CURRENT_MINUTES,
        "min_baseline": MIN_BASELINE_CONCURRENCY,
    }

    per_content = client.query(PER_CONTENT_CURVE_SQL, parameters=params).result_rows
    if not per_content:
        return

    total_baseline = sum(r[2] for r in per_content)
    total_current = sum(r[3] for r in per_content)
    global_pct_drop = (
        (total_baseline - total_current) / total_baseline if total_baseline > 0 else 0
    )

    ended = {
        (r[0], r[1]): (r[2], r[3])
        for r in client.query(SESSION_END_RATIO_SQL, parameters=params).result_rows
    }

    rows_to_insert = []
    for content_id, platform, baseline_c, current_c in per_content:
        if baseline_c <= 0:
            continue
        pct_drop = (baseline_c - current_c) / baseline_c
        key = (content_id, platform)

        if pct_drop < DECLINE_THRESHOLD:
            _pending.pop(key, None)
            continue

        _pending[key] = _pending.get(key, 0) + 1
        if _pending[key] < CONSECUTIVE_CHECKS:
            continue  # require persistence before firing
        _pending[key] = 0  # reset so we don't re-fire every cycle after this

        ended_now, active_baseline = ended.get(key, (0, 0))
        session_end_ratio = ended_now / max(active_baseline, 1)
        cause = classify_cause(global_pct_drop, session_end_ratio)
        message = phrase_alert(content_id, platform, baseline_c, current_c, pct_drop, cause)

        rows_to_insert.append((
            str(uuid.uuid4()), now, content_id, platform,
            round(baseline_c, 1), round(current_c, 1), round(pct_drop, 3),
            cause, message,
        ))
        print(f"[ALERT] {content_id}/{platform}: {message}")

    if rows_to_insert:
        client.insert(
            "concurrency_alerts",
            rows_to_insert,
            column_names=["alert_id", "detected_at", "content_id", "platform",
                           "baseline_concurrency", "current_concurrency",
                           "pct_drop", "probable_cause", "alert_message"],
        )


if __name__ == "__main__":
    client = get_ch_client()
    while True:
        try:
            run_cycle(client)
        except Exception as e:
            print(f"[alert worker] cycle failed: {e}")
        time.sleep(CHECK_INTERVAL_SEC)
