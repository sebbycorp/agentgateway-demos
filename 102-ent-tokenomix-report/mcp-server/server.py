"""Synthetic MCP server exposing a configurable number of echo tools.

TOOL_COUNT (env, default 10) controls how many tools are registered. Each tool
carries a realistic multi-field input schema so its serialized definition has a
representative token cost. Tools are pure echo -> runs are deterministic.
"""
import os
from mcp.server.fastmcp import FastMCP

TOOL_COUNT = int(os.environ.get("TOOL_COUNT", "10"))

mcp = FastMCP("synthetic-tools", host="0.0.0.0", port=8000)


def _make_tool(index: int):
    def echo_tool(
        text: str,
        number: int = 0,
        flag: bool = False,
        tags: list[str] | None = None,
        note: str = "",
    ) -> str:
        """Echo back the provided arguments for synthetic tool."""
        return (
            f"tool_{index:03d} echoed: text={text} number={number} "
            f"flag={flag} tags={tags or []} note={note}"
        )

    return echo_tool


for i in range(TOOL_COUNT):
    mcp.add_tool(
        _make_tool(i),
        name=f"tool_{i:03d}",
        description=(
            f"Synthetic echo tool number {i}. Accepts a text string, an integer "
            f"number, a boolean flag, a list of string tags, and a note string, "
            f"then returns them echoed back. Used to demonstrate MCP progressive "
            f"disclosure (search mode) tool {i:03d}."
        ),
    )


if __name__ == "__main__":
    print(f"Starting synthetic MCP server with {TOOL_COUNT} tools (SSE on :8000/sse)")
    mcp.run(transport="sse")
