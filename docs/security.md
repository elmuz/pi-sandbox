# Security

## What the launcher does

It runs rootless Podman with:

- `--rm`, plus launcher traps and a labelled stale-container sweep, so a closed
  terminal or a killed launcher does not leave the sandbox running
- non-root UID/GID
- `userns=keep-id`
- read-only root filesystem
- `cap-drop=ALL`
- `no-new-privileges`
- memory, PID, CPU and open-file limits
- no direct internet or LAN route; only the internal `pi-egress` network
- no Podman/Docker socket
- no host home, host SSH keys or host namespaces
- no host workspace mount by default; `ro` and `rw` mounts are opt-in
- mirrors a mounted project at its host absolute path and starts Pi there, so
  the footer shows the real project path instead of `/workspace`
- exposes the host Wayland clipboard socket only when clipboard access is
  explicitly enabled

Mounts:

| Container path | Source | Mode |
| --- | --- | --- |
| `/workspace` | project, copy or empty tmpfs | `ro`, `rw` or `ephemeral` |
| project host path | project or its copy | `ro` or `rw` only |
| `/tmp/wayland-0` | host Wayland socket | read-only, opt-in |
| `/state/pi-agent` | named volume `pi-state-<hash>` | read-write |
| `/home/alessio` | named volume `pi-home-<hash>` | read-write |
| `/sessions` | `$PI_SANDBOX_STATE/sessions/<project>-<hash>` | read-write |
| `/auth-seed` | `$PI_SANDBOX_STATE/auth` | read-only |
| `/shared-auth` | per-container tmpfs seeded from `/auth-seed` | read-write |
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
container. See [MCP integration](mcp.md) for the full token contract.

The two GPG rows are present only when signing is explicitly enabled with
`--gpg-sign` or `PI_SANDBOX_GPG_SIGN=1`, and the host is configured for
OpenPGP signing. The entrypoint copies the read-only global files into the
per-project state volume. Credentials are copied from `/auth-seed` into the
per-container tmpfs; the host auth files are never mounted read-write.

## Capability defaults

Everything that widens the sandbox is off unless explicitly enabled:

| Capability | Default | Enable |
| --- | --- | --- |
| Host workspace | Not mounted | `PI_SANDBOX_WORKSPACE_MODE` (not `none`) |
| Public egress | Denied | Add `allow` rules to the egress policy |
| Wayland clipboard | Disabled | `PI_SANDBOX_CLIPBOARD=1` or `--clipboard` |
| GitHub CLI token | Disabled | `PI_SANDBOX_GH_TOKEN=1` or `--gh-token` |
| Host GPG signing | Disabled | `PI_SANDBOX_GPG_SIGN=1` or `--gpg-sign` |
| MCP network | Disabled | Host opt-in + workspace config and token |

Provider auth seeding is the exception: Pi needs credentials to work, so the
read-only auth seed is always copied into the per-container tmpfs.

At startup the launcher prints one summary of the non-default capabilities that
are enabled for that session. `PI_SANDBOX_WARN=0` silences the summary and the
workspace secret warning; it does not change any capability.

## Egress

The sandbox joins only the internal `pi-egress` network. A shared
`pi-egress-proxy` container is dual-homed: it is the only member with a public
bridge. The sandbox receives `HTTP(S)_PROXY` and has no direct route to the
internet or the LAN.

The proxy denies every destination by default, including public ones. A
host-owned policy must explicitly allow the model provider and any package or
git endpoints the agent needs. Non-global addresses, including RFC1918,
loopback, link-local, CGNAT and IPv6 ULA/link-local ranges, stay blocked unless
the policy explicitly allows them. Explicit deny wins over allow, so the agent
cannot bypass MCP to reach the target directly. See
[Egress](egress.md) for the policy syntax and an allowlist example.

Proxy decisions are logged by the proxy container. The policy file lives
outside the workspace and is mounted read-only, so the agent cannot edit its
own block list.

The proxy only covers proxy-aware tools. Raw sockets, SSH and tools that ignore
the proxy variables have no internet. That is deliberate: it avoids a
root-owned host firewall.

## Concurrent sessions

