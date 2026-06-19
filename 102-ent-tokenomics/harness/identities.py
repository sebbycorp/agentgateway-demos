"""identities.py — RBAC personas, token loading/generation, and tool predicates.

Three personas: readonly, team, admin.

Token lifecycle:
  - Tokens are pre-generated and stored in harness/.rbac_token_<role>.txt.
  - If a file is missing or expired, call regenerate() to create a new RS256
    keypair, JWKS, and fresh tokens.

JWT claims:
  - iss: https://tokenomix.demo
  - aud: agentgateway
  - kid: tokenomix-1
  - claim: role ∈ {readonly, team, admin}

Key material written to:
  - harness/.rbac_key.pem       (RSA private key, PEM)
  - harness/.rbac_jwks.json     (JWK Set with public key)
  - harness/.rbac_token_<role>.txt (one JWT per role)
"""
from __future__ import annotations

import json
import pathlib
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

HERE = pathlib.Path(__file__).parent

_KID = "tokenomix-1"
_ISSUER = "https://tokenomix.demo"
_AUDIENCE = "agentgateway"
_TTL = 86400 * 30  # 30 days

_KEY_FILE = HERE / ".rbac_key.pem"
_JWKS_FILE = HERE / ".rbac_jwks.json"


# ---------------------------------------------------------------------------
# Persona definitions
# ---------------------------------------------------------------------------

@dataclass
class Persona:
    """An RBAC identity that drives tool-access assertions."""
    name: str                          # "readonly" | "team" | "admin"
    role: str                          # JWT role claim value
    token_file: pathlib.Path
    # Predicate: given a tool name, return True if this persona should see it.
    tool_predicate: Callable[[str], bool] = field(default=lambda _: True)

    @property
    def token(self) -> str:
        """Load JWT from disk; raise FileNotFoundError if not present."""
        return self.token_file.read_text().strip()

    def auth_header(self) -> Dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def can_see_tool(self, tool_name: str) -> bool:
        return self.tool_predicate(tool_name)


# Tool visibility predicates — these MIRROR the CEL matchExpressions actually
# enforced by the gateway in k8s/github-rbac.yaml (the gateway is the source of
# truth; these are kept in sync for documentation/assertions). Applied to the
# GitHub MCP catalog (47 real tools).
#
# readonly (github-rbac.yaml): allow get_* / list_* / search_*
_READONLY_PREFIXES = ("get_", "list_", "search_")

def _readonly_predicate(tool_name: str) -> bool:
    return tool_name.startswith(_READONLY_PREFIXES)

# team (github-rbac.yaml): everything EXCEPT delete_* / fork_* / create_repository
def _team_predicate(tool_name: str) -> bool:
    return not (tool_name.startswith("delete_")
                or tool_name.startswith("fork_")
                or tool_name == "create_repository")

# admin (github-rbac.yaml): all tools.
def _admin_predicate(_tool_name: str) -> bool:
    return True


PERSONAS: Dict[str, Persona] = {
    "readonly": Persona(
        name="readonly",
        role="readonly",
        token_file=HERE / ".rbac_token_readonly.txt",
        tool_predicate=_readonly_predicate,
    ),
    "team": Persona(
        name="team",
        role="team",
        token_file=HERE / ".rbac_token_team.txt",
        tool_predicate=_team_predicate,
    ),
    "admin": Persona(
        name="admin",
        role="admin",
        token_file=HERE / ".rbac_token_admin.txt",
        tool_predicate=_admin_predicate,
    ),
}

# "no persona" sentinel — used for unauthenticated calls.
PERSONAS["none"] = Persona(
    name="none",
    role="",
    token_file=HERE / ".rbac_token_none.txt",  # will not be read
    tool_predicate=lambda _: True,
)


def get_persona(name: str) -> Persona:
    if name not in PERSONAS:
        raise KeyError(f"Unknown persona '{name}'. Available: {list(PERSONAS)}")
    return PERSONAS[name]


# ---------------------------------------------------------------------------
# Token generation (RS256, proven logic)
# ---------------------------------------------------------------------------

