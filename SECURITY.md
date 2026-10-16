# Security policy

## Supported versions

The latest release receives security fixes. Older tags stay published but are not patched; upgrade
to the current `ghcr.io/rojosinalma/sentinel` tag to receive fixes.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting: open the
repository's **Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/rojosinalma/sentinel/security/advisories/new)). Never file a
security issue in the public tracker.

Include the version (`GET /health` → `version`, or the image tag), how sentinel is deployed (which
node acts, what the hooks mount) and steps to reproduce. I acknowledge reports within a week and
publish a fix and an advisory once one is available.

## Scope

sentinel's HTTP API has no authentication of its own except the bearer on `/mcp`; the deployment
model (which network the cluster port is reachable from, what the acting node's hooks may touch)
is described in [docs/security.md](docs/security.md). A report that assumes an exposed cluster port
on an untrusted network is a documentation issue, not a vulnerability.
