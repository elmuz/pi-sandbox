# MCP integration

This repository only provides the client side of the
[server-mcp](https://github.com/elmuz/server-mcp) deployment. It does not start,
stop, restart or update the MCP containers.

## Contract

- The Pi sandbox and both MCP containers (`mcp-remote` and `mcp-disk`) are the
  only members of the internal control bridge. Its name is
  `$PI_SANDBOX_MCP_NETWORK`, default `pi-control`.
- The MCP services publish no host port. Inside the container, Pi reaches them
  at `http://mcp-remote:8000/mcp` and `http://mcp-disk:8000/mcp`.
- One bearer token is shared by both services. Its path in this repository is
  `$PI_SANDBOX_MCP_TOKEN_FILE`, default
  `$PI_SANDBOX_STATE/secrets/mcp_token`.
- The token file must be a regular, non-empty, single-line file with mode 0600
  or 0400. Group/other access is refused, matching the server-mcp rule.
- The launcher exports the value as `MCP_TOKEN` and passes `--env MCP_TOKEN`.
  The value is never placed in the podman argv, printed by `--dry-run`, or
  mounted into the container.
- The sandbox must not reach the MCP target directly. LAN targets are blocked
  by the egress baseline. Add a public target to the egress deny list so the
  agent cannot bypass MCP; see [Egress](egress.md).

A project opts in by containing `.pi/mcp.json`. See `examples/mcp.json`.

For an opted-in project, the launcher creates the control network with
`--internal` if it does not exist. If the network exists but no MCP container is
attached, it prints a hint and continues; start the server-mcp stack separately
with systemd.

## Missing token

If a project has `.pi/mcp.json` but the token is missing, the launcher exits 2
before `podman run` and prints the fix command:

```bash
install -m 600 ~/.config/server-mcp/secrets/http-token \
  "$PI_SANDBOX_STATE/secrets/mcp_token"
```

## Options

```bash
# Print the final podman command; MCP_TOKEN is shown without its value.
pi-sandbox --dry-run

# Import a token, then launch.
pi-sandbox --mcp-token-file ~/.config/server-mcp/secrets/http-token

# Skip the control network and token for this launch only.
pi-sandbox --no-mcp
```

`PI_SANDBOX_ALLOW_NO_MCP_TOKEN=1` is a diagnostic escape hatch for launching
with `.pi/mcp.json` but no token. It is not intended for normal use.

## Rotating the token

Replace the token in the server-mcp deployment, restart the MCP target, then
import the same value into the sandbox:

```bash
systemctl --user restart server-mcp.target
pi-sandbox --mcp-token-file ~/.config/server-mcp/secrets/http-token
```

## Failure modes

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `401 Unauthorized` | Wrong or rotated token | Compare both token files |
| `403 Forbidden` | Direct MCP target attempt | Add to egress deny list |
| DNS failure | Not on control net or MCP down | Check network and target |
| Permission denied | Token is not mode 0600/0400 | `chmod 600` the token |
| Missing token | No sandbox token copy | Run the printed `install` |

For a 401, compare `$PI_SANDBOX_STATE/secrets/mcp_token` with
`~/.config/server-mcp/secrets/http-token`, then restart the MCP target. For a
DNS or connection failure, check `podman network inspect pi-control`,
`podman ps -a --filter network=pi-control` and
`systemctl --user status server-mcp.target`.

A Pi process running directly on the host is not on `pi-control` and cannot
reach these endpoints. Use stdio transport for a host-run Pi, or explicitly
publish a loopback-only port in the MCP deployment. The sandbox never publishes
a host port by default.

Inside the sandbox, `mcp-remote` and `mcp-disk` are in the default
`NO_PROXY` list, so MCP calls stay on `pi-control` instead of going through the
egress proxy. If you use different MCP hostnames, add them to
`PI_SANDBOX_NO_PROXY` in the launcher config.

## MCP services

The authoritative deployment is the server-mcp Quadlet stack: `mcp-remote` and
`mcp-disk`, on `pi-control` plus the MCP-owned `mcp-egress` network. The MCP
image belongs to the `server-mcp` repository and is not built here.

The Compose file in `compose/compose.yaml` is an optional scaffold for one
remote target. It uses the same internal network name variable and maps the
pi-sandbox state copies onto the server-mcp container paths. It does not join
the MCP's egress network and does not publish a host port. Set the state
directory before using it:

```bash
export PI_SANDBOX_STATE="$HOME/.local/share/pi-sandbox"
export MCP_IMAGE=localhost/server-mcp:dev
podman compose -f compose/compose.yaml up -d
```

## Self-test

Run the contract checks without an MCP stack:

```bash
scripts/mcp-selftest.sh
```
