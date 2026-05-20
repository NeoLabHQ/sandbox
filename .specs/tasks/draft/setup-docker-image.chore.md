---
title: Setup Docker image
---

## Initial User Prompt

setup docker image

### Context

This is a new project, that based on devcontainer image that we use internally. Need setup proper docker images and workflows to build and push them to our public registry.

### Requirements

Create images that fulfill the following requirements:

[] Research and find hardened version of base image of microsoft devcontainer and use it as base
[] Create new Dockerfile.base in root that make base sandbox image based on the base image from previus requirement plus common tools and utils from .devcontainer/Dockerfile first stage apt-get installs + base package managers, like homebrew
[] Research how to possible install following languages in docker image using some version managers, like nvm. Languages:
    - Node.js
    - Python
    - Go
    - Java
[] Add this tools installation with enabled by default latest version of languages to Dockerfile
[] Create Dockerfile.agents that should build from base image and install common agents like claude code, opencode, gemini cli, etc.
[] Add Dockerfile that should build from Dockerfile.agents and add codemap, context7, common languages mcp servers, etc. Include there configure-claude.sh, statusline.sh, install-mcps.sh from devcontainer directory (move them to root)
[] create github workflow that will publish all images to our public registry NeoLabHQ/sandbox:base, NeoLabHQ/sandbox:agents, NeoLabHQ/sandbox:latest
[] Add proper usage description to README.md, that should explain how to use image to setup sandbox using only docker, add examples with devcontainer. Include how to map volumes for project properly. Also include example how to map ~/.claude/ and ~.claude.json so it will work properly with claude code. Also include how to pass CLAUDE_CODE_OAUTH_TOKEN enviroment variable, so it will login out of the box.


## Plan

### Research Findings

#### Base Image

Microsoft publishes general-purpose dev container base images under `mcr.microsoft.com/devcontainers/*`. Two primary candidates exist:

- **`mcr.microsoft.com/devcontainers/base`** — minimal, security-focused image with options for Debian, Ubuntu, and Alpine. Maintained at https://github.com/devcontainers/images with proactive security management, automated patching of critical components, and a `cgmanifest.json` audit trail for 200+ components. Lightweight foundation that lets us add only what we need.
- **`mcr.microsoft.com/devcontainers/universal`** — large, pre-baked image with multiple language runtimes (Python, Node, PHP, Java, Go, C++, Ruby, .NET). Default for GitHub Codespaces but heavy and ships with versions we don't necessarily want.

**Decision:** Use `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` (the hardened Ubuntu 24.04 LTS noble variant). Reasoning: smallest hardened surface from Microsoft, latest LTS, frequent security patching, and an ideal blank canvas for installing language runtimes via version managers (vs. Universal which would conflict with our version-manager approach).

Reference tags considered: `base:ubuntu-24.04`, `base:debian-12` (bookworm), `base:alpine-3.20`. Ubuntu 24.04 picked for the broadest tooling/glibc compatibility required by Homebrew on Linux and binary downloads from upstream toolchains.

**Pin to immutable SHA digest, not the mutable tag.** The tag `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` is mutable — Microsoft rebuilds and re-publishes it weekly to apply security patches, which means an unpinned `FROM` line yields non-reproducible builds and silently changes the build output across CI runs. The `Dockerfile.base` `FROM` line MUST resolve and pin to the corresponding `sha256:...` digest, e.g.:

```dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:<digest>
```

How to obtain and refresh the digest:
1. Resolve the current digest: `docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:ubuntu-24.04 --format '{{json .Manifest.Digest}}'` (or `docker pull` + `docker inspect --format='{{index .RepoDigests 0}}'`).
2. Commit the updated digest into `Dockerfile.base` alongside a comment noting the date and the upstream tag (`# ubuntu-24.04 as of YYYY-MM-DD`).
3. Refresh process: schedule a monthly review (either a calendar reminder, a Dependabot `docker` ecosystem config in `.github/dependabot.yml`, or a Renovate `pinDigests` rule) to bump the digest. The CI vulnerability scan (see Step 5) will also flag stale base images by surfacing newly disclosed CVEs.

#### Language Version Managers

Researched across `nvm`, `pyenv`, `goenv`, `gvm`, `sdkman`, `asdf`, and `mise`. Key findings:

