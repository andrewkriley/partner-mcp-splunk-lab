# OpenTelemetry Demo + Splunk Lab

This folder wires the **[OpenTelemetry Astronomy Shop demo](https://github.com/open-telemetry/opentelemetry-demo)** into the Splunk lab: the demo’s **otel-collector** forwards **traces, metrics, and logs** to Splunk **HTTP Event Collector (HEC)** into the **`otel`** index.

The demo itself is **not** vendored here. Clone it next to this repo or anywhere on disk, pinned to a release that matches the collector snippet below.

## Supported demo version

| Demo tag | Notes |
|----------|--------|
| **2.1.3** | Validated against `src/otel-collector/otelcol-config.yml` pipelines in that tag. When you upgrade the demo, diff that file against `otelcol-config-splunk-hec.yml` and align `receivers` / `processors` / `exporters` lists. |

## Prerequisites

- Splunk lab running with the **bridge** overlay so Splunk joins `splunk-lab-otel` (see below).
- Same **`SPLUNK_HEC_TOKEN`** in the lab `.env` as Splunk was started with (see `.env.example`).
- Docker resources per the [upstream demo docs](https://opentelemetry.io/docs/demo/docker-deployment/) (roughly **6 GB RAM** for the full stack).

## Quick start

**1. Create the shared Docker network** (once):

```bash
docker network create splunk-lab-otel
```

**2. Start the Splunk lab on that network**

From the **splunk-lab repo root**:

```bash
docker compose -f docker-compose.yml -f docker-compose.otel-bridge.yml up -d
```

**3. Clone the OpenTelemetry Demo** (pinned):

```bash
git clone --branch 2.1.3 --depth 1 https://github.com/open-telemetry/opentelemetry-demo.git
cd opentelemetry-demo
```

**4. Start the demo with Splunk export**

From **splunk-lab** repo root (adjust path to your clone):

```bash
chmod +x otel-demo/start-with-splunk.sh
OTEL_DEMO_DIR=/path/to/opentelemetry-demo ./otel-demo/start-with-splunk.sh
```

Or manually:

```bash
export OTEL_COLLECTOR_CONFIG_EXTRAS=/absolute/path/to/splunk-lab/otel-demo/otelcol-config-splunk-hec.yml
cd /path/to/opentelemetry-demo
docker compose \
  -f docker-compose.yml \
  -f /absolute/path/to/splunk-lab/otel-demo/docker-compose.docker-bridge.yml \
  --env-file /absolute/path/to/splunk-lab/.env \
  up -d
```

## Splunk searches

After traffic runs (browse the storefront at **http://localhost:8080** or wait for the load generator):

```spl
index=otel | head 20
```

Traces and JSON-heavy fields are easiest to inspect in **Verbose** or **Raw** mode.

## Files

| File | Purpose |
|------|---------|
| `otelcol-config-splunk-hec.yml` | Second collector config: adds `splunk_hec` exporter and extends pipelines. |
| `docker-compose.docker-bridge.yml` | Demo override: `otel-collector` joins `splunk-lab-otel`, sets `SPLUNK_HEC_URL`. |
| `start-with-splunk.sh` | Creates network if needed, starts lab with bridge, starts demo with overrides. |

## Troubleshooting

- **`Connection refused` to `splunk:8088`** — Splunk was not started with `docker-compose.otel-bridge.yml`, or the `splunk-lab-otel` network does not exist.
- **401 from HEC** — Token in `.env` does not match the token Splunk was bootstrapped with; fix `.env` and restart Splunk, or align the token in Splunk’s HEC settings.
- **No events in `otel`** — Confirm the collector started: `docker logs otel-collector`. After upgrading the demo, re-check pipeline names in `otelcol-config-splunk-hec.yml` against upstream `otelcol-config.yml`.
