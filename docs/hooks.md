# Hooks — the per-service action contract

The sentinel decides; the **hooks** act. Every service in `config/cluster.yml` owns a directory of
four executables (bash by convention, anything with a shebang works) that the acting node — the
service's `standby` — runs under a majority lease. Hooks are **mounted from the host checkout**
(`./hooks:/app/hooks:ro` in every compose file), so adding or changing one is a file drop plus a
container restart, never an image release; the image's own `COPY` of `hooks/` is only the fallback
when that mount is removed.

`hooks/_example/` is the reference implementation of the contract: four small bash scripts that
move the mode file, honour `hold` and `--dry-run`, and print what a real hook would do at each
step. The tests run them; copy the directory to `hooks/<service>/` and fill in the real steps.

## Layout

```
hooks/<service>/promote      make the standby primary
hooks/<service>/demote       hand the primary back
hooks/<service>/health       deeper health of the primary host while promoted
hooks/<service>/replicate    periodic upkeep: fence | stack | warm
hooks/<service>/lib/…        anything the four share (optional)
```

`hooks_dir` in the service's cluster.yml entry overrides the directory (relative to the repo
root; default `hooks/<service>`). A missing or non-executable hook is skipped: the loop logs
`hook <service>/<hook> missing, cannot act` for promote/demote, and treats an absent `health` as
`up` and an absent `replicate` as a no-op.

## Environment

Every run gets the node-wide variables plus the service's:

| Variable | Meaning |
|---|---|
| `SERVICE` | the service name (its cluster.yml key) |
| `PRIMARY` / `STANDBY` | the two host names from the service entry |
| `ACTING_NODE` | this node's `NODE_NAME` (always the service's standby) |
| `STATE_DIR` | **this service's** state dir: `<node state dir>/<service>/` — `mode`, `mode.history`, `promote.lock`, `transition`, `promote-failed`, `failback-failed`, `last-*`, `stack` (legacy name `stack`), `hold` all live here |
| `NODE_STATE_DIR` | the node root; its `hold` is the node-wide hold (covers every service — a hook honouring hold checks both) |
| `SN_ENV` | path of the sentinel `.env` (secrets and any hook-specific variables — everything below the `Hook variables` line in `.env.example`); hooks `source` it |
| `DRY_RUN` | `true` when invoked with `--dry-run` (print the plan, change nothing), else `false` |

Hooks run as the container user with the container's mounts (docker socket, ssh keys, the service's
data directories, a CA file — see `examples/acting-node/compose.yaml`); anything else they need
goes into `.env`, never into the hook.

## The four hooks

| Hook | Invocation by the loop | Contract |
|---|---|---|
| `promote` | `promote --auto` (host down ≥ `promote_after_s`) or `promote --auto --fast` (dead for `dead_confirm_polls` cycles: skip the fence, the primary is unreachable) | Fence the primary, bring the standby's copy of the service up, write `STANDBY` to `$STATE_DIR/mode` (+ append `<iso> <mode>` to `mode.history`), move the routes if the service's `routes.mode` says the hook does (`pihole`), notify. Hold `$STATE_DIR/promote.lock` (flock) and write `$STATE_DIR/transition` (`promote <ts>`) for the duration. Also accepts `--dry-run`, `--force` (re-run while already promoted). |
| `demote` | `demote --yes --auto` (primary healthy and stable ≥ `failback_after_s`) | Reverse of promote: stop the standby's copy, carry the data back, start the primary, write `PRIMARY` to `mode`, routes back, notify. `--yes` skips the interactive confirmation; same lock/transition files (`demote <ts>`). Also accepts `--dry-run`. |
| `health` | every `host_health_interval_s` while promoted and the primary's ssh port answers | Probe the primary host deeper than the sentinel can (ssh login, systemd units, docker). **Last line of stdout** is `up` or `down <reason>`; the loop reads that line, falling back to the exit code (0 = up). |
| `replicate fence` | every `fence_interval_s` while promoted | Re-assert the fence on the primary and the routes. No-op (exit 0) while not promoted. |
| `replicate stack` | every `stack_check_interval_s` while promoted | Repair the standby's own stack; write `$STATE_DIR/stack` (`healthy` \| `degraded: <what>`); the legacy name `stack` is read too. |
| `replicate warm` | every `stack_check_interval_s` while the primary is primary | Warm-follower upkeep so the next promote is fast. No-op when the service has none. |

