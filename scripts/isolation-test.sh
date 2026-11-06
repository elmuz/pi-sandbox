#!/usr/bin/env bash
#
# Verify the sandbox isolation contract.
#
# Default mode needs no Podman: it checks the launcher command line, the
# per-session auth mounts, the limits, and the egress policy parser.
#
# Live mode (--live) creates temporary Podman networks and a temporary proxy,
# then proves that public HTTPS works through the proxy while direct public and
# private connections fail. It does not touch the real pi-egress network.
#
# Usage:
#   scripts/isolation-test.sh
#   scripts/isolation-test.sh --live

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/pi-sandbox"
LIVE=0
if [[ "${1:-}" == "--live" ]]; then
  LIVE=1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-sandbox-isolation.XXXXXX")"
TEST_HOME="$TMP_ROOT/home"
TEST_STATE="$TMP_ROOT/state"
TEST_CONFIG="$TMP_ROOT/config"
TEST_PROJECT="$TMP_ROOT/project"
EGRESS_NETWORK="pi-egress-isolation-$$"
EGRESS_UPLINK="pi-egress-uplink-isolation-$$"
PROXY_NAME="pi-egress-proxy-isolation-$$"
MCP_NETWORK="pi-control-isolation-$$"
MCP_EGRESS_NETWORK="mcp-egress-isolation-$$"
MCP_LISTENER="pi-control-listener-isolation-$$"
MCP_EGRESS_LISTENER="mcp-egress-listener-isolation-$$"
EGRESS_IMAGE="${PI_SANDBOX_EGRESS_IMAGE:-localhost/pi-sandbox-egress:${PI_VERSION:-isolation}}"

