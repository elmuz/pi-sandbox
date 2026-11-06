#!/usr/bin/env bash
#
# Self-test the pi-sandbox <-> server-mcp contract without an MCP stack.
#
# The dry-run checks need no MCP stack. The last check uses a fake podman
# executable to verify that the internal control network is created once and
# that the token never appears in the podman argv.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/pi-sandbox"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-sandbox-mcp-selftest.XXXXXX")"

TEST_HOME="$TMP_ROOT/home"
TEST_STATE="$TMP_ROOT/state"
TEST_PROJECT="$TMP_ROOT/project"
TEST_NETWORK="pi-control"
TEST_TOKEN="$TEST_STATE/secrets/mcp_token"
SECRET="selftest-token-do-not-log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

mkdir -p "$TEST_HOME" "$TEST_STATE" "$TEST_PROJECT"

# Run the launcher in a clean environment. Dry-run checks do not need podman.
run_launcher() {
  env -i \
    HOME="$TEST_HOME" \
    USER="${USER:-$(id -un)}" \
    PATH="${TEST_PATH:-$PATH}" \
    TMPDIR="$TMP_ROOT" \
    PI_SANDBOX_STATE="$TEST_STATE" \
    PI_SANDBOX_MCP_NETWORK="$TEST_NETWORK" \
    PI_SANDBOX_MCP="${MCP_OPT_IN:-0}" \
    PI_SANDBOX_WORKSPACE_MODE="${WORKSPACE_MODE:-rw}" \
    PI_SANDBOX_WARN=0 \
    PI_VERSION=selftest \
    PI_IMAGE=localhost/pi-sandbox:selftest \
    PI_WORKSPACE="$TEST_PROJECT" \
    FAKE_PODMAN_STATE="${FAKE_PODMAN_STATE:-}" \
    FAKE_PODMAN_LOG="${FAKE_PODMAN_LOG:-}" \
    "$LAUNCHER" "$@"
}

write_project_config() {
  mkdir -p "$TEST_PROJECT/.pi"
  printf '{"mcpServers":{}}\n' > "$TEST_PROJECT/.pi/mcp.json"
}

write_sandbox_config() {
  mkdir -p "$TEST_PROJECT/.pi"
  printf '{"mcpServers":{"sandbox":{"url":"http://sandbox:8000/mcp"}}}\n' \
    > "$TEST_PROJECT/.pi/mcp.sandbox.json"
}

write_token() {
  mkdir -p "$TEST_STATE/secrets"
  printf '%s\n' "$SECRET" > "$TEST_TOKEN"
  chmod 600 "$TEST_TOKEN"
}

# 1. Valid token: dry-run shows the control network and MCP_TOKEN, not the value.
write_project_config
write_token
stdout="$TMP_ROOT/stdout.1"
stderr="$TMP_ROOT/stderr.1"
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr" || fail "valid token dry-run exited non-zero"

grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  || fail "dry-run is missing --network $TEST_NETWORK"
grep -Fq -- '--env MCP_TOKEN' "$stdout" \
  || fail "dry-run is missing --env MCP_TOKEN"
grep -Fq -- "$SECRET" "$stdout" "$stderr" \
  && fail "dry-run leaked the token value"

control_count="$(grep -o -- "--network $TEST_NETWORK" "$stdout" | wc -l)"
[[ "$control_count" -eq 1 ]] || fail "dry-run has $control_count control network flags, expected 1"
grep -Fq -- '--network mcp-egress' "$stdout" \
  && fail "dry-run attached the sandbox to mcp-egress"
pass "valid token: one internal network and redacted MCP_TOKEN"

# 1b. A sandbox-specific config wins and is mounted over .pi/mcp.json inside
# the container, so the host file can stay a host-run development config.
write_sandbox_config
stdout="$TMP_ROOT/stdout.1b"
stderr="$TMP_ROOT/stderr.1b"
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr" \
  || fail "sandbox-config dry-run exited non-zero"

grep -Fq -- "src=$TMP_ROOT/pi-sandbox-mcp." "$stdout" \
  || fail "dry-run does not mount a staged sandbox MCP config"
grep -Fq -- "src=$TEST_PROJECT/.pi/mcp.sandbox.json" "$stdout" \
  && fail "dry-run mounts the repository-controlled sandbox config directly"
grep -Fq -- 'dst=/workspace/.pi/mcp.json' "$stdout" \
  || fail "sandbox MCP config is not mounted over .pi/mcp.json"
grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  || fail "sandbox-config dry-run is missing the control network"
pass "sandbox MCP config is overlaid on .pi/mcp.json"

# 1c. The default workspace mode is none, so project MCP config is ignored.
rm -f "$TEST_PROJECT/.pi/mcp.sandbox.json"
stdout="$TMP_ROOT/stdout.1c"
stderr="$TMP_ROOT/stderr.1c"
WORKSPACE_MODE=none MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr" \
  || fail "unmounted-workspace dry-run exited non-zero"
grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  && fail "unmounted workspace still enables the control network"
grep -Fq -- '--env MCP_TOKEN' "$stdout" \
  && fail "unmounted workspace still exports MCP_TOKEN"
pass "unmounted workspace ignores project MCP config"

# 1d. A project config without the host opt-in gets neither network nor token.
write_project_config
write_token
stdout="$TMP_ROOT/stdout.1d"
stderr="$TMP_ROOT/stderr.1d"
run_launcher --dry-run > "$stdout" 2> "$stderr" \
  || fail "host-opt-in-off dry-run exited non-zero"
grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  && fail "project config enabled MCP without host opt-in"
grep -Fq -- '--env MCP_TOKEN' "$stdout" \
  && fail "project config exported MCP_TOKEN without host opt-in"
pass "project config alone does not enable MCP"

# 1e. Host opt-in without a project config does nothing.
rm -rf "$TEST_PROJECT/.pi"
stdout="$TMP_ROOT/stdout.1e"
stderr="$TMP_ROOT/stderr.1e"
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr" \
  || fail "host-opt-in-only dry-run exited non-zero"
grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  && fail "host opt-in without project config enabled the control network"
grep -Fq -- '--env MCP_TOKEN' "$stdout" \
  && fail "host opt-in without project config exported MCP_TOKEN"
pass "host opt-in without project config does nothing"

# 1f. --no-mcp wins over the host opt-in and a project config.
write_project_config
stdout="$TMP_ROOT/stdout.1f"
stderr="$TMP_ROOT/stderr.1f"
MCP_OPT_IN=1 run_launcher --no-mcp --dry-run > "$stdout" 2> "$stderr" \
  || fail "--no-mcp dry-run exited non-zero"
grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  && fail "--no-mcp did not override the host opt-in"
grep -Fq -- '--env MCP_TOKEN' "$stdout" \
  && fail "--no-mcp still exported MCP_TOKEN"
pass "--no-mcp wins over host opt-in and project config"

# 1g. A sandbox overlay symlink that escapes the workspace is refused before
# podman run, and the target contents never appear in the output.
outside="$TMP_ROOT/outside-secret.json"
printf '{"secret":"outside-do-not-print"}\n' > "$outside"
rm -f "$TEST_PROJECT/.pi/mcp.sandbox.json"
ln -s "$outside" "$TEST_PROJECT/.pi/mcp.sandbox.json"
stdout="$TMP_ROOT/stdout.1g"
stderr="$TMP_ROOT/stderr.1g"
set +e
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "escaping overlay symlink exited $status, expected 2"
grep -Fq 'outside the workspace' "$stderr" \
  || fail "escaping overlay symlink error does not name the boundary"
grep -Fq 'outside-do-not-print' "$stdout" "$stderr" \
  && fail "escaping overlay symlink leaked the target contents"
pass "escaping overlay symlink is refused without leaking contents"

# 1h. A symlink that stays inside the workspace is allowed and still staged.
inside="$TEST_PROJECT/.pi/inside-mcp.json"
printf '{"mcpServers":{"inside":{}}}\n' > "$inside"
rm -f "$TEST_PROJECT/.pi/mcp.sandbox.json"
ln -s "$inside" "$TEST_PROJECT/.pi/mcp.sandbox.json"
stdout="$TMP_ROOT/stdout.1h"
stderr="$TMP_ROOT/stderr.1h"
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr" \
  || fail "inside-workspace overlay symlink dry-run exited non-zero"
grep -Fq -- "src=$TMP_ROOT/pi-sandbox-mcp." "$stdout" \
  || fail "inside-workspace overlay symlink was not staged"
grep -Fq -- "src=$TEST_PROJECT/.pi/mcp.sandbox.json" "$stdout" \
  && fail "inside-workspace overlay symlink was mounted directly"
pass "inside-workspace overlay symlink is allowed and staged"

# 2. A group/other-readable token is refused.
chmod 644 "$TEST_TOKEN"
stdout="$TMP_ROOT/stdout.2"
stderr="$TMP_ROOT/stderr.2"
set +e
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "0644 token exited $status, expected 2"
grep -Fq 'mode 0600 or 0400' "$stderr" \
  || fail "0644 token error does not mention the required mode"
pass "0644 token is refused"

# 3. A project that opts in without a token fails before podman run.
rm -f "$TEST_TOKEN"
stdout="$TMP_ROOT/stdout.3"
stderr="$TMP_ROOT/stderr.3"
set +e
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "missing token exited $status, expected 2"
grep -Fq 'install -m 600' "$stderr" \
  || fail "missing token error does not include the fix command"
pass "missing token fails closed with a fix command"

