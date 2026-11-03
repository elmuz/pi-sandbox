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
EGRESS_IMAGE="${PI_SANDBOX_EGRESS_IMAGE:-localhost/pi-sandbox-egress:${PI_VERSION:-isolation}}"

cleanup() {
  if [[ "$LIVE" -eq 1 ]]; then
    run_launcher --stop-egress >/dev/null 2>&1 || true
    podman network rm "$EGRESS_NETWORK" "$EGRESS_UPLINK" >/dev/null 2>&1 || true
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
printf 'deny catafalco.example.com\nallow 192.168.178.50 443\n' \
  > "$TEST_CONFIG/egress-policy.conf"
chmod 600 "$TEST_CONFIG/egress-policy.conf"

run_launcher() {
  env -i \
    HOME="${HOME:?}" \
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
  "dst=/shared-auth" \
  "--network $EGRESS_UPLINK" \
  '--privileged' \
  '/var/run/docker.sock' \
  '/run/podman/podman.sock'; do
  grep -Fq -- "$forbidden" "$TMP_ROOT/dry-run" \
    && fail "dry-run contains forbidden setting: $forbidden"
done
pass "launcher flags, auth seed and internal network are correct"

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

try:
    via_proxy("http://10.0.0.1/")
except urllib.error.HTTPError as exc:
    if exc.code != 403:
        print(f"private target returned {exc.code}, expected 403", file=sys.stderr)
        sys.exit(1)
except Exception as exc:
    print(f"private target failed with the wrong error: {exc}", file=sys.stderr)
    sys.exit(1)
else:
    print("private target was not blocked", file=sys.stderr)
    sys.exit(1)

for host, port in (("example.com", 443), ("10.0.0.1", 80)):
    try:
        direct(host, port)
    except OSError:
        continue
    print(f"direct connection unexpectedly succeeded: {host}:{port}", file=sys.stderr)
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
  --entrypoint python3 \
  "$EGRESS_IMAGE" \
  -c "$PROBE" \
  || fail "live network probes failed"

pass "public HTTPS works through the proxy, private and direct routes fail"
echo "All live isolation checks passed."
