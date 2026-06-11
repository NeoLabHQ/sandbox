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
#   1. Once-per-container project setup. Delegated to the side-effects-only
#      `setup.sh` (resolved relative to this file via $BASH_SOURCE so it works
#      both in-repo and inside the image at /opt/devcontainer/setup.sh).
#      setup.sh performs the project-runtime install (`mise install` /
#      `devbox install`) and env-var-gated MCP registration; it is shared with
#      the devcontainer `postStartCommand` and the interactive-shell rc hooks
#      so those contexts get the same setup the ENTRYPOINT cannot reach. It is
#      best-effort and always exits 0 — a non-zero exit is logged and ignored,
#      since setup failures must NOT prevent the container from starting.
#
#   2. Activator selection. Walks from $PWD up to / looking, at each directory,
#      for `devbox.json` first, then `mise.toml`, then `.mise.toml`, then
#      `.tool-versions`. First match wins.
#        - devbox.json found: hand off to `devbox shell --` so the project's
#          pinned nixpkgs profile is prepended to PATH.
#        - mise project file found: hand off to `mise exec --` (setup.sh already
#          ran `mise install`).
#        - Nothing found: fall through to a plain `exec "$@"` — the image-
#          global mise pins from Dockerfile.base (node@lts, python@latest,
#          go@latest, java@temurin-lts) apply.
#      The find_up detection is kept here (a small, readable duplication of
#      setup.sh's identical walk) because the activator decision is unique to
#      the ENTRYPOINT's `exec` hand-off and has no place in the side-effects
#      script.
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
# (1) Once-per-container project setup.
#
# Delegated to setup.sh — see that script for the full contract. Resolved
# relative to this file via BASH_SOURCE so the same invocation works both for
# local repo runs and inside the image (where this file lives at
# /opt/devcontainer/entrypoint.sh and the script at
# /opt/devcontainer/setup.sh). setup.sh always exits 0, but we still guard the
# call so an unexpected failure (e.g. a missing script) is logged rather than
# aborting the hand-off in section (3).
# -----------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if "$script_dir/setup.sh"; then
  :
else
  log "setup.sh exited non-zero; continuing."
fi

# -----------------------------------------------------------------------------
# (2) Activator selection.
#
# find_up walks from $PWD up to / (exclusive) and returns the first path that
# contains a file named $1. Returns 1 with no output when no match is found.
# This mirrors setup.sh's identical walk; the small duplication is intentional
# (see the header) — the activator decision belongs only to this ENTRYPOINT's
# `exec` hand-off, not to the side-effects script.
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
  log "mise project file detected at ${mise_path}; activating 'mise exec --'."
  activator=(mise exec --)
else
  log "No mise/devbox project file detected — falling back to image-global runtime versions."
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
