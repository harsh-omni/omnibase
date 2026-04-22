# Cloud Event Bus Connection Contract — Design

**Date:** 2026-04-23
**Owner:** Cloud infra (harsh-omni)
**Scope:** Local Claude Code sessions on dev laptops authenticating bidirectionally to cloud Redpanda at `kafka.omninode.ai:9093`.
**Status:** Design validated. Ready for Phase 2 (implementation plan).

---

## Goal

A first-class, documented, codified path for a local Claude Code session to produce and consume from cloud Redpanda with per-actor identity and a predictable local-vs-cloud switch — without building new infra on the broker side (existing SASL/OAUTHBEARER deployment is reused as-is).

## Non-Goals

- Broker-side SASL/OAUTHBEARER plumbing (already deployed; see `repos/omninode_infra/docs/REDPANDA_AUTH_RUNBOOK.md`).
- Cloud-side consumers (omnidash projections, onex-runtime).
- Tailscale / VPN — not required; `kafka.omninode.ai:9093` is a public endpoint with TLS.
- A new broker cluster, a new Keycloak client for `redpanda-events`, or ACL policy authoring.

## Decisions (locked)

| Dimension | Decision |
|---|---|
| Identity model | **Hybrid**: `client_credentials` service account for automated emitters + OAuth 2.0 device code for interactive developer use |
| Bootstrap | **AWS Secrets Manager** — `aws secretsmanager get-secret-value --secret-id onex/dev/local-bootstrap` |
| Token cache | **Local token broker daemon** (`onex-auth-daemon`) — Unix socket, mirrors `delegation_daemon.py` pattern |
| Traffic scope | **Full bidirectional** — producer + consumer + `rpk` CLI wrapper |
| Routing mode | **Hard env switch** — `ONEX_BUS_TARGET=local|cloud`, default `local` |
| Placement | **Split**: contract model + client lib in `omnibase_core`; daemon + bootstrap + CLI in `omninode_infra` |

---

## Architecture

### Identity model

Two actors, one contract.

- **Service-account identity** — automated emitters (hook events, delegation daemon outputs, skill-driven emissions). Keycloak `client_credentials` grant against the existing `redpanda-events` client. Token presents as `tenant_slug=system`.
- **Developer identity** — interactive use (manual scripts, `rpk`, debugging). OAuth 2.0 device code flow against a new `onex-local-dev` Keycloak client (public, no client secret, MFA-compatible). Refresh token persisted in macOS Keychain; access token carries the developer's real Keycloak subject.

### Runtime topology

```
+--------------------+                              AWS Secrets Manager
|  setup-cloud-bus   | --- aws sm get-secret -->   onex/dev/local-bootstrap
+--------------------+                              { redpanda_events_client_secret,
         |                                            onex_local_dev_client_id,
         v                                            keycloak_issuer, kafka_bootstrap }
   ~/.config/onex/bootstrap.json  (0600)

+---------------------+    Unix socket    +---------------------------+   HTTPS
|  hook_event_adapter | <---------------> |     onex-auth-daemon      | <-----> Keycloak
|  kafka_helper.py    |   token request   |  - in-memory token cache  |  JWT fetch
|  onex rpk wrapper   |                   |  - proactive refresh      |  + refresh
+---------------------+                   +---------------------------+
         |
         | ONEX_BUS_TARGET=local -> localhost:19092 (no auth)
         | ONEX_BUS_TARGET=cloud -> kafka.omninode.ai:9093 (SASL_SSL/OAUTHBEARER)
         v
     Redpanda broker
```

---

## Components

### 1. `omnibase_core.models.cloud_bus.ModelCloudBusConnection`

Pydantic model — the wire contract.

```python
class ModelCloudBusConnection(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")
    target: EnumBusTarget                     # local | cloud
    bootstrap_servers: str                    # "localhost:19092" | "kafka.omninode.ai:9093"
    security_protocol: EnumSecurityProtocol   # PLAINTEXT | SASL_SSL
    sasl_mechanism: EnumSaslMechanism | None  # None | OAUTHBEARER
    identity: EnumIdentityKind | None         # None | SERVICE_ACCOUNT | DEVELOPER
    token_broker_socket: Path | None          # /tmp/onex-auth.sock (None when target=local)
```

Plus the enums: `EnumBusTarget`, `EnumSecurityProtocol`, `EnumSaslMechanism`, `EnumIdentityKind`.

### 2. `omnibase_core.cloud_bus.client`

Client library — single entry point for all callers.

- `get_cloud_bus_connection() -> ModelCloudBusConnection` — reads `ONEX_BUS_TARGET` once, constructs the config.
- `get_cloud_bus_producer(identity: EnumIdentityKind) -> KafkaProducer` — returns a producer with a `sasl.oauthbearer.token.refresh.callback` that pulls from the token broker socket.
- `get_cloud_bus_consumer(identity: EnumIdentityKind, group_id: str) -> KafkaConsumer` — same pattern, consumer side.
- `fetch_token(identity: EnumIdentityKind) -> ModelTokenResponse` — direct Unix-socket call; falls back to direct Keycloak fetch when the socket is absent.

