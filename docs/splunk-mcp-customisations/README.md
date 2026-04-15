# Splunk MCP server — lab customisations

This folder documents how the **splunk-lab** Docker image relates to **Splunk’s upstream MCP server** and every deliberate change we maintain on top of it.

Upstream sources and behaviour change over time; treat this doc as the **operator’s map** of what we own vs what Splunk owns.

---

## Upstream source

| Item | Detail |
|------|--------|
| **Repository** | [github.com/splunk/splunk-mcp-server2](https://github.com/splunk/splunk-mcp-server2) |
| **How we consume it** | `mcp/Dockerfile` performs a **shallow git clone** of `splunk-mcp-server2` at build time, then installs npm dependencies under `/app/typescript`. |
| **Why clone instead of only `npm install splunk-mcp-server`?** | The Dockerfile comment notes the **published npm package** had a problem where the process **exited immediately in SSE mode**; building from the **source repo** was the reliable path. Re-verify if you change the upstream pin. |

We do **not** fork the whole repository in this lab repo. We **overlay** a small number of files on top of whatever commit `git clone --depth=1` last fetched.

---

## Files we replace (overlays)

Only these paths in this repo are copied into the cloned tree at image build time:

| Lab file | Upstream path after clone | Purpose |
|----------|---------------------------|---------|
| `mcp/server.ts` | `/app/typescript/server.ts` | MCP transports, session model, tool wiring, guardrails integration. |
| `mcp/splunkClient.ts` | `/app/typescript/splunkClient.ts` | HTTP client to Splunk REST (timeouts, TLS, auth). |

```15:18:mcp/Dockerfile
# Overlay upstream files with our local versions
COPY server.ts /app/typescript/server.ts
# splunkClient.ts: configurable axios timeout via SPLUNK_TIMEOUT_MS (default 120 s)
COPY splunkClient.ts /app/typescript/splunkClient.ts
```

Everything else in `/app/typescript` is **upstream as cloned** (helpers, SDK usage, etc.), until upstream restructures paths — **rebuild after upstream moves files**.

---

## Docker image build (`mcp/Dockerfile`)

| Customisation | Notes |
|---------------|--------|
| **Base image** | `node:20-alpine` |
| **Git** | `apk add git` — required only to clone upstream. |
| **Runtime command** | `npx ts-node server.ts` — **no separate `tsc` build step**; faster to maintain, slightly heavier cold start. |
| **Exposed port** | `8050` (Streamable HTTP MCP default in compose). |

---

## `server.ts` — behavioural customisations

These are the **lab-specific** behaviours worth knowing when diffing against upstream `server.ts`.

### 1. Default transport: Streamable HTTP (`http`)

- `TRANSPORT` defaults to **`http`** (see `config.transport`).
- Uses **`StreamableHTTPServerTransport`** from `@modelcontextprotocol/sdk` plus **Express** on `HOST` / `PORT` (compose: `0.0.0.0:8050`).
- Endpoints: **`POST /mcp`**, **`GET /mcp`**, **`DELETE /mcp`** for the MCP 2025-03-26 streamable HTTP pattern.

Claude Code 2.1+ and Claude Desktop 0.10.5+ connect to `http://localhost:8050/mcp` with `type: "http"` in config.

### 2. One `McpServer` instance per session (HTTP / SSE)

**Problem fixed (lab):** A single global `McpServer` shared across HTTP sessions caused each new client to **`connect()` a new transport** on the same server object, **replacing** the active transport and **dropping in-flight tool responses** → client-side **timeouts** while health checks still passed.

**Approach:** `createMcpServer()` wraps the entire `new McpServer(...)` plus all `server.tool` / `server.resource` registrations. It is invoked:

- **Once per new Streamable HTTP session** (new transport → new server → `connect`),
- **Once per SSE connection**,
- **Once for stdio** (single process).

**Tradeoff:** Each new session pays the cost of **re-registering all tools** in memory; acceptable for a local lab, worth monitoring under very high session churn.

### 3. HTTP session map and idle eviction

- `Map<string, StreamableHTTPServerTransport>` keyed by **MCP session id** (from headers / SDK).
- **TTL:** 10 minutes idle (`SESSION_TTL_MS`); eviction sweep every 5 minutes (`EVICTION_INTERVAL_MS`).
- Timer uses **`unref()`** so it does not keep the Node process alive by itself.

Upstream may differ; this is **lab session lifecycle** policy.

### 4. Shared Splunk client (global)

- **`splunkClient`** is still a **single global** `SplunkClient`, initialised once at startup (`initializeSplunkClient()`).
- Per-session isolation is **MCP protocol / transport** only, not separate Splunk HTTP pools per Claude session.

### 5. Environment-driven guardrails and limits

`config` reads (non-exhaustive; see `server.ts` for full list):

| Variable | Role |
|----------|------|
| `SPL_MAX_EVENTS_COUNT` / `MAX_EVENTS_COUNT` | Cap results for tools. |
| `SPL_RISK_TOLERANCE` | Risk score threshold for SPL validation. |
| `SPL_SAFE_TIMERANGE` | Default safe window for risk checks. |
| `SPL_SANITIZE_OUTPUT` | Output sanitisation toggle. |
| `SERVER_NAME`, `SERVER_DESCRIPTION`, `LOG_LEVEL` | Branding / logging. |

Risk / guardrail helpers live in `./guardrails` (upstream tree); our `server.ts` wires **defaults** from env.

### 6. Stdio mode

When `TRANSPORT=stdio`, console methods are **no-op**’d to avoid corrupting stdio MCP framing.

---

## `splunkClient.ts` — behavioural customisations

| Customisation | Detail |
|---------------|--------|
| **`SPLUNK_TIMEOUT_MS`** | Axios timeout for Splunk REST calls (default **120000** ms). Tuned via `.env` in `docker-compose.yml` passthrough. |
| **TLS** | `https.Agent({ rejectUnauthorized: verify_ssl })` — lab compose sets **`VERIFY_SSL=false`** for Splunk’s self-signed cert. |
| **Auth** | Splunk session token header **or** basic username/password (from compose env). |

Any other diff vs upstream in this file should be called out here when you merge upstream updates.

---

## `docker-compose.yml` wiring (runtime contract)

The **splunk-mcp** service passes (among others):

- `TRANSPORT=http`, `HOST=0.0.0.0`, `PORT=8050`
- `SPLUNK_HOST=splunk`, `SPLUNK_PORT=8089`, `SPLUNK_USERNAME`, `SPLUNK_PASSWORD`
- `VERIFY_SSL=false`, `NODE_TLS_REJECT_UNAUTHORIZED=0` (Node TLS to Splunk)

Ports are **`127.0.0.1:8050:8050`** on the host — MCP is **not** exposed beyond localhost by default.

**Note:** `depends_on` uses **`service_started`** for Splunk, not **`service_healthy`**. The MCP container can start before Splunk REST is ready; first tool calls may fail until Splunk finishes booting.

---

## Refreshing or auditing against upstream

1. Clone Splunk’s repo at the same depth as the Dockerfile (or pin a commit in the Dockerfile for reproducibility — today it is **floating `main`** of `splunk-mcp-server2`).
2. Diff our overlays:
   ```bash
   diff -u /path/to/splunk-mcp-server2/typescript/server.ts mcp/server.ts | less
   diff -u /path/to/splunk-mcp-server2/typescript/splunkClient.ts mcp/splunkClient.ts | less
   ```
3. Rebuild: `docker compose build splunk-mcp` and run integration tests / manual Claude smoke tests.

If upstream **renames** `typescript/` or entrypoints, update **`mcp/Dockerfile`** and this document.

---

## Related project docs

- Root **`README.md`** — MCP Integration (Claude Code / Desktop config).
- **`CLAUDE.md`** — Architecture, env tuning (`SPLUNK_TIMEOUT_MS`, Buttercup time ranges for MCP tools).

---

## Changelog (high level)

| When / PR | Change |
|-----------|--------|
| Streamable HTTP | Switched MCP transport to HTTP + streamable handler (`POST` `/mcp`). |
| Session TTL | Idle eviction for HTTP transports to avoid unbounded session growth. |
| Per-session `McpServer` (#74) | `createMcpServer()` per HTTP/SSE session to prevent transport clobbering and client timeouts. |
| `splunkClient` overlay | `SPLUNK_TIMEOUT_MS` and TLS/auth behaviour for the lab Splunk image. |

*(Add rows when you land further overlay changes.)*
