# API and MCP

Every node serves the same HTTP API on the cluster port (`SENTINEL_PORT`, 4197 by default; the
container listens on 9292 and the compose files publish it as 4197). Action responses are
`{ok, message, …}`; read endpoints return JSON documents.

## Endpoints

| Endpoint | Method | Purpose | Auth |
|---|---|---|---|
| `/health` | GET | liveness (`served_by`, `version`) | none |
| `/status` | GET | legacy single-service document (frozen contract, see below) | none |
| `/api/v1/status` | GET | every service: mode, agreed class, gates, lease, per-host probes and classes | none |
| `/api/sentinel?service=` | GET | dashboard data for one service | none |
| `/api/events?service=&kind=&limit=` | GET | audit events, newest first | none |
| `/api/transitions?service=` | GET | promote/demote runs with exit code and log file | none |
| `/api/hold` | POST | `on=true|false`, optional `service` (else node-wide) | none |
| `/api/promote` | POST | `service`, `confirm=promote` or `dry_run=true`, `fast`, `force` | none |
| `/api/demote` | POST | `service`, `confirm=demote` or `dry_run=true` | none |
| `/peer/view` | GET | this node's gossip view (used by peers) | none |
| `/peer/lease`, `/peer/lease/release` | POST | majority-lease grant/release (used by peers) | none |
| `/mcp` | POST | MCP Streamable HTTP; tools `status cluster events hold promote demote` | bearer `SENTINEL_MCP_TOKEN` |
| `/` | GET | dashboard | none |

Actions (`hold` with a service, `promote`, `demote`) sent to a node that is not the service's
acting node are forwarded to the acting node (`FORWARD_TIMEOUT_S`), so the dashboard buttons and
the MCP tools work from any voter. `dry_run` runs the real hook with `--dry-run` and returns its
output tail in `message`. The `who` parameter (`[\w.@-]{1,64}`) tags the audit row with the
caller; the dashboard sends `dashboard`, a forwarding node appends `@<node>`.

Without `NODE_NAME` the process boots no sentinel runtime and every sentinel route answers 503.

## `/api/v1/status`

The service-neutral document, one entry per service:

```json
{"ok":true,"node":"node-b","at":"…","status_age_s":1,"quorum":"up","reachable_peers":["node-a","witness-1"],
 "majority":2,"hold":false,"transition":null,"tunables":{"poll_interval_s":2,"…":0},
 "hosts":{"node-a":{"role":"member","probes":{"ssh":"up","icmp":"up","https":"up"},
                    "services":{"app":"up 1.4.2"},"classes":{"app":"ok"}}, "…":{}},
 "services":{"app":{"primary":"node-a","standby":"node-b","acting":true,"mode":"node-a","since":"…",
                    "agreed_class":"ok","classification":"ok","gates":{"promote_cooldown_left_s":0,"…":0},
                    "busy":false,"standby_stack":null,"hold":false,"transition":null,"action_running":null,
                    "route_primary":"n/a","routes":{"mode":"off","group":"app","pihole_names":[]},
                    "url":"https://app.example.com","host_urls":{},"lease":null,"last_transition":null}},
 "route_primary":{"app":"n/a"},"ha_connectors":null}
```

Read this one from anything new. Hosts of a service whose primary is promoted are labelled
`standby` (not `degraded`) while they stand by.

## `GET /status` — the legacy document

`/status` is a **frozen contract**: same keys, same order, same types, compact JSON
(`JSON.generate`, no spaces), `Cache-Control: no-store`. It describes exactly one service, the
one named by `LEGACY_SERVICE` (default `opencode`), and its key names carry the host labels of
the deployment the document was first written for: `silver_*` describe the **primary** host and
service, `tiny_*` the **standby**. They are field names, not configuration — the values are your
hosts. `test/fixtures/status_legacy.json` pins the exact output.

```
mode since silver_opencode silver_opencode_version silver_host silver_host_health quorum classification
dead_polls host_probes{ssh,icmp,https} poll_interval_s dead_confirm_polls promoting transition
auto_promote auto_failback hold down_since promote_after_s promote_cooldown_left_s promote_retry_left_s
silver_stable_since failback_after_s failback_retry_left_s flips_in_window tiny_stack route_mode
route_primary ha_connectors checked_at status_age_s
```

| Legacy key | Meaning |
|---|---|
| `mode` | host name of the current primary, read live from the state file (a running hook updates it mid-transition) |
| `since` | when `mode` last changed |
| `silver_opencode`, `silver_opencode_version` | the service's state on the primary host (`up <ver>` / `up auth?` / `down`) and the version alone |
| `silver_host`, `silver_host_health` | the primary host's ssh probe, and the last `health` hook verdict while promoted |
| `silver_stable_since` | since when the primary has been healthy (failback timer) |
| `tiny_stack` | the `replicate stack` marker on the standby (`healthy` / `degraded: …`) |
| `quorum`, `classification`, `dead_polls`, `host_probes` | this node's view of the primary |
| `promoting`, `transition` | a promote/demote hook is running (lock held) / `"<hook> <ts>"` |
| `auto_promote`, `auto_failback`, `hold` | the switches (`"on"`/`"off"` strings) and the hold flag |
| `down_since`, `promote_after_s`, `*_left_s`, `failback_after_s`, `flips_in_window` | the decider's timers and gates |
| `route_mode`, `route_primary`, `ha_connectors` | route mode, who the routes point at (`n/a` when off), tunnel connector count or null |
| `checked_at`, `status_age_s` | the last cycle and its age |

Consumers written against it rely on `mode` being one of the two member names (anything else
counts as unreachable), on the raw `"mode":"<standby>"` substring, on `ha_connectors` being an
integer and on `route_primary == mode`. Keep those invariants if you ever extend it.

## MCP

`POST /mcp` is a stateless MCP Streamable HTTP endpoint (JSON-RPC in the body) with a bearer
token. The tools mirror the API: `status` (`service` optional → the legacy document), `cluster`
(the v1 document for one service), `events` (`service`, `kind`, `limit`), `hold` (`on`,
`service`), `promote` (`service`, `confirm: "promote"` or `dry_run`, `fast`, `force`) and
`demote` (`service`, `confirm: "demote"` or `dry_run`). An empty `SENTINEL_MCP_TOKEN` turns the
endpoint off (404).
