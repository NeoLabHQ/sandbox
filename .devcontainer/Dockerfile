# Thin wrapper — consumes the published :latest image instead of re-building locally.
#
# This single-line FROM lets devcontainer features still layer on top via a
# build context if ever needed in the future, while guaranteeing that
# devcontainer and plain `docker run` consumers share the exact same published
# image rather than divergent local builds.
#
# The full image is built by the three-stage chain:
#   Dockerfile.base  → ghcr.io/neolabhq/sandbox:base
#   Dockerfile.agents → ghcr.io/neolabhq/sandbox:agents
#   Dockerfile       → ghcr.io/neolabhq/sandbox:latest  ← what this wraps
#
# To pin to a specific digest for reproducibility, replace the tag with:
#   FROM ghcr.io/neolabhq/sandbox:latest@sha256:<digest>
FROM ghcr.io/neolabhq/sandbox:latest