cleanup() {
  if [[ "$LIVE" -eq 1 ]]; then
    run_launcher --stop-egress >/dev/null 2>&1 || true
    podman rm -f "$MCP_LISTENER" "$MCP_EGRESS_LISTENER" >/dev/null 2>&1 || true
    podman network rm \
      "$EGRESS_NETWORK" "$EGRESS_UPLINK" "$MCP_NETWORK" "$MCP_EGRESS_NETWORK" \
      >/dev/null 2>&1 || true
  fi
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

mkdir -p "$TEST_HOME" "$TEST_STATE" "$TEST_CONFIG" "$TEST_PROJECT"
printf '%s\n' \
  'default deny' \
  'allow example.com 443' \
  'deny mcp.example.com' \
  'allow 192.168.1.50 443' \
  > "$TEST_CONFIG/egress-policy.conf"
chmod 600 "$TEST_CONFIG/egress-policy.conf"

LAUNCHER_HOME="${HOME:?}"
run_launcher() {
  env -i \
    HOME="$LAUNCHER_HOME" \
    USER="${USER:-$(id -un)}" \
    PATH="$PATH" \
    TMPDIR="$TMP_ROOT" \
    PI_SANDBOX_STATE="$TEST_STATE" \
    PI_SANDBOX_CONFIG_DIR="$TEST_CONFIG" \
    PI_SANDBOX_EGRESS_NETWORK="$EGRESS_NETWORK" \
    PI_SANDBOX_EGRESS_UPLINK="$EGRESS_UPLINK" \
    PI_SANDBOX_EGRESS_PROXY_NAME="$PROXY_NAME" \
    PI_SANDBOX_EGRESS_IMAGE="$EGRESS_IMAGE" \
    PI_SANDBOX_SECRET_SCAN=0 \
    PI_SANDBOX_WARN=0 \
    PI_SANDBOX_WORKSPACE_MODE="${WORKSPACE_MODE:-none}" \
    PI_SANDBOX_CLIPBOARD="${CLIPBOARD_MODE:-0}" \
    PI_SANDBOX_GH_TOKEN="${GH_TOKEN_MODE:-0}" \
    PI_VERSION=isolation \
    PI_IMAGE=localhost/pi-sandbox:isolation \
    PI_WORKSPACE="$TEST_PROJECT" \
    "$LAUNCHER" "$@"
}

# Static launcher contract.
run_launcher --dry-run > "$TMP_ROOT/dry-run" 2> "$TMP_ROOT/dry-run.err" \
  || fail "dry-run exited non-zero"

for needle in \
  '--read-only' \
  '--cap-drop=ALL' \
  '--security-opt=no-new-privileges' \
  '--pids-limit=512' \
  '--memory=4g' \
  '--cpus=2' \
  '--ulimit nofile=8192:8192' \
  "--network $EGRESS_NETWORK" \
  'HTTP_PROXY=http://pi-egress-proxy-isolation-' \
  'HTTPS_PROXY=http://pi-egress-proxy-isolation-' \
  '--label pi-sandbox.launcher-pid=' \
  '--label pi-sandbox.launcher-start=' \
  "src=$TEST_STATE/auth" \
  "dst=/auth-seed" \
  '--tmpfs /shared-auth:'; do
  grep -Fq -- "$needle" "$TMP_ROOT/dry-run" \
    || fail "dry-run is missing: $needle"
done

for forbidden in \
  "src=$TEST_PROJECT" \
  "dst=/shared-auth" \
  "--network $EGRESS_UPLINK" \
  '--network mcp-egress' \
  '--privileged' \
  '/var/run/docker.sock' \
  '/run/podman/podman.sock'; do
  grep -Fq -- "$forbidden" "$TMP_ROOT/dry-run" \
    && fail "dry-run contains forbidden setting: $forbidden"
done
grep -Fq -- '/workspace:rw' "$TMP_ROOT/dry-run" \
  || fail "default dry-run does not use an empty /workspace"
pass "launcher flags, auth seed and internal network are correct"

# Workspace mounts are opt-in; none is the default.
WORKSPACE_MODE=ro run_launcher --dry-run > "$TMP_ROOT/dry-run-ro" 2> "$TMP_ROOT/dry-run-ro.err" \
  || fail "read-only workspace dry-run exited non-zero"
sed 's/\\//g' "$TMP_ROOT/dry-run-ro" > "$TMP_ROOT/dry-run-ro.normalized"
grep -Fq -- "src=$TEST_PROJECT,dst=/workspace,ro" "$TMP_ROOT/dry-run-ro.normalized" \
  || fail "read-only workspace mount is missing"
pass "read-only workspace mount is opt-in"

WORKSPACE_MODE=rw run_launcher --dry-run > "$TMP_ROOT/dry-run-rw" 2> "$TMP_ROOT/dry-run-rw.err" \
  || fail "read-write workspace dry-run exited non-zero"
sed 's/\\//g' "$TMP_ROOT/dry-run-rw" > "$TMP_ROOT/dry-run-rw.normalized"
grep -Fq -- "src=$TEST_PROJECT,dst=/workspace" "$TMP_ROOT/dry-run-rw.normalized" \
  || fail "read-write workspace mount is missing"
grep -Fq -- "src=$TEST_PROJECT,dst=/workspace,ro" "$TMP_ROOT/dry-run-rw.normalized" \
  && fail "read-write workspace mount is read-only"
pass "read-write workspace mount is opt-in"

# Sensitive path trees are refused, including descendants and ancestors.
mkdir -p \
  "$TEST_HOME/.pi/agent" \
  "$TEST_HOME/.ssh/keys" \
  "$TEST_HOME/.pi-backup" \
  "$TEST_STATE/auth"
for sensitive in \
  "$TEST_HOME/.pi" \
  "$TEST_HOME/.pi/agent" \
  "$TEST_HOME/.ssh" \
  "$TEST_HOME/.ssh/keys" \
  "$TEST_STATE" \
  "$TEST_STATE/auth" \
  "$TMP_ROOT"; do
  LAUNCHER_HOME="$TEST_HOME" run_launcher --workspace "$sensitive" --dry-run \
    > "$TMP_ROOT/guard.out" 2> "$TMP_ROOT/guard.err" \
    && fail "sensitive workspace was accepted: $sensitive"
  grep -Fq "sensitive" "$TMP_ROOT/guard.err" \
    || fail "sensitive workspace error does not explain the refusal: $sensitive"
done
pass "sensitive workspace paths and descendants are refused"

ln -s "$TEST_HOME/.pi/agent" "$TEST_HOME/pi-link"
LAUNCHER_HOME="$TEST_HOME" run_launcher --workspace "$TEST_HOME/pi-link" --dry-run \
  > "$TMP_ROOT/guard-link.out" 2> "$TMP_ROOT/guard-link.err" \
  && fail "symlink into a sensitive path was accepted"
grep -Fq "sensitive" "$TMP_ROOT/guard-link.err" \
  || fail "symlink refusal does not explain the sensitive path"
pass "symlink into a sensitive path is refused"

LAUNCHER_HOME="$TEST_HOME" run_launcher --workspace "$TEST_HOME/.pi-backup" --dry-run \
  > "$TMP_ROOT/guard-sibling.out" 2> "$TMP_ROOT/guard-sibling.err" \
  || fail "unrelated sibling workspace was refused"
pass "unrelated sibling workspace is allowed"

LAUNCHER_HOME="$TEST_HOME" run_launcher --workspace "$TEST_HOME" --dry-run \
  > "$TMP_ROOT/guard-home.out" 2> "$TMP_ROOT/guard-home.err" \
  || fail "home workspace scratch dry-run exited non-zero"
grep -Fq "pi-state-scratch" "$TMP_ROOT/guard-home.out" \
  || fail "home workspace did not use the scratch identity"
pass "home workspace still uses the disposable scratch workspace"

# GitHub token is a capability and its value never reaches the podman argv.
mkdir -p "$TEST_STATE/secrets"
printf 'gh-test-token-do-not-print\n' > "$TEST_STATE/secrets/gh_token"
chmod 600 "$TEST_STATE/secrets/gh_token"
run_launcher --dry-run > "$TMP_ROOT/dry-run-gh-off" 2> "$TMP_ROOT/dry-run-gh-off.err" \
  || fail "GitHub-token-off dry-run exited non-zero"
grep -Fq -- '/secrets/gh_token' "$TMP_ROOT/dry-run-gh-off" \
  && fail "GitHub token is enabled by default"
grep -Fq -- '--env GH_TOKEN' "$TMP_ROOT/dry-run-gh-off" \
  && fail "GH_TOKEN is exported by default"

GH_TOKEN_MODE=1 run_launcher --dry-run > "$TMP_ROOT/dry-run-gh-on" 2> "$TMP_ROOT/dry-run-gh-on.err" \
  || fail "GitHub-token-on dry-run exited non-zero"
grep -Fq -- '/secrets/gh_token' "$TMP_ROOT/dry-run-gh-on" \
  || fail "enabled GitHub token is not mounted"
grep -Fq -- '--env GH_TOKEN' "$TMP_ROOT/dry-run-gh-on" \
  || fail "enabled GitHub token is not exported"
grep -Fq -- 'gh-test-token-do-not-print' "$TMP_ROOT/dry-run-gh-on" \
  && fail "GitHub token value leaked into the podman argv"
rm -f "$TEST_STATE/secrets/gh_token"
pass "GitHub token is opt-in and its value stays out of argv"

# GPG is opt-in.
grep -Fq -- 'gpg-agent' "$TMP_ROOT/dry-run" \
  && fail "GPG forwarding is on by default"
pass "GPG forwarding is off by default"

# Policy parser and decision tests.
python3 -m unittest discover -s "$REPO_DIR/image/tests" -p 'test_*.py' \
  >/dev/null 2>&1 \
  || fail "egress policy unit tests failed"
pass "egress policy unit tests pass"

python3 "$REPO_DIR/image/egress_proxy.py" \
  --check-policy \
  --policy "$TEST_CONFIG/egress-policy.conf" \
  >/dev/null \
  || fail "example policy did not validate"
pass "policy file validates"

if [[ "$LIVE" -eq 0 ]]; then
  echo "All static isolation checks passed. Run with --live for network probes."
  exit 0
fi

command -v podman >/dev/null 2>&1 || fail "--live requires podman"
run_launcher --start-egress >/dev/null 2> "$TMP_ROOT/egress.err" \
  || { cat "$TMP_ROOT/egress.err" >&2; fail "could not start temporary egress proxy"; }

PROBE="$(cat <<'PY'
import os
import socket
import sys
import urllib.error
import urllib.request

proxy = os.environ["PROXY"]


def via_proxy(url):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    )
    return opener.open(url, timeout=15).status


