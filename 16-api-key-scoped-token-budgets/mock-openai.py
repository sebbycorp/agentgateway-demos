#!/usr/bin/env python3
"""Tiny OpenAI-compatible stub that always reports a fixed token usage.

Used when OPENAI_API_KEY is unset so the 1.5.0 budget demo can still charge
and then trip Block / show Audit on /api/budgets/status.

Each chat completion reports 25 prompt + 15 completion = 40 total tokens,
matching the committed Tokens limit so the second Block-key call is denied.
"""
from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


TOTAL_TOKENS = 40
PROMPT_TOKENS = 25
COMPLETION_TOKENS = 15


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
                            "id": "gpt-4.1-nano",
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
        model = req.get("model") or "gpt-4.1-nano"
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
