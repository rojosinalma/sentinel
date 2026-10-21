# sentinel — software design document

## Purpose

sentinel is a majority-vote failover controller for self-hosted services that run on one host
with a warm standby on another. One small Ruby process per participating host probes every host,
agrees with its peers on who is up, and — only on the node named as a service's standby, only
under a majority lease — runs the service's own `promote`/`demote` scripts. It never moves data
itself: the hooks do, sentinel decides *when* and makes sure at most one node acts.

Design goals, in order: no split brain (majority + lease), no false promote on a partition (an
isolated node never judges), predictable timing (every delay is a named tunable), everything
auditable (SQLite events, transitions, logs), and the core knows nothing about the services it
fails over (hooks + `cluster.yml`).

## Architecture

### One process, five layers

```
app.rb                  Roda app: /status /api/* /peer/* /mcp /health, dashboard (views/, public/)
config.ru               boots Sentinel.boot! (loop thread) once, then the app
bin/sentinel            CLI: serve | once | status | hold | promote | demote
lib/sentinel/config.rb  Config: typed .env tunables + the cluster table (Host, Service, Probe, ServiceRoutes)
lib/sentinel/workers.rb Workers: safe_thread, bounded Pool, parallel(jobs, timeout:)
lib/sentinel/store.rb   Store: Sequel/SQLite — events, transitions, leases, cluster_state, peer_views
lib/sentinel/state.rb   State / ServiceState: the plain-file state directory hooks share with the core
lib/sentinel/probes*.rb Probes::{Http,Tcp,Icmp}, Probes.host / .quorum → HostView
lib/sentinel/host_view.rb, classifier.rb   per-host view and its class (ok/degraded/dead/isolated/standby)
lib/sentinel/transport.rb  Transport::Http (peers, webhooks) and Transport::InProcess (tests)
lib/sentinel/gossip.rb  Gossip: peer views, freshness, majority agreement, isolation
lib/sentinel/lease.rb   Lease: majority lease, client and server side
lib/sentinel/routes.rb  Routes: optional public-route handover through an external CLI
lib/sentinel/hooks.rb   Hooks: runs hooks/<service>/<hook> with env, log, timeout, transition rows
lib/sentinel/decider.rb Decider: the pure per-service state machine (timers, gates, flap damping)
lib/sentinel/loop.rb    Loop: one cycle every POLL_INTERVAL_S, drives every service
lib/sentinel/status.rb  Status: the legacy /status document and the v1 document
lib/sentinel/actions.rb Actions: hold/promote/demote with forwarding to the acting node
lib/sentinel/mcp_server.rb  MCP tools over the same actions and documents
lib/sentinel/boot.rb    wires the above into a runtime Hash
hooks/<service>/        promote demote health replicate — yours; hooks/_example/ is the reference
```

`lib/sentinel.rb` requires the files in dependency order; each module depends only on the ones
above it. `lib/config.rb` holds the dashboard's own few knobs, `lib/log.rb` the `$log` logger
(`[subsystem]` prefixes, backtraces on thread errors).

### Roles

- **member**: may be `primary` or `standby` of a service. **witness**: votes and probes only.
- **acting node** of a service = its `standby`. Only it runs hooks and takes leases for that
  service; every other node observes, gossips and votes. One node may act for some services and
  observe others.
- **majority** = ⌊hosts/2⌋+1 over all configured hosts. Keep the count odd.

### How nodes talk

Plain HTTP on the cluster port, no shared state:

- `GET /peer/view` — every node publishes its latest cycle: per host the probe results and its
  class per service, the primary it believes in (`primary`, `primary_at`), quorum, hold,
  transition, the lease it holds. Peers poll it every cycle (`Gossip.poll!`, in parallel, bounded
  by `PEER_TIMEOUT_S`); a view older than `PEER_STALE_S` is not counted.
