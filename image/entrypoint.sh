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

# Shared credentials live outside the per-project state volume. Symlinking
# means /login and OAuth refresh write through to the shared files.
if [ -d /shared-auth ]; then
  ln -sfn /shared-auth/auth.json "$state/auth.json"
  ln -sfn /shared-auth/mcp-auth.json "$state/mcp-auth.json"
fi

# If a GitHub token is present, make git use the gh credential helper.
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 || true
fi

exec -- "$@"