def expect_blocked(url, label):
    try:
        via_proxy(url)
    except urllib.error.HTTPError as exc:
        if exc.code != 403:
            print(f"{label} returned {exc.code}, expected 403", file=sys.stderr)
            sys.exit(1)
    except Exception as exc:
        print(f"{label} failed with the wrong error: {exc}", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"{label} was not blocked", file=sys.stderr)
        sys.exit(1)


def direct(host, port):
    sock = socket.create_connection((host, port), timeout=5)
    sock.close()


try:
    status = via_proxy("https://example.com/")
except Exception as exc:
    print(f"public HTTPS through proxy failed: {exc}", file=sys.stderr)
    sys.exit(1)
if status != 200:
    print(f"public HTTPS returned {status}", file=sys.stderr)
    sys.exit(1)

expect_blocked("http://10.0.0.1/", "private target")
expect_blocked("http://example.org/", "unlisted public target")
expect_blocked("http://[2001:db8::1]/", "unlisted IPv6 target")

for host, port in (("example.com", 443), ("10.0.0.1", 80)):
    try:
        direct(host, port)
    except OSError:
        continue
    print(f"direct connection unexpectedly succeeded: {host}:{port}", file=sys.stderr)
    sys.exit(1)

for path in (
    "/etc/pi-egress/policy.conf",
    "/etc/server-mcp/egress-policy.conf",
    os.environ["POLICY_PATH"],
):
    if os.path.exists(path):
        print(f"policy file is visible inside the sandbox: {path}", file=sys.stderr)
        sys.exit(1)

