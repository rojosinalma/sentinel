# Changelog

All notable changes to this project are documented here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Versions before 0.5.0 were internal releases.

## [0.5.0] - 2026-10-16

First public release.

### Added
- MIT license; repository published at [github.com/rojosinalma/sentinel](https://github.com/rojosinalma/sentinel).
- `config/cluster.example.yml` with neutral values (`node-a`, `node-b`, `witness-1`, service `app`); `config/cluster.yml` is untracked and copied from it.
- Per-service `probe.tls_verify` in `cluster.yml` (default `true`).
- `ROUTES_ENV_FILE`: path of the `ha-routes` env file (route mode `ha-routes` only; replaces the implicit lookup next to the binary).
- `LEGACY_REDIRECT_FROM` / `LEGACY_REDIRECT_TO`: configurable host-prefix 308 redirect, off when empty (was hard-wired `standby.` → `sentinel.`).
- `CHANGELOG.md`, public `README.md`, `docs/history/` for the original cutover runbook.

### Changed
- `ROUTE_MODE` defaults to `off` (was `ha-routes`).
- The image is `ghcr.io/rojosinalma/sentinel` (was `ghcr.io/rojosinalma/sentinel` plus a private registry); the GitHub workflow also tags on `v*`.
- `.env.example` and the docs no longer carry the author's hosts, addresses or paths; hook variables are documented as examples for `hooks/opencode` and `hooks/beacon`.

### Removed
- The legacy standby-status page and its keys (`NODE_A_*_URL`, `NODE_B_*_URL`, `DOH_URL`, `DNS_NAMES`, `*_TUNNEL_ID`, `SENTINEL_URL`, `PROBE_TIMEOUT_S`, `PROBE_TLS_VERIFY`, `STATUS_CACHE_S`, `LOG_TAIL_LINES`; `NODE_B_ROOT` and `OPENCODE_SERVER_*` remain as hook/probe variables only).
- `bin/cf-setup`, `bin/deploy-node-b`, `bin/verify` and `connector/` (homelab-specific tooling).

## [0.4.10] - 2026-10-15
- Removed the `traefik` probe alias from `cluster.yml`, probes, host view and the legacy `/status` document (`host_probes` = ssh/icmp/https).

## [0.4.9] - 2026-10-15
- Dropped Traefik labels from the compose files; docker network renamed to `ingress`.
- Hooks: opencode hooks pause the primary's guard timer during transitions; beacon hooks use the same container names on both hosts; routes `off` for both services.

## [0.4.8] - 2026-10-14
- Dashboard page JS on tailor's behaviour layer.

## [0.4.7] - 2026-10-14
- Skin and palette switchers in the navbar.

## [0.4.6] - 2026-10-14
- Dashboard rebuilt on the tailor design kit (WebTUI skin, Dracula palette).

## [0.4.5] - 2026-10-14
- `/status` `mode` read live from the state file while a hook runs.
- Per-service `tunables.probe_timeout_s` and `degraded_confirm_polls`.
- Routes moved and markers cleared only on hook exit 0; core route re-assert at the host-health cadence; honest `unit-started` log.

## [0.4.4] - 2026-10-13
- Service `url` / `host_urls` in `cluster.yml`; dashboard card and host rows link to the service.

## [0.4.3] - 2026-10-13
- Promote/demote/per-service hold forwarded from any node to the acting node; dashboard buttons live everywhere.

## [0.4.1] - 2026-10-13
- Seven voters (four more witnesses); `cluster.yml` and `hooks/` bind-mounted from the host on every node.

## [0.4.0] - 2026-10-13
- Generic multi-service core: per-service state, route groups (`ha-routes` | `pihole` | `off`), service-scoped API/MCP, per-service dashboard; `hooks/beacon` as first second consumer.
- Image built and pushed to GHCR on `main`.

## [0.3.0] – [0.3.1] - 2026-10-11/12
- Release 2: multi-service core, warm followers, `/api/v1/status`, scheduled pruning; cutover fixes (308 redirect, arm64 lockfile, `SN_ENV` override).

## [0.1.0] – [0.2.0] - 2026-10-10/11
- Internal releases: Ruby core (probes, classifier, decider, gossip, majority lease, SQLite store, byte-compatible `/status`), opencode hooks ported from the bash sentinel, dashboard, MCP endpoint, image + per-node composes + release pipeline, the production cutover.
