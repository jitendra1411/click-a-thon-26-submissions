# Dataset filters — which columns back each filter

The product UI exposes filters that map 1:1 to dataset columns, and every
filter applies to the concurrency curve plus all breakdown views.

| UI filter | Dataset column | Notes |
|---|---|---|
| Platform | `platform` | e.g. ANDROID_PHONE, IPHONE, JIO_ANDROID_TV (10 values) |
| Country | `country` | single value in the provided set (`india`) |
| Video type | `video_type` | from content metadata (live / vod / empty=unknown) |
| Content | `content_id` + `title` | content metadata; 33K titles |
| Time range | `event_timestamp` | IST display, UTC storage |
| Granularity | — | 1m / 5m / 15m / 30m / 60m / 1h / 1d (computed, not a column) |

**Unseen-day additions** (new columns the pipeline ingested without code
changes):

| UI/filter | Dataset column | Notes |
|---|---|---|
| Video resolution | `video_resolution` | NEW in the surprise raw file (e.g. 1080p, 720p) |
| Show name | `show_name` | NEW in the surprise content file |

Filters are multi-select (platform, country, video type) and the content
selector is single-select; all filters are applied in the serving SQL
(`WHERE` on the exact `minute_sessions` view / `hourly_kpis` snapshots), so
the curve, KPI cards, heatmap and breakdowns all respect them.
