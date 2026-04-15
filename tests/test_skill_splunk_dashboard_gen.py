"""
Tests for the splunk-lab-dashboard-gen Claude Code skill.

Two tiers:

  Unit tests  — no stack required; validate the skill file, frontmatter,
                env.sh.example, and the dashboard JSON template.

  Integration — marked @pytest.mark.integration; require the Docker stack
                and valid credentials in $HOME/.claude/env.sh (or .env).
                HuggingFace image generation is skipped unless HF_TOKEN is set.

Run unit tests only:
  pytest tests/test_skill_splunk_dashboard_gen.py -v -m "not integration"

Run all (stack must be up):
  pytest tests/test_skill_splunk_dashboard_gen.py -v
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Paths ─────────────────────────────────────────────────────────────────
REPO_ROOT   = Path(__file__).parent.parent
SKILL_PATH  = REPO_ROOT / ".claude" / "skills" / "splunk-lab-dashboard-gen" / "SKILL.md"
ENV_EXAMPLE = REPO_ROOT / "env.sh.example"

# ── Credentials (unit tests only need these for integration tier) ──────────
from dotenv import load_dotenv
load_dotenv(REPO_ROOT / ".env")

SPLUNK_API_URL  = os.getenv("SPLUNK_API_URL", "https://localhost:8089")
SPLUNK_USERNAME = os.getenv("SPLUNK_USERNAME", "admin")
SPLUNK_PASSWORD = os.getenv("SPLUNK_PASSWORD", "Chang3d!")


# ══════════════════════════════════════════════════════════════════════════
# Unit tests — no stack required
# ══════════════════════════════════════════════════════════════════════════

class TestSkillFile:
    """Validate the SKILL.md file exists and is correctly structured."""

    def test_skill_file_exists(self):
        assert SKILL_PATH.exists(), f"Skill file not found at {SKILL_PATH}"

    def test_skill_file_not_empty(self):
        assert SKILL_PATH.stat().st_size > 500, "SKILL.md appears too small — likely incomplete"

    def test_skill_has_yaml_frontmatter(self):
        content = SKILL_PATH.read_text()
        assert content.startswith("---\n"), "SKILL.md must start with YAML frontmatter (---)"
        parts = content.split("---", 2)
        assert len(parts) >= 3, "SKILL.md frontmatter is not properly closed with ---"

    def test_skill_frontmatter_has_name(self):
        frontmatter = _parse_frontmatter(SKILL_PATH)
        assert "name:" in frontmatter, "Frontmatter missing 'name' field"
        assert "splunk-lab-dashboard-gen" in frontmatter

    def test_skill_frontmatter_has_description(self):
        frontmatter = _parse_frontmatter(SKILL_PATH)
        assert "description:" in frontmatter, "Frontmatter missing 'description' field"
        # Description should be non-trivial
        desc_match = re.search(r"description:\s*(.+)", frontmatter)
        assert desc_match and len(desc_match.group(1).strip()) > 20

    def test_skill_frontmatter_has_argument_hint(self):
        frontmatter = _parse_frontmatter(SKILL_PATH)
        assert "argument-hint:" in frontmatter, "Frontmatter missing 'argument-hint' field"

    def test_skill_uses_lab_mcp_tool(self):
        """Skill must reference splunk-lab-guide, not the upstream mcp server name."""
        content = SKILL_PATH.read_text()
        assert "splunk-lab-guide" in content, (
            "Skill must call mcp__splunk-lab-guide__search_oneshot, "
            "not the upstream mcp__splunk-mcp-server__splunk_run_query"
        )
        assert "splunk-mcp-server" not in content, (
            "Skill still references upstream 'splunk-mcp-server' — update to 'splunk-lab-guide'"
        )

    def test_skill_uses_max_count_not_row_limit(self):
        """Lab MCP uses max_count; upstream used row_limit."""
        content = SKILL_PATH.read_text()
        assert "max_count" in content, "Skill should use max_count (lab param), not row_limit"
        assert "row_limit" not in content, "row_limit is the upstream param — replace with max_count"

    def test_skill_uses_extended_earliest_time(self):
        """Default earliest_time must reach Buttercup's January 2025 data."""
        content = SKILL_PATH.read_text()
        # Should NOT still default to -24h as the primary time range
        assert "-24h" not in content or "-2y" in content, (
            "Skill still uses -24h as earliest_time — Buttercup data is Jan 2025, use -2y"
        )

    def test_skill_uses_basic_auth(self):
        """Lab uses basic auth (-u user:pass), not Bearer token header."""
        content = SKILL_PATH.read_text()
        assert '-u "$SPLUNK_USER:$SPLUNK_PASS"' in content, (
            "Skill should use basic auth for the local lab's Splunk REST API"
        )

    def test_skill_references_localhost(self):
        content = SKILL_PATH.read_text()
        assert "localhost" in content, "Skill should default Splunk host to localhost for the lab"

    def test_skill_references_env_sh(self):
        content = SKILL_PATH.read_text()
        assert "env.sh" in content, "Skill should source $HOME/.claude/env.sh for credentials"

    def test_skill_dashboard_json_template_structure(self):
        """The Dashboard Studio JSON template in the skill must contain the required top-level keys."""
        content = SKILL_PATH.read_text()
        assert "```json" in content, "No JSON code block found in SKILL.md"
        required_keys = ("visualizations", "dataSources", "layout", "backgroundImage", "structure")
        for key in required_keys:
            assert f'"{key}"' in content, (
                f"Dashboard Studio JSON template missing required key: {key}"
            )

    def test_skill_covers_all_seven_steps(self):
        content = SKILL_PATH.read_text()
        for step in range(1, 8):
            assert f"## Step {step}" in content, f"SKILL.md is missing ## Step {step}"


