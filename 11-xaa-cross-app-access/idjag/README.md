# Phase B — ID-JAG / Cross App Access (XAA)

End-to-end **Enterprise-Managed Authorization** with agentgateway + Keycloak, with
**no external IdP**. agentgateway turns a user's inbound **ID token** into a
downstream **access token** using the OAuth *Identity Assertion Authorization Grant*
(**ID-JAG**, the open-standard core of Cross App Access) — the client never does a
per-app OAuth dance.

```
client → Bearer <alice ID token> → agentgateway :3030
                                      │  leg 1: token-exchange (agent-client)  → ID-JAG
                                      │  leg 2: jwt-bearer      (resource-client) → access token
                                      ▼
                              echo backend :9000   (sees a token alice never held)
```

## Run

```bash
./deploy.sh          # ID-JAG Keycloak (:8480) + echo backend (:9000) + gateway (:3030)
./round-trip.sh      # raw 3-step exchange, no gateway — prints the decoded ID-JAG
./cleanup.sh         # tear it all down

# or drive + verify through the main harness:
PHASE_B=1 ../test.sh
```

## Pieces

| File | Role |
|------|------|
| `gateway.yaml` | agentgateway `jwtAuth` + `backendAuth.crossAppAccess` (admin/stats/readiness on 15030–15032 to coexist with Phase A) |
| `echo-backend.py` | downstream API that echoes request headers → shows the exchanged token |
| `configure-keycloak.sh` | runs `setup.sh` (realm/clients/leg 1) + `setup-leg2.sh` (self-IdP/jwt-bearer/federated link) |
| `kcadm.sh` | runs Keycloak admin CLI inside the container (no host Keycloak needed) |
| `round-trip.sh` / `mint-idjag.sh` | manual exchange walkthroughs |

## Notes

- **`ceposta/keycloak:id-jag`** is a third-party image (Christian Posta / Solo.io) that
  ships the Identity Assertion (ID-JAG) feature stock Keycloak lacks. It's `amd64`, so it
  runs under emulation on Apple Silicon (slower boot — the deploy waits up to 180s).
- Users/clients: `alice`/`alice`; `agent-client`/`agent-secret` (requester),
  `resource-client`/`resource-secret` (resource AS). Resource id `https://resource.idjag.demo`.
- Runs **alongside** Phase A (different ports); Phase A is untouched.