- `POST /peer/lease` / `/peer/lease/release` — the lease protocol (below).
- `POST /api/promote|demote|hold` on a non-acting node forwards the request to the acting node's
  own API (`Actions.forward!`), so operators and the dashboard talk to any voter.

## Data model and storage

### SQLite (`DB_PATH`, WAL, `busy_timeout 5000`)

Sequel migrations run on every boot and are additive only.

| Table | Columns | Role |
|---|---|---|
| `events` | `id at node kind level host service message data` | the audit trail; kinds `probe.change class.change decision gate lease.request lease.grant lease.deny transition.start transition.end gossip.isolated gossip.quorum hold notify heartbeat boot` |
| `transitions` | `id service action started_at finished_at result exit_code log_file node data` | one row per promote/demote hook run |
| `leases` | `id service holder action token granted_at expires_at granted_by` | leases this node granted or holds |
| `cluster_state` | `key value updated_at` | `primary.<svc>`, `primary_at.<svc>` — the last known primary |
| `peer_views` | `node at received_at body` | the latest view received from each peer |
| `settings` | `key value` | reserved |

`Store.prune!(keep_days:)` runs daily from the loop and drops old events, transitions and expired
leases, so the database stays bounded.

### The state directory (`STATE_DIR`)

Plain files, because the hooks (shell) and the core share them and because they must survive a
restart of either. The node root holds only `hold` (node-wide). Each service owns
`STATE_DIR/<service>/`, which its hooks receive as `$STATE_DIR`:

| File | Writer | Meaning |
|---|---|---|
| `mode` | hooks | host name of the current primary (first line; the legacy `primary=<name>` form is accepted) |
| `mode.history` | hooks, `set_mode!` | `<iso> <mode>` per change; the flap counter reads the tail |
| `promote.lock` | hooks | flock held for the duration of a promote/demote → `busy?` |
| `transition` | hooks | `promote <ts>` / `demote <ts>` while running |
| `promote-failed`, `failback-failed` | core | retry markers (`PROMOTE_RETRY_S`, `FAILBACK_RETRY_S`) |
| `last-promote`, `last-demote` | core | cooldown anchors |
| `stack` | `replicate stack` | `healthy` / `degraded: <what>` |
| `hold` | core / operator | per-service hold |

On boot `State#migrate_legacy!` moves pre-multi-service root files into `<legacy service>/` once
and leaves `mode` as a relative symlink, so anything reading `state/mode` keeps working.

### In memory

`Loop#last` is the only shared snapshot (one Hash per cycle, replaced atomically); `/status`,
`/api/*`, `/peer/view` and the dashboard read it. The Decider keeps per-service timers. Nothing
else accumulates: probe fan-out runs in a bounded `Workers::Pool`, peer bodies go to SQLite.

## Key flows

### One cycle (`Loop#cycle!`, every `POLL_INTERVAL_S`)

