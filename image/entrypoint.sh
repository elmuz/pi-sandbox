#!/usr/bin/env bash
set -euo pipefail

state="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
mkdir -p "$state"

# Copy only the reviewed, non-secret global configuration. The source is
# mounted read-only by ~/.local/bin/pi-sandbox.
if [ -d /global-pi ]; then
  for file in settings.json models.json AGENTS.md; do
    if [ -f "/global-pi/$file" ]; then
      cp -f "/global-pi/$file" "$state/$file"
    fi
  done

  for dir in prompts skills themes extensions; do
    if [ -d "/global-pi/$dir" ]; then
      mkdir -p "$state/$dir"
      cp -a "/global-pi/$dir/." "$state/$dir/"
    fi
  done
fi

# Host credentials are mounted read-only at /auth-seed. Copy them into the
# writable per-container tmpfs at /shared-auth. The host files are never
# modified; /login and OAuth refreshes are discarded when the container exits.
if [ -d /auth-seed ]; then
  mkdir -p /shared-auth
  find /auth-seed -mindepth 1 -maxdepth 1 -type f \
    -exec cp -f {} /shared-auth/ \;
fi

if [ -d /shared-auth ]; then
  ln -sfn /shared-auth/auth.json "$state/auth.json"
  ln -sfn /shared-auth/mcp-auth.json "$state/mcp-auth.json"
fi

# Forwarded gpg-agent socket: place it where gpg in this container expects
# its agent socket. GNUPGHOME contains public keys only; signing happens in
# the host's gpg-agent through the extra socket.
if [ -S /run/gpg-agent/S.gpg-agent ] && [ -n "${GNUPGHOME:-}" ]; then
  socket_dir="$(gpgconf --list-dirs socketdir 2>/dev/null || true)"
  if [ -n "$socket_dir" ]; then
    mkdir -p "$socket_dir"
    chmod 700 "$socket_dir" 2>/dev/null || true
    ln -sfn /run/gpg-agent/S.gpg-agent "$socket_dir/S.gpg-agent"
  fi
fi

# If a GitHub token is present, make git use the gh credential helper and
# rewrite GitHub SSH remotes to HTTPS so existing checkouts work without a
# mounted SSH key.
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 || true
  git config --global --add url."https://github.com/".insteadOf "git@github.com:" || true
  git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/" || true
fi

exec -- "$@"
