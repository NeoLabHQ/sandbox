# syntax=docker/dockerfile:1.7
###############################################################################
# Dockerfile — final (":latest") layer of the NeoLabHQ sandbox image chain.
#
# Chain: base -> agents -> final (-> universal).
#   - Dockerfile.base       -> neolabhq/sandbox:base
#   - Dockerfile.agents     -> neolabhq/sandbox:agents
#   - Dockerfile (this file) -> neolabhq/sandbox:latest
#   - Dockerfile.universal  -> neolabhq/sandbox:universal (optional, Step 4)
#
# What this layer adds on top of :agents:
#   - Copies the three preserved devcontainer helper scripts
#     (`.devcontainer/configure-claude.sh`, `.devcontainer/statusline.sh`,
#     `.devcontainer/install-mcps.sh`) and the new repo-root
#     `entrypoint.sh` into /opt/devcontainer/. The `.devcontainer/` source
#     files are NOT modified by this Dockerfile (or by any task step) per
#     /workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md and
#     the spec's "`.devcontainer/` treatment" decision; the COPY is non-
#     destructive (image-internal only).
#   - Bootstraps ~/.claude/settings.json at build time by running
#     configure-claude.sh as the vscode user. install-mcps.sh is
#     deliberately NOT run at build time — CONTEXT7_API_KEY is a runtime
#     secret. The new entrypoint.sh below performs env-var-gated MCP
#     registration on every container start for published-image consumers;
#     the local `.devcontainer/devcontainer.json` continues to invoke
#     install-mcps.sh as its `postCreateCommand` unchanged.
#   - Verifies that codemap, gopls, pyright, and jdtls are reachable
#     (inherited from :agents) — fails fast at build time if the agents
#     image ever drops one of these.
#   - Sets DOCKER_MCP_IN_CONTAINER=1 so in-container code (and the
#     entrypoint's docker-mcp branch) can detect it is running inside the
#     sandbox image.
#   - Sets sensible defaults (WORKDIR /workspaces, ENTRYPOINT to the new
#     entrypoint.sh, CMD ["sleep","infinity"]) so the image works both as
#     a devcontainer and a standalone `docker run` target.
#
# Authoritative spec (rationale, layering decisions, entrypoint.sh contract):
#   /workspaces/sandbox/.specs/tasks/draft/switch-base-image.md
#   Step 3: Modify final Dockerfile and create entrypoint.sh.
###############################################################################

ARG AGENTS_IMAGE=neolabhq/sandbox:agents
FROM ${AGENTS_IMAGE}

###############################################################################
# Re-declare bash+pipefail SHELL.
#
# Per /workspaces/sandbox/.claude/rules/dockerfile-curl-pipe-pipefail.md
# (hadolint DL4006), every Dockerfile MUST switch the RUN shell to bash with
# `-o pipefail` so a partial pipeline aborts the layer instead of silently
# producing a successful-but-empty install. The SHELL directive does NOT carry
# across `FROM`, so it must be re-declared here even though Dockerfile.base
# and Dockerfile.agents already set it. There are no `curl ... | bash` lines
# in this layer today, but future edits adding one MUST be covered by this
# pipefail SHELL — declaring it once at the top is the documented pattern.
###############################################################################
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

###############################################################################
# OCI image annotations. Consumers (GHCR UI, `docker inspect`, Renovate,
# Dependabot, supply-chain scanners) read these labels to surface source,
# description, and license.
###############################################################################
LABEL org.opencontainers.image.source="https://github.com/NeoLabHQ/sandbox"
LABEL org.opencontainers.image.description="NeoLabHQ sandbox: fully configured devcontainer image with Claude Code, AI agents, LSPs, MCP servers, pre-bootstrapped ~/.claude settings, and an entrypoint that autodetects project mise/devbox files and gates MCP registration on env-var presence"
LABEL org.opencontainers.image.licenses="MIT"

###############################################################################
# Copy devcontainer helper scripts and the new entrypoint into the image.
#
# Source paths:
#   - `.devcontainer/configure-claude.sh`  (preserved unchanged on disk; mode 0664)
#   - `.devcontainer/statusline.sh`        (preserved unchanged on disk; mode 0775)
#   - `.devcontainer/install-mcps.sh`      (preserved unchanged on disk; mode 0664)
#   - `entrypoint.sh`                      (new repo-root file; mode 0755)
#
# Destination: /opt/devcontainer/ — stable, well-known path expected by
# downstream consumers and by the ENTRYPOINT directive below.
#
# The on-disk source files in `.devcontainer/` are NOT modified by this
# Dockerfile or by any task step (see the "`.devcontainer/` treatment" row in
# /workspaces/sandbox/.specs/tasks/draft/switch-base-image.md's Technical
# Decisions table). The COPY directive is non-destructive: it creates fresh
# copies inside the image and the subsequent `chmod +x` below sets the
# executable bit on the in-image copies only — the on-disk modes (664/775/664)
# remain unchanged, satisfying
# /workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md.
###############################################################################
USER root

