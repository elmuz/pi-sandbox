#!/usr/bin/env bash
#
# Verify the disposable workspace contract without a container runtime.
#
# A fake podman records the mount arguments and writes to the mounted source.
# The test proves that an ephemeral launch writes only to a launcher-owned copy,
# that the host checkout is untouched, that the copy is parked or discarded as
# requested, and that read-write mode still mounts the host checkout.
#
# Usage:
#   scripts/workspace-test.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/pi-sandbox"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-sandbox-workspace.XXXXXX")"
TEST_HOME="$TMP_ROOT/home"
TEST_STATE="$TMP_ROOT/state"
TEST_CONFIG="$TMP_ROOT/config"
TEST_PROJECT="$TMP_ROOT/project"
FAKE_BIN="$TMP_ROOT/fake-bin"
FAKE_STATE="$TMP_ROOT/fake-podman-state"
FAKE_LOG="$TMP_ROOT/fake-podman.log"

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

mkdir -p "$TEST_HOME" "$TEST_STATE" "$TEST_CONFIG" "$TEST_PROJECT" "$FAKE_BIN" "$FAKE_STATE"
printf 'original\n' > "$TEST_PROJECT/tracked.txt"
printf 'untracked\n' > "$TEST_PROJECT/untracked.txt"

cat > "$FAKE_BIN/podman" <<'FAKE_PODMAN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_PODMAN_LOG:?}"

case "${1:-}" in
  image)
    [[ "${2:-}" == "exists" ]]
    ;;
  network)
    case "${2:-}" in
      exists)
        [[ -f "${FAKE_PODMAN_STATE:?}/net-${3:?}" ]]
        ;;
      create)
        shift 2
        name=""
        for arg in "$@"; do
          case "$arg" in
            --internal) ;;
            *) name="$arg" ;;
          esac
        done
        [[ -n "$name" ]] || exit 2
        : > "${FAKE_PODMAN_STATE}/net-$name"
        ;;
      inspect)
        echo true
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  container)
    case "${2:-}" in
      exists)
        exit 1
        ;;
      inspect)
        exit 1
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  ps)
    ;;
  run)
    shift
    if [[ "${1:-}" == "-d" ]]; then
      exit 0
    fi

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --mount)
          mount="${2:?}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac

      src=""
      dst=""
      IFS=',' read -r -a parts <<< "${mount:-}"
      for part in "${parts[@]}"; do
        case "$part" in
          src=*) src="${part#src=}" ;;
          dst=*) dst="${part#dst=}" ;;
        esac
      done
      if [[ "$dst" == "/workspace" && -n "$src" ]]; then
        printf 'agent write\n' > "$src/sandbox-marker"
        printf 'changed\n' >> "$src/tracked.txt"
        printf 'new\n' > "$src/agent-new-file.txt"
      fi
    done
    ;;
  rm | start)
    ;;
  *)
    exit 2
    ;;
esac
FAKE_PODMAN
chmod +x "$FAKE_BIN/podman"

run_launcher() {
  env -i \
    HOME="$TEST_HOME" \
    USER="${USER:-$(id -un)}" \
    PATH="$FAKE_BIN:$PATH" \
    TMPDIR="$TMP_ROOT" \
    PI_SANDBOX_STATE="$TEST_STATE" \
    PI_SANDBOX_CONFIG_DIR="$TEST_CONFIG" \
    PI_SANDBOX_WORKSPACE_MODE="${WORKSPACE_MODE:-ephemeral}" \
    PI_SANDBOX_WORKSPACE_DISCARD="${WORKSPACE_DISCARD:-0}" \
    PI_SANDBOX_SECRET_SCAN=0 \
    PI_SANDBOX_WARN=0 \
    PI_VERSION=workspace-test \
    PI_IMAGE=localhost/pi-sandbox:workspace-test \
    PI_WORKSPACE="$TEST_PROJECT" \
    FAKE_PODMAN_STATE="$FAKE_STATE" \
    FAKE_PODMAN_LOG="$FAKE_LOG" \
    "$LAUNCHER" "$@"
}

