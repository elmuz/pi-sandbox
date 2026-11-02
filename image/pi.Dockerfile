# Pi coding-agent sandbox image.
#
# Based on the official Pi container example:
#   node:<version>-slim
#   npm install -g @earendil-works/pi-coding-agent
#
# Base: Debian Trixie (current stable).
#
# This image renames the base image's node user to the host user (UID/GID
# 1000 by default) so rootless Podman with userns=keep-id keeps workspace file
# ownership stable.

ARG BASE_IMAGE=node:24-trixie-slim
# The base image is parameterised for local and CI overrides; the default tag
# is explicit.
# hadolint ignore=DL3006
FROM ${BASE_IMAGE}

ARG SANDBOX_USER=alessio
ARG UID=1000
ARG GID=1000
ARG PI_VERSION=1.4.0
ARG GH_VERSION=2.102.1
ARG GH_SHA256=77b9e297e94c50336823d0f84de7ef1be60cba704601fa0d98f129f47a94987b

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        fd-find \
        git \
        gnupg \
        ripgrep \
        wl-clipboard \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

RUN curl -fsSL -o /tmp/gh.tar.gz \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/gh.tar.gz -C /usr/local/bin --strip-components=2 --wildcards '*/bin/gh' \
    && rm -f /tmp/gh.tar.gz

RUN npm install -g --ignore-scripts \
    "@earendil-works/pi-coding-agent@${PI_VERSION}"

# The node image already uses UID/GID 1000. Rename that account rather than
# creating a conflicting one.
RUN groupmod -n "${SANDBOX_USER}" node \
    && usermod -l "${SANDBOX_USER}" -d "/home/${SANDBOX_USER}" -m node

# Mount points for read-only global config, writable state, shared sessions,
# shared auth, and MCP secrets.
RUN install -d -o root -g root -m 0755 \
    /global-pi \
    /state \
    /sessions \
    /shared-auth \
    /secrets

COPY entrypoint.sh /usr/local/bin/pi-entrypoint
RUN chmod 0755 /usr/local/bin/pi-entrypoint

# Container-only extension. The launcher loads it explicitly, so host Pi never
# sees the sandbox footer marker.
COPY sandbox-status.ts /usr/local/share/pi-sandbox/sandbox-status.ts

USER ${SANDBOX_USER}
ENV HOME=/home/${SANDBOX_USER}
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/pi-entrypoint"]
CMD ["pi"]
