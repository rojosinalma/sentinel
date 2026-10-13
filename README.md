# sentinel

The homelab's HA decision layer: one sentinel per participating host — **node-a**, **node-b**,
**witness-1** (witness) — that probes every host, agrees on who is primary by **majority**
(4 of 7 voters since 2026-10-13: members node-a + node-b, witnesses witness-1..5), takes a 30 s **majority lease** before any action, runs per-service bash **hooks**
(`hooks/opencode/` first) to promote and fail back, records every probe/decision/transition in
SQLite, and serves `/status` byte-compatible with the bash sentinel it replaces, a Dracula
dashboard and an MCP endpoint for agents.

This repo is a history-preserving clone of `standby-status` (the status page it absorbs; the
page still renders on instances without `NODE_NAME`). The design and interfaces are in
[docs/architecture.md](docs/architecture.md); the phase-4 cutover runbook is
[docs/cutover.md](docs/cutover.md). Until that cutover the live bash sentinel in
`~/dev/opencode-node-b/sentinel/` stays armed on node-b.

## How it decides

```
every node, every POLL_INTERVAL_S (2 s):
  probe every host (service /api/info, tcp:22, tcp:443, icmp) in parallel
  classify the primary: ok | degraded | dead | isolated      (bash classifier, 1:1)
  gossip: GET <peer>/peer/view from both peers; publish own view
  agree: a host is DEAD only when a majority of fresh views (4 of 7) say so
  a node without majority contact is ISOLATED and never acts

the ACTING node of a service only (its standby — node-b for opencode; one Loop drives every service
in cluster.yml, each with its own decider and lease):
  while watching (mode = primary): `replicate warm` every STACK/WATCH interval keeps one
    litestream follower per DB at the replica's txid, so a promote renames instead of restoring
  down ≥ PROMOTE_AFTER_S (60 s) or DEAD_CONFIRM_POLLS dead cycles
    → majority lease (POST /peer/lease to both peers, 2 grants incl. self)
    → hooks/opencode/promote --auto [--fast]        (the ported bash promote)
  promoted + primary stable ≥ FAILBACK_AFTER_S (30 s; 600 s when flapping)
    → lease → hooks/opencode/demote --yes --auto
  while promoted: hooks/opencode/replicate fence|stack every FENCE/STACK interval
```

Timers, gates (cooldown, retry, hold, flap damping) and notification texts are the bash
sentinel's, ported 1:1 into `Sentinel::Decider` and verified by table-driven tests.

## Endpoints

| Path | What |
|---|---|
| `GET /status` | Byte-compatible with the bash sentinel (same keys, order, compact JSON; HTTP/1.0 ok). Consumers: both service-guards, replica-guard, Gatus 79, opencode-node-b `bin/verify`, the page itself |
| `GET /peer/view` | This node's gossip view (hosts, classes, primary, lease, seq) |
| `POST /peer/lease`, `/peer/lease/release` | Majority-lease grant/release (peers only) |
| `GET /` | Dashboard: legacy standby cards + cluster view, actions (hold/promote/demote with typed-word confirm), events, transitions |
| `GET /api/status` | The legacy standby-status probe document (page data) |
| `GET /api/v1/status` | All services, neutral names: per-service mode/agreed class/gates, per-host probes |
| `GET /api/sentinel`, `/api/events`, `/api/transitions` | Dashboard data (`?service=` on /api/sentinel) |
| `POST /api/hold`, `/api/promote`, `/api/demote` | Actions (confirm word; `dry_run=true` returns the hook's plan) |
| `POST /mcp` | MCP (Streamable HTTP, stateless) behind `SENTINEL_MCP_TOKEN`: tools `status cluster events hold promote demote` |
| `GET /health` | Instance liveness (legacy shape) |

## CLI

```
bin/sentinel serve                  # puma + the loop
bin/sentinel once | status          # one cycle, print /status JSON (bash --once parity)
bin/sentinel hold [on|off|status]
bin/sentinel promote --dry-run      # execs the hook directly (no lease on dry runs)
bin/sentinel promote                # majority lease → hooks/opencode/promote
bin/sentinel demote                 # majority lease → hook (asks for the word "demote"; --yes skips)
```

## Deployment (release 1)

| Node | Where | Role | Extras |
|---|---|---|---|
| node-a | orchestrator service (ex `standby-status`, id 62), `compose.yaml` | member | port 4197, Traefik `sentinel.node-a.example.com` |
| node-b | plain compose `~/dev/sentinel`, `node-b/compose.yaml` | member, **acting** | docker socket, ssh, `$NODE_B_ROOT` + opencode data mounts, port 4197 |
| witness-1 | plain compose `/opt/sentinel`, `witness-1/compose.yaml` | witness | GHCR multi-arch image, port 4197 |

`bin/release` builds and distributes: node-a registry (amd64) + GHCR
`ghcr.io/rojosinalma/sentinel` (amd64+arm64, buildx) + pre-pull on node-b. Config is `.env`
per instance (`.env.example` lists every tunable); the cluster table `config/cluster.yml` is
identical on every node and `NODE_NAME` picks the row.

## Development

```
bundle install
bundle exec rake test          # minitest; fake clock, in-process 3-node cluster, no LAN access
bin/sentinel once              # one real probe cycle from this host
```

The bash hooks under `hooks/opencode/` are a 1:1 port of
`opencode-node-b/sentinel/bin/{promote,demote}` + `lib/common.sh` (only the env-resolution header
differs); `hooks/_example/` is the fixture the loop tests run end to end. The hook contract (env,
exit codes, logs, adding a service) is `docs/hooks.md`; hooks are mounted from the checkout, not
baked into the image.
