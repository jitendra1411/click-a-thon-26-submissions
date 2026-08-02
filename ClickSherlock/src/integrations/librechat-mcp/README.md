# Custom MCP server — SonyLIV concurrency

The conversational layer over the ClickHouse serving tables. Runs as its own
container (`mcp-sonyliv-concurrency`) and is reached by LibreChat over
streamable-http; see the note in `Dockerfile` for why it isn't spawned
in-process by LibreChat.

## Why a custom server alongside `mcp-clickhouse`

The official server exposes `run_select_query` — an LLM writing arbitrary SQL.
That's useful for exploration and it stays enabled, but it is the wrong tool
for the questions this system is judged on, because the hard part of the
concurrency query is not the syntax:

- deltas must be cumulative-summed **in bucket order**, or the number is wrong
- open sessions live in a different table and must be unioned in, or every
  currently-active viewer is uncounted
- peak is **not summable** across time buckets, so it cannot be rolled up
- `video_type` is not a column — it resolves through a dictionary

A model that gets any one of those wrong returns a confident wrong number.
These tools encode the correct query shape once so it cannot be re-derived
incorrectly per question.

## Tools

| Tool | Answers |
|---|---|
| `get_concurrency` | peak / average / curve for a window, with filters |
| `get_peak_concurrency_detail` | **when** the peak happened, plus the surrounding ramp |
| `compare_concurrency` | peak+average **per** platform / country / content / video_type, each with its own peak time |
| `get_dashboard_analytics` | overview: trend + all four breakdowns in one call |
| `get_data_health` | are the serving-layer invariants intact right now |
| `get_query_evidence` | rows/bytes read per query, from `system.query_log` |
| `get_recent_alerts` | concurrency-decline alerts from the worker |
| `get_request_analytics` | chat/agent request telemetry (a separate stream) |

All accept optional `start`/`end`; when omitted the window resolves
server-side from ClickHouse's `now()`, so "in the last hour" doesn't depend
on the model guessing today's date.

## Correctness decisions worth defending

**Open sessions are unioned in at every grain.** They were previously skipped
for hour/day as "a rounding error". That is backwards — an open session is a
currently-active viewer, so the now-facing questions are exactly where
dropping it understates the answer.

**Open intervals contribute a `+1` and no `-1`.** Their end hasn't happened
yet; emitting a `-1` for a provisional end would close the session early. The
`+1` is clamped to the window start so a viewer who tuned in *before* the
window and is still watching is still counted — the previous
`interval_start BETWEEN start AND end` test silently dropped exactly the
long-running sessions that matter most during a live event.

**Peak is recomputed at minute grain even for hour/day queries.** Peak does
not survive a delta rollup: cumulative-summing hour-level net deltas gives the
count at each hour *boundary*, and every session that starts and ends inside
one bucket cancels to zero. On the current data that reported 66 against a
true peak of 453. A stored per-slice peak table doesn't fix it either —
`max()` over slices returns the largest single slice and `sum()` assumes every
slice peaked in the same minute. Peak is only well-defined at the aggregation
level being asked about, so it is recomputed for the requested filters.
Averages and totals do roll up, and still come from the coarse tables.

**Breakdowns are one query, not one query per value.** `get_dashboard_analytics`
previously ran `SELECT DISTINCT content_id` and then called `get_concurrency`
once per value, each opening a new connection — 3,357+ sequential round-trips
against the real catalog. It now partitions the window function by the
dimension and returns every group from a single scan (~60ms for all four
breakdowns).

## Verifying

The serving layer has its own proof, independent of this server:

```bash
make seed-part-a          # regenerate a synthetic day, then verify
make verify               # just verify (non-zero exit on failure)
```

`verify_serving_layer.py` checks the delta+cumsum curve against a brute-force
overlap count over the raw intervals. The brute force is quadratic and would
never ship, which is exactly what makes it a good oracle — it shares no logic
with the thing it checks. That check is what catches an encoding mistake like
the one described at the top of `../mock_part_a.sql`.

## Known limitation

The interval-derivation state machine (raw events → `session_intervals`) is
**not built**. `gen_synthetic_day.py` generates intervals directly, so
everything from `session_intervals` downward is exercised and proven, but the
numbers are derived from synthetic data, not from the real event stream.
When the dataset lands, replace the generation step with the state machine;
nothing downstream changes.
