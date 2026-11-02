# Usage

## Workspaces

Start Pi in a project directory:

```bash
cd ~/code/some-project
pi-sandbox
```

Or name the workspace explicitly:

```bash
pi-sandbox --workspace ~/code/some-project
```

The project is mounted read-write. If it lives under the host home directory,
it is also mounted at the same absolute path inside the container so Pi can use
the real project path.

Launching from `$HOME` or `/` does not mount that directory. The launcher
creates a temporary empty workspace under `${TMPDIR:-/tmp}`, starts Pi there,
and deletes it when the container exits. This is useful for chats that only
need network access and the tools in the image.

Scratch runs use a stable `scratch` identity for the Pi state volume and the
session directory, so a later scratch run can resume an earlier conversation.
Files created under `/workspace` are temporary and are not kept; use a project
directory for work that must persist.

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
