# Usage

## Help

`pi-sandbox --help` prints the launcher options first, then the help of the Pi
binary inside the sandbox image. The second part is the same help you get from
`pi --help` in a sandbox, because every argument the launcher does not consume
is forwarded to that Pi instance. If the image is not built yet, the launcher
prints only its own help and tells you to run `pi-sandbox --update`.

Use `pi-sandbox -- --help` to skip the launcher help and pass `--help` directly
to Pi.

## Workspaces

The host workspace is not mounted by default. Select a mode explicitly:

```bash
pi-sandbox --workspace-mode none   # default: empty /workspace
pi-sandbox --workspace-mode ro     # project mounted read-only
pi-sandbox --workspace-mode rw     # project mounted read-write
```

Set the default persistently in `~/.config/pi-sandbox/config`:

```bash
PI_SANDBOX_WORKSPACE_MODE=rw
```

| Mode | Host workspace | Use when |
| --- | --- | --- |
| `none` | Not mounted; writable tmpfs | Agent must not touch the checkout |
| `ro` | Mounted read-only | Agent may read code, not modify it |
| `rw` | Mounted read-write | Accept host-side execution risk |

`ro` protects the host workspace from modification. It does not protect
confidentiality: Pi can read files in the checkout, including secrets, and send
them to the model provider or through the egress proxy. `none` avoids both
integrity and confidentiality exposure from the checkout.

Earlier versions mounted the workspace read-write by default. To keep that
behaviour after upgrading, set `PI_SANDBOX_WORKSPACE_MODE=rw` in the launcher
config or pass `--workspace-mode rw`.

Name the project path explicitly with `--workspace PATH`. The path determines
the project identity for state and sessions even when it is not mounted.

When the project is mounted and lives under the host home directory, it is also
mirrored at the same absolute path inside the container so Pi can use the real
project path. With `none`, Pi starts in `/workspace`.

Launching from `$HOME` or `/` never mounts that directory. The launcher creates
a temporary empty workspace under `${TMPDIR:-/tmp}`, starts Pi there, and
deletes it when the container exits. Scratch workspaces are always disposable
and mounted read-write, regardless of `PI_SANDBOX_WORKSPACE_MODE`.

Scratch runs use a stable `scratch` identity for the Pi state volume and the
session directory, so a later scratch run can resume an earlier conversation.
Files created under `/workspace` are temporary and are not kept; use a project
directory with a mounted workspace for work that must persist.

## Working directory and footer

Pi builds its footer from the process working directory. The launcher used to
start Pi in `/workspace`, so every session showed `workspace` in the footer.

When the project is mounted with `ro` or `rw` and lives under the host home
directory, the launcher also mounts it at the same absolute path inside the
container and starts Pi there. The footer then shows the actual project, for
example `~/code/foo`, which makes concurrent sessions distinguishable.

With `none`, Pi starts in the empty `/workspace`, so the built-in footer shows
`workspace`; the container-only marker still shows the project name.

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

## Auth

Provider auth is seeded from the read-only host directory:

```text
$PI_SANDBOX_STATE/auth/
```

The entrypoint copies regular files into a per-container tmpfs. Writes from
`/login` or OAuth refresh are discarded when the container exits; the host
`auth.json` is never modified. See [Security](security.md#credentials).

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

## Container lifecycle

The container is disposable and removed when the session ends. The launcher
installs traps for `SIGHUP`, `SIGINT` and `SIGTERM`, so closing the terminal
window also removes the container instead of leaving it running in the
background. A detached watchdog repeats the cleanup if the launcher is killed
without running its traps, which covers `SIGKILL` and terminal emulators that
do not forward the hangup.

Each container is labelled with the launcher PID and process start time; the
next launch also removes any stopped container, or running container whose
launcher no longer exists, that carries the `pi-sandbox.project` label. The
watchdog usually removes leftovers immediately; the startup sweep is the final
fallback.

If you ever need to inspect or remove a leftover session manually:

```bash
podman ps -a --filter label=pi-sandbox.project
podman rm -f <name>
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

## Network

The sandbox has no direct internet or LAN route. It sends HTTP(S) traffic to
the internal egress proxy, which denies every destination by default. Add
narrow `allow` rules for the model provider and any package or git endpoints,
then restart the proxy. See [Egress](egress.md).

## Clipboard images

Clipboard access is off by default. Enable it for one launch or persistently:

```bash
pi-sandbox --clipboard
```

```bash
PI_SANDBOX_CLIPBOARD=1
```

When enabled, Pi intercepts `ctrl+v` itself; the screenshot tool only puts the
cropped image on the Wayland clipboard. On paste, Pi runs `wl-paste`, reads the
image bytes, writes them to its own temporary file inside the container
(`/tmp/pi-clipboard-<uuid>.<ext>`), and inserts that path into the editor.

That is why the file is in `/tmp` and has a `pi-clipboard-` prefix: Pi created
it. It is not the screenshot tool's file, and nothing under `~/Pictures` is
involved when the tool copies to the clipboard.

To support this, the launcher:

- installs `wl-clipboard` in the image;
- bind-mounts only the host Wayland socket at `/tmp/wayland-0`;
- sets `WAYLAND_DISPLAY=/tmp/wayland-0` and `XDG_RUNTIME_DIR=/tmp`.

The container can read your clipboard while that socket is connected. The rest
of `$XDG_RUNTIME_DIR` is not mounted. Use `--no-clipboard` or set
`PI_SANDBOX_CLIPBOARD=0` to keep it off. Rebuild the image once after a Pi
update:

```bash
pi-sandbox --update
```
