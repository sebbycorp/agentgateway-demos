#!/usr/bin/env python3
"""Tiny OpenAI-compatible stub that always reports a fixed token usage.

Used when OPENAI_API_KEY is unset so the 1.5.0 budget demo can still charge
and then trip Block / show Audit on /api/budgets/status.

Each chat completion reports 150 prompt + 350 completion = 500 total tokens,
sized against the committed limits: the 1000-token budget is crossed on the
second call and the 0.02 USD budget on the second gpt-5.5 call, so Block trips
on the call after that.
"""
from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PROMPT_TOKENS = 150
COMPLETION_TOKENS = 350
TOTAL_TOKENS = PROMPT_TOKENS + COMPLETION_TOKENS


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"mock-openai: {self.address_string()} {fmt % args}")

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/health", "/healthz"):
            self._json(200, {"ok": True})
            return
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            self._json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "gpt-5.5",
                            "object": "model",
                            "owned_by": "mock",
                        }
                    ],
                },
            )
            return
        self._json(404, {"error": {"message": "not found", "code": "not_found"}})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0].rstrip("/")
        if path not in ("/v1/chat/completions", "/chat/completions"):
            self._json(404, {"error": {"message": "not found", "code": "not_found"}})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            req = {}
        model = req.get("model") or "gpt-5.5"
        self._json(
            200,
            {
                "id": "chatcmpl-mock-budget",
                "object": "chat.completion",
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "OK"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": PROMPT_TOKENS,
                    "completion_tokens": COMPLETION_TOKENS,
                    "total_tokens": TOTAL_TOKENS,
                },
            },
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="OpenAI-compatible usage stub")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"mock-openai listening on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
