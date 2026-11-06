#!/usr/bin/env bash
#
# Verify the Pi MCP client header contract used by the sandbox example.
#
# The test starts a fake HTTP MCP endpoint, points a temporary Pi config at it
# with "Authorization: Bearer ${MCP_TOKEN}", and checks that:
#   - a set MCP_TOKEN becomes the bearer header;
#   - an unset MCP_TOKEN fails closed instead of sending the literal text.
#
# It needs `pi` and `python3`. When either is unavailable the test is skipped,
# so the static contract checks still run in a minimal CI image.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO_DIR/examples/mcp.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

# The example must use the supported expansion syntax and no literal token.
grep -Fq '"Authorization": "Bearer ${MCP_TOKEN}"' "$EXAMPLE" \
  || fail "examples/mcp.json does not use the \${MCP_TOKEN} header syntax"
if grep -Eq 'Bearer [A-Za-z0-9._~+/-]{20,}' "$EXAMPLE"; then
  fail "examples/mcp.json appears to contain a literal bearer token"
fi
pass "example uses the \${MCP_TOKEN} header syntax"

if ! command -v pi >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "skip - pi or python3 is not available; live header check not run"
  exit 0
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pi-sandbox-mcp-auth.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$TMP_ROOT/server.py" <<'PY'
import http.server
import sys

headers_path, port_path = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        with open(headers_path, "a", encoding="utf-8") as handle:
            handle.write(self.headers.get("Authorization", "<none>") + "\n")
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"error":"unauthorized"}')

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
PY

python3 "$TMP_ROOT/server.py" "$TMP_ROOT/headers" "$TMP_ROOT/port" &
SERVER_PID=$!

for _ in $(seq 1 50); do
  [[ -s "$TMP_ROOT/port" ]] && break
  sleep 0.1
done
[[ -s "$TMP_ROOT/port" ]] || fail "fake MCP endpoint did not start"
port="$(cat "$TMP_ROOT/port")"

mkdir -p "$TMP_ROOT/home/.pi/agent"
cat > "$TMP_ROOT/home/.pi/agent/mcp.json" <<JSON
{
  "mcpServers": {
    "fake": {
      "url": "http://127.0.0.1:${port}/mcp",
      "headers": {
        "Authorization": "Bearer \${MCP_TOKEN}"
      }
    }
  }
}
JSON

run_pi() {
  (cd "$TMP_ROOT" && HOME="$TMP_ROOT/home" "$@")
}

: > "$TMP_ROOT/headers"
set +e
run_pi env MCP_TOKEN=dummy-token pi mcp list > "$TMP_ROOT/with-token.out" 2>&1
set -e
grep -Fq 'Bearer dummy-token' "$TMP_ROOT/headers" \
  || fail "Pi did not expand \${MCP_TOKEN} into the Authorization header"
pass "Pi expands \${MCP_TOKEN} into the bearer header"

: > "$TMP_ROOT/headers"
set +e
run_pi env -u MCP_TOKEN pi mcp list > "$TMP_ROOT/without-token.out" 2>&1
set -e
grep -Fq 'Failed to resolve MCP server' "$TMP_ROOT/without-token.out" \
  || fail "missing MCP_TOKEN did not produce a resolution error"
grep -Fq 'MCP_TOKEN' "$TMP_ROOT/without-token.out" \
  || fail "missing MCP_TOKEN error does not name the variable"
[[ ! -s "$TMP_ROOT/headers" ]] \
  || fail "missing MCP_TOKEN still sent a request"
pass "missing MCP_TOKEN fails closed without sending the literal text"

echo "All MCP auth contract tests passed."
