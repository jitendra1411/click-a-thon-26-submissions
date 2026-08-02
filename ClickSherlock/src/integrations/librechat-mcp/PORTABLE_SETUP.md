# Portable MCP + LibreChat setup

Bring up just the conversational layer — two MCP servers plus LibreChat —
against a ClickHouse **you already have running with data loaded**. No
bundled ClickHouse, no ClickStack, no Langfuse, no Ollama. That's what
`docker-compose.yml` / `Makefile` (no suffix) are for; this is the slice of
it that travels.

## Files that make up this slice

Everything else in `setup/` (ClickStack, Langfuse, the synthetic-data
generator, the alert worker) is optional and unrelated to this path.

```
setup/
├── docker-compose.portable.yml   # the 4 services: 2 MCP servers + LibreChat + its mongo
├── Makefile.portable             # init / secrets / up / verify / down
├── .env.portable.example         # template — copy to .env.portable, fill in your ClickHouse
├── mcp/
│   ├── clickhouse_concurrency_mcp_server.py   # the custom MCP server
│   ├── Dockerfile
│   └── README.md                 # tool reference + the correctness decisions behind them
└── librechat/
    └── librechat.yaml            # LibreChat config: MCP wiring + model endpoints
```

`mcp/clickhouse_concurrency_mcp_server.py` and `librechat/librechat.yaml` are
shared with the full stack — nothing in them is portable-specific.

## Prerequisites

- Docker (or Colima) running
- A ClickHouse instance, reachable from this machine, with the serving
  tables already loaded: `session_intervals`, `concurrency_deltas_minute`
  (and `_hour`/`_day` if you want long-range queries, `content_dict` as a
  real `DICTIONARY` if you want the `video_type` filter). See
  `mcp/README.md` for what each tool actually reads.
- At least one LLM API key (Anthropic, OpenAI, or DeepSeek) so LibreChat's
  Agents can drive the MCP tools — a model needs real tool-calling support,
  not every local model reliably has it.

## Setup

```bash
cd setup
make -f Makefile.portable init      # creates .env.portable from the template
```

Edit `.env.portable` — the one section that matters is your ClickHouse
connection. Three cases, pick the one that matches your situation:

**ClickHouse is a Docker container on another compose project** (most common
if you're pointing this at another team's or your own separately-running
stack). `host.docker.internal` does **not** reliably reach a port that
container only publishes to `127.0.0.1` on the host — that binding is
host-loopback-only, confirmed unreachable from a different container's
network namespace under Colima (behavior may vary by Docker backend, but
don't assume it works). Instead, join that project's network directly:

```bash
docker network ls                      # find its network, e.g. "clickathon_default"
```
```ini
# .env.portable
CLICKHOUSE_HOST=clickhouse             # the ClickHouse SERVICE name in that compose file
CLICKHOUSE_PORT=8123                   # the CONTAINER-internal port, not a remapped host port
EXTERNAL_CH_NETWORK=clickathon_default
```

**ClickHouse is a native install on this same machine** (not in Docker):

```ini
CLICKHOUSE_HOST=host.docker.internal
CLICKHOUSE_PORT=8123
```

**ClickHouse is remote** (another host, ClickHouse Cloud):

```ini
CLICKHOUSE_HOST=your-instance.clickhouse.cloud
CLICKHOUSE_PORT=8443
CLICKHOUSE_SECURE=true
```

Then:

```bash
make -f Makefile.portable secrets   # generates the 4 LibreChat secrets, once
make -f Makefile.portable up
make -f Makefile.portable verify    # confirms the MCP server can actually reach your data
```

`verify` matters more than it looks — it's the fastest way to tell "my
ClickHouse connection is wrong" apart from "LibreChat's tool-calling is
broken", which look identical from the chat UI (both just fail silently or
return an error the model has to interpret).

## Using it

1. Open the URL `make -f Makefile.portable up` prints (default
   `http://localhost:3081` — deliberately not 3080, so this can run
   alongside the full stack's LibreChat without a port clash).
2. Register an account (registration is open, bound to localhost).
3. **Agents** icon → **New Agent** → pick a tool-calling model → enable both
   MCP servers (`clickhouse-sql`, `sonyliv-concurrency`) in the tool picker.
4. Ask it something: *"What was peak concurrency in the last 24 hours,
   broken down by platform?"*

If the model answers without an error but the numbers look implausible
(monotonically climbing, negative, wildly different at different grains),
run `make -f Makefile.portable verify` and `get_data_health` (one of the MCP
tools — ask the agent to call it) before doubting the LLM. See
`mcp/README.md` for the specific correctness properties that were verified
against known-good data.

## Coexisting with the full stack

Every container name, network name, volume name, and the LibreChat port are
suffixed/offset so `docker-compose.portable.yml` can run at the same time as
`docker-compose.yml` without collisions:

| | Full stack | Portable |
|---|---|---|
| LibreChat port | 3080 | 3081 |
| LibreChat container | `librechat` | `librechat-portable` |
| MCP containers | `mcp-*` | `mcp-*-portable` |
| Compose project | `clickathon` | `clickathon-portable` |

## Cleaning up

```bash
make -f Makefile.portable down       # stop, keep the mongo volume (chat history)
docker volume rm clickathon-portable_librechat_mongo_portable  # also wipe chat history
```
