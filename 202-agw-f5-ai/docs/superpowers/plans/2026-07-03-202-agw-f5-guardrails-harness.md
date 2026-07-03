# 202 AGW F5 Guardrails Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repeatable CLI testing harness for the AgentGateway + F5 AI Guardrails lab.

**Architecture:** Keep `test.sh` as the smoke test. Add `harness/guardrails_harness.py` to load declarative YAML cases, call the deployed `/option-a` and `/option-c` routes, classify results, print a pass/fail table, and write JSONL evidence. Add `run_harness.sh` as the demo entry point that manages a local port-forward when needed.

**Tech Stack:** Python 3, `httpx`, `PyYAML`, pytest, shell, curl/kubectl.

---

### Task 1: Harness Core

**Files:**
- Create: `harness/test_guardrails_harness.py`
- Create: `harness/guardrails_harness.py`
- Create: `harness/requirements.txt`

- [ ] Write tests for response classification and JSONL-safe result records.
- [ ] Run `python -m pytest harness -q` and verify the tests fail because `guardrails_harness` is missing.
- [ ] Implement classification, case loading, HTTP execution, result records, and CLI exit codes.
- [ ] Run `python -m pytest harness -q` and verify the tests pass.

### Task 2: Cases and Runner

**Files:**
- Create: `harness/cases.yaml`
- Create: `run_harness.sh`
- Modify: `.gitignore`
- Modify: `readme.md`

- [ ] Add cases for Option A benign/block, Option C benign/block/redact/response-phase mask.
- [ ] Add `run_harness.sh` to create `harness/.venv`, install dependencies, start port-forward if needed, run the harness, and write `harness/results.jsonl`.
- [ ] Ignore generated harness venv/results.
- [ ] Document the harness commands and output.

### Task 3: Verification

- [ ] Run `python -m pytest adapter harness -q`.
- [ ] Run shell syntax checks for all scripts.
- [ ] Run YAML parse checks for manifests and harness cases.
- [ ] Run `./run_harness.sh` against the deployed kind cluster.
