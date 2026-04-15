import os
import time
import socket
import requests
import urllib3
import pytest
import pytest_asyncio
from pathlib import Path
from dotenv import load_dotenv
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

# Load .env for local dev — silently skipped in CI where .env is created from .env.example
load_dotenv(Path(__file__).parent.parent / ".env")

# Suppress SSL warnings — Splunk uses a self-signed cert on the management API
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Endpoints ──────────────────────────────────────────────────────────────
SPLUNK_WEB_URL  = os.getenv("SPLUNK_WEB_URL",  "http://localhost:8000")
SPLUNK_API_URL  = os.getenv("SPLUNK_API_URL",  "https://localhost:8089")  # Splunk mgmt API uses HTTPS
SPLUNK_HEC_URL  = os.getenv("SPLUNK_HEC_URL",  "https://localhost:8088")  # HEC uses HTTPS
MCP_URL         = os.getenv("MCP_URL",         "http://localhost:8050")
LAB_GUIDE_URL   = os.getenv("LAB_GUIDE_URL",   "http://localhost:3131")

# Credentials — defaults match .env.example so CI works without any override
SPLUNK_USERNAME = os.getenv("SPLUNK_USERNAME", "admin")
SPLUNK_PASSWORD = os.getenv("SPLUNK_PASSWORD", "Chang3d!")
SPLUNK_HEC_TOKEN = os.getenv("SPLUNK_HEC_TOKEN", "a8b4c2d6-e0f1-4321-9876-abcdef012345")

# Buttercup sourcetypes and minimum event counts expected after full ingest
BUTTERCUP_SOURCETYPES = {
    "buttercup_web":      50,
    "buttercup_sales":    10,
    "buttercup_products":  5,
}


@pytest.fixture(scope="session")
def splunk_session():
    """Authenticated requests session for the Splunk management API."""
    session = requests.Session()
    session.auth = (SPLUNK_USERNAME, SPLUNK_PASSWORD)
    session.verify = False
    return session


@pytest.fixture(scope="session")
def buttercup_ready(splunk_session):
    """
    Session-scoped fixture: polls until ALL Buttercup sourcetypes meet their
    minimum event count, or raises after 300s.

    Polling all sourcetypes together in a single loop avoids the problem of
    sequential per-sourcetype timeouts when one sourcetype (access_combined,
    which requires Apache Combined log parsing) takes longer than the others.
    """
    deadline = time.time() + 600
    while time.time() < deadline:
        counts = {}
        for st in BUTTERCUP_SOURCETYPES:
            try:
                results = run_search(
                    splunk_session,
                    f"search index=buttercup sourcetype={st} | stats count",
                )
                counts[st] = int(results[0].get("count", 0)) if results else 0
            except Exception:
                counts[st] = 0

        if all(counts.get(st, 0) >= n for st, n in BUTTERCUP_SOURCETYPES.items()):
            # Counts are met — wait until raw events are also retrievable.
            # Splunk can report counts before events are fully committed to disk.
            for _ in range(12):
                try:
                    raw = run_search(
                        splunk_session,
                        "search index=buttercup sourcetype=buttercup_sales | head 1",
                    )
                    if raw:
                        return counts
                except Exception:
                    pass
                time.sleep(5)
            return counts  # timed out waiting for raw — let tests surface the failure

        time.sleep(5)

    raise TimeoutError(
        f"Buttercup data not fully indexed after 600s. Last counts: {counts}"
    )


def run_search(session, spl, timeout=30):
    """Run a oneshot Splunk search and return the results list."""
    resp = session.post(
        f"{SPLUNK_API_URL}/services/search/jobs",
        data={
            "search": spl,
            "output_mode": "json",
            "exec_mode": "oneshot",
            "earliest_time": "0",   # epoch 0 = all time; avoids missing events with old timestamps
            "latest_time": "now",
        },
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json().get("results", [])


# ── MCP client helpers ────────────────────────────────────────────────────

from contextlib import asynccontextmanager

@asynccontextmanager
async def mcp_connect():
    """Connect to the MCP server over Streamable HTTP and yield an initialized ClientSession.

    Usage in tests::

        async with mcp_connect() as session:
            result = await session.list_tools()

    Using an explicit context manager (not a pytest fixture) avoids the
    anyio cancel-scope teardown issue where pytest-asyncio finalises the
    fixture in a different task.
    """
    async with streamablehttp_client(url=f"{MCP_URL}/mcp") as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            yield session
