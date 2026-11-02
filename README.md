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
</p>
<!-- markdownlint-enable MD013 -->

The repository contains **source assets**. Runtime state, credentials, session
history and target-specific MCP configuration live outside the repository in
`${XDG_DATA_HOME:-$HOME/.local/share}/pi-sandbox`.

## Layout

```text
pi-sandbox/
├── .github/workflows/ci.yml       lint and image build
├── assets/pi-sandbox.jpg          project logo
├── bin/pi-sandbox                 interactive launcher
├── image/
│   ├── pi.Dockerfile              Pi image definition
│   ├── entrypoint.sh              copies global config, links shared auth
│   ├── sandbox-status.ts          container-only footer marker
│   └── .dockerignore
├── compose/compose.yaml           optional MCP Compose scaffold
├── examples/mcp.json              project-level Pi MCP client example
├── examples/mcp/catafalco/        optional target config templates
├── scripts/mcp-selftest.sh        contract checks without an MCP stack
├── install.sh                     creates state dirs and symlinks the launcher
└── README.md
```

Runtime state:

```text
~/.local/share/pi-sandbox/
├── auth/                          shared Pi credentials
├── secrets/                       MCP bearer token (mode 0600 or 0400)
├── sessions/                      shared per-project sessions
├── gpg/home/                      public keyring for forwarded signing
└── mcp/catafalco/                 target config, key, known_hosts, audit
```

`PI_SANDBOX_STATE` overrides the runtime state directory.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

- ShellCheck on the launcher, installer, self-test and entrypoint;
- the MCP contract self-test, which does not need an MCP stack;
- Hadolint on `image/pi.Dockerfile`;
- yamllint on the Compose file, examples and workflow;
- markdownlint on Markdown files;
- actionlint on the workflow itself;
- a Docker build of `image/pi.Dockerfile`, followed by a `pi --version`
  smoke test.

Lint rules live in `.hadolint.yaml`, `.yamllint.yml` and
`.markdownlint-cli2.yaml`.

## Install

```bash
./install.sh
```

This:

- creates the state directories with private modes;
- symlinks `~/.local/bin/pi-sandbox` to this repository;
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

## Build and run

The image is tagged with the host Pi version:

```text
localhost/pi-sandbox:1.4.0
```

The launcher reads `pi --version` and builds that tag if it is missing.
Trixie is the only supported base image.

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
there, and deletes it when the container exits. This is useful for chats that
only need network access and the tools in the image.

Scratch runs use a stable `scratch` identity for the Pi state volume and the
session directory, so a later scratch run can resume an earlier conversation.
Files created under `/workspace` are temporary and are not kept; use a project
directory for work that must persist.

Update the image after an Arch package update:

```bash
pi-sandbox --update
```

`--update` only rebuilds the image and exits. It does not start Pi and works
from any directory, including `$HOME`.

Build a specific version:

```bash
PI_VERSION=1.4.0 pi-sandbox --update
```

## What the launcher does

It runs rootless Podman with:

- `--rm`
- non-root UID/GID
- `userns=keep-id`
- read-only root filesystem
- `cap-drop=ALL`
- `no-new-privileges`
- memory and PID limits
- no Podman/Docker socket
- no host home, host SSH keys or host namespaces
- mirrors the project at its host absolute path and starts Pi there, so the
  footer shows the real project path instead of `/workspace`
- exposes only the host Wayland socket so Pi can read clipboard images

Mounts:

| Container path | Source | Mode |
| --- | --- | --- |
| `/workspace` | project directory | read-write |
| project host path | same project directory | read-write |
| `/tmp/wayland-0` | host Wayland socket | read-only |
| `/state/pi-agent` | named volume `pi-state-<hash>` | read-write |
| `/home/alessio` | named volume `pi-home-<hash>` | read-write |
| `/sessions` | `$PI_SANDBOX_STATE/sessions/<project>-<hash>` | read-write |
| `/shared-auth` | `$PI_SANDBOX_STATE/auth` | read-write |
| `/global-pi/settings.json` | host Pi config | read-only |
| `/global-pi/models.json` | host Pi config | read-only |
| `/global-pi/AGENTS.md` | host Pi config | read-only |
| `/global-pi/prompts/` | host Pi config | read-only |
| `/global-pi/skills/` | host Pi config | read-only |
| `/global-pi/themes/` | host Pi config | read-only |
| `/global-pi/extensions/` | host Pi config | read-only |
| `/gpg` | `$PI_SANDBOX_STATE/gpg/home` | read-write |
| `/run/gpg-agent/S.gpg-agent` | host gpg-agent extra socket | read-only |

