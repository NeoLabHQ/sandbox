#!/usr/bin/env bash
###############################################################################
# setup.sh — once-per-container project setup for neolabhq/sandbox:latest.
#
# Side-effects-only counterpart to entrypoint.sh. Where entrypoint.sh selects
# an activator and `exec`s the CMD as PID 1, this script performs the
# environment-mutating work that must also run in the two contexts the
# ENTRYPOINT never reaches:
#
#   1. ENTRYPOINT          — entrypoint.sh calls this before its `exec`.
#   2. devcontainer flow   — baked as a `postStartCommand` via the image's
#                            `devcontainer.metadata` LABEL. The devcontainer
#                            CLI / VS Code set `overrideCommand: true` for
#                            image-based devcontainers, replacing ENTRYPOINT+CMD
#                            with a sleep loop, so the ENTRYPOINT never runs.
#   3. `docker exec` shells — interactive bash/zsh rc hooks (installed into
#                            /etc/bash.bashrc and /etc/zsh/zshrc) invoke this,
#                            since `docker exec` always bypasses the ENTRYPOINT.
#
# Because it runs from three unrelated contexts — none of which may be broken
# or noticeably slowed — this script:
#   - NEVER `exec`s and NEVER hands off a shell. It only performs side effects.
#   - ALWAYS exits 0. Internal failures are logged to stderr and swallowed.
#   - Is idempotent via sentinel files so repeat invocations are near-instant
#     no-ops (see "Idempotency" below).
#
# Responsibilities (in order):
#
#   1. Project-runtime install. Walks from $PWD up to / looking, at each
#      directory, for `devbox.json` first, then `mise.toml`, then `.mise.toml`,
#      then `.tool-versions`. First match wins.
#        - devbox.json found: `devbox install` in that project directory so the
#          project's pinned nixpkgs packages are materialized. No shell handoff
#          (that is entrypoint.sh's job).
#        - mise project file found: `mise install` (no-op when versions already
#          match).
#        - Nothing found: log and continue.
#      Keyed by a per-container + per-project sentinel so cd-ing between
#      projects re-runs the install for each new project dir, but a second
#      invocation in the same dir is a no-op.
#
#   2. MCP-server registration. Delegated to the standalone
#      `claude/install-mcp.sh`, resolved relative to this file via $BASH_SOURCE
#      so it works both in-repo and inside the image (where this file lives at
#      /opt/devcontainer/setup.sh and the script at
#      /opt/devcontainer/claude/install-mcp.sh). Best-effort: a non-zero exit
#      is logged and ignored. Keyed by a single container-wide sentinel
#      (PWD-independent) so it registers at most once per container.
#
# Idempotency: sentinels live under /tmp (cleared on container restart, giving
# once-per-container semantics). The runtime-install sentinel embeds a stable
# hash of $PWD so each project dir is keyed independently; the MCP sentinel is
# a single fixed path. Each sentinel is written only AFTER its step has run —
# success or best-effort failure both count, since the goal is once-per-
# container execution, not retry-until-success.
#
# Logging contract: all diagnostic output goes to stderr prefixed with
# `[sandbox-setup]` so consumers piping stdout (CI, tooling that parses shell
# output) are not polluted by setup chatter.
###############################################################################

# Intentionally NOT `set -e`: a failure in any step must never abort this
# script, because it runs from rc hooks and a postStartCommand that must not
# break. We guard each step explicitly and always exit 0.
set -uo pipefail

log() {
  printf '[sandbox-setup] %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# find_up walks from $PWD up to / (exclusive) and returns the first path that
# contains a file named $1. Returns 1 with no output when no match is found.
# Mirrors entrypoint.sh's find_up so detection is identical across both scripts.
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

# Stable, collision-resistant-enough key for the current project directory.
# cksum is in coreutils and always present; we only need a per-$PWD token, not
# a cryptographic digest.
pwd_key() {
  printf '%s' "$PWD" | cksum | cut -d' ' -f1
}

# -----------------------------------------------------------------------------
# (1) Project-runtime install (per-container, per-project-dir).
# -----------------------------------------------------------------------------
runtime_sentinel="/tmp/.sandbox-setup.$(pwd_key)"

install_project_runtime() {
  local devbox_path mise_path
  if devbox_path="$(find_up devbox.json)"; then
    local devbox_dir
    devbox_dir="$(dirname "${devbox_path}")"
    log "devbox.json detected at ${devbox_path}; running 'devbox install' in ${devbox_dir}."
    # `--config <dir>` points devbox at the directory holding devbox.json, so
    # the project's pinned packages install regardless of $PWD within the tree.
    if devbox install --config "${devbox_dir}" >&2; then
      log "devbox install completed."
    else
      log "devbox install reported a non-zero status; continuing."
    fi
  elif mise_path="$(find_up mise.toml)" \
    || mise_path="$(find_up .mise.toml)" \
    || mise_path="$(find_up .tool-versions)"; then
    log "mise project file detected at ${mise_path}; running 'mise install'."
    if mise install >&2; then
      log "mise install completed."
    else
      log "mise install reported a non-zero status; continuing."
    fi
  else
    log "No mise/devbox project file detected — relying on image-global runtime versions."
  fi
}

if [ -e "$runtime_sentinel" ]; then
  log "Runtime already set up for this project dir this container session; skipping."
else
  install_project_runtime
  : > "$runtime_sentinel" 2>/dev/null \
    || log "Could not write runtime sentinel ${runtime_sentinel}; runtime install may repeat."
fi

# -----------------------------------------------------------------------------
# (2) MCP-server registration (per-container, PWD-independent).
#
# Delegated to claude/install-mcp.sh, resolved relative to this file so the
# same invocation works in-repo and inside the image. The script's exit status
# is logged but never propagated — MCP registration is best-effort.
# -----------------------------------------------------------------------------
mcp_sentinel="/tmp/.sandbox-setup-mcp"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -e "$mcp_sentinel" ]; then
  log "MCP registration already attempted this container session; skipping."
else
  if "$script_dir/claude/install-mcp.sh"; then
    :
  else
    log "claude/install-mcp.sh exited non-zero; continuing."
  fi
  : > "$mcp_sentinel" 2>/dev/null \
    || log "Could not write MCP sentinel ${mcp_sentinel}; MCP registration may repeat."
fi

# Always succeed: see the header's "ALWAYS exits 0" contract.
exit 0
