# Roadmap

Single source of truth for open work in `pi-sandbox`. It records accepted
findings, decisions and dependencies; it is not a feature guide. The behavioral
documentation stays in the other pages linked from [the index](index.md).

- **Status:** the default-deny model (no workspace, no egress, no extra
  capabilities) and the MCP client contract are implemented. The open work below
  hardens the edges that the 2026-11-05 review found.
- **Review input:** [2026-11-05 review](reviews/2026-11-05-review.md). That file
  is a frozen snapshot; accepted items are copied here and tracked only here.
- **Sibling project:** [server-mcp](https://github.com/elmuz/server-mcp) owns the
  privileged side. Its plan is
  [`docs/modernization-plan.md`](https://github.com/elmuz/server-mcp/blob/main/docs/modernization-plan.md);
  the shared boundary is section 3.8 and the 2026-11-05 items R1/R2.
- **Legend:** **P0** means a documented security property is wrong or trivially
  bypassable; **P1** means a realistic disclosure, footgun or unresolved trust
  decision; **P2** is contract/documentation polish. Status: `[ ]` todo, `[~]`
  in progress, `[x]` done, `[?]` needs decision.

## Work items

Completed items stay here as history; the table lists only open work.

| ID | Pri | Item | Pairs with |
| --- | --- | --- | --- |
| PS-6 | P1 | Disposable workspace | server-mcp 3.8/3b |

Recommended order: PS-1, PS-2, PS-3, PS-4, PS-5 and PS-7 are done; next is
PS-6.

### PS-1 P0 — confine the MCP config overlay mount source

- [x] **Done (2026-11-05).** The launcher canonicalizes the workspace and
      candidate config, requires a regular file inside the workspace, and
      stages the sandbox overlay in a launcher-owned 0700 directory before
      mounting it. An escaping symlink is refused before `podman run`; an
      inside-workspace symlink is allowed and still staged.
      `scripts/mcp-selftest.sh` covers both cases and checks the secret never
      appears in output.
- [x] **Problem.** The launcher tests `.pi/mcp.sandbox.json` with
  `[[ -f ... ]]`, which follows symlinks, then uses that path as the host side
  of a Podman bind mount over the container's `.pi/mcp.json`. A checkout can
  therefore contain a symlink to `$HOME/.pi/agent/auth.json`,
  `$PI_SANDBOX_STATE/secrets/gh_token` or any other host file. A read-only
  workspace mount does not protect confidentiality; the overlay is a separate
  mount.
- [x] **Change.** Canonicalize the workspace and the candidate config, and
  require a regular file whose resolved path is inside the canonical workspace.
  Prefer staging the file in a launcher-owned temporary directory with
  restrictive permissions and mounting the staged copy, so a
  repository-controlled symlink is never a mount source. Fail closed with the
  path in the error, never the contents.
- [x] **Acceptance.** An ordinary in-workspace config still overlays as before.
  A symlink to an outside file is rejected before `podman run`; a fake-Podman
  test proves no outside source appears in the mount arguments; a focused
  container test with a dummy secret proves the container cannot read the
  target, and the secret never appears in error or dry-run output. Decide and
  test the policy for a symlink that stays inside the workspace. **Verified
  2026-11-05** by `scripts/mcp-selftest.sh`.

### PS-2 P0 — require host-side consent before enabling MCP

- [x] **Done (2026-11-05).** MCP now requires both a host opt-in (`--mcp`
      or `PI_SANDBOX_MCP=1`) and a project config. `--no-mcp` wins over both.
      The token is validated only when MCP is actually enabled.
      `scripts/mcp-selftest.sh` covers all four combinations plus the
      missing/invalid/valid token cases, and `docs/mcp.md` documents the
      migration.
- [x] **Problem.** Either `.pi/mcp.sandbox.json` or `.pi/mcp.json` in the
  workspace enables MCP automatically. If the host token exists, the launcher
  exports `MCP_TOKEN` and attaches the container to `pi-control`. A repository
  can trigger a privileged capability by containing a file, including in `ro`
  mode that a user may choose to inspect an untrusted checkout. The startup
  warning does not require consent.
- [x] **Change.** Add a host-controlled opt-in (`--mcp` and/or
  `PI_SANDBOX_MCP=1` in the trusted launcher config), default off. Require both
  the host opt-in and a project config before attaching the network or exporting
  the token. Keep project config as the source of server definitions. Keep
  `--no-mcp` as the per-launch override with precedence. Update the startup
  summary and `docs/mcp.md`, including the migration from file-presence
  behavior.
- [x] **Acceptance.** Project config without host opt-in gets neither network
  nor token (dry-run shows it). Host opt-in plus config enables both without
  printing the value. Host opt-in without config does nothing. `--no-mcp` wins
  over both. Extend `scripts/mcp-selftest.sh` for all four cases and keep the
  missing/invalid/valid token checks. **Verified 2026-11-05** by
  `scripts/mcp-selftest.sh`.

### PS-3 P1 — protect sensitive path trees, not only exact paths

- [x] **Done (2026-11-06).** The launcher canonicalizes `$HOME/.ssh`,
  `$HOME/.pi` and `$STATE_DIR` with `realpath -m` and rejects a workspace that
  is equal to, inside, or an ancestor of any of them. `$HOME` and `/` still use
  the disposable scratch workspace. `scripts/isolation-test.sh` covers exact
  paths, descendants, an unrelated sibling and the scratch case.
- [x] **Problem.** The workspace guard compared exact strings for `/`,
  `$HOME/.ssh`, `$HOME/.pi` and `$STATE_DIR`. It did not reject descendants, so
  `--workspace "$HOME/.pi/agent"` or `--workspace "$PI_SANDBOX_STATE/auth"`
  could expose auth/config state (and `rw` allows persistent tampering). It also
  compared `$STATE_DIR` as configured rather than canonical.
- [x] **Change.** Canonicalize the protected roots as well as the workspace, and
  use path-component comparisons to reject overlap in either direction:
  workspace equal to, inside, or an ancestor of a protected root. Keep the
  scratch behavior for `$HOME` and `/`; do not reject unrelated siblings such as
  `$HOME/.pi-backup`.
- [x] **Acceptance.** Reject exact protected paths, descendants (`.pi/agent`,
  `state/auth`) and ancestors that contain a protected root, including paths
  that resolve into one via a symlink. Allow similarly prefixed unrelated paths.
  Cover an absent state directory and a custom `PI_SANDBOX_STATE`, and confirm
  scratch mode is unchanged.

### PS-6 P1 — disposable workspace for untrusted sessions

- [ ] **Problem.** `rw` mounts the host checkout directly. An untrusted author
  can plant `.pi/mcp.json`, `.pi/extensions`, `AGENTS.md`, git hooks, test/build
  metadata and scripts that a later host-side `pi`, test, build or deploy
  process executes. Ignored paths do not appear in `git diff`. The container
  protects the host during the session, not the checkout afterwards. This is the
  pi-sandbox side of server-mcp 3.8 Phase 3b.
- [ ] **Change.** Offer a disposable clone or ephemeral copy for sandbox
  sessions (for example, `git worktree`/`git clone` into state, or a
  copy-on-write overlay), and/or a read-only host checkout. Keep an explicit
  "shared checkout" mode for trusted use, with a prominent warning. Document the
  interim rule until the mode lands: never run host `pi`, tests, build,
  `pre-commit` or deploy in a checkout an untrusted sandbox wrote to without a
  separate review.
- [ ] **Acceptance.** In the disposable mode, files written inside the sandbox
  do not appear in the host checkout; exiting removes or clearly parks the copy.
  The shared mode is still available and documented as the lower-isolation
  choice. `docs/security.md` matches the implemented behavior.

### PS-5 P1 — decide the concurrent-session trust boundary

- [x] **Decided (2026-11-06): the shared bridge is not a boundary.** Every
  sandbox attaches to the same internal `pi-egress` bridge, and MCP-enabled
  sessions also share `pi-control`. Containers on either bridge can initiate
  connections to peer container addresses; the proxy policy controls proxied
  destinations, not peer-to-peer bridge traffic. The sandbox protects the host
  and the MCP from the author, not two authors from each other. Both sessions
  are untrusted by assumption and share no credentials, auth tmpfs or state
  volume.
- [x] **Documented.** `docs/security.md` has a `Concurrent sessions` section and
  `docs/egress.md` has a `Peer sessions` note. They state the limitation, the
  peer-service scenario and the operational guidance: do not run mutually
  untrusted sessions concurrently, do not enable `--gh-token`, `--gpg-sign` or
  MCP in a session that shares a bridge with an untrusted one, and bind
  development servers to `127.0.0.1`.
- [ ] **Revisit if** mutually untrusted concurrent sessions become a supported
  workflow, or a session can hold a capability another must not reach. The
  isolation design would need per-session internal networks, a per-session
  proxy or a proxy attached to every session network, per-session MCP access,
  and cleanup for normal exit, interrupted launch and stale sessions.

### PS-4 P1 — verify and document the MCP client auth contract

- [x] **Done (2026-11-07).** Pi expands `${NAME}` in `headers` and `env`
  values from the environment. `examples/mcp.json` uses
  `"Authorization": "Bearer ${MCP_TOKEN}"`, and `docs/mcp.md` documents the
  syntax, the missing-variable failure and the server-side cross-link.
  `scripts/mcp-auth-test.sh` starts a fake endpoint and checks that a dummy
  token becomes the bearer header and that an unset `MCP_TOKEN` fails closed
  without sending a request. The check is wired into `scripts/mcp-selftest.sh`
  and skips when `pi` or `python3` is unavailable.
- [x] **Problem.** The review's claim that `examples/mcp.json` contains a
  literal `******` was stale: the file already used
  `"Authorization": "Bearer ${MCP_TOKEN}"`. The real open question was whether
  the Pi MCP client expands `${MCP_TOKEN}` in `headers` at all. If it did not,
  copying the example would send the literal text and the MCP would return 401.
  The contract is shared with server-mcp's MCP documentation.
- [x] **Change.** Verified the client's documented behavior. Interpolation is
  supported; the exact syntax and the missing-variable behavior are documented,
  and a fake-endpoint check confirms the header. The example is explicitly a
  template, not a copy-ready token value.
- [x] **Acceptance.** The example is valid JSON and follows the supported
  convention; a fake-endpoint check confirms the header; `docs/mcp.md` and the
  server-mcp contract agree on who injects the token and in what form.

### PS-7 P2 — keep isolation self-tests in CI

- [x] **Done (2026-11-06).** `scripts/lint.sh --with-tests` runs
  `scripts/mcp-selftest.sh` and `scripts/isolation-test.sh`, and CI calls the
  same entrypoint. The PS-3 guard cases and the live egress/MCP boundary probes
  are part of those scripts; the live probes stay opt-in with `--live`.
- [x] **Problem.** `scripts/isolation-test.sh` and `scripts/mcp-selftest.sh`
  covered the static contract, but the PS-1/PS-2/PS-3 regressions were only
  testable through new fake-Podman and dry-run cases. A fix without a CI check
  drifts.
- [x] **Change.** Add each acceptance case to the existing scripts as the
  corresponding item lands, and keep them in `scripts/lint.sh --with-tests`.
  Prefer fake-Podman/dry-run assertions for CI; keep the live container checks
  opt-in and documented.
- [x] **Acceptance.** CI fails if the overlay source escapes the workspace, if
  MCP is enabled without host consent, or if a protected path descendant is
  accepted.

## Already decided / completed

Keep these here so closed debates are not reopened as new findings.

- [x] Rootless Podman with `userns=keep-id`, read-only root filesystem, dropped
  capabilities, `no-new-privileges` and resource limits.
- [x] Default posture is inert: no workspace, no direct internet/LAN route, no
  clipboard, no GitHub token, no GPG signing, no MCP.
- [x] Shared egress proxy with default-deny policy, host-owned policy file
  mounted read-only, and proxy decisions logged.
- [x] Per-session auth seeded read-only from the host into a tmpfs; the host
  file is never written back.
- [x] MCP contract: internal `pi-control` bridge, no host port, one token file
  with strict permissions, `MCP_TOKEN` passed by name, optional
  `.pi/mcp.sandbox.json` overlay.
- [x] Opt-in clipboard, GitHub token and GPG signing, each documented as a
  capability.
- [x] The proxy only covers proxy-aware tools; raw sockets and SSH have no
  internet. This is a deliberate trade-off, not a bug, until a root-owned
  firewall is considered.
- [x] PS-1: the MCP overlay is canonicalized, confined to the workspace and
  staged in a launcher-owned directory before it becomes a mount source.
- [x] PS-2: MCP requires a host opt-in plus a project config; `--no-mcp` wins.
- [x] PS-3: the workspace guard canonicalizes the protected roots and rejects
  exact paths, descendants and ancestors, while keeping the scratch behavior.
- [x] PS-5: the shared `pi-egress` and `pi-control` bridges are not a boundary
  between sessions; the limitation and operational guidance are documented.
- [x] PS-4: Pi expands `${MCP_TOKEN}` in MCP headers; the example, docs and
  fake-endpoint check agree with the server-mcp bearer contract.
- [x] PS-7: the isolation and MCP self-tests run in `scripts/lint.sh
  --with-tests` and CI, including the new guard and live boundary cases.
- [x] Egress proxy parity: the pi-sandbox proxy matches the server-mcp relay
  behavior (half-close propagation, long idle timeout, healthcheck disconnect),
  and the live self-test covers unlisted public and IPv6 destinations.

## Review snapshots

Point-in-time records live in [`docs/reviews/`](reviews/README.md). They are
provenance, not a second backlog: accepted findings are tracked above, and a
snapshot carries no open TODOs.
