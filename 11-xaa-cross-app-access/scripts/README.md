# Helper scripts

| Script | Status | Purpose |
|--------|--------|---------|
| `get-token.sh <user>` | **ready** | Password grant for `alice` \| `bob` \| `mallory` |
| `decode-jwt.sh <jwt>` | **ready** | Print JWT header/payload for the classroom |
| `idjag-exchange.sh <user>` | later | SSO assertion → ID-JAG → MCP access token |

```bash
# Examples (Keycloak must be up: ../setup-keycloak.sh)
./get-token.sh bob
QUIET=1 ./get-token.sh alice | ./decode-jwt.sh
```
