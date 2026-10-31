# pi-sandbox

Containerized Pi coding-agent harness.

The repository contains **source assets**. Runtime state, credentials, session
history and target-specific MCP configuration live outside the repository in
`${XDG_DATA_HOME:-$HOME/.local/share}/pi-sandbox`.

## Layout

```text
pi-sandbox/
├── .github/workflows/ci.yml       lint and image build
├── bin/pi-sandbox                 interactive launcher
├── image/
│   ├── pi.Dockerfile              Pi image definition
│   ├── entrypoint.sh              copies global config, links shared auth
│   └── .dockerignore
├── compose/compose.yaml           long-running MCP services
├── examples/mcp.json              project-level Pi MCP client example
├── examples/mcp/catafalco/        target config templates
├── install.sh                     creates state dirs and symlinks the launcher
└── README.md
```

Runtime state:

```text
~/.local/share/pi-sandbox/
├── auth/                          shared Pi credentials
├── secrets/                       MCP bearer token
├── sessions/                      shared per-project sessions
└── mcp/catafalco/                 target config, key, known_hosts, audit
```

`PI_SANDBOX_STATE` overrides the runtime state directory.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

- ShellCheck on the launcher, installer and entrypoint;
- Hadolint on `image/pi.Dockerfile`;
- yamllint on the Compose file, examples and workflow;
- markdownlint on Markdown files;
- actionlint on the workflow itself;
- a Docker build of `image/pi.Dockerfile`, followed by a `pi --version`
  smoke test.

Lint rules live in `.hadolint.yaml` and `.yamllint.yml`.

## Install

```bash
./install.sh
```

This:

- creates the state directories with private modes;
- symlinks `~/.local/bin/pi-sandbox` to this repository;
- installs example MCP target files only when they do not already exist.

It does not create or copy credentials.

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

Launching from `$HOME` is refused because it would mount the entire home
directory. Run from a project directory instead.

Update the image after an Arch package update:

```bash
pi-sandbox --update
```

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
| `/secrets/mcp_token` | optional MCP token | read-only |

The entrypoint copies the read-only global files into the per-project state
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

The container does **not** have the host GPG signing key, so commits made inside
the sandbox are unsigned unless you explicitly add a signing key and configure
Git inside the project.

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

## Project MCP config

Only projects with `.pi/mcp.json` join the internal `pi-control` network.
See `examples/mcp.json`.

The launcher passes `MCP_TOKEN` only when both the project MCP file and
`$PI_SANDBOX_STATE/secrets/mcp_token` exist.

## MCP services

The Compose scaffold is in `compose/compose.yaml`. Set the state directory:

```bash
export PI_SANDBOX_STATE="$HOME/.local/share/pi-sandbox"
export MCP_IMAGE=remote-server-mcp:local
podman compose -f compose/compose.yaml up -d
```

The MCP image itself belongs to the `server-mcp` repository and is not built
here.

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
