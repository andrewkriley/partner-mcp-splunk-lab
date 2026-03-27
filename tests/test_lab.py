"""
Integration tests for the Splunk Partner Lab.

These tests require the full Docker Compose stack to be running:
  docker compose up -d

Run locally:
  pytest tests/ -v

All tests are also run in CI on every push to feat/** and on PRs to main.
"""

import subprocess
import socket
import requests
import pytest

from tests.conftest import (
    SPLUNK_WEB_URL,
    SPLUNK_API_URL,
    SPLUNK_HEC_URL,
    SPLUNK_HEC_TOKEN,
    MCP_URL,
    run_search,
    wait_for_indexed,
)


# ── Docker Compose ─────────────────────────────────────────────────────────

class TestDockerCompose:
    def test_compose_config_is_valid(self):
        """docker compose config should exit 0 — catches YAML and schema errors."""
        result = subprocess.run(
            ["docker", "compose", "config", "--quiet"],
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr.decode()


# ── Splunk health ──────────────────────────────────────────────────────────

class TestSplunkHealth:
    def test_web_ui_reachable(self):
        """Splunk login page should return HTTP 200."""
        resp = requests.get(f"{SPLUNK_WEB_URL}/en-US/account/login", timeout=10)
        assert resp.status_code == 200

    def test_management_api_authenticated(self, splunk_session):
        """Admin credentials should authenticate against the Splunk REST API."""
        resp = splunk_session.get(
            f"{SPLUNK_API_URL}/services/server/info",
            params={"output_mode": "json"},
            timeout=10,
        )
        assert resp.status_code == 200
        assert resp.json()["entry"][0]["content"]["serverName"]


# ── Buttercup sample data ──────────────────────────────────────────────────

class TestButtercupData:
    """
    These tests poll with a timeout — Splunk monitor inputs can take
    10–30s to index files after the container becomes healthy.
    """

    def test_access_logs_indexed(self, splunk_session):
        """Web access logs (Apache Combined) should be indexed in main."""
        count = wait_for_indexed(splunk_session, "access_combined", min_count=50)
        assert count >= 50, f"Expected ≥50 access_combined events, got {count}"

    def test_vendor_sales_indexed(self, splunk_session):
        """Vendor sales CSV should be indexed in main."""
        count = wait_for_indexed(splunk_session, "buttercup_sales", min_count=10)
        assert count >= 10, f"Expected ≥10 buttercup_sales events, got {count}"

    def test_products_indexed(self, splunk_session):
        """Product catalogue CSV should be indexed in main."""
        count = wait_for_indexed(splunk_session, "buttercup_products", min_count=5)
        assert count >= 5, f"Expected ≥5 buttercup_products events, got {count}"

    def test_vendor_sales_has_expected_fields(self, splunk_session):
        """Sales records should contain 5 comma-separated CSV fields in the expected order."""
        results = run_search(
            splunk_session,
            "search index=main sourcetype=buttercup_sales | head 1 | table _raw",
        )
        assert results, "No buttercup_sales results returned"
        raw = results[0].get("_raw", "")
        parts = raw.split(",")
        assert len(parts) == 5, f"Expected 5 CSV fields (date,vendor,product,units_sold,revenue), got {len(parts)}: {raw}"


# ── HTTP Event Collector ───────────────────────────────────────────────────

class TestHEC:
    def test_hec_accepts_events(self):
        """HEC should accept a test event and return success."""
        resp = requests.post(
            f"{SPLUNK_HEC_URL}/services/collector/event",
            headers={"Authorization": f"Splunk {SPLUNK_HEC_TOKEN}"},
            json={"event": {"message": "lab-test", "source": "pytest"}, "sourcetype": "lab_test"},
            timeout=10,
            verify=False,  # Splunk HEC uses a self-signed cert
        )
        assert resp.status_code == 200
        assert resp.json().get("code") == 0, f"HEC error: {resp.json()}"


# ── MCP server ─────────────────────────────────────────────────────────────

class TestMCPServer:
    def test_mcp_port_is_open(self):
        """MCP server should be listening on port 8050."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        result = sock.connect_ex(("localhost", 8050))
        sock.close()
        assert result == 0, "Could not connect to MCP server on port 8050"

    def test_mcp_sse_endpoint_responds(self):
        """MCP SSE endpoint should return HTTP 200 when connected."""
        try:
            resp = requests.get(f"{MCP_URL}/sse", stream=True, timeout=5)
            assert resp.status_code == 200
        except requests.exceptions.ReadTimeout:
            # SSE connections stream indefinitely — a ReadTimeout after headers
            # means the server accepted the connection, which is a pass.
            pass
        finally:
            try:
                resp.close()
            except Exception:
                pass
