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
#   2. MCP-server autodetection. Delegated to the standalone script
#      `claude/install-mcp.sh` (resolved relative to this file via
#      $BASH_SOURCE so it works both in-repo and inside the image at
#      /opt/devcontainer/claude/install-mcp.sh). The contract is unchanged
#      from the previous inline implementation — env-var-gated registration
#      mirrors `.devcontainer/install-mcps.sh` (preserved unchanged for the
#      local devcontainer flow):
#        - CONTEXT7_API_KEY set: register the Context7 MCP server via
#          `claude mcp add`.
#        - DOCKER_MCP_SERVER set: activate the baked docker-mcp CLI plugin
#          by running, in order, `docker mcp feature enable profiles`,
#          `docker mcp catalog pull mcp/docker-mcp-catalog`, and
#          `docker mcp profile create --name dev-tools --server
#          "$DOCKER_MCP_SERVER" --connect claude-code`. Each command is
#          best-effort: failures are logged and do not abort startup.
#        - Neither set: log a single skip line and move on.
#      A non-zero exit from install-mcp.sh is logged and ignored — MCP
#      registration failures must NOT prevent the container from starting.
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
# Delegated to claude/install-mcp.sh — see the script for the full contract.
# Resolved relative to this file via BASH_SOURCE so the same invocation works
# both for local repo runs and inside the image (where this file lives at
# /opt/devcontainer/entrypoint.sh and the script at
# /opt/devcontainer/claude/install-mcp.sh). The script's exit status is
# logged but not propagated — MCP registration is best-effort and must not
# block the hand-off in section (3).
# -----------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if "$script_dir/claude/install-mcp.sh"; then
  :
else
  log "claude/install-mcp.sh exited non-zero; continuing."
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
