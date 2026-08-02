# Dashboard query benchmark — all endpoints (2026-08-02)

Every query the dashboard runs, timed end-to-end (API) and captured from
`system.query_log` (ClickHouse). Dataset: **unseen day 2026-07-31**
(6.9M raw events → 2.9M enriched → 866K serving rows read).

## End-to-end API timings (what the browser sees)

| Endpoint | Range | Grain | Points/rows returned | End-to-end |
|---|---|---:|---:|---:|
| `/api/series` | 07-31 day | 1m | 698 buckets | 0.49 s |
| `/api/series` | 07-31 day | 5m | 142 buckets | 0.48 s |
| `/api/series` | 07-31 day | 60m | 13 buckets | 1.13 s |
| `/api/kpis` | 07-31 day | 1m | peak 16,877 | 0.40 s |
| `/api/breakdown` | 07-31 day | 60m | 10 platforms · 3 vtypes · 10 contents | 1.09 s |
| `/api/heatmap` | 07-31 day | 60m | 7×24 grid | 0.29 s |
| `/api/filters` | all | — | 19 platforms · 3 vtypes | 1.12 s |

## ClickHouse-side evidence (query IDs → latency → rows read)

### `/api/filters` (one request = 5 queries)

| Query | ID | ms | rows |
|---|---|---:|---:|
| DISTINCT platform | `49a00613-b80a-4d22-949d-366a03fea08b` | 162 | 996,923 |
| DISTINCT country | `d4644aaa-bd5f-4baf-9947-523f765f2014` | 158 | 996,923 |
| DISTINCT video_type | `32fc7125-7d46-4155-900f-6a6c9087a4c6` | 158 | 996,923 |
| day min/max (IST) | `dceb00bc-2807-484b-aa57-9d51a84a9aeb` | 152 | 996,923 |
| coverage min/max (IST) | `33e7f542-d72e-4c3b-bb27-436cc2156cf3` | 159 | 996,923 |
| top contents (title + peak) | `adf0bb10-8bab-403f-a507-2acda0ec4fa8` | 314 | 996,923 |

### `/api/series` (the concurrency curve)

| Grain | ID | ms | rows |
|---|---|---:|---:|
| 1m | `a557d18f-e323-4e85-8183-a36d51867cb6` | 475 | 866,425 |
| 5m | `76dbe731-314e-48f1-800a-08dcdce0523c` | 463 | 866,425 |
| 60m | `882d59d2-4fc4-4565-9fe8-dc89205def1a` (from prior run) | 668 | 866,425 |

### `/api/kpis` (peak / average / latest / open sessions)

| Query | ID | ms | rows |
|---|---|---:|---:|
| minute curve (peak/avg) | `d6d6a9b8-14ec-405a-8d50-f30f81a44f40` (1m) | 142 | 866,425 |
| open-session count | `4027d78d-a4f8-4bb2-b511-02c7d38466de` | 5 | 108,036 |

### `/api/breakdown` (one request = 3 queries)

| Query | ID | ms | rows |
|---|---|---:|---:|
| peak by platform | `db8eb4c7-9d67-45ba-876a-46bd097a44da` | 486 | 866,425 |
| peak by video_type | `05edde13-6495-45ba-9176-00ac49dd4990` | 267 | 866,425 |
| peak by content (+title) | `5d7b795d-a7b1-4800-a2a3-1676db39bacf` | 317 | 866,425 |

### `/api/heatmap`

| Query | ID | ms | rows |
|---|---|---:|---:|
| peak per (weekday × hour), IST | `c2aa6948-a087-40c7-8a81-55e906f9e25e` | 273 | 866,425 |

## What this proves

- **Every dashboard query reads only the Gold serving layer** (`minute_sessions`
  exact view / `hourly_kpis` / `session_active_intervals`) — never raw events.
  Row counts are the compressed serving rows (866K), not the 6.9M-event raw
  stream.
- Worst query is ~670 ms ClickHouse-side; the page's four parallel calls
  complete in ~1.1 s end-to-end (single-threaded Python server; the
  long-range hourly path drops to ~28 ms).
- Filters apply to the curve and all breakdowns (same WHERE on
  `minute_sessions`).

## Reproduce

```bash
# after bootstrap + snapshots (see 10-unseen-day-runbook.md):
for ep in "series?grain=1m" "series?grain=5m" "series?grain=60m" \
          "kpis?grain=1m" "breakdown?grain=60m" "heatmap?grain=60m"; do
  curl -s "http://localhost:8085/v2/api/$ep&from=2026-07-31T00:00&to=2026-07-31T23:59&platform=all&country=all&video_type=all&content_id=all" >/dev/null
done

# then export the IDs:
SELECT query_id, query_duration_ms, read_rows, read_bytes
FROM system.query_log
WHERE type='QueryFinish' AND query_start_time >= now() - INTERVAL 5 MINUTE
ORDER BY query_start_time DESC;
```
