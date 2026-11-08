# Getting started

## Requirements

- Rootless Podman.
- A host Pi installation for version matching. The launcher falls back to
  `1.4.0` when `pi --version` is unavailable.
- Linux. Wayland is optional and clipboard access is opt-in.

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
└── mcp/target/                 target config, key, known_hosts, audit
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

A fresh sandbox is intentionally inert: it cannot call a model and it cannot see
your project. That is deliberate. To use it as a coding agent, open the two
doors that matter and leave everything else closed:

1. allow your model provider in the egress policy (see
   [Egress and signing](#egress-and-signing));
2. mount the project with `--workspace-mode ephemeral` (or `rw` for a
   deliberate shared checkout).

By default the host workspace is **not** mounted. Pi runs in an empty,
disposable `/workspace`:

```bash
cd ~/code/some-project
pi-sandbox
```

To let Pi read the checkout without changing it:

```bash
pi-sandbox --workspace-mode ro
```

To let Pi edit a disposable copy without touching the host checkout:

```bash
pi-sandbox --workspace-mode ephemeral
```

The launcher copies the working tree, including uncommitted and untracked
files, under `$PI_SANDBOX_STATE/workspaces/`. It mounts the copy read-write and
parks it on exit so you can review the changes. The host checkout is never
modified. Pass `--workspace-discard` to remove the copy on exit.

To edit the host checkout directly, use the shared mode deliberately:

```bash
pi-sandbox --workspace-mode rw
```

Or select the project path explicitly:

```bash
pi-sandbox --workspace ~/code/some-project --workspace-mode ephemeral
```

To opt in persistently, add this to `~/.config/pi-sandbox/config`:

```bash
PI_SANDBOX_WORKSPACE_MODE=ephemeral
```

A read-write mount is a trust decision: the agent can plant files that a
host-side git, Pi, test, build, deploy or IDE process may execute later.
`ephemeral` prevents those writes from reaching the host checkout, but the
parked copy is still untrusted output. Use `none` or `ro` when even reading the
checkout is outside your threat model. See
[workspace exposure](security.md#workspace-exposure-modes).

Launching from `$HOME` or `/` never mounts that directory. Instead, the launcher
creates a temporary empty workspace under `${TMPDIR:-/tmp}`, starts Pi there,
and deletes it when the container exits. Scratch workspaces are always
disposable and are mounted read-write. See
[workspaces](usage.md#workspaces) for details.

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

The sandbox has no direct internet or LAN route. Egress denies every
destination by default, so Pi cannot reach its model provider until you add a
narrow allow rule. Review and edit the policy:

```bash
$EDITOR ~/.config/pi-sandbox/egress-policy.conf
# For example, add: allow openrouter.ai 443
pi-sandbox --check-egress-policy
pi-sandbox --restart-egress
pi-sandbox --egress-status
```

Other capabilities are also off by default: workspace mount, clipboard, GitHub
token, host GPG signing and MCP. See
[capability defaults](security.md#capability-defaults).

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
