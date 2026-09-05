# Verified live output — agentgateway standalone v1.5.0

Policy: `deny: 'request.headers["user-agent"].contains("curl")'`

Captured against standalone **v1.5.0** (`agw-cel-demo`) with the committed `config.yaml`.

## 1) Default curl User-Agent → 403

```http
HTTP/1.1 403 Forbidden
content-type: text/plain

authorization failed
```

## 2) curl -A 'Mozilla/5.0 (demo)' → 200

```http
HTTP/1.1 200 OK
content-type: application/json
```

```json
{
  "http": 200,
  "model": "gpt-4.1-nano-2025-04-14",
  "content": "Hi there, friend!",
  "usage": {
    "prompt_tokens": 14,
    "completion_tokens": 5,
    "total_tokens": 19
  }
}
```
