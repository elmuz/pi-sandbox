<p align="center">
  <img src="assets/pi-sandbox.jpg" alt="pi-sandbox logo" width="180">
</p>

<h1 align="center">pi-sandbox</h1>

<p align="center"><em>Containerized Pi coding-agent harness.</em></p>

<!-- markdownlint-disable MD013 -->
<p align="center">
  <a href="https://github.com/elmuz/pi-sandbox/actions/workflows/ci.yml"><img src="https://github.com/elmuz/pi-sandbox/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://www.shellcheck.net/"><img src="https://img.shields.io/badge/shellcheck-passing-brightgreen.svg" alt="ShellCheck"></a>
  <a href="https://github.com/hadolint/hadolint"><img src="https://img.shields.io/badge/hadolint-passing-brightgreen.svg" alt="Hadolint"></a>
  <a href="https://yamllint.readthedocs.io/"><img src="https://img.shields.io/badge/yamllint-passing-brightgreen.svg" alt="yamllint"></a>
  <a href="https://github.com/DavidAnson/markdownlint"><img src="https://img.shields.io/badge/markdownlint-passing-brightgreen.svg" alt="markdownlint"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>
<!-- markdownlint-enable MD013 -->

A rootless Podman sandbox for the
[Pi coding agent](https://github.com/earendil-works/pi-coding-agent).

Pi runs inside a disposable container with only the selected project mounted
read-write. Host credentials, sessions, global config and Git signing are
bridged deliberately; the host home, SSH keys, Podman socket and namespaces
stay outside the sandbox.

Runtime state lives under `${XDG_DATA_HOME:-$HOME/.local/share}/pi-sandbox`
unless `PI_SANDBOX_STATE` overrides it.

## Features

- Project-only workspace mount, plus a disposable scratch mode for `$HOME` or
  `/`.
- Rootless Podman with `userns=keep-id`, a read-only root filesystem,
  `cap-drop=ALL`, `no-new-privileges` and resource limits.
- Shared Pi auth, sessions and global config without mounting host secrets.
- Optional GitHub CLI access, Git identity and OpenPGP signing through the
  host `gpg-agent`.
- Wayland clipboard access for pasting images into Pi.
- Optional MCP client access to server-mcp over an internal network.

## Quick start

Requires rootless Podman and a host Pi installation.

```bash
git clone git@github.com:elmuz/pi-sandbox.git
cd pi-sandbox
./install.sh

cd ~/code/some-project
pi-sandbox
```

To reuse the host Pi login:

```bash
install -m 0600 ~/.pi/agent/auth.json \
  "$HOME/.local/share/pi-sandbox/auth/auth.json"
```

Rebuild the image after a Pi update with `pi-sandbox --update`.

## Documentation

The [documentation index](docs/index.md) links to every guide.

| Guide | What it covers |
| --- | --- |
| [Getting started](docs/getting-started.md) | Install, image build, first run and updates |
| [Usage](docs/usage.md) | Workspaces, sessions, global config, footer and clipboard |
| [Security](docs/security.md) | Container model, mounts, credentials, Git and GPG |
| [MCP integration](docs/mcp.md) | server-mcp contract, tokens, Compose and troubleshooting |
| [Development](docs/development.md) | Repository layout, CI, lint rules and self-tests |

## License

Released under the [MIT License](LICENSE).
