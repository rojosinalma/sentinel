# Operations

## Day to day

```sh
bin/sentinel once | status                      # one probe cycle, print the /status document
bin/sentinel hold on|off|status                 # block automatic transitions (node-wide)
bin/sentinel promote --service app --dry-run    # the hook's plan, no lease, no change
bin/sentinel promote --service app [--fast]     # under a majority lease
bin/sentinel demote  --service app --yes
```

The same through `POST /api/hold|promote|demote` (confirm word or `dry_run=true`), the
dashboard buttons or the MCP tools — from any node, the request is forwarded to the acting node.
Inside the container the CLI is `docker compose exec sentinel bin/sentinel …`.

## Where to look

| What | Where |
|---|---|
| the loop | `docker compose logs -f sentinel` — `[loop]`, `[gossip]`, `[lease]`, `[hooks]`, `[state]`, `[notify]` prefixes |
| audit trail | `GET /api/events?service=&kind=` (probe/class changes, decisions, gates, leases, holds, notifications, heartbeats) and `GET /api/transitions` (promote/demote runs: exit code, duration, log file) |
| hook output | `LOG_DIR/<service>-promote-<ts>.log`, `<service>-demote-<ts>.log` per run; `<service>-health.log`, `<service>-replicate.log` appended and rotated at 5 MiB; the last 20 lines also come back in the API answer |
| state | `STATE_DIR/<service>/mode` (who is primary), `mode.history`, `transition`, `promote.lock`, `promote-failed` / `failback-failed`, `stack`, `hold`; `STATE_DIR/hold` is the node-wide hold |
| liveness | `GET /health` (the container `HEALTHCHECK` uses it) |

Events and transitions older than `EVENTS_KEEP_DAYS` are pruned once a day; expired leases with
them.

## Holding, promoting, failing back by hand

- `hold on` (node-wide) or `POST /api/hold {on: true, service}` (one service) blocks the
  automatic failback until released: the standby stays in charge while you work on the primary.
  Promotes are not held — set `AUTO_PROMOTE=off` (or `auto_promote: false` for one service) for
  that.
- A manual `promote` takes the same majority lease the loop would; a `--dry-run` takes none and
  changes nothing. `--fast` skips the fence (use it when the primary is confirmed dead).
- After a failed promote the `promote-failed` marker throttles retries (`PROMOTE_RETRY_S`); a
  successful run clears it. The gates and their remaining seconds are in `/api/v1/status`.
- Flapping (≥ `FLAP_FLIPS` mode changes within `FLAP_WINDOW_S`) stretches the failback delay to
  `FLAP_FAILBACK_AFTER_S` and notifies once.

## Adding or changing voters and services

- `config/cluster.yml` is bind-mounted and read at boot: edit it on every node, then restart each
  container (`docker compose up -d`). Keep the voter count odd.
- `hooks/` is bind-mounted and read per run: a changed hook is live at its next invocation, no
  restart. See [hooks.md](hooks.md).
- Adding a service: `services:` entry + `hooks/<service>/` + restart; then check
  `GET /api/v1/status` lists it and `POST /api/promote {service, dry_run: true}` on the acting
  node walks the real hook.

## Upgrading

Images are `ghcr.io/rojosinalma/sentinel:<version>` (amd64 + arm64). Bump `SENTINEL_TAG` in
`.env` (or the compose file), `docker compose pull && docker compose up -d`, one node at a time
with `hold on` (no failback) and `AUTO_PROMOTE=off` (no promote) if you want no transition during
the rollout. A release that changes only the dashboard or the docs can stop at the nodes whose
dashboard you browse (the members); the witnesses' `/status`, gossip and votes are unaffected and
they may stay on the earlier image. The check, with `<old>` the tag the witnesses run:

```
git diff v<old>..v<new> --stat -- lib/ config/ hooks/ Gemfile.lock
```

Empty output means members only. Otherwise read the listed hunks: a changed `/status` or
`/api/v1/status` field, the gossip documents (`/peer/view`, `/peer/lease`), the probes,
classifier or decider, or a dependency with a behaviour change means every voter moves, one node
at a time under hold, since the voters must agree on the same rules and wire format. Comment-only
hunks and new settings that default to the old behaviour do not (0.5.0 → 0.5.5 was such a case).
`config/cluster.yml` and `hooks/` are bind-mounted from the host on every node, so edits there
reach a witness with a file copy plus restart and need no image change. SQLite migrations are additive and run
on boot; state files are plain text and never change format. `APP_VERSION` in `/health` tells you
what runs.

## Notifications

`DISCORD_WEBHOOK_URL` and/or `APPRISE_URL` receive: service down (after `NOTIFY_DOWN_AFTER_S`),
service back, promote/demote start and result (including the degraded case), flapping, and the
hook's own messages. With neither set the message goes to the log (`[notify]`).
