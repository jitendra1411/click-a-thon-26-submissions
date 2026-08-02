# v2 Step 6 — Dashboard: serving (all times IST)

**Goal:** every UI number is computed in Asia/Kolkata — consistently, across
every element.

## The API surface (`ui/server.py`, `CH_DB=sonyliv_v2`)

- `/api/filters` — dimensions, day range, and `cov_min → cov_max` coverage in
  IST.
- `/api/series` — buckets **converted to IST** before returning (the fix that
  made every element agree).
- `/api/kpis` — peak / latest minutes in IST.
- `/api/heatmap` — weekday × hour computed with
  `toTimeZone(minute_bucket, 'Asia/Kolkata')`.

## The timezone fix (why it was inconsistent)

v1's `grain_sql` already bucketed in IST internally, but the returned bucket
strings and the KPI minutes were **raw UTC wall-clock** — so the line chart
labels and "peak minute" cards showed 10:59 while the heatmap showed hour 16
for the *same instant* (16:29 IST). The fix is one helper:

```python
def utc_to_local(ts: str) -> str:
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(ZoneInfo("Asia/Kolkata")).strftime("%Y-%m-%d %H:%M:%S")
```

`/api/series` and `compute_kpis` now run every displayed timestamp through it.
Verified after the fix (all from the same instant, all IST):

| Element | Before (UTC) | After (IST) |
|---|---|---|
| Series peak bucket | 10:59 | **16:29** |
| KPI peak minute | 10:59 | **16:29** |
| Latest minute | 11:31 | **17:01** |
| Heatmap peak hour | 16 (already IST) | 16 |
| Coverage footer | — | 05:40 → 17:01 |

## The core series query

```sql
SELECT toTimeZone(
         toStartOfInterval(toTimeZone(minute_bucket, 'Asia/Kolkata'),
                           INTERVAL 5 MINUTE), 'UTC') AS bucket,
       uniqMerge(sessions_state) AS sessions,
       uniqMerge(users_state)    AS users
FROM sonyliv_v2.minute_sessions        -- a view over versioned facts
WHERE minute_bucket >= toDateTime('2026-07-26 00:00:00')
  AND minute_bucket <= toDateTime('2026-07-26 23:59:59')
GROUP BY bucket ORDER BY bucket
```

`minute_sessions` is a **view** over version-tracked facts joined to
`v_session_versions_current` (no FINAL), with **exact** `uniqExactState`
cardinality; the server converts the returned bucket to IST for display.
The approximate `uniqState` variant is available as `minute_sessions_approx`.

## KPI math

- **Peak** = max of the series; **peak minute** = the IST-converted bucket.
- **Average** is time-weighted (each value weighted by how long it stays
  valid) because the series stores change points, not every minute.
- **Open sessions** = `count() WHERE is_open = 1` on the versioned interval
  table.

## The demo checklist

- Reload with Cmd+Shift+R (browser cache can show the old UTC labels).
- Peak card should read **2,727 @ 16:29 IST** on 07-26.
- Heatmap peak cell: **Sunday, hour 16** (4–5 PM IST) = 2,727.
- Coverage footer: **2026-07-14 21:13 → 2026-07-26 17:01 IST**.
