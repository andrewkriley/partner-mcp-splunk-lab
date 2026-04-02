# AGENTS.md

## Cursor Cloud specific instructions

### Architecture overview

This is a Docker Compose lab with 5 services: Splunk Enterprise, Splunk MCP Server, Lab Guide (nginx), Status API, and Ask Splunk Chat. See `CLAUDE.md` for full architecture details and common commands.

### Cloud VM cgroup v2 workarounds

The Cloud Agent VM runs inside a Firecracker micro-VM whose cgroup v2 hierarchy does **not** delegate the `memory` controller to child cgroups. This causes two issues:

1. **Splunk 10.x crashes** — `splunkd` calls `ContainerInfo::available_memory_size_in_bytes()` which aborts when `/sys/fs/cgroup/memory.max` is missing. **Use Splunk 9.2** (`splunk/splunk:9.2`) instead of the default `splunk/splunk:10.2.1`.
2. **Docker `deploy.resources.limits.memory` fails** — container creation errors with "cannot enter cgroupv2 … with domain controllers". Remove all `deploy` resource limits.
3. **Splunk `validatedb` fails on overlay filesystems** — Splunk's database validation rejects fuse-overlayfs and overlay2. **Mount an ext4 loopback image** as a bind mount for `/opt/splunk/var`.
4. **Splunk needs ≥5 GB free disk** for its dispatch directory. Create the ext4 image with at least 8 GB.

A pre-built `docker-compose.cloud.yml` applies all these workarounds. Always use it in the Cloud VM:

```bash
docker compose -f docker-compose.cloud.yml up -d --build
```

### Starting the stack in Cloud VM

```bash
# 1. Ensure dockerd is running (update script handles this)
# 2. Mount the ext4 loopback if not already mounted
if ! mountpoint -q /workspace/.splunk-var; then
  dd if=/dev/zero of=/tmp/splunk-data.img bs=1M count=8192 2>/dev/null
  mkfs.ext4 -q /tmp/splunk-data.img
  mkdir -p /workspace/.splunk-var
  sudo mount -o loop /tmp/splunk-data.img /workspace/.splunk-var
  sudo chown -R 41812:41812 /workspace/.splunk-var
fi
# 3. Start all services
sg docker -c "docker compose -f docker-compose.cloud.yml up -d --build"
# 4. Wait ~20s for Splunk, then verify
curl -sf http://localhost:8000/en-US/account/login > /dev/null && echo "Splunk ready"
```

### Running tests

```bash
.venv/bin/python3 -m pytest tests/ -v
```

27 tests total: 15 existing infrastructure tests + 12 MCP protocol tests.

The `buttercup_ready` fixture polls for up to 600 seconds waiting for data indexing. First run after a fresh `docker compose up` takes ~20-60s for data to be searchable.

### MCP protocol gotchas

- **`SPLUNK_HOST` must be hostname-only** (e.g. `splunk`), not a full URL. The upstream `SplunkClient` prepends `https://` itself. Setting `SPLUNK_HOST=https://splunk` produces the broken URL `https://https://splunk:8089` and all MCP→Splunk tool calls silently fail.
- **Do not prefix MCP `search_oneshot` queries with `search`** — the MCP server prepends it. `search search index=...` returns 0 results.
- **MCP tests use `mcp_connect()` context manager** (not a pytest fixture) because the MCP SDK's anyio task groups cannot be torn down in a different asyncio task, which pytest-asyncio fixtures do.

### Key ports (all localhost-only)

| Port | Service |
|------|---------|
| 3000 | Ask Splunk Chat UI |
| 3131 | Lab Guide |
| 8000 | Splunk Web UI |
| 8050 | MCP SSE endpoint |
| 8088 | HEC (HTTPS) |
| 8089 | Splunk REST API (HTTPS) |

### Credentials

Default from `.env.example`: `admin` / `Chang3d!`, HEC token `a8b4c2d6-e0f1-4321-9876-abcdef012345`.

### Ask Splunk Chat

The chat service at `:3000` requires `ANTHROPIC_API_KEY` in `.env`. Without it, the container starts but shows a setup prompt. The chat backend connects to the MCP server over SSE, discovers tools, and bridges Claude with Splunk. Configured to use `claude-haiku-4-20250414` by default (override with `CHAT_MODEL` env var).

### Docker access

The `ubuntu` user is in the `docker` group but the session may not have picked it up. Use `sg docker -c "..."` to run Docker commands without `newgrp`.