The MCP token is not mounted. The launcher validates the host file and passes
its value as `--env MCP_TOKEN`, so the file does not need to exist inside the
container.

The two GPG rows are present only when host OpenPGP signing is configured. The
entrypoint copies the read-only global files into the per-project state
volume. Credentials are not copied; they are symlinked from `/shared-auth`.

## Working directory and footer

Pi builds its footer from the process working directory. The launcher used to
start Pi in `/workspace`, so every session showed `workspace` in the footer.

When the project lives under the host home directory, the launcher also mounts
it at the same absolute path inside the container and starts Pi there. The
footer then shows the actual project, for example `~/code/foo`, which makes
concurrent sessions distinguishable.

Sessions created before this change still record `/workspace` as their working
directory. Start a new session to get the mirrored path in the footer.

A scratch workspace created for `$HOME` or `/` is outside the host home
directory, so it is mounted at `/workspace`. The built-in footer shows
`workspace`; the container-only marker shows `⬢ sandbox • scratch`.

Separately, the launcher passes a container-only extension with
`--extension`. It calls `ctx.ui.setStatus()` and adds a third footer line with
the project name:

```text
⬢ sandbox • <project>
```

The launcher passes the project basename as `PI_SANDBOX_PROJECT`. This stays
useful when the project is not under the host home directory and the working
directory is therefore shown as `/workspace`. The built-in footer is not
replaced, and host Pi never loads that extension, so the marker appears only in
a `pi-sandbox` container.

## Clipboard images

Pi intercepts `ctrl+v` itself; the screenshot tool only puts the cropped image
on the Wayland clipboard. On paste, Pi runs `wl-paste`, reads the image bytes,
writes them to its own temporary file inside the container
(`/tmp/pi-clipboard-<uuid>.<ext>`), and inserts that path into the editor.

That is why the file is in `/tmp` and has a `pi-clipboard-` prefix: Pi created
it. It is not the screenshot tool's file, and nothing under `~/Pictures` is
involved when the tool copies to the clipboard.

To support this, the launcher:

- installs `wl-clipboard` in the image;
- bind-mounts only the host Wayland socket at `/tmp/wayland-0`;
- sets `WAYLAND_DISPLAY=/tmp/wayland-0` and `XDG_RUNTIME_DIR=/tmp`.

The container can read your clipboard while that socket is connected. The rest
of `$XDG_RUNTIME_DIR` is not mounted. Rebuild the image once after this change:

```bash
pi-sandbox --update
```

## Global config

Shared read-only from `~/.pi/agent`:

```text
settings.json
models.json
AGENTS.md
prompts/
skills/
themes/
extensions/
```

Not shared:

```text
auth.json
trust.json
sessions/
mcp-auth.json
models-store.json
bin/
keybindings.json
SYSTEM.md
APPEND_SYSTEM.md
```

`fd` is installed in the image, so Pi does not need to download it per project.

## GitHub CLI

The image includes a pinned `gh` release (`2.102.1`) and `git`.

Create a token file:

```bash
printf '%s\n' '<fine-grained-personal-access-token>' \
  > "$HOME/.local/share/pi-sandbox/secrets/gh_token"
chmod 600 "$HOME/.local/share/pi-sandbox/secrets/gh_token"
```

When that file exists, the launcher:

- mounts it read-only at `/secrets/gh_token`;
- sets `GH_TOKEN`;
- lets the entrypoint configure `gh auth setup-git`;
- rewrites GitHub SSH remotes to HTTPS so existing checkouts work without a
  mounted SSH key.

