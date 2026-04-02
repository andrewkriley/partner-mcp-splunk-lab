"""
Chat API backend — bridges the Anthropic Messages API with the Splunk MCP server.

On startup, connects to the MCP server over SSE, discovers available tools,
and converts them to Anthropic-compatible tool definitions.  When a user
sends a message, it runs the Claude → tool-use → MCP → Splunk loop until
Claude produces a final text response.
"""

import os
import json
import asyncio
import logging
from pathlib import Path
from contextlib import asynccontextmanager

import anthropic
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from mcp import ClientSession
from mcp.client.sse import sse_client

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("chat")

MCP_SSE_URL = os.getenv("MCP_SSE_URL", "http://localhost:8050/sse")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
MODEL = os.getenv("CHAT_MODEL", "claude-haiku-4-20250414")
SYSTEM_PROMPT = (Path(__file__).parent / "system_prompt.txt").read_text()

# Cached tool definitions (populated on first /api/chat request)
_anthropic_tools: list[dict] = []
_mcp_tools_raw: dict = {}


async def _get_mcp_tools() -> tuple[list[dict], dict]:
    """Connect to the MCP server and fetch tool definitions."""
    async with sse_client(url=MCP_SSE_URL) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()
            result = await session.list_tools()
            anthropic_tools = []
            raw = {}
            for tool in result.tools:
                raw[tool.name] = tool
                anthropic_tools.append({
                    "name": tool.name,
                    "description": tool.description or "",
                    "input_schema": tool.inputSchema or {"type": "object", "properties": {}},
                })
            return anthropic_tools, raw


async def _call_mcp_tool(name: str, arguments: dict) -> str:
    """Connect to the MCP server and invoke a single tool."""
    async with sse_client(url=MCP_SSE_URL) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments=arguments)
            parts = []
            for block in result.content:
                if hasattr(block, "text"):
                    parts.append(block.text)
            return "\n".join(parts)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _anthropic_tools, _mcp_tools_raw
    try:
        _anthropic_tools, _mcp_tools_raw = await _get_mcp_tools()
        log.info("Loaded %d MCP tools: %s", len(_anthropic_tools),
                 [t["name"] for t in _anthropic_tools])
    except Exception as e:
        log.warning("Could not load MCP tools on startup: %s", e)
    yield


app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")


@app.get("/", response_class=HTMLResponse)
async def index():
    return (Path(__file__).parent / "static" / "index.html").read_text()


@app.get("/api/health")
async def health():
    has_key = bool(ANTHROPIC_API_KEY)
    has_tools = bool(_anthropic_tools)
    return {
        "status": "ok" if has_key and has_tools else "degraded",
        "anthropic_api_key_set": has_key,
        "mcp_tools_loaded": has_tools,
        "mcp_tool_count": len(_anthropic_tools),
        "model": MODEL,
    }


@app.post("/api/chat")
async def chat(request: Request):
    global _anthropic_tools, _mcp_tools_raw

    if not ANTHROPIC_API_KEY:
        return JSONResponse(
            status_code=503,
            content={
                "error": "ANTHROPIC_API_KEY not set",
                "message": "Add ANTHROPIC_API_KEY to your .env file to enable the chat feature.",
            },
        )

    body = await request.json()
    user_message = body.get("message", "")
    history = body.get("history", [])

    if not user_message:
        return JSONResponse(status_code=400, content={"error": "Empty message"})

    # Refresh tools if not loaded
    if not _anthropic_tools:
        try:
            _anthropic_tools, _mcp_tools_raw = await _get_mcp_tools()
        except Exception as e:
            log.error("Failed to load MCP tools: %s", e)
            return JSONResponse(
                status_code=503,
                content={"error": "MCP server unreachable", "message": str(e)},
            )

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    messages = list(history)
    messages.append({"role": "user", "content": user_message})

    tool_calls_log = []
    max_rounds = 10

    for _ in range(max_rounds):
        try:
            response = client.messages.create(
                model=MODEL,
                max_tokens=4096,
                system=SYSTEM_PROMPT,
                tools=_anthropic_tools,
                messages=messages,
            )
        except anthropic.APIError as e:
            return JSONResponse(
                status_code=502,
                content={"error": "Anthropic API error", "message": str(e)},
            )

        if response.stop_reason == "tool_use":
            tool_use_blocks = [b for b in response.content if b.type == "tool_use"]
            messages.append({"role": "assistant", "content": response.content})

            tool_results = []
            for block in tool_use_blocks:
                log.info("Tool call: %s(%s)", block.name, json.dumps(block.input)[:200])
                try:
                    result_text = await _call_mcp_tool(block.name, block.input)
                except Exception as e:
                    result_text = json.dumps({"error": str(e)})

                tool_calls_log.append({
                    "tool": block.name,
                    "input": block.input,
                    "output": result_text[:2000],
                })
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result_text,
                })

            messages.append({"role": "user", "content": tool_results})
        else:
            # Final text response
            text_parts = []
            for block in response.content:
                if hasattr(block, "text"):
                    text_parts.append(block.text)
            return {
                "response": "\n".join(text_parts),
                "tool_calls": tool_calls_log,
                "model": MODEL,
            }

    return JSONResponse(
        status_code=500,
        content={"error": "Max tool-use rounds exceeded"},
    )
