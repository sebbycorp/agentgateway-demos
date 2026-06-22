# 106-ent-atlassian-tokenomics — Design

**Date:** 2026-06-22
**Status:** Approved-pending-review
**Author:** Sebastian Maniak (with Claude Code)

## Summary

A new self-contained demo, `106-ent-atlassian-tokenomics`, that fronts Atlassian's
**Rovo MCP server** (`mcp.atlassian.com/v1/mcp`) with **Enterprise AgentGateway** in
three tool modes — **Standard / Search / Code** — and compares the token cost of
answering the same Jira + Confluence question through each mode.

It is a direct fork of `104-ent-github-tokenomics`. The proven structure stays; only
the upstream MCP target, the injected auth header, and the test prompts change. There
is **no MCP pod in-cluster** — Atlassian's server is external, exactly like GitHub's in
`104`.

## Goals

- Demonstrate AGW Enterprise tool-mode tokenomics on a real, large external MCP catalog
  (Atlassian Jira + Confluence).
- Reuse the 103/104/105 demo conventions so it's consistent with the rest of the repo.
- Document, clearly, the one hard part: connecting AGW to an Atlassian account.

## Non-goals

- No Headroom compression knob (that is `105`'s job).
- No OAuth 2.1 browser flow — we use static API-token auth so the gateway can inject a
  fixed `Authorization` header (machine-to-machine).
- Grafana `observability/` dashboard is **out of scope for v1** (stretch; addable later).

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Demo shape | Tool-modes tokenomics fork of `104` (Standard / Search / Code) |
| Products | Both Jira + Confluence |
| Auth | **Personal API token (Basic auth)** — `Authorization: Basic base64(email:token)` |
| Cluster name | `agw-atlassian-tokenomics` |
| AGW version | `v2026.6.1` (matches 104/105) |
| Gateway API | `v1.5.0` |
| Observability dashboard | Deferred (stretch) |

### Why Basic / personal token (not Bearer / service account)

`maniakacademy.atlassian.net` is a small/personal site. Service-account API keys are an
org-managed-accounts (Atlassian Guard) feature requiring admin provisioning and likely
unavailable on this site. A **personal API token** needs no admin provisioning and works
on any account. The org admin has already enabled **API-token auth** for the Rovo MCP
server (Atlassian Administration → Rovo → Rovo MCP server → Authentication → API token: on),
which is the prerequisite for either method.

## Architecture

```
kind cluster (agw-atlassian-tokenomics)
  └─ Enterprise AgentGateway v2026.6.1   (ns: agentgateway-system)
       ├─ /openai            → OpenAI LLM backend (the model)
       ├─ /mcp/atl-std       → atl-std    (entMcp.toolMode: Standard) ┐
       ├─ /mcp/atl-search    → atl-search (entMcp.toolMode: Search)   ├─ static target →
       └─ /mcp/atl-code      → atl-code   (entMcp.toolMode: Code)     ┘  mcp.atlassian.com:443
                                                                          protocol: StreamableHTTP
                                                                          path: /v1/mcp, tls: {}
                                                                          Authorization: Basic <b64>
```

Each `EnterpriseAgentgatewayBackend` has one `static` target pointing at
`mcp.atlassian.com:443`, `protocol: StreamableHTTP`, `path: /v1/mcp`, with `tls: {}` and
`auth.secretRef` pointing at the `atlassian-key` Secret, injected via
`location.header { name: Authorization, prefix: "Basic " }`.

The Secret stores **`base64(email:api_token)`** (the prefix `Basic ` is prepended by the
gateway), so the upstream sees `Authorization: Basic base64(email:token)`.

HTTPRoutes expose `/mcp/atl-std`, `/mcp/atl-search`, `/mcp/atl-code` on the gateway and
`URLRewrite` the prefix to `/mcp` (same pattern as 104's `gh-*` routes).

## Files (mirrors 104)

| File | Change from 104 |
|------|-----------------|
| `deploy.sh` | cluster `agw-atlassian-tokenomics`; checks `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`, `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN`; computes `base64(email:token)` and substitutes into `k8s/atlassian.yaml` |
| `k8s/atlassian.yaml` | `atlassian-key` Secret (`__ATLASSIAN_B64__` placeholder) + `atl-std/search/code` backends + 3 HTTPRoutes |
| `k8s/openai.yaml` | unchanged from 104 |
| `harness/atl_chat.py` | forked `gh_chat.py`; mode→endpoint map uses `/mcp/atl-*` |
| `harness/atl_questions.py` | forked; Jira + Confluence question set |
| `harness/atl_conversation.py` | forked; multi-turn Jira/Confluence conversation |
| `harness/requirements.txt` | unchanged |
| `test.sh` | Jira+Confluence default question (`ATL_TASK` override), runs all 3 modes |
| `cleanup.sh` | deletes `agw-atlassian-tokenomics` cluster |
| `.env.example` | `AGENTGATEWAY_LICENSE_KEY`, `OPENAI_API_KEY`, `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN` |
| `README.md` | Atlassian framing + **Atlassian account setup section** |
| `COST-ANALYSIS.md` / `REPORT.md` | skeletons for measured results |
| `observability/` | **deferred** (stretch) |

## deploy.sh auth handling (key detail)

```bash
[[ -n "${ATLASSIAN_EMAIL:-}"     ]] || { echo "ERROR: ATLASSIAN_EMAIL not set." >&2; exit 1; }
[[ -n "${ATLASSIAN_API_TOKEN:-}" ]] || { echo "ERROR: ATLASSIAN_API_TOKEN not set." >&2; exit 1; }
ATL_B64="$(printf '%s' "${ATLASSIAN_EMAIL}:${ATLASSIAN_API_TOKEN}" | base64 | tr -d '\n')"
sed "s|__ATLASSIAN_B64__|${ATL_B64}|" "${SCRIPT_DIR}/k8s/atlassian.yaml" | kubectl apply -f-
```

## Atlassian account setup (documented in README)

1. **Admin: enable API-token auth** — Atlassian Administration → Rovo → Rovo MCP server →
   Authentication → turn **API token** on. *(Already done.)*
2. **Create a personal API token** — `https://id.atlassian.com/manage-profile/security/api-tokens`
   → Create API token. Copy it.
3. **Populate `.env`** — `ATLASSIAN_EMAIL=you@domain`, `ATLASSIAN_API_TOKEN=<token>`.
   `deploy.sh` base64-encodes `email:token` and stores it in the `atlassian-key` Secret.
4. Site in use: `maniakacademy.atlassian.net`. Have at least one Jira project with issues
   and one Confluence space with pages so answers are meaningful.

## Test prompt

Default (`ATL_TASK` overrides): a question spanning both products, e.g.
*"List my Jira projects and their open issue counts, and find any Confluence pages that
mention onboarding."* Parameterizable so it can be tuned to the actual site content.

## Known caveats (documented, not hidden)

- **API-token auth exposes a smaller tool set than OAuth.** Atlassian disables some tools
  (e.g. certain Compass tools) under token auth because required product scopes aren't
  available. Fine for a Jira+Confluence tokenomics demo; noted in README.
- Needs real Jira/Confluence content on the site for non-empty answers.
- **Endpoint migration:** use `/v1/mcp` (not the legacy `/v1/sse`, unsupported after
  2026-06-30).
- Code mode runs the same in-gateway sandbox as 104 (`codeMode.timeout: 10s`).

## Success criteria

- `./deploy.sh` brings up the cluster + gateway + all backends with no manual steps
  beyond setting the 4 env vars.
- `./test.sh` answers the same Jira+Confluence question through all three modes and prints
  per-mode token cost.
- `Search` mode shows materially lower prompt-token cost than `Standard` on Atlassian's
  large catalog (the tokenomics thesis), consistent with the 104 GitHub finding.
- `./cleanup.sh` removes the cluster.

## References

- Atlassian remote (Rovo) MCP server: https://www.atlassian.com/platform/remote-mcp-server
- API-token auth config: https://support.atlassian.com/atlassian-rovo-mcp-server/docs/configuring-authentication-via-api-token/
- Control MCP server settings (admin enable): https://support.atlassian.com/security-and-access-policies/docs/control-atlassian-rovo-mcp-server-settings/
- Tool modes: https://docs.solo.io/agentgateway/latest/mcp/tool-mode/
- Sibling demo: `104-ent-github-tokenomics`