Every Pi container then gets GitHub access through that token. Prefer a
fine-grained token limited to the repositories and scopes you actually need.
The host's `~/.config/gh` directory is deliberately not mounted.

If you want to remove GitHub access from Pi, delete the token file or run the
container without `GH_TOKEN`.

## Git identity

The launcher reads the host global Git name and email and passes them into the
container:

```text
GIT_AUTHOR_NAME
GIT_AUTHOR_EMAIL
GIT_COMMITTER_NAME
GIT_COMMITTER_EMAIL
GIT_TERMINAL_PROMPT=0
```

This makes commits and annotated tags work without mounting the host
`~/.gitconfig`.

## GPG signing

When the host uses OpenPGP signing (`user.signingkey`, `commit.gpgsign`, or
`tag.gpgsign`), the launcher forwards the host `gpg-agent` **extra socket** and
links it where `gpg` inside the container expects it.

Only public key material is copied into `$PI_SANDBOX_STATE/gpg/home` at `/gpg`:
`pubring.kbx`, `trustdb.gpg` and `gpg.conf`. The private keys stay in the host
GPG home and are never mounted. The extra socket can sign and decrypt but it
cannot export secret keys.

Signing is still a capability: any process in the container can ask the host
agent to sign data. If the passphrase is not cached, the host pinentry appears.
The launcher starts the host agent if it is not already running.

Git signing settings are injected through `GIT_CONFIG_*` environment variables,
so the container's persistent `~/.gitconfig` is not modified. Rebuild the image
once because it now includes `gnupg`:

```bash
pi-sandbox --update
```

Some GnuPG versions print this harmless line when listing or using keys through
the extra socket:

```text
problem with fast path key listing: Forbidden - ignored
```

This forwarding supports OpenPGP only. If the host sets `gpg.format=ssh`, the
launcher skips it. Commits in the sandbox remain unsigned when no host signing
key or agent socket is available.

## Credentials

The shared auth directory is:

```text
$PI_SANDBOX_STATE/auth/
```

To reuse the host login:

```bash
install -m 0600 ~/.pi/agent/auth.json \
  "$HOME/.local/share/pi-sandbox/auth/auth.json"
```

Do not run `/login` in two containers at the same time.

## Sessions

Sessions are stored per project:

```text
$PI_SANDBOX_STATE/sessions/<project>-<hash>/
```

They survive container removal and can be resumed with `/resume` or:

```bash
pi-sandbox --continue
```

Do not open the same session concurrently from two Pi instances.

## MCP contract

This repository only provides the client side of the server-mcp deployment. It
does not start, stop, restart or update the MCP containers.

The contract is:

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

A project opts in by containing `.pi/mcp.json`. See `examples/mcp.json`.

For an opted-in project, the launcher creates the control network with
`--internal` if it does not exist. If the network exists but no MCP container is
attached, it prints a hint and continues; start the server-mcp stack separately
with systemd.

If a project has `.pi/mcp.json` but the token is missing, the launcher exits 2
before `podman run` and prints the fix command:

```bash
install -m 600 ~/.config/server-mcp/secrets/http-token \
  "$PI_SANDBOX_STATE/secrets/mcp_token"
```

Useful options:

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

Run the contract checks without an MCP stack:

```bash
scripts/mcp-selftest.sh
```

### Rotating the token

Replace the token in the server-mcp deployment, restart the MCP target, then
import the same value into the sandbox:

```bash
systemctl --user restart server-mcp.target
pi-sandbox --mcp-token-file ~/.config/server-mcp/secrets/http-token
```

### Failure modes

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `401 Unauthorized` | Wrong or rotated token | Compare both token files |
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

## Not tracked

Never commit:

```text
auth/auth.json
auth/mcp-auth.json
secrets/mcp_token
secrets/gh_token
mcp/*/.env
mcp/*/ssh/*
mcp/*/audit/
sessions/
```

The repository `.gitignore` excludes these paths.
