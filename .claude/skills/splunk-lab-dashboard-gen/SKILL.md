---
name: splunk-lab-dashboard-gen
description: Generates a Splunk Dashboard Studio dashboard with an AI-generated background image, then deploys it live to Splunk. Runs SPL against the local lab stack via the splunk-lab-guide MCP, synthesises a thematic image prompt, generates a background image via HuggingFace, builds the Dashboard Studio JSON, deploys it via the Splunk REST API, and returns the live dashboard link. Use when the user says "generate a dashboard", "create a splunk dashboard", or "make a dashboard from a query".
argument-hint: [optional: dashboard title or theme]
---

You are generating a Splunk Dashboard Studio dashboard with an AI-generated background image and deploying it live to the local Splunk lab instance.

## Step 1 — Collect inputs

Ask the user for the following (all three are required). Ask in a single message:

1. **Splunk index** — which index to query (e.g. `buttercup`, `main`, `*`)
2. **SPL statement** — the search/stats/chart command to run against that index (e.g. `stats count by sourcetype`, `timechart count by status`)
3. **Dashboard title** — a short name for the dashboard (e.g. "Buttercup Web Traffic")

If `$ARGUMENTS` is provided, use it as the dashboard title and skip asking for it separately.

Do not proceed until all three are provided.

## Step 2 — Run the Splunk query

Construct the full SPL as: `index=<index> <spl_statement>`

Use the `mcp__splunk-lab-guide__search_oneshot` tool:
- `query`: the full SPL above
- `earliest_time`: `-2y`  ← Buttercup sample data is dated January 2025; -24h returns nothing
- `latest_time`: `now`
- `max_count`: 50
- `output_format`: `json`

Analyse the results. Note:
- What data domain this covers (e.g. web traffic, sales, product catalogue)
- Key fields returned (e.g. `status`, `uri`, `vendor`, `revenue`, `count`)
- Any patterns, spikes, or interesting distributions
- Volume and time range of events

This analysis drives both the image prompt and the dashboard panels.

If the search returns zero events, remind the user that Buttercup data uses January 2025 timestamps and suggest `earliest_time: "-2y"` is already set — check the index name and SPL are correct before proceeding.

## Step 3 — Craft the image generation prompt

Based on the query results analysis, write a vivid image generation prompt. Requirements:
- **Dark, clean background** — must work as a dashboard wallpaper without competing with charts and text
- **Avoid complexity** — no circuit board traces, no text or labels, no holographic grids, no busy patterns, no lines overlaid on the image. The image should feel calm and spacious.
- **Solid or photographic** — prefer real-world photography styles: dark server room ambiance, dramatic landscape, deep ocean, night sky, abstract smooth gradients, macro textures (dark metal, carbon fibre, brushed steel)
- **Domain-relevant** — loosely reflect the data domain through subject matter or colour palette (e.g. for web traffic: dark abstract network blur; for sales: warm bokeh retail ambiance; for products: dark studio product photography)
- **Cinematic quality** — wide depth of field, soft focus background, dramatic but subtle lighting
- Keep under 70 words (model limit)

Example prompt: *"Dark empty server room corridor, dramatic low lighting with subtle blue ambient glow, shallow depth of field, smooth dark floor reflections, cinematic wide angle, 4K professional photography, no text, no overlays"*

## Step 4 — Generate the background image

Use the `mcp__huggingface__gr1_z_image_turbo_generate` tool with:
- `prompt`: the prompt from Step 3
- `resolution`: `"1536x864 ( 16:9 )"` (landscape, best for dashboard backgrounds)
- `random_seed`: `true`
- `steps`: `8`

The HuggingFace MCP must be connected in Claude Code with a valid API token. The project’s `.claude/env.sh` (gitignored) should define `export HF_TOKEN=...` — when Bash steps source that file (see Step 6), the token is available to any CLI tooling in the same shell.

The tool will return an image URL. Create the output directory and download the image using the Bash tool:

```bash
mkdir -p "$HOME/dev/claude-created-dashboards/<slug>"
curl -sL "<image_url>" -o "$HOME/dev/claude-created-dashboards/<slug>/background.png"
```

Where `<slug>` is a lowercase, hyphenated version of the dashboard title (e.g. "Buttercup Web Traffic" → `buttercup-web-traffic`). Dashboards are saved under `$HOME/dev/claude-created-dashboards/<slug>` (not inside the repo).

The `<splunk_id>` is the slug with hyphens replaced by underscores (e.g. `buttercup_web_traffic`). This is used as the Splunk view name.

