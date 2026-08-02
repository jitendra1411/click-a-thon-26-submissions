# ClickStack integration

ClickStack is the pipeline's own observability: it watches the ClickHouse
serving layer and the refresh cycles, not the product dashboard. Everything
below is the wiring judges asked for in the ClickStack evidence note.

## What runs where

- **Service** — `clickhouse/clickstack-all-in-one` (HyperDX-style UI +
  bundled ClickHouse + OTel collector), defined in
  [`docker-compose.clickstack.yml`](docker-compose.clickstack.yml) and
  started with the rest of the stack (`docker compose up clickstack`).
- **Ports** — UI `127.0.0.1:8080`, OTLP gRPC `4317`, OTLP HTTP `4318`,
  bundled ClickHouse `8124` (mapped to its internal 8123).
- **Which ClickHouse it writes to** — *ClickStack's own bundled ClickHouse*
  (`default` database), not the product `sonyliv_v2` database.
- **Which tables** — `default.otel_metrics_gauge` (per-cycle gauges) and
  `default.otel_logs` (an INFO `pipeline_refresh` record per cycle) — the
  exact tables the HyperDX-style UI reads.

## How telemetry gets in (no OTLP protobuf needed)

ClickStack's OTLP HTTP receiver is protobuf-only, so the dependency-free path
writes **directly into the otel tables via SQL** — see
[`otlp_pipeline_metrics.py`](otlp_pipeline_metrics.py). The metrics user
(`10-local-metrics-user-clickstack.xml`) is installed in ClickStack's
ClickHouse so the insert uses a dedicated, non-root user.

Metrics emitted per refresh cycle:

- `sonyliv.pipeline.ingestion_lag_seconds`
- `sonyliv.pipeline.ingested_events`
- `sonyliv.pipeline.serving_query_duration_ms`
- `sonyliv.pipeline.serving_query_read_rows`
- `sonyliv.pipeline.peak_concurrency_last_hour`
- `sonyliv.pipeline.open_sessions`

Plus one `otel_logs` row per cycle with the same values (event
`pipeline_refresh`).

## How it is invoked

The pipeline runs it after each refresh cycle from bash (no Python in the
data path — this is a standalone telemetry reporter):

```bash
python3 otlp_pipeline_metrics.py --ch-http http://127.0.0.1:8123 \
                                 --cs-http http://127.0.0.1:8124
```

## Evidence (captured 2026-08-02)

- Live container: `clickstack` — status **healthy** (12+ hours uptime).
- Telemetry rows present in ClickStack's ClickHouse:
  `otel_metrics_gauge` **36,061 rows**, `otel_logs` **16 rows**.
- Dashboard capture: [`../../screenshots/clickstack_integration.png`](../../screenshots/clickstack_integration.png)
  (also embedded in the submission README); live walkthrough in the demo video.

## Reproduce

```bash
docker compose up -d clickstack            # or: make up-obs (full stack)
# install the metrics user into ClickStack's ClickHouse, then after a refresh:
python3 otlp_pipeline_metrics.py
# open http://localhost:8080 and search service=sonyliv-clickhouse
```
