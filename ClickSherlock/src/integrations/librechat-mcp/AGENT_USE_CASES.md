# LibreChat agent — use cases and demo prompts

The agent drives the two MCP servers (official ClickHouse SQL + the custom
concurrency server). All timestamps returned by the custom server are
**Asia/Kolkata IST**; inputs are UTC (the agent can convert).

## Demo prompts (copy-paste into a LibreChat Agent)

**1. Dashboard overview + chart artifact**
> Call get_dashboard_analytics for 2026-07-31 with grain hour, and show me
> the concurrency trend as a line chart artifact, with a platform breakdown
> table below it.

Expected: the agent calls **`render_dashboard_html`** (which returns a
complete self-contained HTML dashboard — inline SVG line chart + platform
table) and returns it verbatim in a ```html fenced block; LibreChat renders
it in the artifact panel. The chart is generated server-side, so the model
cannot mangle it into ```scss or a code block.

**Tip:** the UI has an "✦ Advanced Analytics with AI" button (top-right of
the main chart) that opens LibreChat — paste the prompt there directly.

**2. Peak + when (the "and when?" question)**
> What was peak concurrency on 2026-07-31 and at what time? Show the 5
> minutes around it.

Expected: `get_peak_concurrency_detail` → peak, peak_at (IST), trough, and
the ramp context.

**3. Compare platforms (each peaks at its own minute)**
> Compare peak concurrency across platforms for 2026-07-31. Which platform
> peaked highest, and did they peak at the same time?

Expected: `compare_concurrency` → per-platform peak + peak_at +
`peaks_are_simultaneous`.

**4. "Last hour" without knowing the clock**
> What was peak concurrency in the last hour on Android?

Expected: `get_concurrency` with no start/end → the server resolves the
window from its own clock (lookback_minutes) and applies the platform filter.

**5. Viewing volume (not concurrency)**
> Which content was watched the most on 2026-07-31? Show sessions and
> average watch time per title.

Expected: `get_content_engagement` → session_count / watch minutes /
avg session minutes per content (with title + video_type).

**6. Is the pipeline healthy right now?**
> Check the serving layer health and show the last pipeline evidence.

Expected: `get_data_health` → invariants + open/capped sessions;
`get_query_evidence` → rows/bytes read (proves no raw-event scans).

**7. Decline investigation (ties to the dashboard banner)**
> At 16:30 IST on 2026-07-31 the trend dropped sharply after the peak.
> What happened? Compare with the surrounding hours and platforms.

Expected: `get_concurrency` (window around the drop) +
`compare_concurrency` → the agent explains the ramp rather than looping
(the coverage clamp prevents "no data" loops).

## Why the recursion loop is fixed

The dashboard banner says "decline at 02:00" in IST; the MCP server used to
interpret windows as UTC and returned sparse rows for out-of-coverage times,
so the agent chased a phantom collapse. The server now:

- returns every timestamp as IST (matches the dashboard),
- returns `note: requested window is OUTSIDE the data coverage: ...` plus a
  hint when a window has no data — the agent answers "no data before
  05:42 IST" instead of looping,
- documents the UTC-in / IST-out contract in each tool.

## If an agent still loops or refuses to render

- Retry once — DeepSeek tool-calling can occasionally hiccup on long
  multi-tool turns.
- Be explicit: "use render_dashboard_html and return its output in a ```html
  fenced block".
- For a window the UI labels in IST, give the IST time and let the tool
  describe coverage; the server compares on UTC internally.

## Tools summary (what the agent knows it can do)

- `render_dashboard_html` — full HTML dashboard (SVG chart + tables) for any
  window/filters; the go-to for "show me a chart".
- `get_concurrency` — peak / average / curve at minute/hour/day grain.
- `get_peak_concurrency_detail` — peak time + surrounding ramp.
- `compare_concurrency` — per-platform/country/content/video_type peaks.
- `get_dashboard_analytics` — raw summary + trend + all breakdowns (JSON).
- `get_content_engagement` — sessions, watch minutes, avg session length.
- `get_data_health` / `get_query_evidence` — invariants + rows-read proof.
- `get_recent_alerts` — concurrency-decline alerts (from the worker).