### 3. `onex-auth-daemon` (omninode_infra)

User-space token broker — mirrors `plugins/onex/hooks/lib/delegation_daemon.py`.

- Unix socket: `/tmp/onex-auth.sock`; PID file: `/tmp/onex-auth.pid`.
- In-memory cache of both tokens, keyed by `EnumIdentityKind`. Proactive refresh at `exp - 60s`.
- Request protocol (newline-delimited JSON over the socket):
  - Request: `{"identity": "service_account" | "developer"}`
  - Response: `{"access_token": "...", "expires_at": 1735689300}`
- Runs under launchd (`~/Library/LaunchAgents/ai.omninode.auth.plist`, `KeepAlive=true`).

### 4. `onex auth` CLI (omninode_infra)

- `onex auth login` — runs device-code flow, stores refresh token in macOS Keychain (`security add-generic-password -s onex.auth -a <subject>`), ensures the daemon is running.
- `onex auth status` — prints `ONEX_BUS_TARGET`, cached identities and their TTLs, daemon liveness.
- `onex auth logout` — clears Keychain entry, stops daemon.

### 5. `scripts/setup-cloud-bus.sh` (omninode_infra)

- Calls `aws secretsmanager get-secret-value --secret-id onex/dev/local-bootstrap`.
- Writes `~/.config/onex/bootstrap.json` (0600) with the non-secret bits plus the service-account client secret.
- Installs the launchd plist.
- Idempotent — re-runnable for rotation.

### 6. `onex rpk` wrapper (omninode_infra)

Thin shell script that asks the daemon for a developer token, then execs:

```bash
rpk "$@" \
  --brokers kafka.omninode.ai:9093 \
  --tls-enabled \
  --sasl-mechanism OAUTHBEARER \
  --sasl-token "$TOKEN"
```

### 7. `contract.yaml` (omnibase_core)

Declarative mirror of `ModelCloudBusConnection` under `repos/omnibase_core/src/omnibase_core/contracts/cloud_bus/`. Feeds the drift detector and cross-repo verification.

---

## Data flow

### Flow A — First-time onboarding (once per laptop)

1. `aws sso login` (already working).
2. `bash scripts/setup-cloud-bus.sh` → writes `~/.config/onex/bootstrap.json`, installs launchd plist, starts daemon (no tokens cached yet).
3. `onex auth login` → device code + browser URL; dev completes login (MFA supported); refresh token to Keychain; first access token cached in daemon memory.
4. `export ONEX_BUS_TARGET=cloud` (or via direnv `.envrc`).

### Flow B — Hook event emission (hot path)

1. Claude hook fires → `emit_client_wrapper` → Unix socket → emit daemon.
2. `hook_event_adapter` calls `get_cloud_bus_producer(EnumIdentityKind.SERVICE_ACCOUNT)`.
3. First produce (and every ~240s thereafter) triggers the OAUTHBEARER refresh callback, which does `recv` on `/tmp/onex-auth.sock`.
4. Daemon returns cached token (or refreshes via Keycloak `client_credentials` if inside the 60s refresh window).
5. Producer publishes over SASL_OAUTHBEARER + TLS.

### Flow C — Interactive `rpk`

```bash
onex rpk topic consume onex.evt.runtime.agent-routing.v1
# wrapper fetches developer token from daemon, injects --sasl-token, execs rpk
```

### Flow D — Local-only mode (default pre-cloud-bootstrap)

- `ONEX_BUS_TARGET` unset or `=local` → `get_cloud_bus_connection()` returns `bootstrap_servers=localhost:19092`, `security_protocol=PLAINTEXT`, `identity=None`.
- No daemon call, no token, no TLS. Existing local Redpanda path unchanged.

### Invariant

Hooks and skills *only* call `get_cloud_bus_producer()` / `get_cloud_bus_consumer()`. They never touch Keycloak, AWS, or Keychain directly.

---

## Error handling and failure modes

Fail-loud at boundaries (bootstrap, login). Fail-soft in the hot path (emission, refresh).

| Condition | Detection | Behavior |
|---|---|---|
| `ONEX_BUS_TARGET=cloud` but bootstrap file missing | `get_cloud_bus_connection()` first call | **Hard error** — `CloudBusNotBootstrappedError("run scripts/setup-cloud-bus.sh")`. No silent fallback to local. |
| `ONEX_BUS_TARGET=cloud` but daemon socket missing | Client lib connect ENOENT | **Soft fallback** to stateless per-process Keycloak fetch. Logged warning. |
| Daemon up but Keycloak unreachable | Refresh callback 5xx | Daemon serves last known token until `exp`; after that returns `ServiceUnavailable`. `hook_event_adapter` buffers to its existing on-disk queue. Catches up on recovery. |
| Developer refresh token expired/revoked | Keycloak 400 on refresh | Daemon clears developer identity from cache; `onex auth status` shows `developer: not logged in`. Service-account path unaffected. |
| Clock skew > 60s | Broker-side `exp` rejection | Documented in runbook; daemon logs warn on drift vs Keycloak `iat`. macOS NTP makes this rare. |
| AWS creds expired during bootstrap | `aws secretsmanager` error | Bootstrap script exits nonzero with an explicit "run `aws sso login`" message. |
| Wrong `aud` / missing `tenant_slug` | Broker SASL error at produce | Surfaces as `KafkaError`; daemon logs decoded JWT claims; runbook points at existing auth troubleshooting. |
| Bootstrap secret rotated upstream | Produce starts failing 401 | Re-run `scripts/setup-cloud-bus.sh`; rotation is idempotent. |
| Daemon crashes mid-session | launchd `KeepAlive=true` restarts; client lib falls back to stateless fetch in the gap | — |