COPY .devcontainer/configure-claude.sh \
     .devcontainer/statusline.sh \
     .devcontainer/install-mcps.sh \
     entrypoint.sh \
     /opt/devcontainer/

RUN chmod +x /opt/devcontainer/*.sh

###############################################################################
# Runtime marker for in-container detection.
#
# Code that needs to know it is running inside the sandbox image checks this
# variable. The entrypoint.sh docker-mcp branch (gated on DOCKER_MCP_SERVER)
# also reads it indirectly via `docker mcp --help` — the baked plugin uses
# this flag internally to skip host-only setup paths.
###############################################################################
ENV DOCKER_MCP_IN_CONTAINER=1

###############################################################################
# Drop to the non-root vscode user for the verification + bootstrap RUN steps
# and for the rest of the image lifecycle.
#
# The agents image's final USER is already vscode (per Dockerfile.agents' last
# directive), so this re-declaration is technically redundant — but explicit
# is better than implicit, and it makes this Dockerfile readable on its own
# without having to chase the inherited USER across `FROM` boundaries.
###############################################################################
USER vscode

###############################################################################
# Fail-fast verification: confirm codemap and the three language servers
# installed by Dockerfile.agents are reachable on the inherited PATH.
#
# This is a regression guard, not a runtime requirement — if a future edit
# to Dockerfile.agents accidentally drops one of these binaries, CI's build
# of the :latest layer fails before the broken image is pushed. Running as
# vscode (not root) ensures the check uses the same PATH end-users see at
# runtime (mise shims, ~/.local/bin, ~/.nix-profile/bin, /home/linuxbrew/...,
# /usr/local/bin, etc. — all inherited from Dockerfile.base + Dockerfile.agents).
###############################################################################
RUN command -v codemap \
 && command -v gopls \
 && command -v pyright \
 && command -v jdtls

###############################################################################
# Bootstrap ~/.claude/settings.json at build time.
#
# configure-claude.sh writes settings, copies statusline.sh into ~/.claude/,
# and registers the build-time Claude plugins (typescript-lsp, the sdd /
# sadd / git / ddd / review / tech-stack context-engineering-kit plugins, and
# the typescript-lsp marketplace entry). Running it here ensures every
# consumer of the :latest image — devcontainer, plain `docker run`, CI runner
# — starts with a fully configured Claude environment without waiting for a
# postCreateCommand.
#
# The script uses `$HOME` throughout (verified at task-plan time via
# `grep -n 'HOME\|/home' .devcontainer/*.sh`) so it resolves correctly to
# /home/vscode/ when run as the vscode user.
#
# install-mcps.sh is deliberately NOT run here:
#   - CONTEXT7_API_KEY is a runtime secret and is unavailable at build time.
#   - The entrypoint.sh below performs the same registration at container
#     start, gated on CONTEXT7_API_KEY presence per the spec's contract.
###############################################################################
RUN /opt/devcontainer/configure-claude.sh

###############################################################################
# Final filesystem position and default command.
#
# WORKDIR /workspaces: matches the default devcontainer workspace root and
#   the mount target used in every `docker run` example in the README.
# ENTRYPOINT /opt/devcontainer/entrypoint.sh: wires the new entrypoint as
#   the unconditional first stage of every container invocation. It performs
#   project-runtime autodetection (devbox.json -> mise.toml -> .mise.toml ->
#   .tool-versions walking up from $PWD), env-var-gated MCP registration
#   (CONTEXT7_API_KEY, DOCKER_MCP_SERVER), and then `exec`s the CMD or any
#   explicit `docker run ... <cmd>` argv. See entrypoint.sh for the full
#   contract.
# CMD ["sleep","infinity"]: keeps the container alive when used as a
#   detached `docker run -d` target (CI runners, remote sandboxes). The
#   entrypoint `exec`s this command if no explicit argv is supplied.
#   Interactive `docker run -it` invocations typically pass an explicit
#   command (e.g. `bash`), which the entrypoint will `exec` after activating
#   the appropriate project shell.
###############################################################################
WORKDIR /workspaces
ENTRYPOINT ["/opt/devcontainer/entrypoint.sh"]
CMD ["sleep", "infinity"]

###############################################################################
# Final user. Explicit for clarity (agents image already ends as vscode).
###############################################################################
USER vscode
