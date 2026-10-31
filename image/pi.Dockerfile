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
FROM ${BASE_IMAGE}

ARG USERNAME=alessio
ARG UID=1000
ARG GID=1000
ARG PI_VERSION=1.4.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        fd-find \
        git \
        ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd

RUN npm install -g --ignore-scripts \
    "@earendil-works/pi-coding-agent@${PI_VERSION}"

# The node image already uses UID/GID 1000. Rename that account rather than
# creating a conflicting one.
RUN groupmod -n "${USERNAME}" node \
    && usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m node

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

USER ${USERNAME}
ENV HOME=/home/${USERNAME}
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/pi-entrypoint"]
CMD ["pi"]
