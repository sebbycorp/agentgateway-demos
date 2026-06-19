"""backends.py — provider + MCP backend registry for the eval framework.

Defines:
  - ProviderSpec: how to reach an LLM through the gateway (route, model, temp flag).
  - Backend: a logical (target, mode, catalog_size) → MCP route path descriptor.
  - PROVIDERS: registry of all known providers.
  - BACKENDS: factory / registry for all known MCP backends.
  - helpers: get_mcp_path(), get_provider(), list_backends().
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Provider registry
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ProviderSpec:
    """Everything needed to drive an LLM through the AgentGateway."""
    name: str                    # logical name, e.g. "openai"
    route: str                   # gateway path, e.g. "/openai"
    model: str                   # model id sent in request body
    supports_temperature0: bool  # False for gpt-5.* (rejects temperature != 1)

    def request_body_extras(self) -> dict:
        """Return extra top-level fields to merge into the request body."""
        if self.supports_temperature0:
            return {"temperature": 0}
        # gpt-5.* rejects temperature altogether — omit it entirely
        return {}


# Env-var overrides so callers can swap models without editing code.
_OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-5.5")
_ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-8")

PROVIDERS: Dict[str, ProviderSpec] = {
    "openai": ProviderSpec(
        name="openai",
        route="/openai",
        model=_OPENAI_MODEL,
        supports_temperature0=not _OPENAI_MODEL.startswith("gpt-5"),
    ),
    "anthropic": ProviderSpec(
        name="anthropic",
        route="/anthropic",
        model=_ANTHROPIC_MODEL,
        supports_temperature0=True,
    ),
}

# Convenience: models that reject temperature != 1 (match by prefix).
_NO_TEMP_PREFIXES = ("gpt-5",)

def supports_temperature0(model: str) -> bool:
    """Return False for models known to reject temperature != 1."""
    for prefix in _NO_TEMP_PREFIXES:
        if model.startswith(prefix):
            return False
    return True


def get_provider(name: str) -> ProviderSpec:
    if name not in PROVIDERS:
        raise KeyError(f"Unknown provider '{name}'. Available: {list(PROVIDERS)}")
    return PROVIDERS[name]


# ---------------------------------------------------------------------------
# MCP Backend registry
# ---------------------------------------------------------------------------

# Tool surface sizes per mode (for synthetic routes).
# standard → N (catalog_size); search → 2; codesearch → 2.
# (Code mode is excluded: run_code inlines every tool signature, so it does not
#  reduce tool-definition tokens — it is not a cost-savings mode.)
TOOL_SURFACE: Dict[str, Optional[int]] = {
    "standard": None,   # equals catalog_size
    "search": 2,
    "codesearch": 2,
}

# Valid synthetic catalog sizes — realistic gradient.
SYNTHETIC_CATALOG_SIZES = (5, 10, 15, 30, 50, 100)

# Non-synthetic targets. "rbac" is the dedicated semantic-tool server used for the
# JWT RBAC demo (route /mcp/rbac, Standard mode, JWT-gated).
REAL_TARGETS = ("rbac",)


@dataclass
class Backend:
    """Describes a single MCP endpoint reachable through the gateway."""
    target: str          # e.g. "synthetic" or "rbac"
    mode: str            # e.g. "standard", "search", "code", "codesearch"
    catalog_size: int    # number of tools in the *full* catalog (synthetic) or 0 for real
    route: str           # gateway-relative path, e.g. "/mcp/standard-50"
    expected_tools: Optional[int]  # advertised tool count, None = unknown (real servers)
    headers: Dict[str, str] = field(default_factory=dict)  # e.g. Authorization header

    def mcp_url(self, gateway: str = "http://localhost:8080") -> str:
        return gateway.rstrip("/") + self.route

    def with_persona_headers(self, headers: Dict[str, str]) -> "Backend":
        """Return a copy of this backend with the given headers merged in."""
        new_headers = {**self.headers, **headers}
        return Backend(
            target=self.target,
            mode=self.mode,
            catalog_size=self.catalog_size,
            route=self.route,
            expected_tools=self.expected_tools,
            headers=new_headers,
        )


def _expected_tools(mode: str, catalog_size: int) -> Optional[int]:
    surface = TOOL_SURFACE.get(mode)
    if surface is None:
        return catalog_size  # standard → full catalog
    return surface


def build_synthetic_backend(mode: str, catalog_size: int) -> Backend:
    """Build a Backend for a synthetic MCP route."""
    if mode not in TOOL_SURFACE:
        raise ValueError(f"Unknown mode '{mode}'. Valid: {list(TOOL_SURFACE)}")
    if catalog_size not in SYNTHETIC_CATALOG_SIZES:
        raise ValueError(f"catalog_size {catalog_size} not in {SYNTHETIC_CATALOG_SIZES}")
    route = f"/mcp/{mode}-{catalog_size}"
    return Backend(
        target="synthetic",
        mode=mode,
        catalog_size=catalog_size,
        route=route,
        expected_tools=_expected_tools(mode, catalog_size),
    )


def build_real_backend(server: str, mode: str = "standard") -> Backend:
    """Build a Backend for the RBAC demo server route (/mcp/rbac, Standard mode).

    server must be 'rbac'. This route is JWT-gated — callers must attach a persona
    token via with_persona_headers(); an unauthenticated call returns 401.
    """
    if server != "rbac":
        raise ValueError(f"Unknown server '{server}'. Valid: ('rbac',)")

    route = "/mcp/rbac"
    target = "rbac"
    mode = "standard"

    return Backend(
        target=target,
        mode=mode,
        catalog_size=0,          # real servers: catalog size is dynamic
        route=route,
        expected_tools=None,     # unknown without live listing
    )


# Pre-built registry keyed by (target, mode, catalog_size).
# Synthetic entries only; real entries are constructed on demand.
BACKENDS: Dict[Tuple[str, str, int], Backend] = {}

for _mode in TOOL_SURFACE:
    for _size in SYNTHETIC_CATALOG_SIZES:
        _b = build_synthetic_backend(_mode, _size)
        BACKENDS[(_b.target, _b.mode, _b.catalog_size)] = _b


def get_backend(target: str, mode: str, catalog_size: int) -> Backend:
    """Look up a pre-built backend or construct a real-server backend."""
    key = (target, mode, catalog_size)
    if key in BACKENDS:
        return BACKENDS[key]
    # Try to construct the RBAC server backend.
    if target == "rbac":
        return build_real_backend("rbac", mode)
    raise KeyError(f"No backend registered for {key}")


def list_backends(
    targets: Optional[List[str]] = None,
    modes: Optional[List[str]] = None,
    catalog_sizes: Optional[List[int]] = None,
) -> List[Backend]:
    """Return filtered list of pre-built (synthetic) backends."""
    result = list(BACKENDS.values())
    if targets:
        result = [b for b in result if b.target in targets]
    if modes:
        result = [b for b in result if b.mode in modes]
    if catalog_sizes:
        result = [b for b in result if b.catalog_size in catalog_sizes]
    return result
