"""Sample MCP server for the XAA lab — a tiny todo service.

Exposes two tools behind agentgateway's MCP OAuth:
  - todo_read   (requires scope todo.read,  enforced at the gateway)
  - todo_write  (requires scope todo.write, enforced at the gateway)

The server itself does NOT check auth — agentgateway validates the enterprise
JWT and applies per-tool scope rules (mcpAuthorization) before the call ever
reaches here. That is the whole point of the lab: one SSO login, central policy.

Transport: Streamable HTTP, mounted at /mcp on 0.0.0.0:8000.
"""
from __future__ import annotations

import os

from mcp.server.fastmcp import FastMCP

HOST = os.environ.get("MCP_HOST", "0.0.0.0")
PORT = int(os.environ.get("MCP_PORT", "8000"))

mcp = FastMCP("todo", host=HOST, port=PORT)

# In-memory store — reset on restart; fine for a classroom lab.
_todos: list[str] = ["ship the XAA demo"]


@mcp.tool()
def todo_read() -> list[str]:
    """Return the current list of todo items."""
    return list(_todos)


@mcp.tool()
def todo_write(item: str) -> str:
    """Add a new todo item and return a confirmation string."""
    _todos.append(item)
    return f"added: {item} (total={len(_todos)})"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
