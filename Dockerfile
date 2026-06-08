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
#   - Copies the repo-root `entrypoint.sh` and the `claude/` directory
#     (`configure-claude.sh`, `statusline.sh`, `install-mcp.sh`, etc.) into
#     /opt/devcontainer/. The in-image layout mirrors the repo layout: the
#     `claude/` subdir is preserved at `/opt/devcontainer/claude/`, so the
#     entrypoint's BASH_SOURCE-relative invocation of
#     `claude/install-mcp.sh` resolves identically in the image and in-repo.
#     The `.devcontainer/` folder is intentionally NOT referenced by this
#     Dockerfile so it stays purely a development-only artifact for this
#     repo; the published image is built exclusively from repo-root sources.
#   - Bootstraps ~/.claude/settings.json at build time by running
#     configure-claude.sh as the vscode user. MCP registration is
#     deliberately NOT performed at build time — CONTEXT7_API_KEY and
#     DOCKER_MCP_SERVER are runtime values. The new entrypoint.sh below
#     performs env-var-gated MCP registration on every container start for
#     published-image consumers; the local `.devcontainer/devcontainer.json`
#     continues to invoke its own `.devcontainer/install-mcps.sh` as its
#     `postCreateCommand` for local sandbox development, independent of
#     this image.
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
# Copy the repo-root entrypoint and the `claude/` helper directory into the
# image.
#
# Source paths (all at the repo root — NOT under `.devcontainer/`):
#   - `entrypoint.sh`        (mode 0775) — published-image entrypoint
#   - `claude/`              — directory containing:
#       * `configure-claude.sh`  (mode 0664)
#       * `statusline.sh`        (mode 0775)
#       * `install-mcp.sh`       (mode 0775) — invoked by entrypoint.sh
#       * `claude-helpers.sh`    (mode 0664)
#       * `justfile`             (mode 0664)
#
# Destination: /opt/devcontainer/ — stable, well-known path expected by
# downstream consumers and by the ENTRYPOINT directive below. The `claude/`
# subdir is preserved at `/opt/devcontainer/claude/` so that
# `entrypoint.sh`'s BASH_SOURCE-relative invocation of
# `claude/install-mcp.sh` resolves identically in-repo and in-image.
#
# In addition to the canonical `/opt/devcontainer/claude/` install, the
# justfile and its helper script are placed at the vscode user's $HOME root
# so that `just` finds the sandbox recipes via BOTH its global/user-justfile
# mechanism AND its CWD walk-up fallback from a single on-disk copy:
#
# The `.devcontainer/` folder is deliberately NOT referenced by this COPY (or
# anywhere else in this Dockerfile). It is reserved as a development-only
# artifact for this repo's own devcontainer flow, so the published image's
# build inputs stay isolated from local devcontainer changes. The COPY is
# non-destructive: it creates fresh copies inside the image and the subsequent
# `chmod +x` below sets the executable bit on the in-image copies only — the
# on-disk modes (664/775/775) remain unchanged, satisfying
# /workspaces/sandbox/.claude/rules/preserve-permissions-on-move.md.
###############################################################################
USER root

COPY entrypoint.sh /opt/devcontainer/
COPY claude/ /opt/devcontainer/claude/
COPY --chown=vscode:vscode claude/justfile /home/vscode/justfile
COPY --chown=vscode:vscode claude/claude-helpers.sh /home/vscode/claude-helpers.sh

RUN chmod +x /opt/devcontainer/entrypoint.sh /opt/devcontainer/claude/*.sh

###############################################################################
# Runtime marker for in-container detection.
#
# Code that needs to know it is running inside the sandbox image checks this
# variable. It is also consumed by the baked docker-mcp plugin to skip
# host-only setup paths when the plugin's subcommands run inside the image.
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
# `grep -n 'HOME\|/home' *.sh`) so it resolves correctly to
# /home/vscode/ when run as the vscode user.
#
# MCP registration is deliberately NOT run here:
#   - CONTEXT7_API_KEY and DOCKER_MCP_SERVER are runtime values and are
#     unavailable at build time.
#   - The entrypoint.sh below performs the registration at container start,
#     gated on CONTEXT7_API_KEY / DOCKER_MCP_SERVER presence per the spec's
#     contract.
###############################################################################
RUN /opt/devcontainer/claude/configure-claude.sh

###############################################################################
# Install the `p` alias (user-justfile shortcut) into the vscode user's
# `~/.bashrc`.
#
# Goal: let the user type `p <recipe> [args...]` from ANY working directory
# and have it run the recipe from the canonical user-justfile installed above
# at `/home/vscode/justfile`. Example invocations:
#
#     p claude "Explain this codebase"
#     p claude-add-task "Add validation to /decide endpoint"
#     p help
#
# The alias expands to `just --global-justfile`, which is the canonical
# documented invocation per https://just.systems/man/en/global-and-user-justfiles.html
# ("can be accessed using the `-g` or `--global-justfile` flags"). `just`
# locates the file at `$HOME/justfile`, which is one of the four documented
# global/user-justfile search paths. The long form is used for
# self-documentation.
#
###############################################################################
ENV PATH=/home/vscode:${PATH}

RUN grep -q '# >>> sandbox p-alias >>>' /home/vscode/.bashrc 2>/dev/null \
    || cat >> /home/vscode/.bashrc <<'BASHRC_EOF'

# >>> sandbox p-alias >>>
# `p <recipe> [args...]` runs a recipe from the user-justfile installed at
# $HOME/justfile (one of the four documented global/user-justfile search
# paths per https://just.systems/man/en/global-and-user-justfiles.html).
# (PATH is augmented at the image level via `ENV` in the Dockerfile so that
# bare-basename `source claude-helpers.sh` resolves in non-interactive shells
# too — see the comment block above this RUN.)
alias p='just --global-justfile'
# <<< sandbox p-alias <<<
BASHRC_EOF

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
