"""
MCP protocol-level tests for the Splunk MCP server.

These tests connect as a real MCP client over SSE and exercise the full
protocol pipeline: handshake → tool discovery → tool invocation → Splunk
query → structured results.

Requires the Docker Compose stack to be running:
  docker compose up -d

Run:
  pytest tests/test_mcp_client.py -v
"""

import json
import pytest

from tests.conftest import mcp_connect


EXPECTED_TOOLS = {
    "search_oneshot",
    "get_indexes",
    "get_saved_searches",
}


# ── Protocol handshake ────────────────────────────────────────────────────

class TestMCPProtocol:
    async def test_initialize_returns_capabilities(self):
        """Server should complete the MCP initialize handshake."""
        async with mcp_connect() as session:
            assert session is not None

    async def test_server_capabilities(self):
        """Server should advertise tool and resource capabilities."""
        async with mcp_connect() as session:
            caps = session.get_server_capabilities()
            assert caps is not None
            assert caps.tools is not None


# ── Tool discovery ────────────────────────────────────────────────────────

class TestMCPToolDiscovery:
    async def test_tools_list_not_empty(self):
        """tools/list should return at least one tool."""
        async with mcp_connect() as session:
            result = await session.list_tools()
            assert result.tools, "MCP server returned no tools"

    async def test_tools_list_contains_expected_tools(self):
        """tools/list should include the core Splunk tools."""
        async with mcp_connect() as session:
            result = await session.list_tools()
            tool_names = {t.name for t in result.tools}
            missing = EXPECTED_TOOLS - tool_names
            assert not missing, f"Missing expected tools: {missing}"

    async def test_each_tool_has_description(self):
        """Every registered tool should have a non-empty description."""
        async with mcp_connect() as session:
            result = await session.list_tools()
            for tool in result.tools:
                assert tool.description, f"Tool '{tool.name}' has no description"

    async def test_each_tool_has_input_schema(self):
        """Every registered tool should declare an input schema."""
        async with mcp_connect() as session:
            result = await session.list_tools()
            for tool in result.tools:
                assert tool.inputSchema, f"Tool '{tool.name}' has no input schema"


# ── Tool execution ────────────────────────────────────────────────────────

class TestMCPToolExecution:
    async def test_get_config(self):
        """get_config should return server configuration with splunk_connected=true."""
        async with mcp_connect() as session:
            result = await session.call_tool("get_config", arguments={})
            text = _extract_text(result)
            data = json.loads(text)
            assert data.get("splunk_connected") is True, f"Splunk not connected: {text[:200]}"

    async def test_validate_spl(self):
        """validate_spl should return a risk assessment for a query."""
        async with mcp_connect() as session:
            result = await session.call_tool("validate_spl", arguments={
                "query": "index=buttercup earliest=0 latest=now | stats count",
            })
            text = _extract_text(result)
            data = json.loads(text)
            assert "risk_score" in data
            assert "would_execute" in data

    async def test_get_indexes_returns_buttercup(self, buttercup_ready):
        """get_indexes should include the buttercup index."""
        async with mcp_connect() as session:
            result = await session.call_tool("get_indexes", arguments={})
            text = _extract_text(result)
            assert "buttercup" in text.lower(), (
                f"Expected 'buttercup' index in get_indexes output: {text[:300]}"
            )

    async def test_search_oneshot_returns_data(self, buttercup_ready):
        """search_oneshot with a count query should return results > 0."""
        async with mcp_connect() as session:
            result = await session.call_tool(
                "search_oneshot",
                arguments={
                    "query": "index=buttercup earliest=0 latest=now sourcetype=buttercup_sales | stats count",
                    "earliest_time": "0",
                    "latest_time": "now",
                },
            )
            text = _extract_text(result)
            assert text, "search_oneshot returned empty result"
            assert _result_has_positive_count(text), (
                f"Expected positive count in search_oneshot result: {text[:300]}"
            )

    async def test_search_oneshot_revenue_by_vendor(self, buttercup_ready):
        """search_oneshot with stats query should return vendor revenue rows."""
        async with mcp_connect() as session:
            result = await session.call_tool(
                "search_oneshot",
                arguments={
                    "query": (
                        "index=buttercup earliest=0 latest=now sourcetype=buttercup_sales "
                        "| stats sum(revenue) as total_revenue by vendor "
                        "| sort -total_revenue"
                    ),
                    "earliest_time": "0",
                    "latest_time": "now",
                },
            )
            text = _extract_text(result)
            assert "vendor" in text.lower() or "revenue" in text.lower(), (
                f"Expected vendor/revenue fields in result: {text[:300]}"
            )

    async def test_get_saved_searches(self):
        """get_saved_searches should return without error."""
        async with mcp_connect() as session:
            result = await session.call_tool("get_saved_searches", arguments={})
            assert not result.isError, (
                f"get_saved_searches returned error: {_extract_text(result)}"
            )


# ── Helpers ───────────────────────────────────────────────────────────────

def _extract_text(result) -> str:
    """Pull the concatenated text from a CallToolResult."""
    parts = []
    for block in result.content:
        if hasattr(block, "text"):
            parts.append(block.text)
    return "\n".join(parts)


def _result_has_positive_count(text: str) -> bool:
    """Check whether an MCP search_oneshot result contains count > 0."""
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            # MCP wraps results: {"event_count": N, "events": [...]}
            if int(data.get("event_count", 0)) > 0:
                for evt in data.get("events", []):
                    if int(evt.get("count", 0)) > 0:
                        return True
            if int(data.get("count", 0)) > 0:
                return True
        elif isinstance(data, list):
            for row in data:
                if int(row.get("count", 0)) > 0:
                    return True
    except (json.JSONDecodeError, ValueError, TypeError):
        pass
    import re
    counts = re.findall(r'"count"\s*:\s*"?(\d+)"?', text)
    return any(int(c) > 0 for c in counts) if counts else False
