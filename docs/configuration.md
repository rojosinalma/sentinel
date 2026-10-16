# Configuration

Two files configure a node: `.env` (this node's identity and every tunable, loaded with dotenv)
and `config/cluster.yml` (the host and service table, identical on every node). Copy
`.env.example` and `config/cluster.example.yml` to start.

## `.env`

An empty value means "use the default". Defaults live in `lib/sentinel/config.rb` (core) and
`lib/config.rb` (dashboard).

| Group | Key | Default | Meaning |
|---|---|---|---|
| node/files | `NODE_NAME` | — | this node's key under `hosts:` in cluster.yml (required) |
| | `CLUSTER_FILE` | `config/cluster.yml` | path of the cluster table |
| | `STATE_DIR` | `data/state` | state files (`<svc>/mode`, locks, markers, `hold`) |
| | `LOG_DIR` | `data/logs` | hook logs |
| | `DB_PATH` | `data/sentinel.db` | SQLite audit trail |
| | `EVENTS_KEEP_DAYS` | `30` | daily prune horizon for events/transitions |
| | `SENTINEL_PORT` | `4197` | the port peers use (`sentinel_url` in cluster.yml) |
| | `SENTINEL_TAG` | `0.5.0` | image tag used by the compose files |
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
| | `HA_ROUTES_BIN` | — | the route CLI (mode `ha-routes` only, see below) |
| | `ROUTES_ENV_FILE` | — | env file of that CLI (tunnel id lookup; mode `ha-routes` only) |
| | `HA_TUNNEL_ID`, `CF_API_TOKEN`, `CF_ACCOUNT_ID` | — | Cloudflare tunnel connector count in `/status` (optional) |
| | `ROUTE_TIMEOUT_S` | `60` | timeout for the route command |
| dashboard | `HOST_NAME` | `unknown` | "served by" label |
| | `REFRESH_S` | `10` | page poll interval |
| | `OTHER_INSTANCE_URL`, `OTHER_INSTANCE_NAME` | — | footer link to another node's dashboard |
| | `APP_VERSION`, `BUILD_TIME` | `dev`, — | set by the image build |
| | `LEGACY_REDIRECT_FROM`, `LEGACY_REDIRECT_TO` | — | host-prefix 308 redirect (e.g. `standby.` → `sentinel.`); off when empty |
| legacy | `LEGACY_SERVICE` | `opencode` | the service `GET /status`, the CLI and the MCP tools describe when no `service` is given (see [api.md](api.md)) |
| MCP / misc | `SENTINEL_MCP_TOKEN` | — | bearer for `POST /mcp`; empty disables the endpoint (404) |
| | `LOG_LEVEL` | `info` | logger level |
| | `RACK_ENV` | `production` | `development` enables code reloading |
| | `SN_ENV` | `<repo>/.env` | path of the env file handed to hooks |

Everything below the `Hook variables` line in `.env.example` is read by hooks only, through
`$SN_ENV`; the core never looks at it. Define whatever your own hooks need there.

## `cluster.yml`

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
    tunables: {promote_after_s: 90, probe_timeout_s: 10}   # optional, see below
    routes: {mode: off}             # ha-routes | pihole | off (default)
    url: https://app.example.com    # dashboard link (optional)
    host_urls: {node-a: https://node-a.example.com}         # per-host links (optional)
    hooks_dir: hooks/app            # default hooks/<service>
```

- **Hosts** are `member` (may be primary or standby of a service) or `witness` (votes only).
  Keep the total odd: a host counts as dead only when ⌊n/2⌋+1 fresh views agree.
- **`probes`** are per host: `ssh`/`https` are TCP ports, `icmp` on/off. A host whose service
  URL is down but whose host probes answer is `degraded`; nothing answering is `dead`.
- **`quorum_tcp`**: a node that reaches none of these targets (and fewer than a majority of its
  peers) is `isolated` and never judges anyone.
- **`health`**: one URL per host that serves the service; 200 → `up <version>` (the body's
  `version` field when it is JSON), 401 → `up auth?`, anything else → `down`. A host not listed
  is judged on host probes only.
- **`tunables`** may override any of `promote_after_s failback_after_s promote_cooldown_s
  promote_retry_s failback_retry_s flap_flips flap_window_s flap_failback_after_s
  dead_confirm_polls degraded_confirm_polls probe_timeout_s notify_down_after_s fence_interval_s
  stack_check_interval_s host_health_interval_s` (`Config::SERVICE_TUNABLES`).
- **`routes.mode`**: `off` (default) does nothing; `pihole` means the hooks move DNS records
  themselves and the core only reports; `ha-routes` makes the core run
  `$HA_ROUTES_BIN set <host> --group <group>` after a successful hook and `get` to report
  `route_primary`. The CLI is yours to provide — any executable with that `get`/`set` interface
  works, so treat the mode as an extension point for moving public routes.

Changing `cluster.yml` needs a container restart on every node; changing a hook does not (the
`hooks/` directory is bind-mounted).