- **`mise`** (https://mise.jdx.dev): Rust-based, fast, single-tool unified manager that replaces `asdf` + `direnv` + (partially) `make`. Native Docker support, no shell sourcing gymnastics required (binary on PATH), idempotent installs, ships its own activation hook, well-suited for multi-user containers. Supports Node, Python, Go, Java (Temurin/Zulu/Corretto), Ruby, etc. through a unified plugin ecosystem.
- **`asdf`**: Older shim-based tool. Works but slower; shim model adds friction; requires shell sourcing in every `RUN`.
- **`nvm`/`pyenv`/`goenv`/`sdkman`**: Per-language, each with their own quirks (bash-only, `source` per RUN layer, separate update cadence, slower in scripts). Multiple tools = multiple failure points.

**Decision:** Use **`mise`** as the single version manager for Node.js, Python, Go, and Java. Rationale: one binary, no shell sourcing, fastest install times, deterministic, easy to pin "latest" versions via `mise use -g node@latest python@latest go@latest java@latest`. Falls back gracefully because installed runtimes are placed on PATH via `mise activate`.

Backup approach if `mise` is unacceptable: combine `nvm` (Node), `pyenv` (Python), official `golang` tarball (Go), `sdkman` (Java) — but this requires four sets of sourcing/activation, which complicates the Dockerfile.

#### AI Coding Agents

- **Claude Code** — Recommended installer: `curl -fsSL https://claude.ai/install.sh | bash`. The legacy `npm install -g @anthropic-ai/claude-code` is now deprecated. Installs to `~/.local/bin/claude`.
- **OpenCode** — Recommended installer: `curl -fsSL https://opencode.ai/install | bash`. Alternative: `npm install -g opencode-ai`. Installs as `opencode` binary.
- **Gemini CLI** — `npm install -g @google/gemini-cli`. Requires Node.js 20+. Installs as `gemini` binary.
- **Codex (OpenAI)** — `npm install -g @openai/codex`. Installs as `codex` binary. Included as a fourth required agent for broader coverage parity.

All four agents install cleanly into the `node` user's home directory; no root-level changes required beyond ensuring `PATH` includes `~/.local/bin` and the npm global prefix.

#### MCP Servers

- **Context7** — already installed via `claude mcp add --scope user --transport http context7 https://mcp.context7.com/mcp` (existing pattern in `install-mcps.sh`).
- **Codemap** — Go binary; already built in current Dockerfile from `JordanCoin/codemap`.
- **Common language servers** — `typescript-language-server` (npm), `pyright` (npm/pip), `gopls` (`go install golang.org/x/tools/gopls@latest`), `jdtls` (Java LSP) can be installed at the agents/final layer.
- Existing `install-mcps.sh` runs at `postCreateCommand` time (needs runtime env vars) — keep this pattern.

#### GitHub Container Registry Workflow

GHCR publishes under `ghcr.io/<owner>/<image>`. Standard pattern:
- `actions/checkout@v4`
- `docker/setup-qemu-action@v3` + `docker/setup-buildx-action@v3` for multi-arch builds (`linux/amd64,linux/arm64`)
- `docker/login-action@v3` with `${{ secrets.GITHUB_TOKEN }}` and `packages: write` permission
- `docker/metadata-action@v5` to generate semver/SHA tags
- `docker/build-push-action@v6` with `cache-from: type=gha`, `cache-to: type=gha,mode=max`, and explicit `tags` list

We need to build three images sequentially because each depends on the prior: `base` → `agents` → `latest` (final). Each push targets `ghcr.io/NeoLabHQ/sandbox` with a distinct tag.

#### Claude Code Volume Mounting

Claude Code persists across container restarts via:
- `~/.claude/` directory — contains `.credentials.json`, settings, statusline, plugins, and session state.
- `~/.claude.json` — onboarding state (`hasCompletedOnboarding`), MCP registrations, project history. **Required to avoid re-onboarding on every container start.**
- `CLAUDE_CODE_OAUTH_TOKEN` env var — if set, Claude Code skips the OAuth login flow. Token obtained via `claude setup-token` on a host machine.

Recommended pattern for `docker run`:
```bash
-v "$HOME/.claude:/home/node/.claude" \
-v "$HOME/.claude.json:/home/node/.claude.json" \
-e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
```

---

### Implementation Steps

#### Step 1: Create `Dockerfile.base`

Create `/workspaces/sandbox/Dockerfile.base` (root, not `.devcontainer/`).

- `FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04`
- Run `apt-get update && apt-get install -y` for all utility packages currently in stage 1 of `.devcontainer/Dockerfile`: `apt-utils bash-completion openssh-client gnupg2 dirmngr iproute2 procps lsof htop net-tools psmisc curl tree wget rsync ca-certificates unzip bzip2 xz-utils zip nano vim-tiny less jq lsb-release apt-transport-https dialog libc6 libgcc1 libkrb5-3 libgssapi-krb5-2 'libicu[0-9][0-9]' 'liblttng-ust[0-9]' libstdc++6 zlib1g locales sudo ncdu man-db strace manpages manpages-dev init-system-helpers build-essential file retry git`. Note: drop `python3 python3-pip` — Python is installed via `mise` in step 3.
- Run `apt-get -y upgrade --no-install-recommends && apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/*` to shrink image.
- Install **GitHub CLI** (`gh`) using existing keyring + apt repository commands.
- Install **Homebrew** (Linuxbrew) as the `ubuntu` (or `vscode`) user — Microsoft's hardened base ships with a non-root user. Run with `NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`. Append `/home/linuxbrew/.linuxbrew/bin` and `sbin` to PATH.
- Install **`mise`** globally: `curl https://mise.run | sh` (installs to `/usr/local/bin/mise` when run as root with `MISE_INSTALL_PATH=/usr/local/bin/mise`). Add `eval "$(/usr/local/bin/mise activate bash)"` to `/etc/bash.bashrc` so all shells (login + non-login) pick up runtimes.
- Install latest Node.js, Python, Go, and Java via `mise`:
  ```
  mise use -g node@latest python@latest go@latest java@latest
  mise reshim
  ```
  Pin Java vendor to a free distribution (e.g., `java@temurin-21`) if `latest` resolves to a non-free variant.
- Install `dvc` and `yq` via `pip` (now coming from `mise`'s Python).
- Verify the final non-root user matches `.devcontainer/Dockerfile` conventions (likely `ubuntu` in base image; keep `node` only if the prior `javascript-node` user expectations matter — we will normalize to whatever user the base image ships and update `configure-claude.sh` paths accordingly, or `useradd node` if downstream tooling expects the literal `node` user). **Decision: keep a `node` user (UID 1000) by either remapping the existing default user or creating it explicitly**, so all existing scripts (`/home/node/...`) keep working.

Output image tag: `ghcr.io/NeoLabHQ/sandbox:base`.

#### Step 2: Create `Dockerfile.agents`

Create `/workspaces/sandbox/Dockerfile.agents`.

- `ARG BASE_IMAGE=ghcr.io/NeoLabHQ/sandbox:base`
- `FROM ${BASE_IMAGE}`
- Switch to the non-root user (`USER node`).
- Install **Claude Code**: `curl -fsSL https://claude.ai/install.sh | bash`. Ensure `PATH` includes `/home/node/.local/bin`.
- Install **OpenCode**: `curl -fsSL https://opencode.ai/install | bash` (installs to `~/.opencode/bin` or similar; add to PATH).
- Install **Gemini CLI**: `npm install -g @google/gemini-cli` (npm global prefix set to user dir so no `sudo` needed).
- Install **Codex CLI**: `npm install -g @openai/codex` (fourth required agent for parity).
- Install **TypeScript LSP and helpful global tools**: `npm install -g typescript-language-server typescript rust-just bun` (preserve current behavior).
- **Architectural note**: Although requirement 6 lists codemap and language MCP servers / LSPs as belonging to the final `Dockerfile` layer, they are installed here in `Dockerfile.agents` because they are **code-intelligence dependencies of the AI agents themselves** (codemap feeds agent context; gopls/pyright/jdtls are LSP backends the agents call via MCP). Installing them in the agents layer (1) keeps the agents image self-sufficient for any consumer (not just the final image), (2) avoids re-installing heavy Go/npm toolchains in the final layer, and (3) cleanly separates "AI tooling" (agents image) from "user-facing configuration" (final image). The final `Dockerfile` (Step 3) then verifies their presence and only adds the configuration scripts on top.
- Install **codemap**: `git clone --depth 1 https://github.com/JordanCoin/codemap.git /tmp/codemap && cd /tmp/codemap && go build -o /usr/local/bin/codemap . && rm -rf /tmp/codemap` (re-use Go from `mise` shim path; may need `sudo` or perform as root then switch back).
- Install **gopls** (Go LSP): `go install golang.org/x/tools/gopls@latest`.
- Install **pyright** (Python LSP): `npm install -g pyright`.
- Install **jdtls / eclipse.jdt.ls** (Java LSP): download the latest milestone tarball from `https://download.eclipse.org/jdtls/milestones/` and extract to `/opt/jdtls` (or install via `mise use -g jdtls@latest` if the plugin is available). Symlink the launcher onto `PATH` as `jdtls`.
- Install **`docker-mcp` CLI plugin** (migrated from `.devcontainer/devcontainer.json` `bash-command` feature): clone `https://github.com/docker/mcp-gateway.git`, `make docker-mcp`, and install the resulting binary into `/home/node/.docker/cli-plugins/docker-mcp`. Use `HOME=/home/node` during build and `chown -R node:node /home/node/` to ensure correct ownership. This requires the Docker CLI at runtime, which the devcontainer's `docker-outside-of-docker` feature (preserved — see Step 4) supplies.

Output image tag: `ghcr.io/NeoLabHQ/sandbox:agents`.

#### Step 3: Create final `Dockerfile`

Create `/workspaces/sandbox/Dockerfile` (root, replacing or superseding the `.devcontainer/Dockerfile` for image-build purposes).

- `ARG AGENTS_IMAGE=ghcr.io/NeoLabHQ/sandbox:agents`
- `FROM ${AGENTS_IMAGE}`
- `USER root`
- `COPY configure-claude.sh statusline.sh install-mcps.sh /opt/devcontainer/`
- `RUN chmod +x /opt/devcontainer/*.sh`
- `ENV DOCKER_MCP_IN_CONTAINER=1`
- `USER node`
- **Verify codemap and language MCP servers are present** (inherited from the agents image per the architectural note in Step 2): add a `RUN` step `command -v codemap && command -v gopls && command -v pyright && command -v jdtls` so the final image fails fast if the agents image ever drops one of these. This explicitly satisfies requirement 6's "add codemap, context7, common languages mcp servers" — codemap, gopls, pyright, jdtls are inherited from `:agents`, and Context7 is registered at runtime via `install-mcps.sh`.
- **Pre-register Context7 MCP at build time (where possible)**: any MCP that does not require runtime secrets can be registered here. For Context7 specifically, the API key is runtime-only, so its `claude mcp add` invocation stays in `install-mcps.sh`. The final `Dockerfile` is the canonical place where the MCP wiring is assembled, even though some calls fire at `postCreateCommand`.
- `RUN /opt/devcontainer/configure-claude.sh` to bootstrap `~/.claude/settings.json`, statusline, and Claude plugins (matches existing stage 4 behavior).
- Do **not** run `install-mcps.sh` at build time — keep it as `postCreateCommand` because it needs runtime env vars (e.g., `CONTEXT7_API_KEY`).
- Set sensible defaults like `WORKDIR /workspaces` and `CMD ["sleep","infinity"]` so the image is usable both as a devcontainer and a standalone `docker run` target.

Output image tag: `ghcr.io/NeoLabHQ/sandbox:latest`.

#### Step 4: Move scripts from `.devcontainer/` to repo root and migrate `devcontainer.json`

- Move `configure-claude.sh`, `statusline.sh`, `install-mcps.sh` from `/workspaces/sandbox/.devcontainer/` to `/workspaces/sandbox/`.
- **Replace `.devcontainer/Dockerfile`** with a thin wrapper: a single-line `FROM ghcr.io/neolabhq/sandbox:latest` (optionally pinned to `@sha256:<digest>` for reproducibility). The devcontainer must consume the published image rather than re-build locally — this eliminates duplicated build logic, guarantees parity between devcontainer and standalone `docker run` consumers, and matches the migration table below (which already switches `devcontainer.json` to `image:` rather than `build:`). Keeping the file (vs. deleting it) is intentional: a `FROM`-only Dockerfile lets devcontainer features still layer on top via a build context if ever needed in the future.
- Update `.devcontainer/devcontainer.json` `postCreateCommand` path if anything changes (it currently references `/opt/devcontainer/install-mcps.sh` — that path is preserved by the final `Dockerfile`'s `COPY`).

**Decision per existing `.devcontainer/devcontainer.json` entry** — each declared property is enumerated below with an explicit migration choice:

| `devcontainer.json` entry | Current value | Decision | Rationale |
|---------------------------|---------------|----------|-----------|
| `name` | `"Node 22 (bookworm) + Claude Code"` | **Update in devcontainer.json** to `"NeoLabHQ Sandbox (Ubuntu 24.04)"` | Stale: image is moving to Ubuntu 24.04 + multi-language; name should reflect that. |
| `build.dockerfile` | `"Dockerfile"` | **Replace with `"image": "ghcr.io/neolabhq/sandbox:latest"`** | Devcontainer now consumes the published image instead of a local build. Eliminates duplicated build logic. |
| `features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"]` | `{}` | **Preserve in devcontainer.json (do NOT bake into image)** | This feature mounts the host Docker socket and installs the Docker CLI; it depends on host-level configuration (socket path, group GID mapping) that only the devcontainer CLI / VS Code can wire up. Baking it into the image would not provide the socket mount, so it MUST remain a `features` entry. Verified that devcontainer features still apply when `image:` is used in place of `build:`. |
| `features["ghcr.io/devcontainers-extra/features/bash-command:1"]` (docker-mcp install) | bash command that clones `docker/mcp-gateway`, builds it, and installs `docker-mcp` CLI plugin to `/home/node/.docker/cli-plugins/` | **Bake into `Dockerfile.agents` and DEPRECATE the feature entry** | The install is a deterministic, reproducible build step with no runtime/host dependency. Moving it into `Dockerfile.agents` (1) shaves ~30-60s off every devcontainer start, (2) makes `docker-mcp` available in plain `docker run` usage (not just devcontainer), and (3) eliminates the brittle `bash-command` feature wrapper. The `docker-mcp` plugin only requires the Docker CLI at runtime, which the `docker-outside-of-docker` feature still supplies. After migration, remove this `features` entry entirely. |
| `customizations.vscode.settings` (`terminal.integrated.defaultProfile.linux`) | `"zsh"` | **Preserve in devcontainer.json** | VS Code-specific UX setting; not relevant to non-VS Code consumers of the image. |
| `customizations.vscode.extensions` | list of 6 extensions | **Preserve in devcontainer.json** | VS Code-specific; cannot be expressed in a plain Docker image. |
| `forwardPorts` / `portsAttributes` | `[3000, 8080]` etc. | **Preserve in devcontainer.json** | Devcontainer-spec-only feature; no image equivalent. |
| `containerEnv` (`NODE_ENV`, `COLORTERM`) | dev defaults | **Preserve in devcontainer.json** | These are dev-environment defaults that should NOT bleed into a generic published image (e.g., `NODE_ENV=development` would be wrong for CI use of the image). Image will set neutral defaults only. |
| `remoteEnv` (`ANTHROPIC_API_KEY`, `CONTEXT7_API_KEY`) | passthrough from host | **Preserve in devcontainer.json** | Devcontainer-spec passthrough mechanism; the README will document the equivalent `-e` flags for plain `docker run`. |
| `postCreateCommand.install-mcps` | `/opt/devcontainer/install-mcps.sh` | **Preserve in devcontainer.json**; script lives at `/opt/devcontainer/install-mcps.sh` inside the image (COPYed by final `Dockerfile`). | Needs runtime secrets (`CONTEXT7_API_KEY`); cannot be baked. Path is stable across the image rebuild. |
| `remoteUser` | `"node"` | **Preserve in devcontainer.json**; image also defaults `USER node`. | Consistent UID 1000 across both consumption modes. |

Net effect on `.devcontainer/devcontainer.json` after this step:
- Switch `build.dockerfile` → `image: ghcr.io/neolabhq/sandbox:latest`.
- Keep `docker-outside-of-docker` feature.
- Remove the `devcontainers-extra/features/bash-command` (docker-mcp) feature; functionality is now in the agents image.
- Everything else (customizations, ports, env, postCreate, remoteUser) preserved verbatim.

#### Step 5: Create `.github/workflows/docker-publish.yml`

Workflow triggers: `push` to `master`, manual `workflow_dispatch`, and tag pushes (`v*`).

Permissions: `contents: read`, `packages: write`.

Jobs (sequential, each depending on the previous so the next layer can pull the just-pushed image):

1. `build-base` — builds `Dockerfile.base`, pushes `ghcr.io/neolabhq/sandbox:base` (and optionally `base-<sha>`, `base-<date>`).
2. `build-agents` — `needs: build-base`. Builds `Dockerfile.agents` with `build-args: BASE_IMAGE=ghcr.io/neolabhq/sandbox:base`. Pushes `:agents`.
3. `build-final` — `needs: build-agents`. Builds `Dockerfile` with `build-args: AGENTS_IMAGE=ghcr.io/neolabhq/sandbox:agents`. Pushes `:latest`.

Each job uses:
- `actions/checkout@v4`
- `docker/setup-qemu-action@v3`
- `docker/setup-buildx-action@v3`
- `docker/login-action@v3` with `registry: ghcr.io`, `username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}`
- `docker/metadata-action@v5` to produce semver + branch + SHA tags
- `docker/build-push-action@v6` — first invocation: **build only** (`push: false`, `load: true` for single-arch local scan OR `outputs: type=oci,dest=/tmp/image.tar`) so the image can be scanned before publishing.
- **Vulnerability scan gate** (run BEFORE the push):
  - `aquasecurity/trivy-action@0.24.0` (or pinned current SHA) with `format: sarif`, `severity: CRITICAL,HIGH`, `exit-code: 1`, `ignore-unfixed: true`. Fails the job if a fixable CRITICAL/HIGH CVE is found in the image filesystem or OS packages.
  - Alternative / complement: `anchore/scan-action@v4` (grype) producing SARIF output.
  - Upload the SARIF report via `github/codeql-action/upload-sarif@v3` so findings appear in the repo Security tab.
  - **SBOM**: generate with `anchore/sbom-action@v0` (Syft) in SPDX format and attach as a workflow artifact; on tag pushes also publish the SBOM as an OCI referrer with `cosign attach sbom` or `docker buildx build --sbom=true`.
- Final `docker/build-push-action@v6` invocation with `push: true`, `platforms: linux/amd64,linux/arm64`, `cache-from: type=gha,scope=<layer>`, `cache-to: type=gha,mode=max,scope=<layer>` runs only after the scan step succeeds.

Note: org name in GHCR must be lowercase (`neolabhq/sandbox`).

Optional but recommended: a separate scheduled workflow (`schedule: cron`) that re-scans the latest published `:base`, `:agents`, `:latest` tags weekly to surface newly disclosed CVEs without requiring a code change — this signal feeds the base-image-digest refresh process described in Research Findings.

##### Rollback plan

Every workflow run pushes both a moving tag (`:base`, `:agents`, `:latest`) and an immutable SHA-suffixed tag (`:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`) — those immutable tags exist specifically to enable instant rollback. If a bad image is published:

- **Re-tag the previous SHA-pinned image to the moving tag** to restore service immediately: `docker buildx imagetools create -t ghcr.io/neolabhq/sandbox:latest ghcr.io/neolabhq/sandbox:latest-<previous-good-sha>` (and analogously for `:base` / `:agents`). This is atomic at the registry level and requires no rebuild.
- **Revert the digest pin in dependent images**: if `Dockerfile.agents` pins `:base@sha256:<bad>` (or `Dockerfile` pins `:agents@sha256:<bad>`), open a revert commit that restores the previous digest, then re-run the workflow. Likewise update `.devcontainer/Dockerfile`'s `FROM ghcr.io/neolabhq/sandbox:latest@sha256:<digest>` to the previous good digest.
- **Invalidate poisoned build cache**: clear the affected GitHub Actions cache scopes via the GitHub Actions cache UI or `gh actions-cache delete <key>` so the bad layers are not silently reused on the next build. Re-run with `cache-from` disabled for one cycle if in doubt.
- **Notify consumers**: post a brief notice in the README's "Image variants & tags" section (or a GitHub release note on the previous-good tag) instructing users to pull by the explicit `:latest-<good-sha>` tag until the next clean publish.

#### Step 6: Update `README.md`

Replace the current two-line README with comprehensive documentation. Sections:

1. **Overview** — what the image is, what's preinstalled.
2. **Image variants & tags** — `:base`, `:agents`, `:latest` with what each contains.
3. **Quick start with Docker** — `docker pull` + `docker run` examples.
4. **Volume mapping for projects** — mount workspace, mount `~/.claude` and `~/.claude.json` (with an explanation of why both are needed), mount SSH/git configs if needed.
5. **Passing `CLAUDE_CODE_OAUTH_TOKEN`** — how to obtain one (`claude setup-token` on host), how to pass with `-e` flag; mention `ANTHROPIC_API_KEY` and `CONTEXT7_API_KEY` as alternatives.
6. **Using as a devcontainer** — example `devcontainer.json` snippet using `"image": "ghcr.io/neolabhq/sandbox:latest"`.
7. **Tools included** — list languages, agents, MCP servers, LSPs.
8. **Building locally** — `docker build -f Dockerfile.base -t sandbox:base .` chain.

Example `docker run` to include in README:
```bash
docker run -it --rm \
  -v "$PWD:/workspaces/$(basename $PWD)" \
  -v "$HOME/.claude:/home/node/.claude" \
  -v "$HOME/.claude.json:/home/node/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces/$(basename $PWD)" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

#### Step 7: Verify and iterate

- Build all three images locally with `docker buildx build` to confirm the chain works.
- Run final image and verify: `claude --version`, `opencode --version`, `gemini --version`, `node --version`, `python --version`, `go version`, `java --version`, `mise --version`, `codemap --help`.
- Confirm `~/.claude/settings.json` is populated and statusline runs.
- Run `install-mcps.sh` manually to confirm Context7 MCP registration works.
- Test devcontainer path: rebuild `.devcontainer` and confirm VS Code attach still works.

---

### Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base image | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` | Hardened, minimal, actively patched by Microsoft; Ubuntu LTS gives best compatibility for Homebrew + binary toolchains. |
| Version manager | `mise` | Single Rust binary covers Node + Python + Go + Java; no per-RUN shell sourcing; faster than asdf; modern and actively maintained. |
| Java distribution | Temurin (Adoptium) via `mise` | Free, OpenJDK-based, broad adoption; avoids Oracle licensing concerns. |
| Image layering | 3 separate Dockerfiles (`base` → `agents` → final) | Matches user requirement; enables independent rebuilds; smaller agent-only delta; cacheable. |
| Registry | `ghcr.io/neolabhq/sandbox` | Required by task; lowercase org per GHCR rules. |
| Multi-arch | `linux/amd64` + `linux/arm64` | Apple Silicon parity; matches `dpkg --print-architecture` logic already in existing Dockerfile. |
| Scripts location | Move to repo root | Required by task; allows `Dockerfile` (final) to `COPY` from `.` without `..` paths and keeps `.devcontainer/` clean. |
| Non-root user | `node` (UID 1000) | Preserved for backward compatibility with all existing `/home/node/...` paths in `configure-claude.sh`, `statusline.sh`, and `.devcontainer/devcontainer.json`. |
| MCP install timing | `postCreateCommand` (runtime), not build time | Needs `CONTEXT7_API_KEY` and other secrets only available at container start. |

---

### File Structure

Files to **create**:
- `/workspaces/sandbox/Dockerfile.base`
- `/workspaces/sandbox/Dockerfile.agents`
- `/workspaces/sandbox/Dockerfile`
- `/workspaces/sandbox/.github/workflows/docker-publish.yml`

Files to **move** (from `.devcontainer/` to repo root):
- `configure-claude.sh`
- `statusline.sh`
- `install-mcps.sh`

Files to **update**:
- `/workspaces/sandbox/README.md` — full usage documentation
- `/workspaces/sandbox/.devcontainer/Dockerfile` — replace contents with thin `FROM ghcr.io/neolabhq/sandbox:latest` wrapper (committed choice; no alternative path)
- `/workspaces/sandbox/.devcontainer/devcontainer.json` — verify `postCreateCommand` still resolves to `/opt/devcontainer/install-mcps.sh`

Files to **leave untouched**:
- `/workspaces/sandbox/.claude/`
- `/workspaces/sandbox/claude-helpers.sh`
- `/workspaces/sandbox/justfile`
- `/workspaces/sandbox/LICENSE`
- `/workspaces/sandbox/.specs/`

