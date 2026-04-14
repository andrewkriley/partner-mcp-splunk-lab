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

- **splunk-mcp** (built from `mcp/Dockerfile`) — Official Splunk MCP server (`splunk-mcp-server` npm package). Runs in SSE mode on `127.0.0.1:8050`. Connects to Splunk via internal Docker networking on `splunk:8089`. No MCP endpoint auth — localhost-only by design.

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

The project ships `.claude/settings.json` with the MCP server pre-configured for Claude Code — no `claude mcp add` required.

**Why mcp-remote instead of `--transport sse`:**
`claude mcp add --transport sse` requires an HTTPS endpoint. The lab MCP server serves plain HTTP on `localhost:8050`. Using `mcp-remote` as a stdio proxy avoids this — Claude Code communicates with it over stdio, and it forwards requests to `localhost:8050` over HTTP with no SSL involved.

**Claude Code** — automatic via `.claude/settings.json` (committed in this repo):
```json
{
  "mcpServers": {
    "splunk-lab-guide": {
      "command": "npx",
      "args": ["-y", "mcp-remote@0.1.38", "http://localhost:8050/sse"]
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
      "command": "npx",
      "args": ["-y", "mcp-remote@0.1.38", "http://localhost:8050/sse"]
    }
  }
}
```

Restart Claude Desktop after editing.

**Prerequisite:** Node.js must be installed on the host (for `npx`).

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