print("live probes passed")
PY
)"

podman run --rm \
  --network "$EGRESS_NETWORK" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --env "PROXY=http://$PROXY_NAME:3128" \
  --env "POLICY_PATH=$TEST_CONFIG/egress-policy.conf" \
  --entrypoint python3 \
  "$EGRESS_IMAGE" \
  -c "$PROBE" \
  || fail "live network probes failed"

pass "public HTTPS works; private, unlisted public, IPv6 and direct routes fail"

# The author is on pi-egress and, when MCP is enabled, pi-control. It is never
# on the MCP egress network. Prove the intended path and the missing one.
podman network create --internal "$MCP_NETWORK" >/dev/null
podman network create --internal "$MCP_EGRESS_NETWORK" >/dev/null

LISTENER="$(cat <<'PY'
import socket
import time

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("0.0.0.0", 19000))
sock.listen()
time.sleep(300)
PY
)"

podman run -d --name "$MCP_LISTENER" \
  --network "$MCP_NETWORK" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --entrypoint python3 \
  "$EGRESS_IMAGE" -c "$LISTENER" >/dev/null

podman run -d --name "$MCP_EGRESS_LISTENER" \
  --network "$MCP_EGRESS_NETWORK" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --entrypoint python3 \
  "$EGRESS_IMAGE" -c "$LISTENER" >/dev/null

mcp_ip="$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MCP_LISTENER")"
mcp_egress_ip="$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MCP_EGRESS_LISTENER")"
[[ -n "$mcp_ip" && -n "$mcp_egress_ip" ]] \
  || fail "could not determine the MCP listener addresses"

CONNECT="$(cat <<'PY'
import socket
import sys

socket.create_connection((sys.argv[1], 19000), 2).close()
PY
)"

if podman run --rm \
  --network "$EGRESS_NETWORK" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --entrypoint python3 \
  "$EGRESS_IMAGE" -c "$CONNECT" "$mcp_egress_ip" >/dev/null 2>&1; then
  fail "author on pi-egress reached the mcp-egress listener"
fi
pass "author on pi-egress cannot reach mcp-egress"

podman run --rm \
  --network "$EGRESS_NETWORK" \
  --network "$MCP_NETWORK" \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --entrypoint python3 \
  "$EGRESS_IMAGE" -c "$CONNECT" "$mcp_ip" >/dev/null \
  || fail "author on pi-egress and pi-control cannot reach the MCP listener"
pass "author on pi-egress and pi-control can reach the MCP listener"

echo "All live isolation checks passed."
