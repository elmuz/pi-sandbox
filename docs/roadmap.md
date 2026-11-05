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
| PS-3 | P1 | Protect sensitive path trees | PS-1, PS-6 |
| PS-6 | P1 | Disposable workspace | server-mcp 3.8/3b |
| PS-5 | P1 | Concurrent-session boundary | server-mcp 3.8, R1 |
| PS-4 | P1 | Verify MCP client auth contract | server-mcp MCP docs |
| PS-7 | P2 | Keep isolation self-tests in CI | PS-1, PS-2, PS-3 |

Recommended order: PS-1 and PS-2 are done; next are PS-3 and PS-6, then the
PS-5 decision, then PS-4, with PS-7 growing alongside each change.

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

- [ ] **Problem.** The workspace guard compares exact strings for `/`,
  `$HOME/.ssh`, `$HOME/.pi` and `$STATE_DIR`. It does not reject descendants, so
  `--workspace "$HOME/.pi/agent"` or `--workspace "$PI_SANDBOX_STATE/auth"` can
  expose auth/config state (and `rw` allows persistent tampering). It also
  compares `$STATE_DIR` as configured rather than canonical.
- [ ] **Change.** Canonicalize the protected roots as well as the workspace, and
  use path-component comparisons to reject overlap in either direction:
  workspace equal to, inside, or an ancestor of a protected root. Keep the
  scratch behavior for `$HOME` and `/`; do not reject unrelated siblings such as
  `$HOME/.pi-backup`.
- [ ] **Acceptance.** Reject exact protected paths, descendants (`.pi/agent`,
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

- [ ] **Problem.** Every sandbox attaches to the same internal `pi-egress`
  bridge. It has no public route, but containers on it can still initiate
  connections to peer container addresses. The proxy policy controls proxied
  destinations, not peer-to-peer bridge traffic. Session A could listen and an
  untrusted session B could connect.
- [ ] **Decision needed.** Are concurrently running sandboxes mutually trusted?
  If yes, document the shared bridge as explicitly not a boundary, including the
  peer-service scenario and guidance not to run mutually untrusted sessions
  concurrently. If no, design per-session internal networks while preserving
  proxy access, with cleanup for normal exit, interrupted launch and stale
  sessions.
- [ ] **Acceptance (if isolated).** Two sandboxes: one listens on its container
  interface, the other cannot connect; both reach the proxy; direct public/LAN
  routes stay unavailable; networks are cleaned up on exit and interrupt.
  **Acceptance (if not isolated):** `docs/security.md` and `docs/egress.md`
  state the limitation and the operational guidance.

### PS-4 P1 — verify and document the MCP client auth contract

- [ ] **Problem.** The review's claim that `examples/mcp.json` contains a
  literal `******` is stale: the current file uses
  `"Authorization": "Bearer ${MCP_TOKEN}"`. The real open question is whether
  the Pi MCP client expands `${MCP_TOKEN}` in `headers` at all. If it does not,
  copying the example sends the literal text and the MCP returns 401. The
  contract is shared with server-mcp's MCP documentation.
- [ ] **Change.** Verify the client's documented behavior. If interpolation is
  supported, state the exact syntax and add a check that a dummy token produces
  the expected bearer header against a fake endpoint. If it is not, document a
  safe alternative that does not store the secret in the repository, and make
  clear that the example is a template, not a copy-ready token value. Never put
  a real token in the example.
- [ ] **Acceptance.** The example is valid JSON and follows the supported
  convention; a fake-endpoint check confirms the header; `docs/mcp.md` and the
  server-mcp contract agree on who injects the token and in what form.

### PS-7 P2 — keep isolation self-tests in CI

- [ ] **Problem.** `scripts/isolation-test.sh` and `scripts/mcp-selftest.sh`
  cover the current static contract, but the PS-1/PS-2/PS-3 regressions are only
  testable through new fake-Podman and dry-run cases. A fix without a CI check
  drifts.
- [ ] **Change.** Add each acceptance case to the existing scripts as the
  corresponding item lands, and keep them in `scripts/lint.sh --with-tests`.
  Prefer fake-Podman/dry-run assertions for CI; keep the live container checks
  opt-in and documented.
- [ ] **Acceptance.** CI fails if the overlay source escapes the workspace, if
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

## Review snapshots

Point-in-time records live in [`docs/reviews/`](reviews/README.md). They are
provenance, not a second backlog: accepted findings are tracked above, and a
snapshot carries no open TODOs.
