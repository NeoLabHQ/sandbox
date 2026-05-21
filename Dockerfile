# syntax=docker/dockerfile:1.7
###############################################################################
# Dockerfile — final (":latest") layer of the NeoLabHQ sandbox image chain.
#
# Chain: base -> agents -> final.
#   - Dockerfile.base  → neolabhq/sandbox:base
#   - Dockerfile.agents → neolabhq/sandbox:agents
#   - Dockerfile       → neolabhq/sandbox:latest  (this file)
#
# What this layer adds on top of :agents:
#   - Copies and makes executable the three devcontainer helper scripts
#     (configure-claude.sh, statusline.sh, install-mcps.sh) from the repo root
#     into /opt/devcontainer/ inside the image.
#   - Verifies that codemap, gopls, pyright, and jdtls are reachable (inherited
#     from :agents) — fails fast if the agents image ever drops one of these.
#   - Bootstraps ~/.claude/settings.json at build time by running
#     configure-claude.sh; install-mcps.sh is deferred to postCreateCommand
#     because it requires the runtime CONTEXT7_API_KEY secret.
#   - Sets DOCKER_MCP_IN_CONTAINER=1 so in-container code can detect it is
#     running inside the sandbox image.
#   - Sets sensible defaults (WORKDIR /workspaces, CMD sleep infinity) so the
#     image works both as a devcontainer and a standalone `docker run` target.
#
# Rationale, layering decisions, and the full migration table live in:
#   .specs/tasks/todo/setup-docker-image.chore.md
#   (sections "Step 3: Create final Dockerfile" and
#    "Step 4: Move scripts and migrate devcontainer.json").
###############################################################################

ARG AGENTS_IMAGE=neolabhq/sandbox:agents
FROM ${AGENTS_IMAGE}

###############################################################################
# Force every `RUN` to use bash with `-o pipefail` so that piped commands
# abort loudly if any stage of the pipeline fails.
# Docker's default `/bin/sh` is dash on Debian/Ubuntu and silently treats a
# broken pipe as success. See .claude/rules/dockerfile-curl-pipe-pipefail.md.
###############################################################################
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

###############################################################################
# OCI image annotations. Consumers (GHCR UI, `docker inspect`, Renovate,
# Dependabot, supply-chain scanners) read these labels to surface source,
# description, and license.
###############################################################################
LABEL org.opencontainers.image.source="https://github.com/NeoLabHQ/sandbox"
LABEL org.opencontainers.image.description="NeoLabHQ sandbox: fully configured devcontainer image with Claude Code, AI agents, LSPs, MCP servers, and pre-bootstrapped ~/.claude settings"
LABEL org.opencontainers.image.licenses="MIT"

###############################################################################
# Copy devcontainer helper scripts as root and make them executable.
#
# Source: repo root (scripts were moved there in Step 3 from .devcontainer/).
# Destination: /opt/devcontainer/ — stable path expected by postCreateCommand
#   in devcontainer.json (`/opt/devcontainer/install-mcps.sh`).
#
# Modes: source files are 0644/0755 from the repo; explicit chmod +x ensures
# all three are executable regardless of the original mode on disk.
###############################################################################
USER root

COPY configure-claude.sh statusline.sh install-mcps.sh /opt/devcontainer/
RUN chmod +x /opt/devcontainer/*.sh

###############################################################################
# Runtime marker for in-container detection.
# Code that needs to know it is running inside the sandbox image (e.g. the
# docker-mcp plugin, shell aliases, postCreateCommand guards) checks this var.
###############################################################################
ENV DOCKER_MCP_IN_CONTAINER=1

###############################################################################
# Verify that codemap and the language servers are reachable.
#
# These binaries are installed in :agents; the final layer inherits them.
# This `command -v` check makes the final image fail-fast during CI if the
# :agents layer ever drops one of these tools — catching the regression before
# a broken image reaches :latest.
#
# Why run as codespace?  Some of these binaries live under
# /home/codespace/.local/bin (GOBIN) and /home/codespace/.npm-global/bin
# (npm globals), which are on PATH only for the codespace user. Running as
# codespace is the canonical way to confirm that the binaries are reachable
# in the same environment that end-users and devcontainers will use.
###############################################################################
USER codespace

RUN command -v codemap \
 && command -v gopls \
 && command -v pyright \
 && command -v jdtls

###############################################################################
# Bootstrap ~/.claude/settings.json at build time.
#
# configure-claude.sh sets up ~/.claude/settings.json, installs the statusline
# plugin, and registers any build-time Claude plugins. Running it here ensures
# that every consumer of the :latest image (devcontainer, plain `docker run`,
# CI runner) starts with a fully configured Claude environment without waiting
# for a postCreateCommand.
#
# install-mcps.sh is deliberately NOT run here — it needs the runtime
# CONTEXT7_API_KEY secret, which is unavailable at build time.
###############################################################################
RUN /opt/devcontainer/configure-claude.sh

###############################################################################
# Final filesystem position and default command.
#
# WORKDIR /workspaces: matches the default devcontainer workspace root and the
#   mount target used in all docker run examples in the README.
# CMD ["sleep", "infinity"]: keeps the container alive when used as a detached
#   `docker run -d` target (CI runners, remote sandboxes). Devcontainer ignores
#   CMD in favour of the devcontainer lifecycle; interactive `docker run -it`
#   invocations typically pass an explicit command (e.g. `bash`).
###############################################################################
WORKDIR /workspaces
CMD ["sleep", "infinity"]