### Observability (v1)

- Daemon writes a structured log line per refresh: `identity`, `grant_type`, `new_exp`, `latency_ms`.
- Daemon exposes a `status` RPC on the socket — consumed by `onex auth status`.
- Emission envelope tagged with `actor.identity_kind` so cloud-side consumers can distinguish service-account vs developer traffic.
- Reuse the existing `RedpandaSASLAuthFailures` Prometheus alert (see `REDPANDA_AUTH_RUNBOOK.md`). No new metrics surface in v1.

---

## Testing strategy

### Unit (fast, no external deps)

- `ModelCloudBusConnection` field validation; `frozen=True` / `extra=forbid` enforcement; enum exhaustiveness.
- `get_cloud_bus_connection()` env parsing: unset → local; `local` → correct config; `cloud` → correct config; `cloud` + missing bootstrap → `CloudBusNotBootstrappedError`.
- Daemon socket protocol: round-trip request/response; malformed input handling.
- Daemon cache semantics: refresh triggers within 60s of `exp`; concurrent requests don't trigger duplicate Keycloak calls (lock-per-identity).
- `onex rpk` wrapper flag injection; missing daemon produces an explicit error message.

### Integration (docker + mocked Keycloak)

- Ephemeral Redpanda with OAUTHBEARER + mock Keycloak issuing valid JWTs with `aud=redpanda-events`. Assert producer connects, publishes, consumer reads back the exact payload (field-by-field, not just `count > 0`).
- `setup-cloud-bus.sh` against localstack Secrets Manager — assert `bootstrap.json` written with perms `0600` and all required keys present.
- Daemon restart mid-session — kill daemon, produce another event, assert stateless fallback works, assert no events dropped.

### End-to-end proof of life (mandatory Task N)

Against real `kafka.omninode.ai:9093`:

1. Run `setup-cloud-bus.sh`; verify bootstrap file exists with perms `0600`.
2. Run `onex auth login` (device code); verify `onex auth status` shows developer identity with live TTL.
3. With `ONEX_BUS_TARGET=cloud`, publish a known event to `onex.evt.test.cloud-bus-probe.v1` with payload `{"probe_id": "<uuid>", "source": "laptop"}`.
4. `onex rpk topic consume onex.evt.test.cloud-bus-probe.v1 --num 1` — assert the exact `probe_id` round-trips.
5. Verify the event appears in the cloud-side dashboard or projection table with matching `probe_id` and `actor.identity_kind=service_account`.
6. Flip `ONEX_BUS_TARGET=local`, publish again, verify local Redpanda received it and cloud did not.

### Regression guards

- CI check: grep `hook_event_adapter.py` + `kafka_helper.py` for raw `KafkaProducer(...)` construction outside `get_cloud_bus_producer()`; fails PR if a bypass appears.
- CI check: `ModelCloudBusConnection` is the only place that maps `EnumBusTarget` → bootstrap strings (single source of truth).

---

## Open items (deferred)

- Dev-side Prometheus metrics (daemon refresh latency histogram, failure counter).
- Keychain-backed service-account secret storage (currently on disk at `~/.config/onex/bootstrap.json`).
- OIDC device-code client `onex-local-dev` has to be added to `omninode-realm.json` — separate Keycloak PR.
- Linux support (current design targets macOS via launchd + Keychain; Linux port would swap launchd → systemd --user and Keychain → `secret-tool` / libsecret).

## References

- `repos/omninode_infra/docs/REDPANDA_AUTH_RUNBOOK.md` — broker-side SASL/OAUTHBEARER deployment.
- `repos/omninode_infra/docs/COMPENSATING_CONTROLS.md` — public Kafka endpoint risk model.
- `repos/omninode_infra/docs/beta-user-guide/kafka-client-python.md` — external client connection patterns.
- `repos/omniclaude/plugins/onex/hooks/lib/delegation_daemon.py` — daemon pattern being mirrored.
- `repos/omniclaude/plugins/onex/hooks/lib/hook_event_adapter.py:253` — existing Kafka producer (auth wiring lands here).
- `repos/omniclaude/plugins/onex/skills/_shared/kafka_helper.py` — existing `kcat` helper (auth wiring lands here).