1. **Probe** every host in parallel: the service health URLs (`Probes::Http`, Basic credential
   and `resolve` ip from the service's `probe:` block, `tls_verify`), the TCP ports and ICMP from
   the host's `probes:`; plus the `quorum_tcp` targets. Each host becomes a `HostView`.
2. **Classify** locally, per service and host (`Classifier.classify`): service up → `ok`; my
   quorum down → `isolated` (I must not judge); any host probe up → `degraded`; nothing → `dead`.
   A host that is this service's primary while another host holds `mode` is labelled `standby`.
3. **Gossip**: poll every peer's `/peer/view`; `quorum = "up"` iff I reach a majority of voters
   *and* the TCP quorum targets are not all down.
4. **Agree** per host (`Classifier.agree` over fresh views including my own): `dead` needs a
   majority of dead votes, `degraded` a majority of down votes, else `ok`.
5. **Mode**: on the acting node the state file (hooks write it); elsewhere the newest
   `primary_at` among peer views and my `cluster_state`, else `service.primary`.
6. If `promote.lock` is held → observe only (`busy`).
7. **Decide** (acting node only): `Decider#step(now, mode, agreed_class, quorum, host_health,
   auto_promote, auto_failback)` → `:none | :promote | :promote_fast | :failback |
   :fence_and_route | :stack_check | :watch_maintenance` plus notifications, log lines and the
   gate snapshot.
8. **Act**: `promote`/`failback` take a lease (`Lease#acquire!`), run the hook with the lease
   renewed every `LEASE_RENEW_S` in a helper thread, release it; `:fence_and_route` runs
   `replicate fence` and re-asserts routes; `:stack_check` runs `health` and `replicate stack`;
   `:watch_maintenance` runs `replicate warm` while the primary is primary.
9. **Record**: re-read `mode`, store `primary.<svc>` / `primary_at.<svc>`, publish `last`, emit
   events for every change and a `heartbeat` every `HEARTBEAT_S`.

### Decision rules (`Decider`)

- **Fast promote** after `DEAD_CONFIRM_POLLS` consecutive agreed-`dead` cycles with quorum up
  (the primary is unreachable; the hook skips the fence with `--fast`).
- **Normal promote** when the service has been down ≥ `PROMOTE_AFTER_S` (after
  `DEGRADED_CONFIRM_POLLS` degraded cycles) and the class is not dead (the host answers, so the
  hook can fence it).
- **Gates**, in order: `AUTO_PROMOTE` (node-wide or `auto_promote` per service) → quorum →
  cooldown since the last demote (`PROMOTE_COOLDOWN_S`) → retry marker (`PROMOTE_RETRY_S`).
  Each blocked step logs once per `FENCE_INTERVAL_S`. `hold` does not block a promote: a down
  service still gets its standby; hold is for keeping the standby in charge.
- **Failback** when promoted, `host_health` (the `health` hook) has been `up` for
  `FAILBACK_AFTER_S` — or `FLAP_FAILBACK_AFTER_S` once `FLAP_FLIPS` mode changes happened within
  `FLAP_WINDOW_S` — unless `AUTO_FAILBACK=off`, `hold` (node-wide or per service, notified once),
  or a `failback-failed` retry is pending.
- `dead_polls` resets on any non-dead cycle; `down_since` resets when the service is up.

### Majority lease (`Lease`)

The acting node POSTs `{service, holder, action, ttl_s, token}` to every peer in parallel; a
peer grants when the holder is the service's standby and it holds no unexpired lease for that
service with another holder, and records the grant. Granted when `grants + 1 ≥ majority`; denied
otherwise (every deny is an event). Renewals carry the same token; a renewal that loses the
majority raises `Lease::Expired` and the loop logs it (the running hook finishes — a hook is
never killed for a lost lease, the lease exists to stop a *second* actor from starting).

### Hook execution (`Hooks`)

`hooks_dir/<hook> <args>` with env `SERVICE PRIMARY STANDBY ACTING_NODE STATE_DIR NODE_STATE_DIR
SN_ENV DRY_RUN`, stdout+stderr to `LOG_DIR/<service>-<hook>-<ts>.log` (health/replicate append
to one file, rotated at 5 MiB), SIGTERM after `HOOK_TIMEOUT_S`, SIGKILL 10 s later. Exit `0`
done, `1` nothing changed (marker touched, retried), `2` done but degraded (mode trusted, routes
not moved, `replicate stack` keeps repairing). promote/demote runs become `transitions` rows. The
full contract is [hooks.md](hooks.md).

### Routes (`Routes`, optional)

With `routes.mode: ha-routes` the core runs `$HA_ROUTES_BIN set <mode host> --group <service>`
after a successful hook and re-asserts it at the host-health cadence once the mode host's service
actually answers; `get` feeds `route_primary`. `pihole` leaves route moves to the hooks; `off`
(default) does nothing. The CLI is an extension point: any executable with that interface.

## Configuration surface

`.env` (every tunable, typed defaults in `Config::DEFAULTS`, cast errors logged and defaulted)
and `config/cluster.yml` (hosts, roles, probes, quorum targets, services with health URLs, probe
options, per-service `tunables`, `auto_promote`, `routes`, `hooks_dir`, dashboard URLs). Both
files are bind-mounted from the checkout; `cluster.yml` is read at boot, hooks per run. The
complete reference is [configuration.md](configuration.md).

## Decisions and rationale

- **Majority of views, not a leader.** Every node computes the same agreement from the same
  gossip, so there is no election and no single point whose death stalls the cluster. The lease
  adds the one thing agreement cannot: mutual exclusion while a hook runs.
- **Only the standby acts.** A static acting node per service keeps the hooks simple (they know
  which host they run on) and removes a class of races; HA for the controller itself comes from
  the fact that a dead standby means nothing to fail over to anyway.
- **`isolated` beats everything.** A node that lost its own quorum sees every host as down; it
  must never promote. Quorum is both peer reachability and the `quorum_tcp` targets, so a node cut
  from the network but still seeing a peer on the same switch does not act alone.
- **Hooks are external executables with a small contract.** Fencing, replication and start-up are
  specific to each service; keeping them out of the core keeps the core generic and lets a hook
  be tested by running it (`--dry-run`).
- **Plain-file state shared with hooks.** `mode`, locks and markers are files so shell hooks can
  read and write them atomically and an operator can inspect them with `cat`.
- **SQLite for the audit trail**, one file per node, WAL, additive migrations — no external
  service for a process whose job is to work when things are broken.
- **Fast path vs. normal path.** A dead host gets promoted after a few confirmed polls because
  waiting cannot help; a merely unhealthy service waits `PROMOTE_AFTER_S` because it may recover
  and because the hook must fence a host that is still up.
- **Flap damping and cooldowns** in the decider, not the hooks: timers are the controller's
  business; hooks stay idempotent and stateless beyond the mode file.
- **The legacy `/status` document is frozen.** Its keys, their order and their types stay
  byte-identical so existing consumers keep working (`primary_*` for the primary side,
  `standby_*` for the standby side; 0.6.0 renamed the keys once, to drop fixed host labels);
  `/api/v1/status` is the neutral document for everything new, and `LEGACY_SERVICE` names which
  service `/status` reports (default: the first service in `cluster.yml`).
- **Actions forward to the acting node** rather than failing on the wrong node, so dashboards
  and MCP clients need one URL, not one per service.

## Current scope

- One acting node (the standby) per service; a service has exactly one primary and one standby.
  Several services may spread their roles over the members any way they like.
- Agreement is per host and per service over fresh views; there is no persistent consensus log.
  A cycle's decision is recomputed from scratch each time, which is what makes the loop easy to
  reason about and restart.
- Route handover is through an external CLI or the hooks; the core ships no DNS or proxy driver
  of its own.
- Authentication exists on the MCP endpoint; the HTTP API relies on network placement or a
  fronting proxy ([security.md](security.md)).
- The dashboard is a read-and-act page for one node; it links to the other node's page rather than
  aggregating.

## Operations

Logs go to stdout with `[loop] [gossip] [lease] [hooks] [state] [notify] [config]` prefixes;
`/health` is the liveness probe (the image `HEALTHCHECK` uses it); `/api/events` and
`/api/transitions` are the audit trail; hook output is in `LOG_DIR`. Upgrades are an image tag
bump plus `docker compose up -d`, one node at a time, with `hold on` and `AUTO_PROMOTE=off` if no
transition may happen meanwhile; migrations are additive and the state files never change format. Details in
[operations.md](operations.md).

## Tests

`rake test` runs minitest with a fake clock, in-process transport
(`Transport::InProcess`) and a three-node cluster (`node-a`, `node-b`, `witness-1`) built
from `test/loop_test.rb`'s YAML; no network, no ssh, no docker. `hooks/_example/` is what the
loop and API tests execute. `test/fixtures/status_legacy.json` pins the legacy document byte for
byte.
