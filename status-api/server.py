#!/usr/bin/env python3
"""Status API — exposes GET /api/status as JSON for the lab-guide dashboard."""

import json
import re
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

import docker
import requests
import urllib3

urllib3.disable_warnings()

CORE_CONTAINERS = ["splunk", "splunk-mcp", "lab-guide", "status-api"]

HTTP_CHECKS = [
    {"name": "Splunk Web", "url": "http://splunk:8000/en-US/account/login", "stream": False},
    {"name": "Splunk MCP", "url": "http://splunk-mcp:8050/sse",             "stream": True},
]

OTEL_CHECKS = [
    {"name": "OTEL Collector", "container": "otel-collector", "url": "http://otel-collector:4318"},
    {"name": "Jaeger",         "container": "jaeger",         "url": "http://jaeger:16686"},
    {"name": "Prometheus",     "container": "prometheus",     "url": "http://prometheus:9090"},
    {"name": "Grafana",        "container": "grafana",        "url": "http://grafana:3000"},
]


def _parse_started(ts):
    """Parse Docker StartedAt timestamp (may contain nanoseconds) into a datetime."""
    if not ts or ts.startswith("0001"):
        return None
    # Truncate sub-microsecond precision, normalise timezone
    clean = re.sub(r'(\.\d{6})\d*', r'\1', ts).replace('Z', '+00:00')
    try:
        return datetime.fromisoformat(clean)
    except Exception:
        return None


def _uptime(started_ts):
    dt = _parse_started(started_ts)
    if not dt:
        return None
    secs = int((datetime.now(timezone.utc) - dt).total_seconds())
    if secs < 0:
        return None
    h, rem = divmod(secs, 3600)
    m, s   = divmod(rem, 60)
    return f"{h}h {m}m" if h else f"{m}m {s}s"


def check_containers():
    try:
        client = docker.from_env()
    except Exception:
        return [{"name": n, "state": "error", "health": None, "uptime": None}
                for n in CORE_CONTAINERS]

    results = []
    for name in CORE_CONTAINERS:
        try:
            c     = client.containers.get(name)
            state = c.attrs["State"]
            health = state.get("Health", {}).get("Status") if "Health" in state else None
            results.append({
                "name":   name,
                "state":  state.get("Status", "unknown"),
                "health": health,
                "uptime": _uptime(state.get("StartedAt")),
            })
        except docker.errors.NotFound:
            results.append({"name": name, "state": "not_found", "health": None, "uptime": None})
        except Exception:
            results.append({"name": name, "state": "error",     "health": None, "uptime": None})
    return results


def check_services():
    results = []
    for svc in HTTP_CHECKS:
        t0 = time.time()
        try:
            resp = requests.get(svc["url"], timeout=3, verify=False, stream=svc["stream"])
            if svc["stream"]:
                resp.close()
            latency = int((time.time() - t0) * 1000)
            results.append({
                "name":        svc["name"],
                "status":      "ok" if resp.status_code < 400 else "degraded",
                "latency_ms":  latency,
                "http_status": resp.status_code,
            })
        except Exception:
            results.append({"name": svc["name"], "status": "down", "latency_ms": None})
    return results


def check_otel():
    try:
        client  = docker.from_env()
        running = {c.name for c in client.containers.list()}
    except Exception:
        running = set()

    results = []
    for svc in OTEL_CHECKS:
        if svc["container"] not in running:
            results.append({"name": svc["name"], "status": "not_configured"})
            continue
        t0 = time.time()
        try:
            resp = requests.get(svc["url"], timeout=3, verify=False)
            resp.close()
            results.append({
                "name":       svc["name"],
                "status":     "ok",
                "latency_ms": int((time.time() - t0) * 1000),
            })
        except Exception:
            results.append({"name": svc["name"], "status": "down", "latency_ms": None})
    return results


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # suppress access logs

    def do_GET(self):
        if self.path == "/api/status":
            data = {
                "timestamp":  datetime.now(timezone.utc).isoformat(),
                "containers": check_containers(),
                "services":   check_services(),
                "otel":       check_otel(),
            }
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type",   "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8081), Handler)
    print("Status API running on :8081", flush=True)
    server.serve_forever()
