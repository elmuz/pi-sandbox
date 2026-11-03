# pi-sandbox documentation

`pi-sandbox` runs the Pi coding agent in a rootless Podman container. The
container gets one project workspace and a deliberately small set of host
capabilities; everything else stays on the host.

Start with [Getting started](getting-started.md) for installation and a first
run, then use the other guides as needed.

| Guide | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Requirements, install, image build, first run and updates |
| [Usage](usage.md) | Workspaces, sessions, global config, footer and clipboard |
| [Security](security.md) | Container model, mounts, credentials, Git and GPG |
| [Egress](egress.md) | Proxy model, policy syntax, lifecycle and verification |
| [MCP integration](mcp.md) | server-mcp contract, tokens, Compose and troubleshooting |
| [Development](development.md) | Repository layout, CI, lint rules and self-tests |

## Quick links

- [Install pi-sandbox](getting-started.md#install)
- [Run Pi in a project](getting-started.md#build-and-run)
- [Reuse the host Pi login](security.md#credentials)
- [Configure egress policy](egress.md)
- [Configure MCP access](mcp.md)
- [Review the security model](security.md)
- [Run the test suite](development.md#tests)

The project overview and quick start are in the [README](../README.md).
