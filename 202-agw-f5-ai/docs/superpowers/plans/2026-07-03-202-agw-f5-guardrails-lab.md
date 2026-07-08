# 202 AGW F5 Guardrails Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable kind lab for AgentGateway plus F5 AI Guardrails using article Options A and C.

**Architecture:** Option A routes AgentGateway to the F5 OpenAI-compatible inline endpoint. Option C routes AgentGateway to OpenAI directly and calls an in-cluster FastAPI adapter from promptGuard request and response webhooks; the adapter calls F5 ScanAPI.

**Tech Stack:** kind, Helm, Gateway API, Enterprise AgentGateway v2026.6.3, FastAPI, pytest, curl, jq.

---

### Task 1: Adapter Contract

**Files:**
- Create: `202-agw-f5-ai/adapter/app.py`
- Create: `202-agw-f5-ai/adapter/test_app.py`
- Create: `202-agw-f5-ai/adapter/requirements.txt`
- Create: `202-agw-f5-ai/adapter/Dockerfile`

- [ ] Write pytest tests for pass, request reject, request redaction, response masking, and ScanAPI failure.
- [ ] Implement the FastAPI adapter with `/healthz`, `/request`, and `/response`.
- [ ] Run `python -m pytest adapter -q`.

### Task 2: Kubernetes Manifests

**Files:**
- Create: `202-agw-f5-ai/manifests/*.yaml`

- [ ] Add the Gateway, Option A backend/route, Option C backend/route, adapter deployment/service, and promptGuard policy.
- [ ] Use placeholders only for non-secret deploy-time values.
- [ ] Validate YAML with `yq`.

### Task 3: Demo Scripts

**Files:**
- Create: `202-agw-f5-ai/deploy.sh`
- Create: `202-agw-f5-ai/test.sh`
- Create: `202-agw-f5-ai/setup-guardrails.sh`
- Create: `202-agw-f5-ai/cleanup.sh`
- Create: `202-agw-f5-ai/step-by-step.sh`
- Create: `202-agw-f5-ai/.env.example`

- [ ] Follow repo K8s demo conventions.
- [ ] Source gitignored `.env` files when present.
- [ ] Keep real secrets out of generated tracked files.
- [ ] Build and load the local adapter image into kind.

### Task 4: Documentation and Skill

**Files:**
- Create: `202-agw-f5-ai/readme.md`
- Modify: `/Users/sebbycorp/.agents/skills/f5-ai-guardrails/SKILL.md`

- [ ] Document prerequisites, Option A/C flows, commands, and expected test behavior.
- [ ] Validate the skill with `quick_validate.py`.

### Task 5: Verification

- [ ] Run adapter tests.
- [ ] Run shell syntax checks.
- [ ] Run YAML parsing checks.
- [ ] Run deploy if all required env vars are available.
