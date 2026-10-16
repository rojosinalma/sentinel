# sentinel

Majority-vote failover for self-hosted services: one small Ruby process per host that probes,
agrees on who is primary, takes a lease and runs your promote/demote scripts.

![dashboard](docs/images/dashboard.png)



## How it works

1. Every node probes every host (service health URL, TCP ports, ICMP) every `POLL_INTERVAL_S`.
2. Each probe result is **classified**: `ok`, `degraded` (service down, host up), `dead`
   (nothing answers) or `isolated` (this node lost its own quorum and must not judge).
3. Nodes exchange views over `GET /peer/view`. A host counts as dead only when a **majority**
   (≥ ⌊n/2⌋+1 of the configured voters; keep the count odd) of fresh views say so.
4. Only the service's **standby** node acts (the *acting node*). After the configured delay it
   requests a **30 s majority lease** from its peers, renewed while it works.
5. Under the lease it runs the service's **hooks**: `promote` to take over, `demote` to hand
   back once the primary is healthy and stable, `health` / `replicate` for upkeep in between.
6. Optionally the core then moves the public **routes** (`routes.mode`, off by default).
7. Every probe change, decision, lease and transition is written to SQLite and shown on the
   dashboard, `/api/events` and `/api/transitions`.

Cooldowns, retries, flap damping (`FLAP_*`) and a manual `hold` keep it from ping-ponging.

## Quick start

```sh
git clone https://github.com/rojosinalma/sentinel.git && cd sentinel
cp config/cluster.example.yml config/cluster.yml   # your hosts and services
cp .env.example .env                                # set NODE_NAME to this host's key
mkdir -p data                                       # state + sqlite; owned by you, not root
docker compose up -d
```

The container runs as uid 1000 (`APP_UID`/`APP_GID` build args); `data/` must be writable by it.

Repeat on every voter with its own `NODE_NAME`; `config/cluster.yml` and `hooks/` are bind-mounted
from the checkout and must be identical on every node. The image is
`ghcr.io/rojosinalma/sentinel:0.5.0` (amd64 + arm64).