Every sandbox joins the shared internal `pi-egress` bridge. When MCP is
enabled, it also joins the shared `pi-control` bridge. Neither bridge is a
boundary between sandbox sessions: a container on either bridge can connect to
a peer container's address and listening ports. The egress proxy policy
controls proxied destinations, not peer-to-peer bridge traffic.

This is a deliberate limitation, not a claim of session isolation. The sandbox
protects the host and the MCP from the author; it does not separate two authors
from each other. Both sessions are untrusted by assumption, and they share no
credentials, auth tmpfs or state volume.

Operational guidance:

- Do not run mutually untrusted sessions concurrently on the same host. Use a
  separate host or VM when you need that separation.
- Do not enable `--gh-token`, `--gpg-sign` or MCP in a session that shares a
  bridge with an untrusted session.
- Bind development servers to `127.0.0.1` inside the container, not `0.0.0.0`,
  so a peer cannot reach them.
- Treat `pi-egress` and `pi-control` as a flat network among sessions.

Per-session networks are a possible future change. They would require a
per-session proxy or a proxy attached to every session network, plus
per-session MCP access, cleanup and stale-network handling. That is not
implemented.

## Workspace secret warning

The launcher scans up to six levels of a mounted workspace for common secret
names such as `.env`, `.vaults`, `*.vault_pass`, `id_*`, `*.pem`, `*.key` and
`.netrc`. It prints a warning because `ro`, `rw` and `ephemeral` expose those
files to Pi. The scan is advisory; set `PI_SANDBOX_SECRET_SCAN=0` to disable
it. It does not run when the workspace is not mounted (`none`).

## Workspace exposure modes

`PI_SANDBOX_WORKSPACE_MODE` controls what the container can do with the host
checkout. It defaults to `none`.

| Mode | Host checkout | What it protects |
| --- | --- | --- |
| `none` | Not mounted; empty tmpfs | Integrity and confidentiality |
| `ro` | Mounted read-only | Integrity; data can still leak |
| `ephemeral` | Copied; copy mounted read-write | Host checkout and later runs |
| `rw` | Mounted read-write | Nothing after the session |

The `ro` mount is useful for review and analysis. It does not prevent the agent
from reading repository secrets and sending them to the model provider or
through the egress proxy. The model provider already receives prompt content by
design, so treat any mounted checkout as disclosed to that provider.

The `ephemeral` mode copies the working tree, including `.git`, uncommitted
changes and untracked files, into a launcher-owned directory under
`$PI_SANDBOX_STATE/workspaces/` and mounts the copy read-write. The host
checkout is not a mount source, so an agent cannot plant `.git/hooks`,
`.pi/mcp.json`, `AGENTS.md`, build metadata or executable files in the host
checkout through the sandbox. The copy is still readable by the agent and by
the model provider, so confidentiality is the same as `ro`.

On exit the copy is parked under the state directory and the path is printed.
`--workspace-discard` or `PI_SANDBOX_WORKSPACE_DISCARD=1` removes it instead.
A parked copy is untrusted agent output. Do not run host `pi`, tests, builds,
deploys, `pre-commit` or git hooks inside it without reviewing it first. Copy
individual changes back intentionally; the launcher never applies them to the
host checkout.

Ephemeral copies are not resumed automatically. Each launch starts from the
current host checkout. Keep the parked path to recover changes later; the
launcher will not reopen it as a workspace.

The `rw` mount is the shared-checkout coding mode and is a deliberate trust
decision. An untrusted agent can plant files that a host-side process executes
later:

- `.git/hooks`, plus `.git/config` settings such as `core.hooksPath`,
  `core.fsmonitor`, `filter.*`, `diff.*`, `credential.helper`, `gpg.program`,
  `alias.*` and `url.*.insteadOf`;
- `.gitmodules`, `.gitattributes` filters, and executable-bit changes;
- `.pi/mcp.json`, `.pi/mcp.sandbox.json`, `.pi/extensions`,
  `.pi/settings.json` and `AGENTS.md`, which a host-run Pi or the launcher
  reads; `AGENTS.md` is also prompt input, so it can steer host-side work;
- package and build scripts, for example `package.json` lifecycle scripts,
  `pyproject.toml`, `setup.py`, `conftest.py`, `Makefile`, `justfile`,
  `.pre-commit-config.yaml`, `.cargo/config.toml` and `build.rs`;
