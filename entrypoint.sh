#!/usr/bin/env bash
###############################################################################
# entrypoint.sh — runtime entrypoint for neolabhq/sandbox:latest.
#
# Wired into the final Dockerfile (Step 3 of
# /workspaces/sandbox/.specs/tasks/draft/switch-base-image.md) as:
#   ENTRYPOINT ["/opt/devcontainer/entrypoint.sh"]
#   CMD ["sleep","infinity"]
#
# Runs as the vscode user (inherited from the final image's USER). Idempotent
# by construction — safe to invoke multiple times in the same container.
#
# Responsibilities (in order):
#
#   1. Project-runtime autodetection. Walks from $PWD up to / looking, at each
#      directory, for `devbox.json` first, then `mise.toml`, then `.mise.toml`,
#      then `.tool-versions`. First match wins.
#        - devbox.json found: hand off to `devbox shell --` so the project's
#          pinned nixpkgs profile is prepended to PATH.
#        - mise.toml / .mise.toml / .tool-versions found: run `mise install`
#          (no-op when versions already match) and hand off to `mise exec --`.
#        - Nothing found: fall through to a plain `exec "$@"` — the image-
#          global mise pins from Dockerfile.base (node@lts, python@latest,
#          go@latest, java@temurin-lts) apply.
#
#   2. MCP-server autodetection. Env-var-gated registration mirrors
#      `.devcontainer/install-mcps.sh` (which is preserved unchanged for the
#      local devcontainer flow) but adds the conditional check the local
#      script's TODO comments call out:
#        - CONTEXT7_API_KEY set: register the Context7 MCP server via
#          `claude mcp add`.
#        - DOCKER_MCP_SERVER set: activate the baked docker-mcp CLI plugin
#          by running, in order, `docker mcp feature enable profiles`,
#          `docker mcp catalog pull mcp/docker-mcp-catalog`, and
#          `docker mcp profile create --name dev-tools --server
#          "$DOCKER_MCP_SERVER" --connect claude-code`. Each command is
#          best-effort: failures are logged and do not abort startup.
#        - Neither set: log a single skip line and move on.
#
#   3. Hand off to the CMD (or any explicit `docker run ... <cmd>` argv).
#      Never silently swallows CMD — every code path ends with `exec`.
#
# Logging contract: all diagnostic output goes to stderr prefixed with
# `[entrypoint]` so consumers piping the container's stdout (e.g. CI capturing
# program output) are not polluted by entrypoint chatter.
###############################################################################

set -euo pipefail

log() {
  printf '[entrypoint] %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# (1) Project-runtime autodetection.
#
# find_up walks from $PWD up to / (exclusive) and returns the first path that
# contains a file named $1. Returns 1 with no output when no match is found.
# -----------------------------------------------------------------------------
find_up() {
  local name="$1" dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -e "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

activator=()
if devbox_path="$(find_up devbox.json)"; then
  log "devbox.json detected at ${devbox_path}; activating devbox shell."
  activator=(devbox shell --)
elif mise_path="$(find_up mise.toml)" \
  || mise_path="$(find_up .mise.toml)" \
  || mise_path="$(find_up .tool-versions)"; then
  log "mise project file detected at ${mise_path}; running 'mise install' and activating 'mise exec --'."
  mise install >&2 || log "mise install reported a non-zero status; continuing."
  activator=(mise exec --)
else
  log "No mise/devbox project file detected — falling back to image-global runtime versions."
fi

# -----------------------------------------------------------------------------
# (2) MCP-server autodetection (env-var-gated).
#
# Registration commands are best-effort: a failure to register one MCP server
# must NOT prevent the container from starting (e.g. transient network error
# while contacting mcp.context7.com). Each branch logs success/failure and
# proceeds to the hand-off in section (3).
# -----------------------------------------------------------------------------
mcp_registered=0

if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  log "CONTEXT7_API_KEY is set; registering Context7 MCP server."
  if claude mcp add --scope user --transport http context7 \
      https://mcp.context7.com/mcp \
      --header "CONTEXT7_API_KEY: ${CONTEXT7_API_KEY}" >&2; then
    log "Context7 MCP server registered."
  else
    log "Context7 MCP server registration returned non-zero; continuing."
  fi
  mcp_registered=1
fi

if [ -n "${DOCKER_MCP_SERVER:-}" ]; then
  log "DOCKER_MCP_SERVER is set; activating docker-mcp CLI plugin."
  if docker mcp feature enable profiles >&2; then
    log "Docker MCP feature 'profiles' enabled."
  else
    log "Docker MCP 'feature enable profiles' returned non-zero; continuing."
  fi
  if docker mcp catalog pull mcp/docker-mcp-catalog >&2; then
    log "Docker MCP catalog 'mcp/docker-mcp-catalog' pulled."
  else
    log "Docker MCP 'catalog pull mcp/docker-mcp-catalog' returned non-zero; continuing."
  fi
  if docker mcp profile create --name dev-tools \
      --server "$DOCKER_MCP_SERVER" \
      --connect claude-code >&2; then
    log "Docker MCP profile 'dev-tools' created for server '${DOCKER_MCP_SERVER}'."
  else
    log "Docker MCP 'profile create' returned non-zero; continuing."
  fi
  mcp_registered=1
fi

if [ "$mcp_registered" -eq 0 ]; then
  log "No MCP env vars detected; skipping MCP registration."
fi

# -----------------------------------------------------------------------------
# (3) Hand off to CMD / explicit argv.
#
# When no argv was supplied (`docker run <image>` with no command) the image's
# CMD provides `sleep infinity` per the final Dockerfile, so "$@" is always
# non-empty in practice. Guard the activator branch with an arg-count check
# anyway so that `devbox shell --` / `mise exec --` never run with no command
# (which would drop into an interactive shell in an unexpected place).
# -----------------------------------------------------------------------------
if [ "$#" -eq 0 ]; then
  log "No CMD provided; nothing to exec."
  exit 0
fi

if [ "${#activator[@]}" -gt 0 ]; then
  exec "${activator[@]}" "$@"
fi
exec "$@"
