# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Pre-push hook

A pre-push hook blocks pushes until integration tests pass. Install it once after cloning:

```bash
cp hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

The hook starts the stack automatically if it's not running, runs `pytest tests/ -v`, then tears it down. If the stack is already up, it runs tests against it and leaves it running.

## Common commands

```bash
# Start the lab
docker compose up -d

# Watch Splunk startup (ready when "Ansible playbook complete" appears)
docker compose logs -f splunk

# Stop containers (data preserved)
docker compose down

# Full reset — wipe all indexed data
docker compose down -v

# Rebuild the MCP server image after changes to mcp/Dockerfile
docker compose build splunk-mcp

# Rebuild the status-api image after changes to status-api/
docker compose build status-api

# Check container health
docker compose ps
```

## Architecture

Five services run in Docker Compose:

- **splunk** (`splunk/splunk:10.2.1`) — Splunk Enterprise. All ports bound to `127.0.0.1`. Data persisted in the `splunk-var` named volume. The `buttercup_app/` directory is bind-mounted into `/opt/splunk/etc/apps/buttercup_app` and auto-indexed on first boot.

- **splunk-mcp** (built from `mcp/Dockerfile`) — Official Splunk MCP server (`splunk-mcp-server` npm package). Runs in **Streamable HTTP mode** on `127.0.0.1:8050/mcp`. Connects to Splunk via internal Docker networking on `splunk:8089`. No MCP endpoint auth — localhost-only by design. `mcp/server.ts` is our local overlay of the upstream `server.ts`, adding the `http` transport branch.

- **lab-guide** (`nginx:alpine`) — Lab guide served at `127.0.0.1:${LAB_GUIDE_PORT}` (default `3131`). Mounts `lab-guide/` as the web root and `lab-guide/nginx.conf` as the nginx config. Proxies `/api/status` to `status-api:8081` and `/ask/api/*` to `chat:3000/api/*` so Ask Splunk shares the same origin as the guide (embedded at `/ask/`).

- **status-api** (built from `status-api/Dockerfile`) — Python sidecar that exposes `GET /api/status` on port 8081 (internal only). Uses the Docker SDK via a read-only `docker.sock` mount to check container states and probes Splunk Web and MCP HTTP endpoints for service health.

- **chat** (built from `chat/Dockerfile`) — Ask Splunk FastAPI backend (internal port 3000 only). Bridges the Anthropic Messages API with the MCP server for the Chat tab; Explore Tools uses MCP only. Requires `ANTHROPIC_API_KEY` in `.env` for Chat. Gracefully degrades without it. The browser loads the UI from `lab-guide/ask/index.html` (static) under `/ask/`; API calls go to `/ask/api/*`.

## Buttercup app

`buttercup_app/` is a minimal Splunk app that auto-ingests sample data:

- `default/inputs.conf` — `monitor://` stanzas that tell Splunk to watch the `data/` directory
- `default/props.conf` — CSV parsing config for the two CSV sourcetypes
- `data/` — the actual sample files (`buttercup_access.txt`, `vendor_sales.csv`, `products.csv`)

Data lands in the `buttercup` index under sourcetypes `buttercup_web`, `buttercup_sales`, and `buttercup_products`.

**Searching in Splunk Web:** Buttercup events use **January 2025** timestamps. Splunk Search defaults to a short recent window (for example **Last 24 hours**), which often returns **no rows** outside that window. Use **All time** in the time picker, or add `earliest=0 latest=now` to SPL after `index=buttercup` (see README and lab guide examples).

## Environment variables

All runtime config lives in `.env` (gitignored). See `.env.example` for the full reference. The only required variable is `SPLUNK_PASSWORD`. `SPLUNK_HEC_TOKEN` pre-sets the HEC token so it's known before boot.

## MCP integration

The project ships **`.mcp.json`** at the repo root for the **Claude Code CLI** (project-scoped MCP). It also ships **`.claude/settings.json`** with the same `mcpServers` entry for other Claude clients that read that path.

The MCP server uses the **Streamable HTTP transport** (MCP spec 2025-03-26). This is a stateful POST endpoint — no persistent SSE connection, no proxy process needed. Claude Code 2.1+ connects to it directly.

**Claude Code CLI** — committed **`.mcp.json`** (also writable via `claude mcp add -s project …`):
```json
{
  "mcpServers": {
    "splunk-lab-guide": {
      "type": "http",
      "url": "http://localhost:8050/mcp"
    }
  }
}
```

**Claude Desktop** — one-time manual edit to the machine-local config:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "splunk-lab-guide": {
      "type": "http",
      "url": "http://localhost:8050/mcp"
    }
  }
}
```

Restart Claude Desktop after editing.

## Searching via MCP

The MCP server is registered as **`splunk-lab-guide`** — always use the MCP tools; do not fall back to `curl` against Splunk's REST API.

### Buttercup time range
Buttercup events use **January 2025** timestamps. The `search_oneshot` and `search_export` tools default to `earliest_time: -24h`, which returns **zero results**. Always pass an explicit range:

| Goal | `earliest_time` value |
|---|---|
| All Buttercup data | `-2y` |
| January 2025 only | `2025-01-01T00:00:00.000+0000` |
| Last two years | `-2y` |

### Choosing the right search tool
- **`search_oneshot`** — synchronous; Splunk holds the HTTP connection open until the search finishes. Use for small, bounded queries with `| head N` or tight time ranges.
- **`search_export`** — streaming; more resilient for aggregations (`stats`, `timechart`, `chart`) or when expecting >100 rows.

### Writing fast SPL for Buttercup
- Always scope by sourcetype — don't scan the whole index:
  - `sourcetype=buttercup_web` — web access logs (clientip, uri, status, bytes)
  - `sourcetype=buttercup_sales` — order transactions (product_name, categoryId, sale_price, quantity)
  - `sourcetype=buttercup_products` — product catalogue (productId, product_name, category)
- Add `| head 50` to cap raw event returns
- Add `| table field1 field2 ...` to drop unused fields before the result is returned
- Use `output_format: markdown` for readable output, `csv` for tabular data

### Example patterns
```spl
# Raw sales rows — all time
index=buttercup sourcetype=buttercup_sales earliest=-2y | head 20

# Revenue by product (use search_export for aggregations)
index=buttercup sourcetype=buttercup_sales earliest=-2y
| stats sum(sale_price) as revenue by product_name
| sort -revenue

# Top pages by traffic
index=buttercup sourcetype=buttercup_web earliest=-2y
| stats count by uri | sort -count | head 10
```

### Tuning timeouts and result limits
`search_oneshot` has a configurable axios timeout (default 120 s). For unusually slow queries, set `SPLUNK_TIMEOUT_MS` in `.env`. To cap result size for faster interactive responses, set `SPL_MAX_EVENTS_COUNT=1000` (default is 100 000).

## Known gotchas

- **Do not name data files with a `.log` extension.** The Splunk Docker image silently blocks all `.log` files under `/opt/splunk/etc/` from being monitored — they never appear in `splunk list monitor` and are never indexed. Use `.txt`, `.csv`, or any other extension instead.

## GitHub token scopes

The `gh` CLI is used throughout this repo for PRs, branch protection, CI checks, and triggering workflows. The personal access token needs these scopes:

| Scope | Required for |
|---|---|
| `repo` | Push/pull, branch protection rules, PRs, issues |
| `workflow` | Triggering `workflow_dispatch` (e.g. manual GitHub Pages deploy) |
| `read:org` | `gh pr` and `gh run` commands |

To update scopes: **GitHub → Settings → Developer settings → Personal access tokens**.

To manually trigger a Pages redeploy (e.g. after workflow changes that didn't touch `lab-guide/`):

```bash
gh workflow run deploy-pages.yml --ref main
```

## Security posture

This lab is intentionally insecure for local demo use:
- All ports are `127.0.0.1`-only
- MCP endpoint has no authentication
- `VERIFY_SSL=false` on the MCP→Splunk connection

Do not change port bindings to `0.0.0.0` without adding authentication.
