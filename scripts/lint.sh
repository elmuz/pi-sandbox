#!/usr/bin/env bash
#
# Run the repository linters, and optionally the self-tests.
#
# The CI lint job runs this exact script and both paths use the same pinned
# tool versions, so a green local run means a green CI lint job. A tool is
# taken from PATH only when the installed version matches the pin; otherwise
# the pinned version runs from a container image through podman or docker.
#
# Usage:
#   scripts/lint.sh                # linters only
#   scripts/lint.sh --with-tests   # linters plus the self-tests
#
# Set PI_SANDBOX_CONTAINER_ENGINE=podman or docker to force an engine.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Keep these in sync with the versions documented in docs/development.md.
SHELLCHECK_VERSION=0.11.0
HADOLINT_VERSION=2.15.1
YAMLLINT_VERSION=1.38.0
MARKDOWNLINT_VERSION=0.24.0
ACTIONLINT_VERSION=1.7.12

DOCKERFILES=(image/pi.Dockerfile image/egress-proxy.Dockerfile)
YAML_TARGETS=(compose examples .github .yamllint.yml)
MARKDOWN_GLOBS=('**/*.md' '**/*.markdown')

with_tests=0
for arg in "$@"; do
  case "$arg" in
    --with-tests) with_tests=1 ;;
    -h | --help)
      sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

engine=${PI_SANDBOX_CONTAINER_ENGINE:-}
if [[ -z "$engine" ]]; then
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      engine=$candidate
      break
    fi
  done
fi

step() { printf '\n==> %s\n' "$*"; }

# matches <command> <expected-version>
# True when the command is on PATH and reports exactly the pinned version.
matches() {
  local cmd=$1 expected=${2//./\\.}
  command -v "$cmd" >/dev/null 2>&1 || return 1
  "$cmd" --version 2>&1 | grep -qE "(^|[^0-9.])$expected([^0-9.]|$)"
}

# in_container <image> [args...]
in_container() {
  local image=$1
  shift
  if [[ -z "$engine" ]]; then
    echo "error: $image is needed but neither podman nor docker is installed" >&2
    exit 1
  fi
  "$engine" run --rm --volume "$PWD:/mnt:ro" --workdir /mnt "$image" "$@"
}

# Mirror the file selection of the CI ShellCheck action: any file whose
# shebang names a POSIX or Bash shell, excluding the Git directory.
mapfile -t shell_files < <(
  find . -path ./.git -prune -o -type f -print0 |
    xargs -0 -r grep -lE '^#! */[^ ]*/(env[[:space:]]+)?[abk]*sh\b' 2>/dev/null |
    sort
)
if ((${#shell_files[@]} == 0)); then
  echo "error: no shell scripts found" >&2
  exit 1
fi

step "ShellCheck $SHELLCHECK_VERSION"
if matches shellcheck "$SHELLCHECK_VERSION"; then
  shellcheck --severity=warning --format=gcc "${shell_files[@]}"
else
  in_container "docker.io/koalaman/shellcheck:v$SHELLCHECK_VERSION" \
    --severity=warning --format=gcc "${shell_files[@]}"
fi

for dockerfile in "${DOCKERFILES[@]}"; do
  step "Hadolint $HADOLINT_VERSION ($dockerfile)"
  if matches hadolint "$HADOLINT_VERSION"; then
    hadolint --config .hadolint.yaml --failure-threshold warning "$dockerfile"
  else
    # The hadolint image has no entrypoint: name the binary explicitly.
    in_container "docker.io/hadolint/hadolint:v$HADOLINT_VERSION" \
      /bin/hadolint --config .hadolint.yaml --failure-threshold warning "$dockerfile"
  fi
done

step "yamllint $YAMLLINT_VERSION"
if matches yamllint "$YAMLLINT_VERSION"; then
  yamllint --config-file .yamllint.yml "${YAML_TARGETS[@]}"
else
  in_container docker.io/library/python:3.13-slim sh -c \
    "pip install --quiet --disable-pip-version-check yamllint==$YAMLLINT_VERSION &&
     exec yamllint --config-file .yamllint.yml ${YAML_TARGETS[*]}"
fi

step "markdownlint-cli2 $MARKDOWNLINT_VERSION"
if matches markdownlint-cli2 "$MARKDOWNLINT_VERSION"; then
  markdownlint-cli2 "${MARKDOWN_GLOBS[@]}"
else
  in_container "docker.io/davidanson/markdownlint-cli2:v$MARKDOWNLINT_VERSION" \
    "${MARKDOWN_GLOBS[@]}"
fi

step "actionlint $ACTIONLINT_VERSION"
# actionlint shells out to ShellCheck, so the local binary is used only when
# both versions match the pins; otherwise run the self-contained image.
if matches actionlint "$ACTIONLINT_VERSION" &&
  matches shellcheck "$SHELLCHECK_VERSION"; then
  actionlint
else
  in_container "docker.io/rhysd/actionlint:$ACTIONLINT_VERSION" -color
fi

if ((with_tests)); then
  step "MCP contract self-test"
  scripts/mcp-selftest.sh

  step "Isolation self-test"
  scripts/isolation-test.sh
fi

printf '\nAll checks passed.\n'
