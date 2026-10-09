# standby-status

Status page for the opencode warm standby (node-a ⇄ node-b). One small Ruby/Roda app, no database,
deployed **on both hosts** so the page survives whichever host is down:

| instance | where it runs | URL |
|---|---|---|
| node-a | orchestrator service `standby-status` (id 62) | https://status.node-a.example.com |
| node-b | plain compose project `~/dev/standby-status` on node-b | https://status.node-b.example.com |
| either | LAN name with two A records (192.0.2.20 + 192.0.2.50) | https://standby.example.com |
| either | public, CF Access, dedicated tunnel with a connector on each host | https://standby.example.com |

## What it shows

- **Primary** (from the sentinel's `mode`, else `state/mode` on node-b), since when, `hold`,
  `promoting` and `transition` flags, the *node-a down* timer against `promote_after_s` and the
  *node-a stable* timer against `failback_after_s`, cooldowns, flips, quorum.
- **Hosts**: opencode (`/api/info`, version; a 401 still counts as up) and webui (`/health`,
  version) on node-a and node-b. The standby's services are shown as *stopped (standby)*.
- **Public DNS**: where `webui.example.com` / `opencode.example.com` point, resolved over DoH.
  Proxied records hide their CNAME; the target is then inferred from the sentinel's mode.
- **Replica lag** and the **last promote/demote log tail** — node-b instance only (it reads
  `$NODE_B_ROOT` read-only); the node-a instance says *n/a on node-a*.
- Footer: build version/time, served-by host, link to the other host's instance.

The page polls `GET /api/status` every `REFRESH_S` seconds and toasts on every state change
(primary, sentinel reachability, hold/promoting, service up/down, DNS target).

## Routes

| route | returns |
|---|---|
| `GET /` | the page |
| `GET /api/status` | all probes, run in parallel with `PROBE_TIMEOUT_S`, coalesced for `STATUS_CACHE_S` |
| `GET /health` | `{ok:true, served_by, version}` — Gatus target |

## Configuration

Everything is environment, loaded from `.env` by dotenv (`.env.example` lists every key; defaults
in `lib/config.rb`). Per host: `HOST_NAME`, `OTHER_INSTANCE_*`, `NODE_B_ROOT` (node-b only),
`OPENCODE_SERVER_PASSWORD` (same as node-a's `server.env`). `.env` is 0600 and never committed.

## Run locally

```
docker build -t standby-status:dev .
docker run --rm -p 9292:9292 -v $PWD/.env:/app/.env:ro standby-status:dev
```

## Release and deploy

```
bin/release [tag|sha]   # build, push registry.example.com + ghcr.io/rojosinalma, pre-pull on node-b
bin/deploy-node-b pull    # sync node-b/compose.yaml to node-b, pull, compose up (secrets installed once)
bin/verify              # both instances, dual-A name, public 302, connector count (with CF_* env)
```

node-a picks up a new tag via the orchestrator: edit `image:` in `compose.yaml`, `PUT
/api/services/62/compose`, then `control_service start` (see `AGENTS.md`). `bin/cf-setup` is the
idempotent one-time Cloudflare setup (tunnel `standby-status`, ingress, CNAME, token files) and
needs `CF_API_TOKEN CF_ACCOUNT_ID CF_ZONE_TOKEN CF_ZONE_ID` in the environment.

## Layout

```
app.rb  config.ru  lib/{config,logger,workers,status}.rb  lib/probes/*.rb   # app
views/  public/css/{dracula,app}.css  public/js/app.js  public/favicon.svg  # UI (house Dracula design)
compose.yaml        node-a base compose (handed to the orchestrator)
connector/          node-a cloudflared replica (plain compose; token file 0600, not in git)
node-b/compose.yaml   node-b compose project (app + connector), synced by bin/deploy-node-b
bin/{release,deploy-node-b,cf-setup,verify}
```