- shell and editor entry points such as `.envrc` (direnv), `.vscode/tasks.json`,
  `.vscode/settings.json`, `.idea` run configurations and workspace trust
  prompts;
- deployment files such as `compose.yaml` and `Containerfile` that the host
  later builds or runs, and CI workflows that execute remotely after a push.

Ignored and untracked files are part of the risk: `.pi/`, `.env`, `.git/hooks`
and payloads added to `.git/info/exclude` do not appear in a normal `git diff`.
Symlinks and executable bits can also change what a host-side tool follows or
runs.

The container protects the host from direct access *during the session*. It does
not protect a host-side process that later reads or executes the same checkout.
The launcher cannot make a read-write mount safe against that later execution.

If a shared read-write mount is outside your threat model:

- use `none` for maximum isolation, `ro` when Pi only needs to read the code,
  or `ephemeral` when Pi needs to edit;
- keep a separate clone for sandbox sessions and another checkout for host-side
  development, tests and releases if you keep using `rw`;
- before running host `pi`, git hooks, tests, builds, deploys, IDEs or
  `pre-commit` against a sandbox-written checkout, review tracked, untracked and
  ignored files, `.git/config`, `.git/hooks` and executable bits.

This limitation also applies to MCP configuration. MCP is off unless the host
opts in, and the sandbox overlay is staged outside the workspace so a
repository-controlled symlink cannot become a mount source. That is not a
security boundary: the agent has a shell and, once MCP is enabled, the token, so
it can call the MCP server directly or run a nested Pi with its own config. The
MCP server's own policy is the enforcement point.

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

At start, the entrypoint copies regular files from the read-only
`/auth-seed` mount into a per-container tmpfs at `/shared-auth`. Pi reads and
writes the tmpfs copy. On exit, the copy is discarded. A compromised session
cannot write a poisoned token into the host `auth.json` or `mcp-auth.json`.

Because the copy is discarded, a `/login` or OAuth refresh performed inside the
sandbox does not persist. Re-run `/login` when a provider token expires. A
static provider key such as an OpenRouter key is unaffected: it is copied
unchanged on each launch.

Do not run `/login` in two containers at the same time.

## GitHub CLI

The image includes a pinned `gh` release (`2.102.1`) and `git`.

Create a token file:

```bash
printf '%s\n' '<fine-grained-personal-access-token>' \
  > "$HOME/.local/share/pi-sandbox/secrets/gh_token"
chmod 600 "$HOME/.local/share/pi-sandbox/secrets/gh_token"
```

The token is a capability and is off by default. Enable it with
`PI_SANDBOX_GH_TOKEN=1` or `--gh-token`. When enabled and the file exists, the
launcher:

- mounts it read-only at `/secrets/gh_token`;
- exports `GH_TOKEN` to the container through the environment, not the podman
  argv;
- lets the entrypoint configure `gh auth setup-git`;
- rewrites GitHub SSH remotes to HTTPS so existing checkouts work without a
  mounted SSH key.

Every Pi container then gets GitHub access through that token. Prefer a
fine-grained token limited to the repositories and scopes you actually need.
The host's `~/.config/gh` directory is deliberately not mounted.

If you want to remove GitHub access from Pi, unset `PI_SANDBOX_GH_TOKEN`, delete
the token file, or run the container without `GH_TOKEN`.

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

Host GPG forwarding is opt-in and off by default. Enable it with
`--gpg-sign`, `--no-gpg-sign`, or a persistent setting:

```bash
printf 'PI_SANDBOX_GPG_SIGN=1\n' >> ~/.config/pi-sandbox/config
```

When enabled and the host uses OpenPGP signing (`user.signingkey`,
`commit.gpgsign`, or `tag.gpgsign`), the launcher forwards the host
`gpg-agent` **extra socket** and links it where `gpg` inside the container
expects it.

Only public key material is copied into `$PI_SANDBOX_STATE/gpg/home` at `/gpg`:
`pubring.kbx`, `trustdb.gpg` and `gpg.conf`. The private keys stay in the host
GPG home and are never mounted. The extra socket can sign and decrypt but it
cannot export secret keys.

Signing is still a capability: any process in the container can ask the host
agent to sign data. If the passphrase is not cached, the host pinentry appears.
The launcher starts the host agent if it is not already running. Leave the
default off when you do not need signed commits from the sandbox.

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
