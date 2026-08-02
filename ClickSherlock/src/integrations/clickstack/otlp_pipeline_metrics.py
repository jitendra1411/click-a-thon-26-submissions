#!/usr/bin/env python3
"""
Send SonyLIV pipeline telemetry to ClickStack's ClickHouse.

ClickStack's OTLP HTTP receiver is protobuf-only, so the dependency-free path
is to write directly into its bundled ClickHouse tables (default.otel_logs,
default.otel_metrics_gauge) - the exact tables its UI reads. The metrics user
(setup/clickhouse-users.d/10-local-metrics-user-clickstack.xml) is installed
in both ClickHouse instances.

Dependencies: Python 3 stdlib only.

Usage:
    python3 otlp_pipeline_metrics.py [--ch-http http://127.0.0.1:8123]
                                     [--cs-http http://127.0.0.1:8124]
"""

import argparse
import json
import time
import urllib.parse
import urllib.request


def ch_query(ch_http: str, sql: str) -> str:
    """Run a ClickHouse statement over HTTP (SELECT/INSERT alike)."""
    sql = sql.rstrip().rstrip(";")
    url = f"{ch_http}/?user=sonyliv_metrics"
    # POST is required for modifying statements (GET implies readonly in 26.x).
    req = urllib.request.Request(
        url, data=sql.encode(), method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode()


def first_row(ch_http: str, sql: str) -> dict:
    rows = ch_query(ch_http, sql + " FORMAT JSONEachRow").strip().splitlines()
    return json.loads(rows[0]) if rows else {}


def collect(ch_http: str) -> dict:
    g = {}
    row = first_row(
        ch_http,
        "SELECT toUnixTimestamp64Milli(now64(3)) - toUnixTimestamp64Milli(max(event_time)) "
        "AS lag_ms, count() AS events FROM sonyliv.raw_events",
    )
    g["ingestion_lag_seconds"] = max(0.0, (row.get("lag_ms") or 0) / 1000.0)
    g["ingested_events"] = float(row.get("events") or 0)

    row = first_row(
        ch_http,
        "SELECT query_duration_ms, read_rows FROM system.query_log "
        "WHERE type = 'QueryFinish' AND query LIKE '%minute_sessions%' "
        "ORDER BY event_time DESC LIMIT 1",
    )
    g["serving_query_duration_ms"] = float(row.get("query_duration_ms") or 0)
    g["serving_query_read_rows"] = float(row.get("read_rows") or 0)

    row = first_row(
        ch_http,
        "SELECT max(c) AS c FROM ("
        " SELECT minute_bucket, uniqMerge(sessions_state) AS c "
        " FROM sonyliv.minute_sessions "
        " WHERE minute_bucket >= now() - INTERVAL 1 HOUR GROUP BY minute_bucket)",
    )
    g["peak_concurrency_last_hour"] = float(row.get("c") or 0)

    row = first_row(
        ch_http,
        "SELECT count() AS n FROM sonyliv.session_active_intervals WHERE is_open = 1",
    )
    g["open_sessions"] = float(row.get("n") or 0)
    return g


def clickstack_insert_gauges(cs_http: str, g: dict) -> None:
    now_sql = "now()"
    rows = ", ".join(
        f"('sonyliv-clickhouse', 'sonyliv.pipeline.{name}', '', '1', "
        f"{{'instance':'local-sonyliv-ch'}}, {now_sql}, {value}, 0)"
        for name, value in g.items()
    )
    sql = (
        "INSERT INTO otel_metrics_gauge "
        "(ServiceName, MetricName, MetricDescription, MetricUnit, Attributes, TimeUnix, Value, Flags) "
        f"VALUES {rows}"
    )
    ch_query(cs_http, sql)


def clickstack_insert_log(cs_http: str, g: dict) -> None:
    body = json.dumps(
        {
            "event": "pipeline_refresh",
            "ingestion_lag_seconds": g["ingestion_lag_seconds"],
            "peak_concurrency_last_hour": g.get("peak_concurrency_last_hour", 0),
            "open_sessions": g.get("open_sessions", 0),
            "serving_query_duration_ms": g.get("serving_query_duration_ms", 0),
        }
    ).replace("'", "''")
    attrs = ", ".join(
        f"'{k}': '{v}'" for k, v in {
            "event": "pipeline_refresh",
            "instance": "local-sonyliv-ch",
            "ingestion_lag_seconds": round(g["ingestion_lag_seconds"], 1),
            "peak_concurrency_last_hour": round(g.get("peak_concurrency_last_hour", 0)),
            "open_sessions": round(g.get("open_sessions", 0)),
            "serving_query_duration_ms": round(g.get("serving_query_duration_ms", 0)),
            "ingested_events": round(g.get("ingested_events", 0)),
        }.items()
    )
    sql = (
        "INSERT INTO otel_logs "
        "(Timestamp, SeverityText, SeverityNumber, ServiceName, Body, LogAttributes) "
        f"VALUES (now64(3), 'INFO', 9, 'sonyliv-clickhouse', '{body}', {{{attrs}}})"
    )
    ch_query(cs_http, sql)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ch-http", default="http://127.0.0.1:8123")
    ap.add_argument("--cs-http", default="http://127.0.0.1:8124")
    args = ap.parse_args()

    g = collect(args.ch_http)
    try:
        clickstack_insert_gauges(args.cs_http, g)
        clickstack_insert_log(args.cs_http, g)
        print(f"ClickStack telemetry sent: {json.dumps(g, sort_keys=True)}")
    except Exception as exc:  # never break the pipeline because telemetry failed
        print(f"ClickStack delivery failed (pipeline continues): {exc}")


if __name__ == "__main__":
    main()