## Step 5 — Build the Dashboard Studio JSON

Analyse the Splunk query results from Step 2 to determine the best visualisation types. Design multiple panels where the data supports it:
- `timechart` or time-series results → `splunk.line` or `splunk.area`
- `stats count by <field>` → `splunk.bar` or `splunk.pie`
- Raw events / `table` → `splunk.events` or `splunk.table`
- Single value / `stats count` → `splunk.singlevalue`

Encode the background image as base64 and embed it using the Bash tool:

```bash
base64 -i "$HOME/dev/claude-created-dashboards/<slug>/background.png"
```

Build the dashboard JSON using the Dashboard Studio structure below. Embed the base64 image as `"data:image/png;base64,<base64_string>"` in the `backgroundImage.src` field.

```json
{
  "visualizations": {
    "viz_1": {
      "type": "<splunk.bar|splunk.pie|splunk.line|splunk.table|splunk.singlevalue>",
      "dataSources": { "primary": "ds_1" },
      "title": "<descriptive panel title>",
      "options": {
        "seriesColors": ["#00b4d8", "#f77f00", "#9b5de5", "#06d6a0", "#ef233c"]
      }
    }
  },
  "dataSources": {
    "ds_1": {
      "type": "ds.search",
      "options": {
        "query": "index=<index> <spl_statement>",
        "queryParameters": {
          "earliest": "-2y",
          "latest": "now"
        }
      }
    }
  },
  "inputs": {},
  "layout": {
    "type": "absolute",
    "options": {
      "width": 1440,
      "height": 960,
      "backgroundImage": {
        "sizeType": "cover",
        "src": "data:image/png;base64,<base64_string>"
      }
    },
    "structure": [
      {
        "item": "viz_1",
        "type": "block",
        "position": { "x": 60, "y": 80, "w": 1320, "h": 480 },
        "options": { "backgroundColor": "transparent" }
      }
    ],
    "globalInputs": []
  },
  "title": "<dashboard title>",
  "description": "Generated by Claude from index=<index> | <spl_statement>"
}
```

Every item in `layout.structure` must include `"options": { "backgroundColor": "transparent" }` so panels show the background image rather than the default opaque panel colour.

Use the Write tool to save the final JSON to `$HOME/dev/claude-created-dashboards/<slug>/dashboard.json`.

## Step 6 — Deploy to Splunk Dashboard Studio

The Splunk REST API (`/data/ui/views`) stores Dashboard Studio dashboards as XML with the JSON embedded in a `<definition><![CDATA[...]]></definition>` block.

All Bash in this step runs from the **splunk-lab repository root** (Claude Code project directory). Resolve it before sourcing credentials:

```bash
SPLUNK_LAB_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; [[ -z "$SPLUNK_LAB_ROOT" ]] && SPLUNK_LAB_ROOT="$PWD"
```

**Step 6a — Generate the XML wrapper** using the Bash tool:

```bash
python3 << 'PYEOF'
import os
slug = "<slug>"
title = "<dashboard title>"
json_path = os.path.expanduser(f"~/dev/claude-created-dashboards/{slug}/dashboard.json")
with open(json_path) as f:
    dashboard_json = f.read()
xml = f"""<dashboard version="2" theme="dark">
    <label>{title}</label>
    <description>Generated by Claude</description>
    <definition><![CDATA[
{dashboard_json}
    ]]></definition>
</dashboard>"""
out = os.path.expanduser(f"~/dev/claude-created-dashboards/{slug}/dashboard_wrapped.xml")
with open(out, "w") as f:
    f.write(xml)
print(f"Written {len(xml)} chars to {out}")
PYEOF
```

**Step 6b — Resolve Splunk credentials** from `.claude/env.sh` in the repo (gitignored; copy from `env.sh.example` or run `./install.sh` and accept the skill prompt — install mints `SPLUNK_API_TOKEN` when Splunk is reachable):

```bash
SPLUNK_LAB_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; [[ -z "$SPLUNK_LAB_ROOT" ]] && SPLUNK_LAB_ROOT="$PWD"
source "$SPLUNK_LAB_ROOT/.claude/env.sh" 2>/dev/null || true
# Fall back to lab defaults if env.sh is not set up
SPLUNK_HOST="${SPLUNK_HOST:-localhost}"
SPLUNK_USER="${SPLUNK_USER:-admin}"
# Prefer Bearer when install.sh (or the user) set SPLUNK_API_TOKEN; else basic auth
if [[ -n "${SPLUNK_API_TOKEN:-}" ]]; then
  _AUTH=( -H "Authorization: Bearer ${SPLUNK_API_TOKEN}" )
else
  _AUTH=( -u "${SPLUNK_USER}:${SPLUNK_PASS}" )
fi
```