# 4. A project without an MCP config gets neither the control network nor a token.
rm -rf "$TEST_PROJECT/.pi"
stdout="$TMP_ROOT/stdout.4"
stderr="$TMP_ROOT/stderr.4"
MCP_OPT_IN=1 run_launcher --dry-run > "$stdout" 2> "$stderr" || fail "no-config dry-run exited non-zero"

grep -Fq -- "--network $TEST_NETWORK" "$stdout" \
  && fail "no-config dry-run contains the control network flag"
grep -Fq -- '--env MCP_TOKEN' "$stdout" \
  && fail "no-config dry-run contains MCP_TOKEN"
pass "project without MCP config skips the network and token"

# 5. The internal network is created idempotently. Fake podman records argv and
# remembers which networks exist, so no real container or MCP stack is needed.
write_project_config
write_token

FAKE_BIN="$TMP_ROOT/fake-bin"
FAKE_PODMAN_STATE="$TMP_ROOT/fake-podman-state"
FAKE_PODMAN_LOG="$TMP_ROOT/fake-podman.log"
mkdir -p "$FAKE_BIN" "$FAKE_PODMAN_STATE"
export FAKE_PODMAN_STATE FAKE_PODMAN_LOG

cat > "$FAKE_BIN/podman" <<'FAKE_PODMAN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_PODMAN_LOG:?}"

case "${1:-}" in
  network)
    case "${2:-}" in
      exists)
        name="${3:?}"
        [[ -f "${FAKE_PODMAN_STATE:?}/$name" ]]
        ;;
      create)
        shift 2
        internal=0
        name=""
        for arg in "$@"; do
          case "$arg" in
            --internal) internal=1 ;;
            *) name="$arg" ;;
          esac
        done
        [[ -n "$name" ]] || exit 2
        if [[ "$internal" -eq 1 ]]; then
          printf 'internal\n' > "${FAKE_PODMAN_STATE}/$name"
        else
          printf 'normal\n' > "${FAKE_PODMAN_STATE}/$name"
        fi
        ;;
      inspect)
        shift 2
        format=""
        name=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --format) format="$2"; shift 2 ;;
            *) name="$1"; shift ;;
          esac
        done
        [[ -f "${FAKE_PODMAN_STATE:?}/$name" ]] || exit 1
        case "$format" in
          *Internal*) [[ "$(<"${FAKE_PODMAN_STATE}/$name")" == "internal" ]] && echo true || echo false ;;
          *) echo '{}' ;;
        esac
        ;;
      *) exit 2 ;;
    esac
    ;;
  container)
    case "${2:-}" in
      exists)
        [[ -f "${FAKE_PODMAN_STATE:?}/container-${3:?}" ]]
        ;;
      inspect)
        shift 2
        format=""
        name=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --format) format="$2"; shift 2 ;;
            *) name="$1"; shift ;;
          esac
        done
        [[ -f "${FAKE_PODMAN_STATE:?}/container-$name" ]] || exit 1
        case "$format" in
          *State.Running*) echo true ;;
          *) echo '{}' ;;
        esac
        ;;
      *) exit 2 ;;
    esac
    ;;
  run)
    name=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == "--name" ]]; then
        name="$arg"
        break
      fi
      previous="$arg"
    done
    if [[ -n "$name" ]]; then
      printf 'running\n' > "${FAKE_PODMAN_STATE}/container-$name"
    fi
    exit 0
    ;;
  rm)
    for arg in "$@"; do
      case "$arg" in
        -f|--force) ;;
        *) rm -f "${FAKE_PODMAN_STATE:?}/container-$arg" ;;
      esac
    done
    exit 0
    ;;
  start)
    printf 'running\n' > "${FAKE_PODMAN_STATE:?}/container-${2:?}"
    ;;
  ps|image|build)
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
FAKE_PODMAN
chmod +x "$FAKE_BIN/podman"

TEST_PATH="$FAKE_BIN:$PATH"
export TEST_PATH

: > "$FAKE_PODMAN_LOG"
MCP_OPT_IN=1 run_launcher > "$TMP_ROOT/stdout.5a" 2> "$TMP_ROOT/stderr.5a" \
  || fail "first fake launch exited non-zero"
MCP_OPT_IN=1 run_launcher > "$TMP_ROOT/stdout.5b" 2> "$TMP_ROOT/stderr.5b" \
  || fail "second fake launch exited non-zero"

create_count="$(grep -c -- "^network create --internal $TEST_NETWORK$" "$FAKE_PODMAN_LOG" || true)"
[[ "$create_count" -eq 1 ]] \
  || fail "control network was created $create_count times, expected 1"
grep -Fq -- "$SECRET" "$FAKE_PODMAN_LOG" \
  && fail "token value appeared in the podman argv"
pass "internal control network creation is idempotent and token-free"

echo "All MCP contract self-tests passed."