The **acting node** (a service's `standby`) runs the hooks, so it needs whatever they need —
typically the docker socket, ssh keys and the service's data directories mounted at the same
paths as on the host. [tiny/compose.yaml](tiny/compose.yaml) is the acting-node example;
[compose.yaml](compose.yaml) is a plain member/witness.

## Configuration

All keys live in `.env` (loaded with dotenv); an empty value means "use the default".

| Group | Key | Default | Meaning |
|---|---|---|---|
| node/files | `NODE_NAME` | — | this node's key under `hosts:` in cluster.yml (required) |
| | `CLUSTER_FILE` | `config/cluster.yml` | path of the cluster table |
| | `STATE_DIR` | `data/state` | state files (`<svc>/mode`, locks, markers, `hold`) |
| | `LOG_DIR` | `data/logs` | hook logs |
| | `DB_PATH` | `data/sentinel.db` | SQLite audit trail |
| | `EVENTS_KEEP_DAYS` | `30` | daily prune horizon for events/transitions |
| | `SENTINEL_PORT` | `4197` | the port peers use (`sentinel_url` in cluster.yml) |
| polling | `POLL_INTERVAL_S` | `2` | loop cycle |
| | `DEAD_CONFIRM_POLLS` | `5` | consecutive dead cycles before a fast promote |
| | `DEGRADED_CONFIRM_POLLS` | `1` | consecutive degraded cycles before counting the service down |
| timers | `PROMOTE_AFTER_S` | `60` | service down this long → promote |
| | `FAILBACK_AFTER_S` | `30` | primary healthy this long → demote (fail back) |
| | `PROMOTE_COOLDOWN_S` | `120` | no promote this soon after a demote |
| | `PROMOTE_RETRY_S` | `120` | retry delay after a failed promote |
| | `FAILBACK_RETRY_S` | `300` | retry delay after a failed demote |
| flap control | `FLAP_FLIPS` | `3` | mode flips within the window that count as flapping |
| | `FLAP_WINDOW_S` | `3600` | the window |
| | `FLAP_FAILBACK_AFTER_S` | `600` | failback delay while flapping |
| cadences | `HOST_HEALTH_INTERVAL_S` | `15` | `health` hook while promoted |
| | `FENCE_INTERVAL_S` | `60` | `replicate fence` while promoted (also log throttling) |
| | `STACK_CHECK_INTERVAL_S` | `30` | `replicate stack` (promoted) / `replicate warm` (watching) |
| | `STACK_RETRY_S` | `120` | retry delay for a degraded stack |
| | `HEARTBEAT_S` | `300` | heartbeat event |
| switches | `AUTO_PROMOTE` | `on` | `on`/`off`, node-wide (per service: `auto_promote` in cluster.yml) |
| | `AUTO_FAILBACK` | `on` | `on`/`off` |
| timeouts | `TCP_TIMEOUT_S` | `2` | TCP/ICMP probes |
| | `HTTP_TIMEOUT_S` | `5` | service health probes (per service: `tunables.probe_timeout_s`) |
| | `PEER_TIMEOUT_S` | `2` | gossip and lease requests |
| | `PEER_STALE_S` | `10` | a peer view older than this is not counted |
| | `FORWARD_TIMEOUT_S` | `60` | an action received on a non-acting node is forwarded to the acting one |
| | `LEASE_TTL_S` | `30` | majority lease TTL |
| | `LEASE_RENEW_S` | `10` | renew interval while a hook runs |
| | `HOOK_TIMEOUT_S` | `900` | SIGTERM a hook after this (SIGKILL 10 s later) |
| notifications | `NOTIFY_DOWN_AFTER_S` | `60` | notify after the service is down this long |
| | `DISCORD_WEBHOOK_URL` | — | Discord webhook (empty = skipped) |
| | `APPRISE_URL` | — | Apprise endpoint (empty = skipped) |
| routes | `ROUTE_MODE` | `off` | node-wide default for `routes.mode`: `ha-routes` \| `off` |
| | `HA_ROUTES_BIN` | — | the `ha-routes` binary (mode `ha-routes` only) |
| | `ROUTES_ENV_FILE` | — | env file of `ha-routes` (tunnel id lookup; mode `ha-routes` only) |
| | `HA_TUNNEL_ID`, `CF_API_TOKEN`, `CF_ACCOUNT_ID` | — | Cloudflare tunnel connector count (optional) |
| | `ROUTE_TIMEOUT_S` | `60` | timeout for the route command |
| dashboard | `HOST_NAME` | `unknown` | "served by" label |
| | `REFRESH_S` | `10` | page poll interval |
| | `OTHER_INSTANCE_URL`, `OTHER_INSTANCE_NAME` | — | footer link to another node's dashboard |
| | `APP_VERSION`, `BUILD_TIME` | `dev`, — | set by the image build |
| | `LEGACY_REDIRECT_FROM`, `LEGACY_REDIRECT_TO` | — | host-prefix 308 redirect (`standby.` → `sentinel.`); off when empty |
| MCP / misc | `SENTINEL_MCP_TOKEN` | — | bearer for `POST /mcp`; empty disables the endpoint (404) |
| | `LOG_LEVEL` | `info` | logger level |
| | `RACK_ENV` | `production` | `development` enables code reloading |
| | `SN_ENV` | `<repo>/.env` | path of the env file handed to hooks |

### cluster.yml

```yaml
hosts:
  node-a:    {address: 192.0.2.10, sentinel_url: http://192.0.2.10:4197, role: member,  probes: {ssh: 22, https: 443, icmp: true}}
  node-b:    {address: 192.0.2.20, sentinel_url: http://192.0.2.20:4197, role: member,  probes: {ssh: 22, https: 443, icmp: true}}
  witness-1: {address: 192.0.2.30, sentinel_url: http://192.0.2.30:4197, role: witness, probes: {ssh: 22, icmp: true}}
quorum_tcp: [192.0.2.1:53]          # a node that cannot reach any of these is isolated
services:
  app:
    primary: node-a
    standby: node-b                 # the acting node
    health:                         # probed every cycle; 200 → up, 401 → up auth?, else down
      node-a: http://192.0.2.10:8080/health
      node-b: http://192.0.2.20:8080/health
    probe:                          # optional
      username_env: APP_USER        # names of .env variables holding a Basic credential
      password_env: APP_PASS
      headers: {X-Probe: sentinel}
      resolve: {node-a: 192.0.2.10} # same URL on every host → connect to this ip instead
      tls_verify: true              # false for self-signed certificates
    auto_promote: true              # optional, overrides AUTO_PROMOTE
    tunables: {promote_after_s: 90, probe_timeout_s: 10}   # optional, see SERVICE_TUNABLES
    routes: {mode: off}             # ha-routes | pihole | off (default)
    url: https://app.example.com    # dashboard link (optional)
    host_urls: {node-a: https://node-a.example.com}         # per-host links (optional)
    hooks_dir: hooks/app            # default hooks/<service>
```

Hosts are `member` (may be primary/standby) or `witness` (votes only). `probes` are per host:
`ssh`/`https` TCP ports, `icmp` on/off. `tunables` may override any of `promote_after_s
failback_after_s promote_cooldown_s promote_retry_s failback_retry_s flap_flips flap_window_s
flap_failback_after_s dead_confirm_polls degraded_confirm_polls probe_timeout_s
notify_down_after_s fence_interval_s stack_check_interval_s host_health_interval_s`.

Route modes: `off` (default) does nothing; `pihole` means the hooks move DNS records themselves;
`ha-routes` makes the core run `ha-routes set <host> --group <group>` after a successful hook —
that CLI is private to the author's homelab, so treat the mode as an extension point.

## Hooks

The sentinel decides; hooks act. Each service owns four executables in `hooks/<service>/`:

| Hook | Called | Must |
|---|---|---|
| `promote [--auto] [--fast] [--dry-run]` | service down long enough | fence the primary, start the standby, write `STANDBY` to `$STATE_DIR/mode` |
| `demote --yes [--auto] [--dry-run]` | primary healthy and stable | the reverse, write `PRIMARY` to `mode` |
| `health` | periodically while promoted | last stdout line `up` or `down <reason>` |
| `replicate fence\|stack\|warm` | periodic upkeep | re-fence, repair own stack, keep followers warm |

Exit `0` done, `1` nothing changed (retried later), `2` done but degraded. Environment:
`SERVICE PRIMARY STANDBY ACTING_NODE STATE_DIR NODE_STATE_DIR SN_ENV DRY_RUN`. Full contract in
[docs/hooks.md](docs/hooks.md). Start from [hooks/_example](hooks/_example) (the minimal set the
tests run). `hooks/opencode` and `hooks/fleet` are shipped as real-world examples; they are
specific to the author's setup (host names, units, container names) and are not meant to run
elsewhere unchanged.

## API and MCP

| Endpoint | Method | Purpose | Auth |
|---|---|---|---|
| `/health` | GET | liveness | none |
| `/status` | GET | legacy single-service document (frozen contract, see below) | none |
| `/api/v1/status` | GET | every service: mode, agreed class, gates, per-host probes | none |
| `/api/sentinel?service=` | GET | dashboard data for one service | none |
| `/api/events?service=&kind=&limit=` | GET | audit events, newest first | none |
| `/api/transitions?service=` | GET | promote/demote runs with exit code and log file | none |
| `/api/hold` | POST | `on=true|false`, optional `service` (else node-wide) | none |
| `/api/promote` | POST | `service`, `confirm=promote` or `dry_run=true`, `fast`, `force` | none |
| `/api/demote` | POST | `service`, `confirm=demote` or `dry_run=true` | none |
| `/peer/view` | GET | this node's gossip view (peers) | none |
| `/peer/lease`, `/peer/lease/release` | POST | majority-lease grant/release (peers) | none |
| `/mcp` | POST | MCP Streamable HTTP, tools `status cluster events hold promote demote` | bearer `SENTINEL_MCP_TOKEN` |
| `/` | GET | dashboard | none |

Actions sent to a non-acting node are forwarded to the acting node. Every action response is
`{ok, message, …}`.

### Security

Only `/mcp` carries authentication. `/peer/*`, `/api/promote`, `/api/demote`, `/api/hold` and the
dashboard are **unauthenticated**: run sentinel on a trusted network (the cluster port should be
reachable by the voters only) or put an authenticating proxy in front of everything but `/peer/*`.

## Operations

```sh
bin/sentinel once | status                      # one probe cycle, print the /status document
bin/sentinel hold on|off|status                 # block automatic transitions (node-wide)
bin/sentinel promote --service app --dry-run    # the hook's plan, no lease, no change
bin/sentinel promote --service app [--fast]     # under a majority lease
bin/sentinel demote  --service app --yes
```

The same via `POST /api/hold|promote|demote` (confirm word or `dry_run=true`), the dashboard
buttons, or the MCP tools. Hook output lands in `LOG_DIR/<service>-<hook>-<ts>.log`; the last
lines come back in the API answer. `GET /api/events` and `/api/transitions` are the audit trail;
`docker compose logs -f sentinel` shows the loop (`[loop]`, `[gossip]`, `[lease]`, `[hooks]`).

## Built for a homelab, generic by config

sentinel was written to fail over one deployment (an `opencode` server and its web UI between
two hosts) and ran there as internal releases 0.1–0.4 before being published. Two traces of that
remain on purpose:

- `GET /status` is a **frozen contract** from that deployment: its keys are named `silver_*` /
  `tiny_*` (the original hosts) and it reports the service called `opencode` (`LEGACY_SERVICE`).
  Consumers written against it keep working; everything new should read `/api/v1/status`, which
  is service-neutral.
- `hooks/opencode` and `hooks/fleet` are the author's real hooks, kept as worked examples.

Everything else — hosts, services, probes, timers, routes — comes from `cluster.yml` and `.env`.

## Development

```sh
bundle install
bundle exec rake test                 # minitest: fake clock, in-process 3-node cluster, no network
RACK_ENV=development bin/sentinel serve
```

## License

[MIT](LICENSE) — Copyright (c) 2026 rojosinalma.
