# Changelog

All notable changes to this project are documented here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Tests use `beacon` as the second-service fixture (was `beacon`); nothing in the core knows a
  service name, so the rename of the homelab's beacon service is a `cluster.yml` change only.

## [0.5.5] - 2026-10-16

### Changed
- Dashboard icons come from tailor's Iconify sprite (`public/tailor/icons.svg`, 17 Bootstrap Icons
  subsetted by `tailor apply --icons`) as inline `<svg class="t-icon"><use>` references; I dropped
  the vendored Bootstrap Icons font and its stylesheet. Icons the page builds at runtime go through
  one `icon()` helper in `app.js`.
- Card bodies and footers space their children with tailor's `t-stack`/`t-cluster` instead of the
  `.mt-2`/`.mb-2` helpers, which are gone from `app.css` along with the timer margin.

## [0.5.4] - 2026-10-16

### Fixed
- Dashboard: the host tables scroll sideways inside a narrow card instead of running past its
  border (the service cards at two-per-row widths).

### Changed
- Vendored tailor assets 0.5.1 (`.t-empty-icon` sizing fix for sprite SVGs).

## [0.5.3] - 2026-10-16

### Changed
- Dashboard on tailor core 0.5.0 (vendored assets refreshed from 0.3.0): the shell no longer
  leaves an empty row above the footer below 992px; the card-header meta uses the `t-card-tools`
  slot, the navbar timestamp hides on small screens via `t-hide`, and table cells use `t-nowrap`
  — the matching rules in `app.css` are gone.

## [0.5.2] - 2026-10-16

### Changed
- Dashboard: the skin/palette/mode switcher is tailor's `data-tailor-pickers` element in the footer
  (options sorted by name); the hand-written selects and the mode toggle in the navbar are gone.
  Vendored tailor assets refreshed to 0.3.0.

## [0.5.1] - 2026-10-16

### Added
- `LEGACY_SERVICE` selects the service that `GET /status`, the CLI and the MCP tools describe
  when no `service` is given (default `opencode`, the name the frozen document was written for).
- `examples/acting-node/compose.yaml`: the acting node's compose with the mounts hooks typically
  need (docker socket, ssh, service directories, CA file) as placeholders.
- `run-tests` workflow; OCI labels on the image; `CONTRIBUTING.md`, `docs/SDD.md`,
  `docs/configuration.md`, `docs/api.md`, `docs/security.md`, `docs/operations.md`.
- `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and pull request templates, Dependabot for gems,
  actions and the base image; run names on both workflows.
- Vendored bootstrap-icons 1.11.3 — the dashboard loads no CDN assets.

### Changed
- Licence to AGPL-3.0 (was MIT).
- The image workflow is `publish-image`; `bin/release` only tags and pushes (the workflow builds
  and publishes).
- `compose.yaml` no longer joins an external docker network; add one in your own override if
  your proxy needs it.
- `hooks/_example/` is the single reference implementation of the hook contract; the docs
  describe what a real promote/demote does instead of pointing at site-specific hooks.

## [0.5.0] - 2026-10-16

First public release.

### Added
- MIT license; repository at [github.com/rojosinalma/sentinel](https://github.com/rojosinalma/sentinel).
- `config/cluster.example.yml` with neutral values (`node-a`, `node-b`, `witness-1`, service
  `app`); `config/cluster.yml` is untracked and copied from it.
- Per-service `probe.tls_verify` in `cluster.yml` (default `true`).
- `ROUTES_ENV_FILE`: path of the route CLI's env file (route mode `ha-routes` only).
- `LEGACY_REDIRECT_FROM` / `LEGACY_REDIRECT_TO`: configurable host-prefix 308 redirect, off when
  empty.
- `CHANGELOG.md` and the public `README.md`.

### Changed
- `ROUTE_MODE` defaults to `off`.
- The image is `ghcr.io/rojosinalma/sentinel`, published for amd64 and arm64 on every push to
  `main` and on `v*` tags.
- `.env.example` documents every key with neutral example values.

### Removed
- The pre-sentinel status page and its keys (`*_URL` host pairs, `DOH_URL`, `DNS_NAMES`,
  `*_TUNNEL_ID`, `SENTINEL_URL`, `PROBE_TIMEOUT_S`, `PROBE_TLS_VERIFY`, `STATUS_CACHE_S`,
  `LOG_TAIL_LINES`).
- Deployment-specific helper scripts and the connector compose.

## [0.4.10] - 2026-10-15
- Removed the `traefik` probe alias from `cluster.yml`, probes, host view and the legacy
  `/status` document (`host_probes` = ssh/icmp/https).

## [0.4.9] - 2026-10-15
- Dropped reverse-proxy labels from the compose files.
- Hooks may pause the primary's own re-assert timer during transitions; route mode `off` works
  for every service.

## [0.4.8] - 2026-10-14
- Dashboard page JS on tailor's behaviour layer.

## [0.4.7] - 2026-10-14
- Skin and palette switchers in the navbar.

## [0.4.6] - 2026-10-14
- Dashboard rebuilt on the tailor design kit (WebTUI skin, Dracula palette).

## [0.4.5] - 2026-10-14
- `/status` `mode` read live from the state file while a hook runs.
- Per-service `tunables.probe_timeout_s` and `degraded_confirm_polls`.
- Routes moved and markers cleared only on hook exit 0; core route re-assert at the host-health
  cadence.

## [0.4.4] - 2026-10-13
- Service `url` / `host_urls` in `cluster.yml`; dashboard card and host rows link to the service.

## [0.4.3] - 2026-10-13
- Promote/demote/per-service hold forwarded from any node to the acting node; dashboard buttons
  work everywhere.

## [0.4.1] - 2026-10-13
- Any odd number of voters; `cluster.yml` and `hooks/` bind-mounted from the host on every node.

## [0.4.0] - 2026-10-13
- Multi-service core: per-service state, route groups (`ha-routes` | `pihole` | `off`),
  service-scoped API/MCP, per-service dashboard.
- Image built and pushed to GHCR on `main`.

## [0.3.0] – [0.3.1] - 2026-10-11/12
- Multi-service loop, warm followers (`replicate warm`), `/api/v1/status`, scheduled pruning,
  configurable 308 redirect, arm64 lockfile, `SN_ENV` override.

## [0.1.0] – [0.2.0] - 2026-10-10/11
- Ruby core: probes, classifier, decider, gossip, majority lease, SQLite store, the legacy
  `/status` document, dashboard, MCP endpoint, image and per-node composes.
