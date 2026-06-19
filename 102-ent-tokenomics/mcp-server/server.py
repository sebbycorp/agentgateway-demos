"""Synthetic MCP server exposing a configurable number of echo tools.

TOOL_COUNT (env, default 10) controls how many tools are registered. Each tool
carries a realistic multi-field input schema so its serialized definition has a
representative token cost. Tools are pure echo -> runs are deterministic.

TOOL_NAMING (env, default "numeric"):
  - "numeric"  -> tools named tool_000, tool_001, ... (used by the cost sweep)
  - "semantic" -> tools named with action prefixes (get_/list_/create_/update_/
                  delete_resource_NNN), so RBAC-by-prefix is meaningful. Used by
                  the dedicated RBAC demo backend.
"""
import os
from mcp.server.fastmcp import FastMCP

TOOL_COUNT = int(os.environ.get("TOOL_COUNT", "10"))
TOOL_NAMING = os.environ.get("TOOL_NAMING", "numeric")

mcp = FastMCP("synthetic-tools", host="0.0.0.0", port=8000)

# Action verbs cycled through in semantic naming mode (readonly = get_/list_).
_VERBS = ("get", "list", "create", "update", "delete")


def _make_tool(name: str):
    def echo_tool(
        text: str,
        number: int = 0,
        flag: bool = False,
        tags: list[str] | None = None,
        note: str = "",
    ) -> str:
        """Echo back the provided arguments for synthetic tool."""
        return (
            f"{name} echoed: text={text} number={number} "
            f"flag={flag} tags={tags or []} note={note}"
        )

    return echo_tool


def _tool_name(index: int) -> str:
    if TOOL_NAMING == "semantic":
        verb = _VERBS[index % len(_VERBS)]
        return f"{verb}_resource_{index:03d}"
    return f"tool_{index:03d}"


for i in range(TOOL_COUNT):
    name = _tool_name(i)
    mcp.add_tool(
        _make_tool(name),
        name=name,
        description=(
            f"Synthetic echo tool '{name}'. Accepts a text string, an integer "
            f"number, a boolean flag, a list of string tags, and a note string, "
            f"then returns them echoed back. Used to demonstrate MCP progressive "
            f"disclosure."
        ),
    )


if __name__ == "__main__":
    print(f"Starting synthetic MCP server with {TOOL_COUNT} tools (SSE on :8000/sse)")
    mcp.run(transport="sse")