A hook never decides *whether* to act — the loop, the lease and `hold` did that. Still, `demote`
should refuse on its own while `$STATE_DIR/hold` or `$NODE_STATE_DIR/hold` exists (as
`hooks/_example/demote` does), because hooks are also run by hand.

## Exit codes, timeout, logs

| Exit | Meaning | Loop reaction |
|---|---|---|
| `0` | done | marker (`promote-failed` / `failback-failed`) cleared |
| `1` | nothing changed — refused or failed before the point of no return | marker touched, retried after `promote_retry_s` / `failback_retry_s` |
| `2` | done but degraded (mode moved, a part of the stack is not healthy) | mode is trusted, `replicate stack` keeps repairing |

Any other code is a failure like `1`. A hook that runs longer than `HOOK_TIMEOUT_S` (900 s) gets
`SIGTERM` to its process group, `SIGKILL` 10 s later, and `[hooks] killed after …` appended to its
log. `promote`/`demote` runs are also rows in the `transitions` table (`/api/transitions?service=`).

Logs: `LOG_DIR/<service>-promote-<ts>.log` and `<service>-demote-<ts>.log` per run; `health` and
`replicate` append to `LOG_DIR/<service>-health.log` / `<service>-replicate.log`, rotated to `.1` at
5 MiB. stdout and stderr both land there; the last 20 lines come back to the loop (dry-run output
in the API/MCP answer, `health`'s verdict).

## Running a hook by hand

```
bin/sentinel promote --service <svc> --dry-run      # the plan, no lease, no change
bin/sentinel promote --service <svc> [--fast]       # under a majority lease, like the loop
bin/sentinel demote  --service <svc> [--yes]
```

or through the API/MCP (`POST /api/promote {service, confirm:"promote"|dry_run}`, MCP `promote`/
`demote` with `confirm` or `dry_run`). Both run on the acting node only.

## Adding a service

1. **`config/cluster.yml`** — one entry under `services:` (identical on every node, synced together):

   ```yaml
   app:
     primary: node-a
     standby: node-b
     health:
       node-a: https://app.example.com/health
       node-b: https://app.example.com/health
     probe:                      # optional
       username_env: APP_USER    # .env var names; `username:` is the literal fallback
       password_env: APP_PASS
       headers: {X-Probe: sentinel}
       resolve: {node-a: 192.0.2.10, node-b: 192.0.2.20}   # same URL on both hosts → connect per ip
       tls_verify: true          # false for self-signed certificates
     auto_promote: false         # optional, overrides AUTO_PROMOTE for this service
     tunables: {promote_after_s: 90}   # optional, any key in Config::SERVICE_TUNABLES
     routes: {mode: off}         # off (default) | pihole (hooks move DNS) | ha-routes (external CLI, group = service)
     hooks_dir: hooks/app        # optional, default hooks/<name>
   ```

   `health` URLs are probed every cycle on each listed host (200 → `up <version>`, 401 → `up auth?`,
   anything else → `down`); a host not listed is judged on its host probes only.
2. **`hooks/<service>/`** — the four executables above (`chmod +x`), state kept in `$STATE_DIR`,
   secrets read from `$SN_ENV`. Start from `hooks/_example/`. A typical real `promote` fences the
   primary over ssh (stop its units, block its port), brings the standby's copy up from a
   replica (restore or rename a warm follower), waits for its health URL, then writes `mode`;
   `demote` does the reverse and carries the data back; `replicate warm` keeps the follower
   current so the next promote is a rename, not a restore.
3. **Restart the sentinel container** on every node (`docker compose up -d`). The hooks mount picks
   the files up on its own; the cluster.yml change needs the restart.
4. Verify: `GET /api/v1/status` lists the service; `POST /api/promote {service, dry_run: true}` on the
   acting node runs the real hook in dry-run; `GET /api/events?service=<svc>` shows its rows.
