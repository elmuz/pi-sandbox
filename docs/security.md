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

## Egress

The sandbox joins only the internal `pi-egress` network. A shared
`pi-egress-proxy` container is dual-homed: it is the only member with a public
bridge. The sandbox receives `HTTP(S)_PROXY` and has no direct route to the
internet or the LAN.

The proxy allows public destinations by default and blocks every non-global
address, including RFC1918, loopback, link-local, CGNAT and IPv6 ULA/link-local
ranges. A host-owned policy can deny an MCP target or allow a private/local
resource. Explicit deny wins over allow, so the agent cannot bypass MCP to
reach the target directly. See [Egress](egress.md) for the policy syntax.

Proxy decisions are logged by the proxy container. The policy file lives
outside the workspace and is mounted read-only, so the agent cannot edit its
own block list.

The proxy only covers proxy-aware tools. Raw sockets, SSH and tools that ignore
the proxy variables have no internet. That is deliberate: it avoids a
root-owned host firewall.

## Workspace secret warning

The launcher scans up to six levels of the workspace for common secret names
such as `.env`, `.vaults`, `*.vault_pass`, `id_*`, `*.pem`, `*.key` and
`.netrc`. It prints a warning because the workspace is mounted read-write. The
scan is advisory; set `PI_SANDBOX_SECRET_SCAN=0` to disable it.

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
