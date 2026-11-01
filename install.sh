#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${PI_SANDBOX_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-sandbox}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"

mkdir -p \
  "$BIN_DIR" \
  "$STATE_DIR/auth" \
  "$STATE_DIR/secrets" \
  "$STATE_DIR/sessions" \
  "$STATE_DIR/gpg/home" \
  "$STATE_DIR/mcp/catafalco/ssh" \
  "$STATE_DIR/mcp/catafalco/audit"

chmod 700 \
  "$STATE_DIR/auth" \
  "$STATE_DIR/secrets" \
  "$STATE_DIR/sessions" \
  "$STATE_DIR/gpg" \
  "$STATE_DIR/gpg/home" \
  "$STATE_DIR/mcp/catafalco" \
  "$STATE_DIR/mcp/catafalco/ssh" \
  "$STATE_DIR/mcp/catafalco/audit"

ln -sfn "$REPO_DIR/bin/pi-sandbox" "$BIN_DIR/pi-sandbox"

install_if_missing() {
  local source="$1"
  local destination="$2"
  local mode="$3"

  if [[ ! -e "$destination" ]]; then
    install -m "$mode" "$source" "$destination"
  fi
}

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
echo "  launcher:   $BIN_DIR/pi-sandbox"
