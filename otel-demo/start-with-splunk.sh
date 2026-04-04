#!/usr/bin/env bash
# Start the official OpenTelemetry Demo with the collector forwarding MELT to this Splunk lab via HEC.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEMO_DIR="${OTEL_DEMO_DIR:-${1:-}}"

if [[ -z "$DEMO_DIR" || ! -f "$DEMO_DIR/docker-compose.yml" ]]; then
  echo "Usage: OTEL_DEMO_DIR=/path/to/opentelemetry-demo $0"
  echo "   or: $0 /path/to/opentelemetry-demo"
  echo ""
  echo "Clone the demo first, pinned to a supported release (see otel-demo/README.md)."
  exit 1
fi

ENV_FILE="$LAB_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — copy .env.example and set SPLUNK_PASSWORD and SPLUNK_HEC_TOKEN."
  exit 1
fi

if ! grep -qE '^SPLUNK_HEC_TOKEN=.+$' "$ENV_FILE" 2>/dev/null; then
  echo "SPLUNK_HEC_TOKEN must be set in .env (non-empty)."
  exit 1
fi

NETWORK_NAME="${SPLUNK_OTEL_NETWORK:-splunk-lab-otel}"
docker network inspect "$NETWORK_NAME" &>/dev/null || docker network create "$NETWORK_NAME"

echo "==> Ensuring Splunk lab is on bridge network $NETWORK_NAME"
(
  cd "$LAB_ROOT"
  docker compose -f docker-compose.yml -f docker-compose.otel-bridge.yml --env-file "$ENV_FILE" up -d
)

export OTEL_COLLECTOR_CONFIG_EXTRAS="$SCRIPT_DIR/otelcol-config-splunk-hec.yml"

echo "==> Starting OpenTelemetry Demo from $DEMO_DIR"
cd "$DEMO_DIR"
docker compose \
  -f docker-compose.yml \
  -f "$SCRIPT_DIR/docker-compose.docker-bridge.yml" \
  --env-file "$ENV_FILE" \
  up -d

echo ""
echo "Demo frontend (Envoy) is usually http://localhost:8080"
echo "Splunk HEC index: otel — try: index=otel | head 20"
