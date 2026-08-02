#!/usr/bin/env python3
"""
SonyLIV Concurrency KPI UI - dependency-free HTTP server.

Serves the static frontend from ui/static/ and proxies parameterized queries
to the sonyliv ClickHouse serving layer (minute_sessions / minute_deltas /
session_active_intervals). All KPI math (peak, time-weighted average, peak
minute) is computed from the sparse series so the UI never scans raw events.

Run:
    python3 ui/server.py --port 8085
Env overrides: CH_HTTP (default http://127.0.0.1:8123), CH_USER (default sonyliv_metrics)
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from zoneinfo import ZoneInfo

CH_HTTP = os.environ.get("CH_HTTP", "http://127.0.0.1:8123")
CH_USER = os.environ.get("CH_USER", "sonyliv_metrics")
CH_DB = os.environ.get("CH_DB", "sonyliv_v2")  # v2 is the primary solution
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# URL prefix -> (database, label). /v1 = v1 solution (sonyliv), /v2 = v2
# solution (sonyliv_v2). The unprefixed root defaults to CH_DB for
# backward compatibility.
SOLUTIONS = {
    "v1": {"db": "sonyliv", "label": "Solution v1 — day-scoped rebuild (Python)"},
    "v2": {"db": "sonyliv_v2", "label": "Solution v2 — ClickHouse-native, session-scoped refresh"},
}

# v1 stores approximate uniqState sketches; v2's benchmark views store exact
# uniqExactState. The merge function must match the stored state type.
def merge_fn(db: str) -> str:
    return "uniqExactMerge" if db == "sonyliv_v2" else "uniqMerge"

TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$")
DIM_RE = re.compile(r"^[A-Za-z0-9_\- ]*$")
GRAIN_RE = re.compile(r"^(\d+)(m|h|d)$")
GRAIN_UNIT_SQL = {"m": "MINUTE", "h": "HOUR", "d": "DAY"}
TZ_RE = re.compile(r"^[A-Za-z_+\-/]{1,64}$")
TZ_DEFAULT = "Asia/Kolkata"  # spec: default display tz for business users
_TZ = ZoneInfo(TZ_DEFAULT)
EMPTY_SENTINEL = "__empty__"  # URL-safe stand-in for the empty video_type value


def ch_raw(sql: str) -> str:
    url = f"{CH_HTTP}/?user={urllib.parse.quote(CH_USER)}&query={urllib.parse.quote(sql)}"
    with urllib.request.urlopen(url, timeout=120) as resp:
        return resp.read().decode()


def ch_rows(sql: str) -> list:
    body = ch_raw(sql.rstrip().rstrip(";") + " FORMAT JSONEachRow").strip()
    return [json.loads(line) for line in body.splitlines() if line]


def normalize_ts(ts: str) -> str:
    ts = ts.strip().replace("T", " ")
    if not TS_RE.match(ts):
        raise ValueError(f"bad timestamp: {ts}")
    if len(ts) == 10:
        ts += " 00:00:00"
    elif len(ts) == 16:
        ts += ":00"
    return ts


def utc_to_local(ts: str) -> str:
    """Buckets are UTC wall-clock (grain_sql returns UTC datetimes whose
    wall-clock equals the IST bucket). Format them back as IST for display."""
    try:
        dt = datetime.fromisoformat(ts)
    except ValueError:
        return ts
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(_TZ).strftime("%Y-%m-%d %H:%M:%S")


def ist_to_utc(ts: str) -> str:
    """Frontend from/to are IST wall-clock (the dashboard's display tz).
    Convert to UTC before comparing against the stored UTC clock."""
    try:
        dt = datetime.fromisoformat(ts)
    except ValueError:
        return ts
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_TZ)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def build_where(q: dict, alias: str = "minute_bucket") -> str:
    """Filters on the *stored* UTC clock. from/to arrive as IST wall-clock
    (dashboard display tz) and are converted to UTC here. Dimension filters
    accept comma-separated multi-values (IN clause)."""
    conds = [
        f"{alias} >= toDateTime('{ist_to_utc(normalize_ts(q['from']))}')",
        f"{alias} <= toDateTime('{ist_to_utc(normalize_ts(q['to']))}')",
    ]
    for col in ("platform", "country", "video_type"):
        val = q.get(col, "all")
        vals = [v for v in (val or "").split(",") if v != "all"]
        vals = ["" if v == EMPTY_SENTINEL else v for v in vals]
        vals = [v for v in vals if not (v == "" and col != "video_type")]
        if vals:
            if not all(DIM_RE.match(v) for v in vals):
                raise ValueError(f"bad {col}")
            quoted = ", ".join(f"'{v}'" for v in vals)
            conds.append(f"{col} IN ({quoted})")
    cid = q.get("content_id")
    if cid and cid != "all":
        if not cid.isdigit():
            raise ValueError("bad content_id")
        conds.append(f"content_id = {cid}")
    return " AND ".join(conds)


def grain_sql(grain: str) -> str:
    """Map '5m' / '1h' / '1d' to a bucketing expression on the *UTC* clock.
    Returns a UTC datetime whose wall-clock equals the IST bucket."""
    m = GRAIN_RE.match(grain)
    if not m:
        raise ValueError("bad grain")
    n, unit = int(m.group(1)), m.group(2)
    return (f"toTimeZone(toStartOfInterval(toTimeZone(minute_bucket, '{TZ_DEFAULT}'), "
            f"INTERVAL {n} {GRAIN_UNIT_SQL[unit]}), 'UTC')")


def fast_path_applies(q: dict, db: str = "sonyliv_v2") -> bool:
    """Long-range coarse-grain queries read finalized hourly snapshots.
    Threshold: v2 database + grain >= 1 hour AND range >= 3 days.
    Everything else uses the exact minute path."""
    if db != "sonyliv_v2":
        return False
    m = GRAIN_RE.match(q["grain"])
    if not m:
        return False
    n, unit = int(m.group(1)), m.group(2)
    if unit == "m" and n < 60:
        return False
    if unit not in ("h", "m"):
        return False
    frm = datetime.fromisoformat(q["from"])
    to = datetime.fromisoformat(q["to"])
    return (to - frm).days >= 3


def hourly_dim_filter(q: dict) -> str:
    """Dimension predicates on hourly_kpis (NULL = that dimension not in the
    snapshot's set; 'all' = the global/aggregate row)."""
    conds = []
    for col in ("platform", "country", "video_type"):
        val = q.get(col, "all")
        if val and val != "all":
            vals = [v for v in val.split(",") if v != "all"]
            if vals:
                quoted = ", ".join(f"'{v}'" for v in vals)
                conds.append(f"{col} IN ({quoted})")
    cid = q.get("content_id")
    if cid and cid != "all":
        conds.append(f"content_id = {cid}")
    # NULL dims = snapshot rows that aggregate over that dimension
    for col in ("platform", "country", "video_type", "content_id"):
        if not any(c.startswith(col) for c in conds):
            conds.append(f"{col} IS NULL")
    return " AND ".join(conds)


def sanitize(q: dict) -> dict:
    grain = q.get("grain", "1h")
    grain_sql(grain)  # validate
    return {
        "from": normalize_ts(q.get("from", "2026-07-26 00:00:00")),
        "to": normalize_ts(q.get("to", "2026-07-28 23:59:59")),
        "grain": grain,
        "platform": q.get("platform", "all"),
        "country": q.get("country", "all"),
        "video_type": q.get("video_type", "all"),
        "content_id": q.get("content_id", "all"),
    }


def series_query(q: dict, db: str) -> str:
    if fast_path_applies(q, db):
        return (
            "SELECT toTimeZone(hour_bucket, 'Asia/Kolkata') AS bucket, "
            "peak_concurrency AS sessions, peak_users AS users "
            f"FROM {db}.hourly_kpis "
            f"WHERE {hourly_dim_filter(q)} "
            f"AND metric_definition = 'foreground_active' "
            f"AND toDate(toTimeZone(hour_bucket, '{TZ_DEFAULT}')) >= toDate('{q['from']}') "
            f"AND toDate(toTimeZone(hour_bucket, '{TZ_DEFAULT}')) <= toDate('{q['to']}') "
            "ORDER BY bucket"
        )
    m = merge_fn(db)
    return (
        f"SELECT {grain_sql(q['grain'])} AS bucket, "
        f"{m}(sessions_state) AS sessions, {m}(users_state) AS users "
        f"FROM {db}.minute_sessions "
        f"WHERE {build_where(q)} "
        f"GROUP BY bucket ORDER BY bucket"
    )


def compute_kpis(rows: list, frm: datetime, to: datetime, fast: bool = False) -> dict:
    if not rows:
        return {
            "peak_sessions": 0, "peak_users": 0, "avg_sessions": 0.0,
            "peak_minute": None, "latest_sessions": 0, "latest_minute": None,
        }
    peak = max(rows, key=lambda r: r["sessions"])
    latest = rows[-1]
    total_w = 0.0
    acc = 0.0
    for i, r in enumerate(rows):
        end = rows[i + 1]["bucket"] if i + 1 < len(rows) else to
        w = max(0.0, (end - r["bucket"]).total_seconds())
        acc += r["sessions"] * w
        total_w += w
    peak_str = peak["bucket"].strftime("%Y-%m-%d %H:%M:%S")
    latest_str = latest["bucket"].strftime("%Y-%m-%d %H:%M:%S")
    return {
        "peak_sessions": peak["sessions"],
        "peak_users": peak["users"],
        "avg_sessions": round(acc / total_w, 2) if total_w else 0.0,
        "peak_minute": (peak_str if fast else utc_to_local(peak_str))[:16],
        "latest_sessions": latest["sessions"],
        "latest_users": latest["users"],
        "latest_minute": (latest_str if fast else utc_to_local(latest_str))[:16],
    }


def api_filters(db: str, sol_label=None):
    m = merge_fn(db)
    platforms = [r["platform"] for r in ch_rows(
        f"SELECT DISTINCT platform FROM {db}.minute_sessions ORDER BY platform")]
    countries = [r["country"] for r in ch_rows(
        f"SELECT DISTINCT country FROM {db}.minute_sessions ORDER BY country")]
    vtypes = [r["video_type"] for r in ch_rows(
        f"SELECT DISTINCT video_type FROM {db}.minute_sessions ORDER BY video_type")]
    contents = ch_rows(
        f"SELECT content_id, dictGet('{db}.content_dict', 'title', content_id) AS title, "
        "max(c) AS peak FROM ("
        f" SELECT content_id, minute_bucket, {m}(sessions_state) AS c "
        f" FROM {db}.minute_sessions GROUP BY minute_bucket, content_id)"
        " GROUP BY content_id, title ORDER BY peak DESC LIMIT 50")
    days = ch_rows(
        "SELECT min(toDate(toTimeZone(minute_bucket, 'Asia/Kolkata'))) AS dmin, "
        "max(toDate(toTimeZone(minute_bucket, 'Asia/Kolkata'))) AS dmax "
        f"FROM {db}.minute_sessions")
    cov = ch_rows(
        "SELECT min(toTimeZone(minute_bucket, 'Asia/Kolkata')) AS mn, "
        f"max(toTimeZone(minute_bucket, 'Asia/Kolkata')) AS mx FROM {db}.minute_sessions")
    return {
        "platforms": platforms,
        "countries": countries,
        "video_types": vtypes,
        "contents": contents,
        "day_min": days[0]["dmin"] if days else None,
        "day_max": days[0]["dmax"] if days else None,
        "tz": TZ_DEFAULT,
        "cov_min": cov[0]["mn"] if cov else None,
        "cov_max": cov[0]["mx"] if cov else None,
        "sol": sol_label,
    }


def api_kpis(q: dict, db: str):
    fast = fast_path_applies(q, db)
    rows = [dict(r, bucket=datetime.fromisoformat(r["bucket"])) for r in ch_rows(series_query(q, db))]
    frm = datetime.fromisoformat(q["from"])
    to = datetime.fromisoformat(q["to"])
    k = compute_kpis(rows, frm, to, fast=fast)
    open_sessions = 0
    try:
        open_rows = ch_rows(
            f"SELECT count() AS n FROM {db}.session_active_intervals "
            f"WHERE is_open = 1 AND event_dt >= toDate('{ist_to_utc(q['from'])}') "
            f"AND event_dt <= toDate('{ist_to_utc(q['to'])}')")
        open_sessions = open_rows[0]["n"] if open_rows else 0
    except Exception:
        pass
    k["open_sessions"] = open_sessions
    k["points"] = len(rows)
    k["source"] = "hourly_kpis" if fast else "minute_sessions"
    return k


def api_series(q: dict, db: str):
    fast = fast_path_applies(q, db)
    rows = ch_rows(series_query(q, db))
    buckets = [r["bucket"] if fast else utc_to_local(r["bucket"]) for r in rows]
    return {"buckets": buckets,
            "sessions": [r["sessions"] for r in rows],
            "users": [r["users"] for r in rows],
            "source": "hourly_kpis" if fast else "minute_sessions"}


def api_breakdown(q: dict, db: str):
    m = merge_fn(db)
    where = build_where(q)
    by_platform = ch_rows(
        "SELECT platform, max(c) AS peak FROM ("
        f"SELECT platform, minute_bucket, {m}(sessions_state) AS c "
        f"FROM {db}.minute_sessions WHERE {where} GROUP BY minute_bucket, platform)"
        " GROUP BY platform ORDER BY peak DESC LIMIT 10")
    by_vtype = ch_rows(
        "SELECT video_type, max(c) AS peak FROM ("
        f"SELECT video_type, minute_bucket, {m}(sessions_state) AS c "
        f"FROM {db}.minute_sessions WHERE {where} GROUP BY minute_bucket, video_type)"
        " GROUP BY video_type ORDER BY peak DESC")
    by_content = ch_rows(
        f"SELECT content_id, dictGet('{db}.content_dict', 'title', content_id) AS title, "
        "max(c) AS peak, argMax(minute_bucket, c) AS peak_minute FROM ("
        f"SELECT content_id, minute_bucket, {m}(sessions_state) AS c "
        f"FROM {db}.minute_sessions WHERE {where} GROUP BY minute_bucket, content_id)"
        " GROUP BY content_id, title ORDER BY peak DESC LIMIT 10")
    for r in by_content:
        if r.get("peak_minute"):
            r["peak_minute"] = utc_to_local(r["peak_minute"])[:16]
    return {"by_platform": by_platform, "by_video_type": by_vtype, "by_content": by_content}


def api_heatmap(q: dict, db: str):
    m = merge_fn(db)
    """Punch-card grid: rows = weekday (Mon..Sun), cols = hour of day.
    Cell value = peak concurrent sessions in that (hour, weekday) over the range."""
    where = build_where(q)
    rows = ch_rows(
        "SELECT dow, hr, max(v) AS v FROM ("
        " SELECT toDayOfWeek(toTimeZone(minute_bucket, 'Asia/Kolkata')) AS dow, "
        " toHour(toTimeZone(minute_bucket, 'Asia/Kolkata')) AS hr, "
        f" {m}(sessions_state) AS v "
        f" FROM {db}.minute_sessions "
        f" WHERE {where} GROUP BY minute_bucket, dow, hr)"
        " GROUP BY dow, hr ORDER BY dow, hr")
    grid = [[0] * 24 for _ in range(7)]
    for r in rows:
        # toDayOfWeek: Mon=1 .. Sun=7
        if 1 <= r["dow"] <= 7 and 0 <= r["hr"] <= 23:
            grid[r["dow"] - 1][r["hr"]] = int(r["v"])
    return {"weekdays": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], "grid": grid}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        sol = None
        for prefix, info in SOLUTIONS.items():
            if path == "/" + prefix or path.startswith("/" + prefix + "/"):
                sol = prefix
                path = path[len(prefix) + 1:] or "/"
                break
        db = SOLUTIONS[sol]["db"] if sol else CH_DB

        if path.startswith("/api/"):
            q = urllib.parse.parse_qs(parsed.query)
            one = {k: v[0] for k, v in q.items()}
            try:
                if path == "/api/filters":
                    return self._json(api_filters(db, SOLUTIONS[sol]["label"] if sol else None))
                sq = sanitize(one)
                if path == "/api/kpis":
                    return self._json(api_kpis(sq, db))
                if path == "/api/series":
                    return self._json(api_series(sq, db))
                if path == "/api/breakdown":
                    return self._json(api_breakdown(sq, db))
                if path == "/api/heatmap":
                    return self._json(api_heatmap(sq, db))
                return self._json({"error": "unknown api"}, 404)
            except Exception as exc:  # noqa: BLE001 - surface as JSON for the UI
                return self._json({"error": str(exc)}, 400)
        if sol:
            # serve static assets under /v1/ and /v2/ from the same directory
            self.path = path
        return super().do_GET()


def main():
    port = 8085
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    print(f"SonyLIV KPI UI -> http://127.0.0.1:{port}  (ClickHouse: {CH_HTTP})")
    # Threaded so the dashboard's four parallel API calls (Promise.all) are
    # served concurrently instead of serially (measured ~35% faster page load).
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