class TestEnvShExample:
    """Validate env.sh.example is present and complete."""

    def test_env_sh_example_exists(self):
        assert ENV_EXAMPLE.exists(), f"env.sh.example not found at {ENV_EXAMPLE}"

    def test_env_sh_example_exports_splunk_host(self):
        content = ENV_EXAMPLE.read_text()
        assert "SPLUNK_HOST" in content

    def test_env_sh_example_exports_splunk_user(self):
        content = ENV_EXAMPLE.read_text()
        assert "SPLUNK_USER" in content

    def test_env_sh_example_exports_splunk_pass(self):
        content = ENV_EXAMPLE.read_text()
        assert "SPLUNK_PASS" in content

    def test_env_sh_example_mentions_token_option(self):
        """Token auth should be documented as an alternative."""
        content = ENV_EXAMPLE.read_text()
        assert "SPLUNK_API_TOKEN" in content

    def test_env_sh_example_has_chmod_instruction(self):
        """File should remind operators to protect credentials."""
        content = ENV_EXAMPLE.read_text()
        assert "chmod" in content or "600" in content, (
            "env.sh.example should instruct operators to chmod 600 the file"
        )


# ══════════════════════════════════════════════════════════════════════════
# Integration tests — require live stack
# ══════════════════════════════════════════════════════════════════════════

@pytest.mark.integration
class TestDashboardGenIntegration:
    """Integration tests that require the Docker Compose stack to be running."""

    def test_splunk_rest_api_reachable(self, splunk_session):
        """Splunk management API should respond on port 8089."""
        resp = splunk_session.get(
            f"{SPLUNK_API_URL}/services/server/info",
            params={"output_mode": "json"},
            timeout=10,
        )
        assert resp.status_code == 200, f"Splunk REST API returned {resp.status_code}"
        data = resp.json()
        assert data.get("entry"), "Unexpected response from server/info"

    def test_dashboard_deploy_and_retrieve(self, splunk_session):
        """Deploy a minimal test dashboard and confirm it can be retrieved."""
        test_id = "claude_skill_test_dashboard"
        minimal_json = json.dumps({
            "visualizations": {},
            "dataSources": {},
            "inputs": {},
            "layout": {
                "type": "absolute",
                "options": {"width": 1440, "height": 960},
                "structure": [],
                "globalInputs": []
            },
            "title": "Claude Skill Test Dashboard",
            "description": "Automated test — safe to delete"
        })
        xml = f"""<dashboard version="2" theme="dark">
    <label>Claude Skill Test Dashboard</label>
    <description>Automated test</description>
    <definition><![CDATA[
{minimal_json}
    ]]></definition>
</dashboard>"""

        # Check if it exists already
        check = splunk_session.get(
            f"{SPLUNK_API_URL}/servicesNS/admin/search/data/ui/views/{test_id}",
            timeout=10,
        )

        if check.status_code == 200:
            # Update
            resp = splunk_session.post(
                f"{SPLUNK_API_URL}/servicesNS/admin/search/data/ui/views/{test_id}",
                data={"eai:data": xml},
                timeout=10,
            )
        else:
            # Create
            resp = splunk_session.post(
                f"{SPLUNK_API_URL}/servicesNS/admin/search/data/ui/views",
                data={"name": test_id, "eai:data": xml},
                timeout=10,
            )

        assert resp.status_code in (200, 201), (
            f"Dashboard deploy returned {resp.status_code}: {resp.text[:300]}"
        )

        # Retrieve and confirm
        get_resp = splunk_session.get(
            f"{SPLUNK_API_URL}/servicesNS/admin/search/data/ui/views/{test_id}",
            params={"output_mode": "json"},
            timeout=10,
        )
        assert get_resp.status_code == 200
        entry = get_resp.json().get("entry", [])
        assert entry, "Deployed dashboard not found in views API"
        assert entry[0]["name"] == test_id

    async def test_search_returns_data_suitable_for_dashboard(self, buttercup_ready):
        """search_oneshot with a stats query should return rows usable as dashboard data."""
        from tests.conftest import mcp_connect
        async with mcp_connect() as session:
            result = await session.call_tool(
                "search_oneshot",
                arguments={
                    "query": (
                        "index=buttercup sourcetype=buttercup_web earliest=-2y latest=now "
                        "| stats count by status | sort -count"
                    ),
                    "earliest_time": "-2y",
                    "latest_time": "now",
                    "max_count": 10,
                },
            )
            text = "".join(
                block.text for block in result.content if hasattr(block, "text")
            )
            assert text, "search_oneshot returned empty result"
            data = json.loads(text)
            assert int(data.get("event_count", 0)) > 0, (
                f"Expected rows for dashboard — got 0 events. "
                f"Check Buttercup data is indexed. Response: {text[:200]}"
            )

    @pytest.mark.skipif(
        not os.getenv("HF_TOKEN"),
        reason="HF_TOKEN not set — skipping HuggingFace image generation test"
    )
    def test_huggingface_mcp_image_tool_is_available(self):
        """HuggingFace image tool must be listed in connected MCPs (requires HF_TOKEN)."""
        result = subprocess.run(
            ["claude", "mcp", "list"],
            capture_output=True, text=True, timeout=15
        )
        assert "huggingface" in result.stdout.lower(), (
            "HuggingFace MCP not connected — required for splunk-lab-dashboard-gen. "
            "Connect it in Claude Code settings."
        )


# ── Helpers ───────────────────────────────────────────────────────────────

def _parse_frontmatter(path: Path) -> str:
    """Return the raw YAML frontmatter string from a markdown file."""
    content = path.read_text()
    parts = content.split("---", 2)
    return parts[1] if len(parts) >= 3 else ""
