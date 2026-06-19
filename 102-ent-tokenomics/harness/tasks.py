"""tasks.py — labeled task suite for the MCP progressive-disclosure eval.

Each Task specifies:
  - id:             unique string identifier
  - prompt:         user message sent to the LLM
  - expected_tools: ordered list of tool names the LLM should call (for accuracy)
  - loop_steps:     for agentic-loop tasks, the number of sequential dependent
                    tool calls in the chain (0 = single-shot)
  - description:    human-readable summary

Tasks are deterministic where possible (fixed tool names, fixed args) so that
`correct` (top-1 tool match) is measurable without an LLM judge.

Agentic-loop tasks:
  make_loop_task(k) generates a chain of k dependent calls:
  step i calls tool_{i:03d} with text='step_{i}', receives the echo, then
  passes it as the text arg to tool_{i+1:03d}.  The expected tool list is
  [tool_000, tool_001, ..., tool_{k-1:03d}].

  This requires tools tool_000 … tool_{k-1} to exist in the active catalog,
  so pair with catalog_size >= k.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional


@dataclass(frozen=True)
class Task:
    """A single evaluation task."""
    id: str
    prompt: str
    expected_tools: List[str]
    loop_steps: int = 0         # 0 = single-shot; >0 = agentic loop depth
    description: str = ""

    @property
    def is_agentic_loop(self) -> bool:
        return self.loop_steps > 0

    @property
    def min_catalog_size(self) -> int:
        """Minimum catalog size needed for all expected tools to exist."""
        # synthetic tools are named tool_NNN; highest index = min catalog size
        indices = []
        for name in self.expected_tools:
            if name.startswith("tool_"):
                try:
                    indices.append(int(name[5:]) + 1)
                except ValueError:
                    pass
        return max(indices) if indices else 1


# ---------------------------------------------------------------------------
# Concrete task definitions
# ---------------------------------------------------------------------------

# --- Single-shot tasks (reuse run_ab.py's proven two-tool task) ---

TASK_TWO_TOOLS = Task(
    id="two_tools",
    prompt=(
        "Use the available tools to do BOTH of the following, then reply with the two "
        "returned strings joined by ' | ':\n"
        "1) call the tool named tool_003 with text='alpha' and number=1\n"
        "2) call the tool named tool_005 with text='beta' and number=2"
    ),
    expected_tools=["tool_003", "tool_005"],
    loop_steps=0,
    description="Call tool_003 then tool_005 in one turn (matches run_ab.py v2 task)",
)

TASK_SINGLE_ECHO = Task(
    id="single_echo",
    prompt=(
        "Call the tool named tool_001 with text='hello' and number=42. "
        "Reply with exactly the string the tool returned."
    ),
    expected_tools=["tool_001"],
    loop_steps=0,
    description="Single tool call — baseline latency/token measurement",
)

TASK_SEARCH_ONLY = Task(
    id="search_only",
    prompt=(
        "Search for documents matching the query 'tokenomix cost analysis'. "
        "Use the first search tool available and return the results."
    ),
    # Synthetic search routes surface tools named search_NNN; the actual first
    # tool will be discovered at runtime — we record selected vs expected.
    expected_tools=["tool_search"],
    loop_steps=0,
    description="Exercise the search tool surface (mode=search/codesearch)",
)

TASK_CODE_ONLY = Task(
    id="code_only",
    prompt=(
        "Use the code execution tool to compute 7 * 6 and return only the numeric result."
    ),
    expected_tools=["tool_code"],
    loop_steps=0,
    description="Exercise the code tool surface (mode=code/codesearch)",
)

# --- Agentic-loop task factory ---

def make_loop_task(k: int) -> Task:
    """Return a Task that chains k dependent tool calls.

    Step i: call tool_{i:03d} with text='step_{i}', capture its echo,
    pass the echo as text to tool_{i+1:03d}, etc.

    This requires tools tool_000 … tool_{k-1} in the catalog.
    """
    if k < 1:
        raise ValueError(f"loop k must be >= 1, got {k}")

    tool_names = [f"tool_{i:03d}" for i in range(k)]

    # Build a prompt that explicitly chains each call.
    steps = []
    for i in range(k):
        if i == 0:
            steps.append(
                f"Step 1: call tool_{i:03d} with text='step_{i}' and number={i}."
            )
        else:
            steps.append(
                f"Step {i+1}: take the string returned by the previous tool and pass it "
                f"as text= to tool_{i:03d} with number={i}."
            )
    steps.append(
        "After all steps are complete, reply with the final returned string."
    )
    prompt = (
        f"Perform a chain of {k} sequential tool calls as follows:\n"
        + "\n".join(steps)
    )

    return Task(
        id=f"loop_k{k}",
        prompt=prompt,
        expected_tools=tool_names,
        loop_steps=k,
        description=f"Agentic loop of {k} dependent sequential tool calls",
    )


# Pre-built loop tasks for common sweep values.
LOOP_TASKS = {k: make_loop_task(k) for k in (1, 3, 5)}

# ---------------------------------------------------------------------------
# Task registry
# ---------------------------------------------------------------------------

ALL_TASKS: List[Task] = [
    TASK_TWO_TOOLS,
    TASK_SINGLE_ECHO,
    TASK_SEARCH_ONLY,
    TASK_CODE_ONLY,
    *LOOP_TASKS.values(),
]

_TASK_INDEX = {t.id: t for t in ALL_TASKS}


def get_task(task_id: str) -> Task:
    if task_id not in _TASK_INDEX:
        raise KeyError(f"Unknown task '{task_id}'. Available: {list(_TASK_INDEX)}")
    return _TASK_INDEX[task_id]


def list_task_ids() -> List[str]:
    return list(_TASK_INDEX.keys())


# Default "cheap smoke run" task set (short tasks, single-turn, tools ≤ idx 5).
SMOKE_TASKS: List[str] = ["two_tools", "single_echo"]
