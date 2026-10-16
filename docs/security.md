# Security

sentinel is built to run on a network you trust. Only `POST /mcp` carries authentication (the
`SENTINEL_MCP_TOKEN` bearer). `/peer/*`, `/api/promote`, `/api/demote`, `/api/hold`, the read
endpoints and the dashboard are **unauthenticated**, and the promote/demote actions run hooks
that fence hosts and move services.

What I recommend:

1. **Keep the cluster port private.** Expose `4197` to the voters only (firewall, VLAN, VPN).
   Peers need `/peer/*`; nothing else does.
2. **Front the human-facing paths with an authenticating proxy** if you want the dashboard or
   the API reachable from elsewhere: proxy `/`, `/api/*`, `/status`, `/health` behind your SSO,
   leave `/peer/*` for the voters only. The MCP endpoint has its own bearer; send it over TLS.
3. **Treat `.env` as secret** (`0600`, owned by the container user): it holds the MCP token, the
   probe credentials named in `cluster.yml` and whatever your hooks read through `$SN_ENV`.
4. **Give the acting node only what its hooks need.** A voter that runs no hooks needs no docker
   socket, no ssh key and no service data mount (`compose.yaml`, `witness/compose.yaml`); only the
   acting node (`examples/acting-node/compose.yaml`) gets them, read-only where possible.
5. **Lease and hold are safety, not authorisation.** The majority lease stops two nodes from
   acting at once and `hold` blocks automatic transitions; neither stops a caller who can reach
   the API from asking for a promote. The `confirm` word exists to stop accidents, not attackers.

Report security issues privately through GitHub's security advisories for the repository.