If neither `SPLUNK_API_TOKEN` nor `SPLUNK_PASS` is usable after sourcing, stop and instruct the user to create `.claude/env.sh` from `env.sh.example` at the repo root (`cp env.sh.example .claude/env.sh && chmod 600 .claude/env.sh`, then set `SPLUNK_PASS` to match `SPLUNK_PASSWORD` in `.env`, or run `./install.sh` to mint `SPLUNK_API_TOKEN` automatically).

**Step 6c — Check if the dashboard already exists:**

```bash
SPLUNK_LAB_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; [[ -z "$SPLUNK_LAB_ROOT" ]] && SPLUNK_LAB_ROOT="$PWD"
source "$SPLUNK_LAB_ROOT/.claude/env.sh" 2>/dev/null || true
SPLUNK_HOST="${SPLUNK_HOST:-localhost}"
SPLUNK_USER="${SPLUNK_USER:-admin}"
if [[ -n "${SPLUNK_API_TOKEN:-}" ]]; then
  _AUTH=( -H "Authorization: Bearer ${SPLUNK_API_TOKEN}" )
else
  _AUTH=( -u "${SPLUNK_USER}:${SPLUNK_PASS}" )
fi
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
  "${_AUTH[@]}" \
  "https://$SPLUNK_HOST:8089/servicesNS/admin/search/data/ui/views/<splunk_id>")
echo $STATUS
```

**If STATUS is 200 (update existing):**

```bash
SPLUNK_LAB_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; [[ -z "$SPLUNK_LAB_ROOT" ]] && SPLUNK_LAB_ROOT="$PWD"
source "$SPLUNK_LAB_ROOT/.claude/env.sh" 2>/dev/null || true
SPLUNK_HOST="${SPLUNK_HOST:-localhost}"
SPLUNK_USER="${SPLUNK_USER:-admin}"
if [[ -n "${SPLUNK_API_TOKEN:-}" ]]; then
  _AUTH=( -H "Authorization: Bearer ${SPLUNK_API_TOKEN}" )
else
  _AUTH=( -u "${SPLUNK_USER}:${SPLUNK_PASS}" )
fi
curl -sk -X POST \
  "${_AUTH[@]}" \
  "https://$SPLUNK_HOST:8089/servicesNS/admin/search/data/ui/views/<splunk_id>" \
  --data-urlencode "eai:data@$HOME/dev/claude-created-dashboards/<slug>/dashboard_wrapped.xml" \
  -o /dev/null -w "HTTP %{http_code}"
```

**If STATUS is 404 (create new):**

```bash
SPLUNK_LAB_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; [[ -z "$SPLUNK_LAB_ROOT" ]] && SPLUNK_LAB_ROOT="$PWD"
source "$SPLUNK_LAB_ROOT/.claude/env.sh" 2>/dev/null || true
SPLUNK_HOST="${SPLUNK_HOST:-localhost}"
SPLUNK_USER="${SPLUNK_USER:-admin}"
if [[ -n "${SPLUNK_API_TOKEN:-}" ]]; then
  _AUTH=( -H "Authorization: Bearer ${SPLUNK_API_TOKEN}" )
else
  _AUTH=( -u "${SPLUNK_USER}:${SPLUNK_PASS}" )
fi
curl -sk -X POST \
  "${_AUTH[@]}" \
  "https://$SPLUNK_HOST:8089/servicesNS/admin/search/data/ui/views" \
  -d "name=<splunk_id>" \
  --data-urlencode "eai:data@$HOME/dev/claude-created-dashboards/<slug>/dashboard_wrapped.xml" \
  -o /dev/null -w "HTTP %{http_code}"
```

A response of `HTTP 200` or `HTTP 201` confirms successful deployment. If the API returns an error, report the HTTP status and response body to the user and stop — do not retry without user input.

## Step 7 — Report to the user

Tell the user:

```
Dashboard deployed: <dashboard title>

Live dashboard: http://localhost:8000/en-US/app/search/<splunk_id>

Local files:
  Image:     ~/dev/claude-created-dashboards/<slug>/background.png
  Dashboard: ~/dev/claude-created-dashboards/<slug>/dashboard.json
```
