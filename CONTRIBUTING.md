# Contributing

Issues and pull requests are welcome. Keep changes focused; one topic per PR.

## Running it locally

```sh
bundle install
cp config/cluster.example.yml config/cluster.yml   # or point CLUSTER_FILE at your own
cp .env.example .env                                # NODE_NAME must be a key under hosts:
RACK_ENV=development bin/sentinel serve             # code reloads on the next request
```

`bin/sentinel once` runs one probe cycle and prints the legacy `/status` document — handy to
check a cluster file against real hosts without starting the loop. With Docker,
`docker compose up -d` after `docker compose build` runs the same thing from the image.

## Tests

```sh
bundle exec rake test
```

minitest, no network: a fake clock, an in-process transport and a three-node cluster
(`node-a`, `node-b`, `witness-1`) built in `test/loop_test.rb`. The loop and API tests execute
`hooks/_example/`. `test/fixtures/status_legacy.json` pins the legacy `/status` document byte for
byte — a change there is a contract change and needs a very good reason. Add a test for every
behaviour change in `lib/`; tests never touch ssh, docker or real hosts.

## Code style and layout

- Ruby: small methods, keyword arguments, `freeze` on constants, `$log.info "[subsystem] …"`.
  Routes in `app.rb` only validate, call into `lib/sentinel/actions.rb` or `status.rb` and
  render; no business logic in routes. Every endpoint answers `{ok, message, …}`.
- No host names, addresses or paths in `lib/` — they come from `cluster.yml` or `Config`. Tests use
  the neutral names above and documentation addresses (`192.0.2.x`, `example.com`).
- Threads go through `Workers.safe_thread` / `Workers::Pool`; collections stay bounded.
- Hooks are bash by convention, `set -euo pipefail`, and must honour `--dry-run`.
- `ruby -wc` clean; the diagnostics the editor shows should be empty before you commit.

## Commits and PRs

- Plain, descriptive commit messages in the imperative ("Add per-service probe timeout"); no
  attribution trailers.
- Every commit and tag is GPG-signed (`git config commit.gpgsign true`); unsigned commits are not
  merged.
- A PR describes the behaviour change and how you verified it. Update the docs and the
  `[Unreleased]` section of `CHANGELOG.md` in the same PR.
- `run-tests` must be green.

## Documentation

| File | What goes there |
|---|---|
| `README.md` | what it is, requirements, installation, usage, development, licence — nothing else |
| `CONTRIBUTING.md` | this file: running locally, tests, style, commits, docs map, releasing |
| `SECURITY.md` | how to report a vulnerability, supported versions |
| `CODE_OF_CONDUCT.md` | Contributor Covenant 2.1 |
| `docs/SDD.md` | design: architecture, data model, flows, decisions, scope, operations summary |
| `docs/configuration.md` | every `.env` key and `cluster.yml` field |
| `docs/hooks.md` | the hook contract, environment, exit codes, adding a service |
| `docs/api.md` | HTTP endpoints, the v1 document, the frozen legacy `/status` document, MCP tools |
| `docs/security.md` | what is and is not authenticated, how to deploy safely |
| `docs/operations.md` | CLI, logs, state files, holds, upgrades, notifications |
| `CHANGELOG.md` | Keep a Changelog, one section per version |

A new topic gets a new `docs/<topic>.md`, not a README section.

## Releasing

1. Move the `[Unreleased]` notes in `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD`.
2. `bin/release X.Y.Z` — writes `VERSION`, bumps `SENTINEL_TAG` in the compose files and
   `.env.example`, commits, signs and tags `vX.Y.Z` and pushes (`RELEASE_GH=1` also creates the GitHub
   release from the changelog section).
3. The `publish-image` workflow builds the multi-arch image for the tag and pushes
   `ghcr.io/rojosinalma/sentinel:X.Y.Z`, `:X.Y` and `:sha-<short>`; pushes to `main` refresh
   `:latest`.
