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
    LAB_GUIDE_URL,
    BUTTERCUP_SOURCETYPES,
    run_search,
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
    The buttercup_ready fixture (session-scoped) polls until all sourcetypes
    reach their minimum counts before any test in this class runs, using a
    single shared 300s timeout. Individual tests then just assert counts
    without additional waiting.
    """

    def test_access_logs_indexed(self, buttercup_ready):
        """Web access logs (Apache Combined) should be indexed in the buttercup index."""
        count = buttercup_ready["buttercup_web"]
        assert count >= BUTTERCUP_SOURCETYPES["buttercup_web"], \
            f"Expected ≥{BUTTERCUP_SOURCETYPES['buttercup_web']} buttercup_web events, got {count}"

    def test_vendor_sales_indexed(self, buttercup_ready):
        """Vendor sales CSV should be indexed in the buttercup index."""
        count = buttercup_ready["buttercup_sales"]
        assert count >= BUTTERCUP_SOURCETYPES["buttercup_sales"], \
            f"Expected ≥{BUTTERCUP_SOURCETYPES['buttercup_sales']} buttercup_sales events, got {count}"

    def test_products_indexed(self, buttercup_ready):
        """Product catalogue CSV should be indexed in the buttercup index."""
        count = buttercup_ready["buttercup_products"]
        assert count >= BUTTERCUP_SOURCETYPES["buttercup_products"], \
            f"Expected ≥{BUTTERCUP_SOURCETYPES['buttercup_products']} buttercup_products events, got {count}"

    def test_vendor_sales_has_expected_fields(self, buttercup_ready, splunk_session):
        """Sales CSV fields (vendor, product, units_sold, revenue) must be extracted with correct names."""
        results = run_search(
            splunk_session,
            "search index=buttercup sourcetype=buttercup_sales | head 1 | fields vendor, product, units_sold, revenue",
        )
        assert results, "No buttercup_sales results returned"
        row = results[0]
        for field in ("vendor", "product", "units_sold", "revenue"):
            assert field in row and row[field], \
                f"Expected field '{field}' missing or empty — check INDEXED_EXTRACTIONS in props.conf"

    def test_vendor_sales_revenue_query(self, buttercup_ready, splunk_session):
        """Lab-guide SPL: stats sum(revenue) by vendor should return results."""
        results = run_search(
            splunk_session,
            "search index=buttercup sourcetype=buttercup_sales | stats sum(revenue) as total_revenue by vendor | sort -total_revenue",
        )
        assert results, "Revenue by vendor query returned no results"
        assert all("vendor" in r and "total_revenue" in r for r in results)

    def test_vendor_sales_timechart_query(self, buttercup_ready, splunk_session):
        """Lab-guide SPL: timechart span=1d sum(revenue) by vendor should span multiple days."""
        results = run_search(
            splunk_session,
            "search index=buttercup sourcetype=buttercup_sales | timechart span=1d sum(revenue) by vendor",
        )
        assert len(results) > 1, \
            f"Expected multiple daily buckets, got {len(results)} — check TIME_FORMAT in props.conf"

    def test_web_status_field_extracted(self, buttercup_ready, splunk_session):
        """Apache Combined log field extraction should populate the status field."""
        results = run_search(
            splunk_session,
            "search index=buttercup sourcetype=buttercup_web | stats count by status | where status!=\"\"",
        )
        assert results, \
            "No status values extracted from buttercup_web — check EXTRACT-apache in props.conf"
        statuses = {r["status"] for r in results}
        assert statuses, "status field is empty on all buttercup_web events"

    @pytest.mark.parametrize(
        "spl",
        (
            "search index=buttercup earliest=0 latest=now sourcetype=buttercup_web | stats count by status",
            "search index=buttercup earliest=0 latest=now sourcetype=buttercup_sales | stats sum(revenue) as total_revenue by vendor | sort -total_revenue",
            "search index=buttercup earliest=0 latest=now sourcetype=buttercup_sales | stats sum(units_sold) as total_units by product | sort -total_units",
            "search index=buttercup earliest=0 latest=now sourcetype=buttercup_sales | timechart span=1d sum(revenue) by vendor",
        ),
    )
    def test_readme_and_lab_guide_buttercup_spl(self, buttercup_ready, splunk_session, spl):
        """README and lab-guide SPL (with all-time bounds) must return rows."""
        results = run_search(splunk_session, spl)
        assert results, f"Documented query returned no results: {spl}"
        if "timechart" in spl:
            assert len(results) > 1, "timechart should span multiple days of sample sales"


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


# ── Lab Guide ──────────────────────────────────────────────────────────────

class TestLabGuide:
    def test_lab_guide_port_is_open(self):
        """Lab guide nginx should be listening on its configured port."""
        from urllib.parse import urlparse
        port = urlparse(LAB_GUIDE_URL).port or 3131
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        result = sock.connect_ex(("localhost", port))
        sock.close()
        assert result == 0, f"Could not connect to lab guide on port {port}"

    def test_lab_guide_returns_html(self):
        """Lab guide should return HTTP 200 with HTML content."""
        resp = requests.get(LAB_GUIDE_URL, timeout=10)
        assert resp.status_code == 200
        assert "text/html" in resp.headers.get("Content-Type", "")


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