# 1. Ephemeral mode writes to a copy, never the host checkout.
: > "$FAKE_LOG"
WORKSPACE_MODE=ephemeral run_launcher > "$TMP_ROOT/ephemeral.out" 2> "$TMP_ROOT/ephemeral.err" \
  || fail "ephemeral launch failed"

parked="$(find "$TEST_STATE/workspaces" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$parked" ]] || fail "ephemeral workspace was not parked"
[[ -f "$parked/sandbox-marker" ]] || fail "agent write is missing from the ephemeral copy"
[[ "$(stat -c '%a' "$parked")" == "700" ]] || fail "parked workspace is not private"
[[ -f "$parked/agent-new-file.txt" ]] || fail "agent-created file is missing from the ephemeral copy"
grep -Fq 'changed' "$parked/tracked.txt" || fail "agent edit is missing from the ephemeral copy"

[[ ! -e "$TEST_PROJECT/sandbox-marker" ]] || fail "agent write reached the host checkout"
[[ ! -e "$TEST_PROJECT/agent-new-file.txt" ]] || fail "agent-created file reached the host checkout"
grep -Fq 'original' "$TEST_PROJECT/tracked.txt" || fail "host checkout was modified"
grep -Fq "src=$parked" "$FAKE_LOG" || fail "ephemeral copy was not the mount source"
grep -Fq "Ephemeral workspace parked: $parked" "$TMP_ROOT/ephemeral.err" \
  || fail "parked workspace path was not reported"
grep -Fq "Treat it as untrusted agent output" "$TMP_ROOT/ephemeral.err" \
  || fail "parked workspace warning is missing"
pass "ephemeral workspace isolates writes and parks the copy"

# 2. Read-write mode still mounts the host checkout, so the contrast is real.
rm -rf "${TEST_STATE:?}/workspaces"
: > "$FAKE_LOG"
WORKSPACE_MODE=rw run_launcher > "$TMP_ROOT/rw.out" 2> "$TMP_ROOT/rw.err" \
  || fail "read-write launch failed"
[[ -f "$TEST_PROJECT/sandbox-marker" ]] || fail "read-write mode did not mount the host checkout"
grep -Fq "src=$TEST_PROJECT" "$FAKE_LOG" || fail "read-write host mount is missing"
rm -f "$TEST_PROJECT/sandbox-marker" "$TEST_PROJECT/agent-new-file.txt"
printf 'original\n' > "$TEST_PROJECT/tracked.txt"
pass "read-write mode keeps the shared-checkout behavior"

# 3. Discard removes the copy instead of parking it.
rm -rf "${TEST_STATE:?}/workspaces"
: > "$FAKE_LOG"
WORKSPACE_MODE=ephemeral WORKSPACE_DISCARD=1 run_launcher \
  > "$TMP_ROOT/discard.out" 2> "$TMP_ROOT/discard.err" \
  || fail "ephemeral discard launch failed"
if find "$TEST_STATE/workspaces" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
  fail "discarded ephemeral workspace was left behind"
fi
grep -Fq 'Ephemeral workspace parked' "$TMP_ROOT/discard.err" \
  && fail "discarded workspace was reported as parked"
pass "ephemeral discard removes the copy"

# 4. Dry-run does not copy and does not create the parked directory.
rm -rf "${TEST_STATE:?}/workspaces"
WORKSPACE_MODE=ephemeral run_launcher --dry-run > "$TMP_ROOT/dry.out" 2> "$TMP_ROOT/dry.err" \
  || fail "ephemeral dry-run failed"
[[ ! -d "$TEST_STATE/workspaces" ]] || fail "ephemeral dry-run created a workspace copy"
pass "ephemeral dry-run is side-effect free"

echo "All disposable workspace checks passed."
