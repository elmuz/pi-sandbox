#!/usr/bin/env bash
#
# Install the pi-sandbox launcher and runtime state directories.
#
# Usage:
#   ./install.sh [--force]
#
# Set PI_SANDBOX_MCP_TOKEN_FILE to an existing server-mcp token to import it as
# $STATE_DIR/secrets/mcp_token with mode 0600. An existing token is never
# overwritten unless --force is given.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${PI_SANDBOX_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-sandbox}"
CONFIG_DIR="${PI_SANDBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pi-sandbox}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
MCP_TOKEN_DEST="$STATE_DIR/secrets/mcp_token"
MCP_TOKEN_SOURCE="${PI_SANDBOX_MCP_TOKEN_FILE:-}"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p \
  "$BIN_DIR" \
  "$CONFIG_DIR" \
  "$STATE_DIR/auth" \
  "$STATE_DIR/secrets" \
  "$STATE_DIR/sessions" \
  "$STATE_DIR/gpg/home" \
  "$STATE_DIR/mcp/catafalco/ssh" \
  "$STATE_DIR/mcp/catafalco/audit"

chmod 700 \
  "$CONFIG_DIR" \
  "$STATE_DIR/auth" \
  "$STATE_DIR/secrets" \
  "$STATE_DIR/sessions" \
  "$STATE_DIR/gpg" \
  "$STATE_DIR/gpg/home" \
  "$STATE_DIR/mcp/catafalco" \
  "$STATE_DIR/mcp/catafalco/ssh" \
  "$STATE_DIR/mcp/catafalco/audit"

ln -sfn "$REPO_DIR/bin/pi-sandbox" "$BIN_DIR/pi-sandbox"

# Import the shared server-mcp bearer token without ever printing its value.
# An existing token is kept unless --force is given.
if [[ -n "$MCP_TOKEN_SOURCE" ]]; then
  if [[ ! -f "$MCP_TOKEN_SOURCE" ]]; then
    echo "MCP token source is not a regular file: $MCP_TOKEN_SOURCE" >&2
    exit 2
  fi
  if [[ ! -s "$MCP_TOKEN_SOURCE" ]]; then
    echo "MCP token source is empty: $MCP_TOKEN_SOURCE" >&2
    exit 2
  fi

  source_real="$(realpath "$MCP_TOKEN_SOURCE")"
  destination_real="$(realpath -m "$MCP_TOKEN_DEST")"

  if [[ "$source_real" != "$destination_real" ]]; then
    if [[ -e "$MCP_TOKEN_DEST" && "$FORCE" -ne 1 ]]; then
      echo "Keeping existing MCP token: $MCP_TOKEN_DEST (use --force to replace)."
    else
      install -d -m 700 "$(dirname "$MCP_TOKEN_DEST")"
      install -m 600 "$MCP_TOKEN_SOURCE" "$MCP_TOKEN_DEST"
      echo "Imported MCP token: $MCP_TOKEN_DEST"
    fi
  fi
elif [[ ! -e "$MCP_TOKEN_DEST" ]]; then
  echo "Warning: no MCP token at $MCP_TOKEN_DEST." >&2
  echo "  Import one with: PI_SANDBOX_MCP_TOKEN_FILE=~/.config/server-mcp/secrets/http-token $0" >&2
fi

install_if_missing() {
  local source="$1"
  local destination="$2"
  local mode="$3"

  if [[ ! -e "$destination" ]]; then
    install -m "$mode" "$source" "$destination"
  fi
}

install_if_missing \
  "$REPO_DIR/examples/config.example" \
  "$CONFIG_DIR/config" 0600
install_if_missing \
  "$REPO_DIR/examples/egress-policy.example.conf" \
  "$CONFIG_DIR/egress-policy.conf" 0600
install_if_missing \
  "$REPO_DIR/examples/mcp/catafalco/config.example.yaml" \
  "$STATE_DIR/mcp/catafalco/config.yaml" 0600
install_if_missing \
  "$REPO_DIR/examples/mcp/catafalco/env.example" \
  "$STATE_DIR/mcp/catafalco/.env" 0600
install_if_missing \
  "$REPO_DIR/examples/mcp/catafalco/known_hosts.example" \
  "$STATE_DIR/mcp/catafalco/known_hosts" 0644
install_if_missing \
  "$REPO_DIR/examples/mcp/catafalco/ssh/id_ed25519.example" \
  "$STATE_DIR/mcp/catafalco/ssh/id_ed25519" 0600

echo "Installed pi-sandbox:"
echo "  repository: $REPO_DIR"
echo "  state:      $STATE_DIR"
echo "  config:     $CONFIG_DIR"
echo "  egress:     $CONFIG_DIR/egress-policy.conf"
echo "  launcher:   $BIN_DIR/pi-sandbox"
echo "  mcp token:  $MCP_TOKEN_DEST"