def _load_or_generate_key():
    """Load existing RSA private key from .rbac_key.pem, or generate a new one."""
    try:
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
    except ImportError as exc:
        raise ImportError("pip install cryptography") from exc

    if _KEY_FILE.exists():
        pem = _KEY_FILE.read_bytes()
        return load_pem_private_key(pem, password=None)

    from cryptography.hazmat.primitives.asymmetric import rsa
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )
    from cryptography.hazmat.primitives.serialization import (
        Encoding, PrivateFormat, NoEncryption
    )
    _KEY_FILE.write_bytes(
        private_key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    )
    return private_key


def _build_jwks(private_key) -> dict:
    """Build a JWK Set from the RSA private key's public half."""
    import base64

    pub = private_key.public_key()
    pub_nums = pub.public_key().public_numbers() if hasattr(pub, "public_key") else pub.public_numbers()

    def _b64url_int(n: int) -> str:
        length = (n.bit_length() + 7) // 8
        raw = n.to_bytes(length, "big")
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    return {
        "keys": [{
            "kty": "RSA",
            "use": "sig",
            "alg": "RS256",
            "kid": _KID,
            "n": _b64url_int(pub_nums.n),
            "e": _b64url_int(pub_nums.e),
        }]
    }


def _make_token(private_key, role: str) -> str:
    """Issue a signed RS256 JWT for the given role."""
    try:
        import jwt as pyjwt  # PyJWT
    except ImportError as exc:
        raise ImportError("pip install pyjwt") from exc

    now = int(time.time())
    payload = {
        "iss": _ISSUER,
        "aud": _AUDIENCE,
        "iat": now,
        "exp": now + _TTL,
        "role": role,
    }
    from cryptography.hazmat.primitives.serialization import (
        Encoding, PrivateFormat, NoEncryption
    )
    pem = private_key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    return pyjwt.encode(
        payload,
        pem,
        algorithm="RS256",
        headers={"kid": _KID},
    )


def regenerate(roles: Optional[List[str]] = None) -> Dict[str, str]:
    """(Re)generate key, JWKS, and JWT tokens for the given roles.

    Defaults to all three personas. Returns {role: token_string}.
    Writes .rbac_key.pem, .rbac_jwks.json, .rbac_token_<role>.txt.
    Does NOT hit the network.
    """
    if roles is None:
        roles = ["readonly", "team", "admin"]

    private_key = _load_or_generate_key()

    jwks = _build_jwks(private_key)
    _JWKS_FILE.write_text(json.dumps(jwks, indent=2))

    tokens: Dict[str, str] = {}
    for role in roles:
        tok = _make_token(private_key, role)
        out_file = HERE / f".rbac_token_{role}.txt"
        out_file.write_text(tok)
        tokens[role] = tok

    return tokens


def load_tokens(roles: Optional[List[str]] = None) -> Dict[str, str]:
    """Load tokens from disk. Returns {role: token_string}.

    Raises FileNotFoundError if a token file is missing; call regenerate() first.
    """
    if roles is None:
        roles = ["readonly", "team", "admin"]
    result = {}
    for role in roles:
        f = HERE / f".rbac_token_{role}.txt"
        result[role] = f.read_text().strip()
    return result


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

def assert_rbac_subset(
    readonly_tools: List[str],
    admin_tools: List[str],
) -> None:
    """Assert that readonly tool list is a subset of admin tool list."""
    extra = set(readonly_tools) - set(admin_tools)
    assert not extra, (
        f"readonly tools not in admin set: {extra}\n"
        f"  readonly={sorted(readonly_tools)}\n"
        f"  admin={sorted(admin_tools)}"
    )


if __name__ == "__main__":
    # Quick offline smoke-test: regenerate keys+tokens and print summaries.
    print("Regenerating RBAC key material (offline, no network)...")
    toks = regenerate()
    for role, tok in toks.items():
        print(f"  {role}: {tok[:60]}...")
    print(f"Key:  {_KEY_FILE}")
    print(f"JWKS: {_JWKS_FILE}")
    for role in toks:
        print(f"Token ({role}): {HERE / f'.rbac_token_{role}.txt'}")
