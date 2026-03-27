import os
import time
import socket
import requests
import urllib3
import pytest
from pathlib import Path
from dotenv import load_dotenv

# Load .env for local dev — silently skipped in CI where .env is created from .env.example
load_dotenv(Path(__file__).parent.parent / ".env")

# Suppress SSL warnings — Splunk uses a self-signed cert on the management API
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Endpoints ──────────────────────────────────────────────────────────────
SPLUNK_WEB_URL  = os.getenv("SPLUNK_WEB_URL",  "http://localhost:8000")
SPLUNK_API_URL  = os.getenv("SPLUNK_API_URL",  "https://localhost:8089")  # Splunk mgmt API uses HTTPS
SPLUNK_HEC_URL  = os.getenv("SPLUNK_HEC_URL",  "https://localhost:8088")  # HEC uses HTTPS
MCP_URL         = os.getenv("MCP_URL",         "http://localhost:8050")

# Credentials — defaults match .env.example so CI works without any override
SPLUNK_USERNAME = os.getenv("SPLUNK_USERNAME", "admin")
SPLUNK_PASSWORD = os.getenv("SPLUNK_PASSWORD", "Chang3d!")
SPLUNK_HEC_TOKEN = os.getenv("SPLUNK_HEC_TOKEN", "a8b4c2d6-e0f1-4321-9876-abcdef012345")


@pytest.fixture(scope="session")
def splunk_session():
    """Authenticated requests session for the Splunk management API."""
    session = requests.Session()
    session.auth = (SPLUNK_USERNAME, SPLUNK_PASSWORD)
    session.verify = False
    return session


def run_search(session, spl, timeout=30):
    """Run a oneshot Splunk search and return the results list."""
    resp = session.post(
        f"{SPLUNK_API_URL}/services/search/jobs",
        data={
            "search": spl,
            "output_mode": "json",
            "exec_mode": "oneshot",
        },
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json().get("results", [])


def wait_for_indexed(session, sourcetype, min_count=1, timeout=90, interval=5):
    """
    Poll until at least min_count events exist for the given sourcetype.
    Splunk monitor inputs can take 10–30s to index files after startup.
    """
    spl = f"search index=main sourcetype={sourcetype} | stats count"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            results = run_search(session, spl)
            count = int(results[0].get("count", 0)) if results else 0
            if count >= min_count:
                return count
        except Exception:
            pass
        time.sleep(interval)
    raise TimeoutError(
        f"sourcetype={sourcetype} had fewer than {min_count} events after {timeout}s"
    )
