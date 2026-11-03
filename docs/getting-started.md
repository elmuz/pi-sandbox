# Getting started

## Requirements

- Rootless Podman.
- A host Pi installation for version matching. The launcher falls back to
  `1.4.0` when `pi --version` is unavailable.
- Linux. Wayland is optional but required for clipboard image paste.

## Install

```bash
./install.sh
```

This:

- creates the state and config directories with private modes;
- symlinks `~/.local/bin/pi-sandbox` to this repository;
- installs the launcher config and egress policy only when they do not already
  exist;
- installs example MCP target files only when they do not already exist;
- warns when `$PI_SANDBOX_STATE/secrets/mcp_token` is missing.

To import the shared token from the server-mcp deployment:

```bash
PI_SANDBOX_MCP_TOKEN_FILE=~/.config/server-mcp/secrets/http-token \
  ./install.sh
```

The token is copied to `$PI_SANDBOX_STATE/secrets/mcp_token` with mode 0600.
An existing token is never overwritten unless `--force` is passed. The
installer does not create or copy any other credential.

## Runtime state

Runtime state lives outside the repository:

```text
~/.local/share/pi-sandbox/
├── auth/                          read-only seed for per-session auth
├── secrets/                       MCP bearer token (mode 0600 or 0400)
├── sessions/                      shared per-project sessions
├── gpg/home/                      public keyring for opt-in signing
└── mcp/catafalco/                 target config, key, known_hosts, audit
```

`PI_SANDBOX_STATE` overrides the runtime state directory.

Launcher configuration lives separately:

```text
~/.config/pi-sandbox/
├── config                         optional launcher settings
└── egress-policy.conf             host-owned egress allow/deny rules
```

`PI_SANDBOX_CONFIG_DIR` overrides the config directory.

The repository contains **source assets**. Credentials, session history and
target-specific MCP configuration stay in the runtime state directory.

## Build and run

The image is tagged with the host Pi version:

```text
localhost/pi-sandbox:1.4.0
```

The launcher reads `pi --version` and builds that tag if it is missing.
It also builds the egress proxy image if it is missing. Trixie is the only
supported Pi base image.

```bash
cd ~/code/some-project
pi-sandbox
```

or:

```bash
pi-sandbox --workspace ~/code/some-project
```

Launching from `$HOME` or `/` does not mount that directory. Instead, the
launcher creates a temporary empty workspace under `${TMPDIR:-/tmp}`, starts Pi
there, and deletes it when the container exits. See
[workspaces](usage.md#workspaces) for the scratch-mode details.

## Update the image

After a Pi or package update:

```bash
pi-sandbox --update
```

`--update` rebuilds both the Pi image and the egress proxy image, removes the
old proxy container, and exits. It does not start Pi and works from any
directory, including `$HOME`.

Build a specific version:

```bash
PI_VERSION=1.4.0 pi-sandbox --update
```

## Egress and signing

The sandbox has no direct internet or LAN route. Review and edit the policy:

```bash
$EDITOR ~/.config/pi-sandbox/egress-policy.conf
pi-sandbox --check-egress-policy
pi-sandbox --start-egress
pi-sandbox --egress-status
```

Host GPG signing is opt-in. Enable it once:

```bash
printf 'PI_SANDBOX_GPG_SIGN=1\n' >> ~/.config/pi-sandbox/config
pi-sandbox --dry-run | grep gpg-agent
```

## Next steps

- Learn about workspaces and sessions in [Usage](usage.md).
- Review the container boundary in [Security](security.md).
- Configure proxy rules in [Egress](egress.md).
- Connect server-mcp in [MCP integration](mcp.md).
