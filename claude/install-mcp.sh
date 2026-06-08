#!/usr/bin/env bash
###############################################################################
# install-mcp.sh — env-var-gated MCP-server autodetection.
#
# Extracted from entrypoint.sh's Stage 2 so it can be invoked standalone
# (e.g. from a postCreate hook or by a user re-running registration without
# restarting the container). entrypoint.sh delegates to this script during
# container start; behavior is unchanged from the original inline block.
#
# Gating:
#   - CONTEXT7_API_KEY set: register the Context7 MCP server via
#     `claude mcp add`.
#   - DOCKER_MCP_SERVER set: activate the baked docker-mcp CLI plugin
#     by running, in order, `docker mcp feature enable profiles`,
#     `docker mcp catalog pull mcp/docker-mcp-catalog`, and
#     `docker mcp profile create --name dev-tools --server
#     "$DOCKER_MCP_SERVER" --connect claude-code`. Each command is
#     best-effort: failures are logged and do not abort the script.
#   - Neither set: log a single skip line and exit 0.
#
# Logging contract: all diagnostic output goes to stderr prefixed with
# `[install-mcp]` so consumers piping stdout are not polluted.
###############################################################################

set -euo pipefail

log() {
  printf '[install-mcp] %s\n' "$*" >&2
}

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

exit 0
