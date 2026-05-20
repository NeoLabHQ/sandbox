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
- **`mcr.microsoft.com/devcontainers/universal`** — large, pre-baked image with multiple language runtimes (Python, Node, PHP, Java, Go, C++, Ruby, .NET, Conda) plus their version managers (nvm, rvm, rbenv, SDKMAN). Default for GitHub Codespaces. Heavier on disk: approximately ~5-6 GB unpacked / ~2-3 GB compressed for `universal:6-noble` vs. ~400 MB unpacked / ~80 MB compressed for `base:ubuntu-24.04` — roughly 10-15x larger pull/storage footprint, but eliminates ~1 GB of Node/Python/Go/Java installation layers that would otherwise need to be added on top of `base`. (Order-of-magnitude estimate from public image registry metadata and Microsoft devcontainer docs; verify in CI before relying on these numbers for capacity planning.)

**Decision:** Use **`mcr.microsoft.com/devcontainers/universal:6-noble`** as the base (rationale for the explicit `-noble` suffix is in the tag-variants table below). It already ships the four languages this task explicitly requires (Node, Python, Go, Java) at sensible defaults, plus matching version managers (`nvm` for Node, the `/usr/local/python/*` layout for Python, `SDKMAN` for Java, Go installed under `/usr/local/go`). Reusing Microsoft's continuously-patched multi-language layer is strictly better than reinventing it on top of `base:ubuntu-24.04` with a custom meta-manager: fewer moving parts, broader compatibility, weekly security rebuilds from Microsoft, and parity with GitHub Codespaces.

Tag variants considered for the `6.x` family (based on the upstream image's documented contents at the time of writing — confirm against `github.com/devcontainers/images/blob/main/src/universal/manifest.json` at build time):

| Tag | Root OS | Notes |
|-----|---------|-------|
| `6` | Ubuntu 24.04 (noble) | Floating major. Tracks the newest `6.x` patch on Noble. |
| `6-noble` | Ubuntu 24.04 (noble) | Explicit Noble variant; identical content to `6` at present, but the suffix future-proofs us if Microsoft adds a non-Noble `6-*` variant. |
| `6-linux` | Ubuntu 24.04 (noble) | **Legacy/compat alias** preserved from the `2.x`/`3.x` era when "linux" was the only suffix. Currently a synonym for `6-noble`. New consumers should not use it. |
| `6.0.4-noble` | Ubuntu 24.04 (noble) | Patch-pinned; mutable only within that exact patch's rebuild window. |

**Chosen tag: `mcr.microsoft.com/devcontainers/universal:6-noble`.** Picking the explicit `-noble` suffix (instead of bare `6`) keeps the OS root explicit in the Dockerfile and is forward-compatible if Microsoft branches the `6-*` family to other distros. Picking `6-noble` over `6.0.4-noble` keeps us on the floating-patch channel so security rebuilds (see below) flow in automatically.

**Pin strategy: floating major-version tag (`6-noble`), NOT an immutable `sha256:` digest.** Microsoft rebuilds and re-publishes the `6-*-noble` tags weekly to apply CVE fixes; pinning to a digest freezes us on a known-vulnerable image and shifts the responsibility of cherry-picking patches onto us. The trade-off vs. digest pinning is intentional:

| Property | Floating tag (`6-noble`) | Digest pin (`@sha256:...`) |
|----------|--------------------------|----------------------------|
| Security patches flow in automatically | Yes (weekly rebuild) | No (manual bump required) |
| Reproducible bit-for-bit builds | No (tag content changes) | Yes |
| Operational overhead | None | Monthly digest-bump PR + churn |
| Failure mode | Upstream breakage at build time | Stale CVEs in production |

We accept the loss of bit-for-bit reproducibility at the **base** layer because it is a known, named, audited upstream maintained by Microsoft. Reproducibility is recovered at the **layers we own** through the following mitigations:

1. **Per-build digest capture in the CI workflow.** The `build-base` job (Step 5) resolves and records the upstream digest (`docker buildx imagetools inspect mcr.microsoft.com/devcontainers/universal:6-noble --format '{{json .Manifest.Digest}}'`) into the build summary and as an OCI annotation on our published `:base` image, so any of our images can be traced back to an exact upstream snapshot for forensics/rollback even though the source `Dockerfile` does not pin.
2. **Our own published tags ARE digest-pinned downstream.** `Dockerfile.agents` pins `ghcr.io/neolabhq/sandbox:base@sha256:<digest>` and the final `Dockerfile` pins `ghcr.io/neolabhq/sandbox:agents@sha256:<digest>`. Reproducibility is therefore enforced at every layer we control; only the Microsoft-owned root floats.
3. **Scan-on-publish.** Trivy + Syft (Step 5) run on every build against the resolved image, so a regression introduced by an upstream rebuild is caught before the moving `:base` tag advances.
4. **Rollback via SHA-tagged variants.** Every workflow run also publishes `:base-<sha>`, `:agents-<sha>`, `:latest-<sha>` immutable tags — instant point-in-time rollback if a Microsoft rebuild regresses (see Rollback plan in Step 5).

```dockerfile
FROM mcr.microsoft.com/devcontainers/universal:6-noble
```

No `@sha256:` suffix on this `FROM` line, by design.

#### Language Version Managers

The base image (`devcontainers/universal:6-noble`) already ships managers and runtimes for every language this task requires. The table below is a sketch of what to expect — the exact versions float as Microsoft rebuilds the tag, so the verification command in Step 7 (`docker run --rm mcr.microsoft.com/devcontainers/universal:6-noble bash -c '...'`) is the authoritative source of truth at build time:

| Language | Preinstalled in `:6-noble` (sketch — confirm at build time) | Manager already present | Layout |
|----------|-------------------------------------------------------------|-------------------------|--------|
| Node.js | Active LTS line(s) via `nvm` (multiple LTS versions installed; run `nvm list` in the image for exact versions) | `nvm` | `/usr/local/share/nvm/versions/node/*` |
| Python | Recent stable Python 3 versions via Microsoft's pyenv-compatible layout (run `python3 --version` and `ls /usr/local/python` in the image) | Microsoft's `/usr/local/python` layout (pyenv-compatible) | `/usr/local/python/<version>` |
| Go | Recent stable Go (run `go version` in the image) | (vendored tarball install, no per-user manager) | `/usr/local/go` |
| Java | Current Temurin LTS line(s) via SDKMAN (run `sdk list java` in the image) | `SDKMAN!` | `/usr/local/sdkman/candidates/java/*` |
| Ruby | Recent stable Ruby line(s) via `rvm` (run `rvm list` in the image) | `rvm` / `rbenv` | `/usr/local/rvm/rubies/*` |

The base image's per-language managers (`nvm`, SDKMAN, the `/usr/local/python` layout, the Go tarball install) remain present and functional; `oryx`'s build-time detection still auto-installs additional minor versions on demand based on repo contents. On top of that we add **`mise`** as a unified meta version manager so the four required languages (Node, Python, Go, Java) can be pinned, listed, and upgraded through a single CLI and a single `mise.toml` source of truth — without removing or fighting the base image's managers (see coexistence note below).

Researched additional managers we could layer on top:

- **`mise`** (https://mise.jdx.dev): Rust-based single binary; unified Node/Python/Go/Java/Ruby support; idempotent; no shell sourcing required for non-interactive use (shims-on-PATH mode). **Chosen.**
- **`proto`** (https://moonrepo.dev/proto): Rust-based single binary; first-class for Node/Python/Go/Bun/Deno/Ruby; Java requires asdf-plugin fallback so coverage is weaker than `mise` for this project's required languages.
- **`vfox`** (https://vfox.lhan.me): Lua-plugin-based, cross-platform (incl. Windows). Plugin model similar to `asdf`. Slower install than Rust-based options.
- **`aqua`** (https://aquaproj.github.io): CLI-binary installer, NOT a language-runtime manager. Useful for tooling like `gh`, `jq`, `kubectl`. Different category — complementary, not a `mise` alternative.
- **`asdf`**, **`nvm`/`pyenv`/`goenv`/`sdkman`**: legacy shim/sourcing model; the universal image already uses these where it makes sense and they continue to ship the per-language runtimes; `mise` sits *above* them as the meta manager rather than replacing them.

**Decision: install `mise` as the meta version manager for Node, Python, Go, and Java.** Rationale: `mise` is a single Rust binary with no shell-sourcing requirement at runtime (PATH-prepended shims work in any non-interactive shell, which is exactly what Docker `RUN` layers, `docker exec`, and CI invocations are), it covers all four required languages first-class (unlike `proto`, where Java is plugin-fallback), and it makes the project's default language versions explicit and discoverable via `mise.toml`/`mise current` rather than scattered across `nvm alias default`, the `python` symlink, the Go tarball, and SDKMAN's `current` symlink.

**Coexistence with the base image's managers.** `mise` is installed **alongside** `nvm`, SDKMAN, `rvm`/`rbenv`, the `/usr/local/python` layout, and the `/usr/local/go` install — not in place of them. The image-shipped managers continue to own their existing runtime trees on disk; nothing is uninstalled. The only PATH change is that `mise`'s shims directory is prepended to `PATH` so that `node`, `python`, `go`, `java`, and `javac` resolve through `mise` first. If `mise` has no managed version for a language (or for a language `mise` is not configured to handle, e.g. Ruby/PHP/.NET), the shim falls through and the base image's manager-supplied binary wins via the remainder of `PATH`. `oryx`'s build-time repo-detection still runs against the base image's managers and is unaffected.

**Additions actually needed on top of universal:6-noble:**

- **`mise`** (https://mise.jdx.dev) — meta version manager for Node, Python, Go, Java (see decision above). Installed system-wide so every user (including `codespace`) shares the same managed runtimes and the same `mise.toml` defaults.
- **Homebrew (Linuxbrew)** — not shipped in `universal:6-noble`. Required by this project for cross-cutting CLI tooling that is awkward to install via apt or language-specific package managers. Install non-interactively as the `codespace` user.
- A small handful of repo-specific CLI/LSP tools (Step 2): codemap, gopls, pyright, jdtls, ripgrep-like helpers — none of which are language *runtimes*, so they don't compete with the image's manager layout.

Everything else from the original `.devcontainer/Dockerfile` first stage (apt utilities, `gh`, etc.) is **already in `universal:6-noble`**; we only top up what is genuinely missing (see Step 1).

#### AI Coding Agents

- **Claude Code** — Recommended installer: `curl -fsSL https://claude.ai/install.sh | bash`. The legacy `npm install -g @anthropic-ai/claude-code` is now deprecated. Installs to `~/.local/bin/claude`.
- **OpenCode** — Recommended installer: `curl -fsSL https://opencode.ai/install | bash`. Alternative: `npm install -g opencode-ai`. Installs as `opencode` binary.
- **Gemini CLI** — `npm install -g @google/gemini-cli`. Requires Node.js 20+. Installs as `gemini` binary.
- **Codex (OpenAI)** — `npm install -g @openai/codex`. Installs as `codex` binary. Included as a fourth required agent for broader coverage parity.

All four agents install cleanly into the `codespace` user's home directory; no root-level changes required beyond ensuring `PATH` includes `~/.local/bin` and the npm global prefix.

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

Recommended pattern for `docker run` (target paths under the new `codespace` home):
```bash
-v "$HOME/.claude:/home/codespace/.claude" \
-v "$HOME/.claude.json:/home/codespace/.claude.json" \
-e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
```

For ephemeral / single-shot use (CI, throwaway sandbox, remote agent jobs), omit both volume mounts and rely solely on `CLAUDE_CODE_OAUTH_TOKEN`: Claude Code skips the OAuth flow, runs without onboarding, and discards all state on container exit. This is the recommended pattern for CI / non-interactive contexts where binding to a host's Claude profile is undesirable.

---

### Implementation Steps

#### Step 1: Create `Dockerfile.base`

Create `/workspaces/sandbox/Dockerfile.base` (root, not `.devcontainer/`).

- `FROM mcr.microsoft.com/devcontainers/universal:6-noble` — no digest pin (see Base Image section for rationale).
- `USER root` for setup, then drop back to `codespace` at the end.
- Detect missing packages and top up only what `universal:6-noble` does not already ship. Universal already includes the vast majority of what the legacy `.devcontainer/Dockerfile` stage 1 installed (`curl`, `wget`, `git`, `gh`, `jq`, `unzip`, `zip`, `bzip2`, `xz-utils`, `nano`, `vim`, `less`, `build-essential`, `ca-certificates`, `locales`, `sudo`, `man-db`, `procps`, `lsof`, `htop`, `net-tools`, `psmisc`, `strace`, `tree`, `rsync`, `gnupg2`, `dirmngr`, `apt-transport-https`, `iproute2`, `file`, `bash-completion`, etc.). The remaining short top-up list (verify by running `dpkg -l | grep <pkg>` in the image first; remove anything already present): `retry ncdu` plus anything Trivy flags as missing on a first build. No language packages — `python3`, `node`, `go`, `default-jdk` are all already provided by the image's runtime layout, do NOT `apt install` them.
- Run `apt-get update && apt-get -y upgrade --no-install-recommends && apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/*` to absorb any pending security updates published between Microsoft's last rebuild and our build.
- Do NOT reinstall GitHub CLI — already present in `universal:6-noble` via the `github-cli` feature.
- Install **`mise`** (https://mise.jdx.dev) as the meta version manager for Node, Python, Go, and Java. The base image's per-language managers (`nvm`, SDKMAN, the `/usr/local/python` layout, `/usr/local/go`) are left in place — see "Coexistence with the base image's managers" in Research Findings.
  ```dockerfile
  USER root
  # System-wide install so all users (codespace and any future users) share one runtime tree.
  ENV MISE_INSTALL_PATH=/usr/local/bin/mise
  ENV MISE_DATA_DIR=/usr/local/share/mise
  ENV MISE_CONFIG_DIR=/etc/mise
  ENV MISE_CACHE_DIR=/var/cache/mise
  RUN curl -fsSL https://mise.run | sh \
   && mkdir -p "$MISE_DATA_DIR" "$MISE_CONFIG_DIR" "$MISE_CACHE_DIR" \
   && chown -R codespace:codespace "$MISE_DATA_DIR" "$MISE_CONFIG_DIR" "$MISE_CACHE_DIR"
  # Prepend mise shims for non-interactive shells (Docker RUN, docker exec, CI).
  # Per mise docs, shims-on-PATH is the recommended pattern for non-interactive use;
  # `mise activate` is reserved for interactive rc files.
  RUN printf '%s\n' \
        'export MISE_DATA_DIR=/usr/local/share/mise' \
        'export PATH=/usr/local/share/mise/shims:$PATH' \
        > /etc/profile.d/mise.sh \
   && chmod 0644 /etc/profile.d/mise.sh
  ENV MISE_DATA_DIR=/usr/local/share/mise
  ENV PATH=/usr/local/share/mise/shims:${PATH}

  USER codespace
  # Set global defaults for the four required languages. Hedged version selectors:
  # `lts` resolves to the current Node LTS, `latest` resolves to the current stable
  # release of Python/Go, and `temurin-lts` resolves to the current Eclipse Temurin LTS.
  # All resolutions are deferred to build time so security/patch rolls flow in
  # automatically (mirrors the floating-tag pin strategy for the base image).
  # Exact versions are recorded at build time by the Step 7 verification commands.
  RUN mise use --global node@lts python@latest go@latest java@temurin-lts \
   && mise install \
   && mise reshim
  ```
  References:
  - mise Docker cookbook: https://github.com/jdx/mise/blob/main/docs/mise-cookbook/docker.md
  - mise shims (non-interactive use): https://github.com/jdx/mise/blob/main/docs/dev-tools/shims.md
- Install **Homebrew (Linuxbrew)** as the `codespace` user — second significant addition vs. the upstream image:
  ```dockerfile
  USER codespace
  RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  RUN echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/codespace/.bashrc \
   && echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/codespace/.zshrc
  ```
  Also append `/home/linuxbrew/.linuxbrew/bin` and `/home/linuxbrew/.linuxbrew/sbin` to a profile fragment in `/etc/profile.d/linuxbrew.sh` so non-login shells also pick it up.
- Install pip-level helpers used by the existing scripts (`dvc`, `yq`) into the image's default Python (`/usr/local/python/current/bin/pip install --user dvc yq`) so they're on `codespace`'s PATH without touching system site-packages.
- **Non-root user: `codespace`** (UID/GID 1000) — this is the user the universal image ships with. **Migration note:** existing scripts (`configure-claude.sh`, `statusline.sh`, `install-mcps.sh`) and `.devcontainer/devcontainer.json` currently hardcode `/home/node/...` and `remoteUser: "node"`. As part of Step 4 these references are rewritten to `/home/codespace/...` (or, equivalently, made `$HOME`-relative). We do NOT recreate a literal `node` user on top of the universal image — that would diverge from the upstream UID/GID convention and break feature-supplied permissions (`docker-outside-of-docker` group mapping, etc.).

Output image tag: `ghcr.io/NeoLabHQ/sandbox:base`.

#### Step 2: Create `Dockerfile.agents`

Create `/workspaces/sandbox/Dockerfile.agents`.

- `ARG BASE_IMAGE=ghcr.io/neolabhq/sandbox:base`
- `FROM ${BASE_IMAGE}` — pin to the published `:base@sha256:<digest>` resolved by the `build-base` CI job (so this layer is reproducible even though the Microsoft root floats; see Base Image rationale).
- Switch to the non-root user (`USER codespace`).
- Install **Claude Code**: `curl -fsSL https://claude.ai/install.sh | bash`. Ensure `PATH` includes `/home/codespace/.local/bin`.
- Install **OpenCode**: `curl -fsSL https://opencode.ai/install | bash` (installs to `~/.opencode/bin` or similar; add to PATH).
- Install **Gemini CLI**: `npm install -g @google/gemini-cli` (npm global prefix set to user dir so no `sudo` needed).
- Install **Codex CLI**: `npm install -g @openai/codex` (fourth required agent for parity).
- Install **TypeScript LSP and helpful global tools**: `npm install -g typescript-language-server typescript rust-just bun` (preserve current behavior).
- **Architectural note**: Although requirement 6 lists codemap and language MCP servers / LSPs as belonging to the final `Dockerfile` layer, they are installed here in `Dockerfile.agents` because they are **code-intelligence dependencies of the AI agents themselves** (codemap feeds agent context; gopls/pyright/jdtls are LSP backends the agents call via MCP). Installing them in the agents layer (1) keeps the agents image self-sufficient for any consumer (not just the final image), (2) avoids re-installing heavy Go/npm toolchains in the final layer, and (3) cleanly separates "AI tooling" (agents image) from "user-facing configuration" (final image). The final `Dockerfile` (Step 3) then verifies their presence and only adds the configuration scripts on top.
- Install **codemap**: `git clone --depth 1 https://github.com/JordanCoin/codemap.git /tmp/codemap && cd /tmp/codemap && go build -o /usr/local/bin/codemap . && rm -rf /tmp/codemap` (uses the `go` already provided by `universal:6-noble` at `/usr/local/go/bin/go`; perform the install as root then `chown` and switch back to `codespace`).
- Install **gopls** (Go LSP): `go install golang.org/x/tools/gopls@latest`.
- Install **pyright** (Python LSP): `npm install -g pyright`.
- Install **jdtls / eclipse.jdt.ls** (Java LSP): download the latest milestone tarball from `https://download.eclipse.org/jdtls/milestones/` and extract to `/opt/jdtls`. Symlink the launcher onto `PATH` as `jdtls`. Java itself comes from SDKMAN's `current` symlink at `/usr/local/sdkman/candidates/java/current`.
- Install **`docker-mcp` CLI plugin** (migrated from `.devcontainer/devcontainer.json` `bash-command` feature): clone `https://github.com/docker/mcp-gateway.git`, `make docker-mcp`, and install the resulting binary into `/home/codespace/.docker/cli-plugins/docker-mcp`. Use `HOME=/home/codespace` during build and `chown -R codespace:codespace /home/codespace/.docker` to ensure correct ownership. This requires the Docker CLI at runtime, which the devcontainer's `docker-outside-of-docker` feature (preserved — see Step 4) supplies.

Output image tag: `ghcr.io/NeoLabHQ/sandbox:agents`.

#### Step 3: Create final `Dockerfile`

Create `/workspaces/sandbox/Dockerfile` (root, replacing or superseding the `.devcontainer/Dockerfile` for image-build purposes).

- `ARG AGENTS_IMAGE=ghcr.io/neolabhq/sandbox:agents`
- `FROM ${AGENTS_IMAGE}` — pin to `:agents@sha256:<digest>` resolved by the `build-agents` CI job.
- `USER root`
- `COPY configure-claude.sh statusline.sh install-mcps.sh /opt/devcontainer/`
- `RUN chmod +x /opt/devcontainer/*.sh`
- `ENV DOCKER_MCP_IN_CONTAINER=1`
- `USER codespace`
- **Verify codemap and language MCP servers are present** (inherited from the agents image per the architectural note in Step 2): add a `RUN` step `command -v codemap && command -v gopls && command -v pyright && command -v jdtls` so the final image fails fast if the agents image ever drops one of these. This explicitly satisfies requirement 6's "add codemap, context7, common languages mcp servers" — codemap, gopls, pyright, jdtls are inherited from `:agents`, and Context7 is registered at runtime via `install-mcps.sh`.
- **Pre-register Context7 MCP at build time (where possible)**: any MCP that does not require runtime secrets can be registered here. For Context7 specifically, the API key is runtime-only, so its `claude mcp add` invocation stays in `install-mcps.sh`. The final `Dockerfile` is the canonical place where the MCP wiring is assembled, even though some calls fire at `postCreateCommand`.
- `RUN /opt/devcontainer/configure-claude.sh` to bootstrap `~/.claude/settings.json`, statusline, and Claude plugins (matches existing stage 4 behavior).
- Do **not** run `install-mcps.sh` at build time — keep it as `postCreateCommand` because it needs runtime env vars (e.g., `CONTEXT7_API_KEY`).
- Set sensible defaults like `WORKDIR /workspaces` and `CMD ["sleep","infinity"]` so the image is usable both as a devcontainer and a standalone `docker run` target.

Output image tag: `ghcr.io/NeoLabHQ/sandbox:latest`.

#### Step 4: Move scripts from `.devcontainer/` to repo root and migrate `devcontainer.json`

- Move `configure-claude.sh`, `statusline.sh`, `install-mcps.sh` from `/workspaces/sandbox/.devcontainer/` to `/workspaces/sandbox/`.
- **Rewrite `/home/node/...` references** in `configure-claude.sh`, `statusline.sh`, `install-mcps.sh` to `/home/codespace/...` (or, preferably, `$HOME/...` so the scripts are user-agnostic). The universal image's user is `codespace` (UID 1000), so the literal `node` user no longer exists.
- **Replace `.devcontainer/Dockerfile`** with a thin wrapper: a single-line `FROM ghcr.io/neolabhq/sandbox:latest` (optionally pinned to `@sha256:<digest>` for reproducibility). The devcontainer must consume the published image rather than re-build locally — this eliminates duplicated build logic, guarantees parity between devcontainer and standalone `docker run` consumers, and matches the migration table below (which already switches `devcontainer.json` to `image:` rather than `build:`). Keeping the file (vs. deleting it) is intentional: a `FROM`-only Dockerfile lets devcontainer features still layer on top via a build context if ever needed in the future.
- Update `.devcontainer/devcontainer.json`: switch `remoteUser` from `"node"` to `"codespace"`, and confirm `postCreateCommand` still resolves to `/opt/devcontainer/install-mcps.sh` (that path is preserved by the final `Dockerfile`'s `COPY`).

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
| `remoteUser` | `"node"` | **Update in devcontainer.json** to `"codespace"`; image defaults `USER codespace`. | The new base image (`universal:6-noble`) ships `codespace` as the UID 1000 user. Existing `/home/node/...` script references are rewritten to `/home/codespace/...` (or `$HOME/...`) in Step 4. |

Net effect on `.devcontainer/devcontainer.json` after this step:
- Switch `build.dockerfile` → `image: ghcr.io/neolabhq/sandbox:latest`.
- Keep `docker-outside-of-docker` feature.
- Remove the `devcontainers-extra/features/bash-command` (docker-mcp) feature; functionality is now in the agents image.
- Update `remoteUser` from `"node"` to `"codespace"`.
- Everything else (customizations, ports, env, postCreate) preserved verbatim.

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

Every workflow run pushes both a moving tag (`:base`, `:agents`, `:latest`) and an immutable SHA-suffixed tag (`:base-<sha>`, `:agents-<sha>`, `:latest-<sha>`) — those immutable tags exist specifically to enable instant rollback. If a bad image is published (whether caused by our changes or by an upstream Microsoft rebuild of `universal:6-noble` flowing through our floating-tag pin):

- **Re-tag the previous SHA-pinned image to the moving tag** to restore service immediately: `docker buildx imagetools create -t ghcr.io/neolabhq/sandbox:latest ghcr.io/neolabhq/sandbox:latest-<previous-good-sha>` (and analogously for `:base` / `:agents`). This is atomic at the registry level and requires no rebuild.
- **Revert the digest pin in our owned downstream layers**: if `Dockerfile.agents` pins `ghcr.io/neolabhq/sandbox:base@sha256:<bad>` (or the final `Dockerfile` pins `:agents@sha256:<bad>`), open a revert commit that restores the previous digest, then re-run the workflow. Likewise update `.devcontainer/Dockerfile`'s `FROM ghcr.io/neolabhq/sandbox:latest@sha256:<digest>` to the previous good digest. (We do NOT have a digest to revert on the Microsoft root, since `Dockerfile.base` floats on `universal:6-noble` by design — see Base Image section. For an upstream regression, the fix is to roll back to the prior good `:base-<sha>` we already published, NOT to pin Microsoft's tag.)
- **Temporarily hard-pin the upstream tag (emergency only)**: if Microsoft's `6-noble` rebuild is repeatedly regressing, the `build-base` job will record the last-known-good upstream digest in its OCI annotation; an emergency PR may pin `Dockerfile.base` to `mcr.microsoft.com/devcontainers/universal:6-noble@sha256:<good>` as a stop-gap until upstream stabilizes, then revert to the floating tag once verified.
- **Invalidate poisoned build cache**: clear the affected GitHub Actions cache scopes via the GitHub Actions cache UI or `gh actions-cache delete <key>` so the bad layers are not silently reused on the next build. Re-run with `cache-from` disabled for one cycle if in doubt.
- **Notify consumers**: post a brief notice in the README's "Image variants & tags" section (or a GitHub release note on the previous-good tag) instructing users to pull by the explicit `:latest-<good-sha>` tag until the next clean publish.

#### Step 6: Update `README.md`

Replace the current two-line README with comprehensive documentation. Sections:

1. **Overview** — what the image is, what's preinstalled.
2. **Image variants & tags** — `:base`, `:agents`, `:latest` with what each contains.
3. **Quick start with Docker (persistent setup)** — `docker pull` + `docker run` examples with `~/.claude` and `~/.claude.json` mapped so Claude state survives between containers.
4. **Quick start without persistent Claude state (ephemeral / single-shot / CI)** — same image, but no `~/.claude*` mounts; relies on `CLAUDE_CODE_OAUTH_TOKEN` for auth and discards Claude state at container exit.
5. **Volume mapping for projects** — mount workspace, mount `~/.claude` and `~/.claude.json` (with an explanation of why both are needed), mount SSH/git configs if needed.
6. **Mounting multiple project directories in the same container** — multi-`-v` pattern.
7. **Passing `CLAUDE_CODE_OAUTH_TOKEN`** — how to obtain one (`claude setup-token` on host), how to pass with `-e` flag; mention `ANTHROPIC_API_KEY` and `CONTEXT7_API_KEY` as alternatives.
8. **Using as a devcontainer** — two flavors:
   - **Quick setup** — minimal `devcontainer.json` using `"image": "ghcr.io/neolabhq/sandbox:latest"` with the `docker-outside-of-docker` feature.
   - **Setup with Docker MCP** — devcontainer that wires up the [Docker MCP Catalog & Toolkit](https://docs.docker.com/ai/mcp-catalog-and-toolkit/) (gateway repo: [`docker/mcp-gateway`](https://github.com/docker/mcp-gateway)) so the in-container `docker-mcp` plugin can proxy MCP servers from the host Docker MCP catalog.
9. **Tools included** — list languages (Node, Python, Go, Java — managed by **`mise`** at current-LTS / current-stable defaults so they can be re-pinned via `mise use --global` or a project-level `mise.toml`; plus Ruby, PHP, .NET inherited from `universal:6-noble` at recent-stable lines; exact resolved versions are documented as the output of the Step 7 `mise current` + verification command rather than pinned in the README), version managers (`mise` for the four required languages; `nvm`/SDKMAN/`rvm`/etc. retained from the base image and reachable as fall-through for languages mise does not manage), agents (Claude Code, OpenCode, Gemini CLI, Codex), MCP servers (Context7, codemap, docker-mcp), LSPs (gopls, pyright, jdtls, typescript-language-server), plus Homebrew.
10. **Building locally** — `docker build -f Dockerfile.base -t sandbox:base .` chain.

##### Example: persistent Claude state (recommended for daily dev)

```bash
docker run -it --rm \
  -v "$PWD:/workspaces/$(basename "$PWD")" \
  -v "$HOME/.claude:/home/codespace/.claude" \
  -v "$HOME/.claude.json:/home/codespace/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces/$(basename "$PWD")" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

##### Example: ephemeral / single-shot (CI, throwaway sandboxes)

No `~/.claude*` mounts — Claude Code reads the token from `CLAUDE_CODE_OAUTH_TOKEN`, skips onboarding, and discards all state at container exit. Suitable for CI runners, one-off remote agent jobs, and disposable PR review sandboxes.

```bash
docker run -it --rm \
  -v "$PWD:/workspaces/$(basename "$PWD")" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e CONTEXT7_API_KEY \
  -w "/workspaces/$(basename "$PWD")" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

The README will explicitly call out the trade-off: without the `~/.claude*` mounts each container starts cold (re-runs onboarding-skip via the token), no command history, no plugin state. With them, those persist across runs at the cost of binding the container to a specific host's Claude profile.

##### Example: multiple project directories in one container

Mount each project under a sibling path inside `/workspaces`:

```bash
docker run -it --rm \
  -v "$HOME/code/project-a:/workspaces/project-a" \
  -v "$HOME/code/project-b:/workspaces/project-b" \
  -v "$HOME/code/shared-lib:/workspaces/shared-lib" \
  -v "$HOME/.claude:/home/codespace/.claude" \
  -v "$HOME/.claude.json:/home/codespace/.claude.json" \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -w "/workspaces" \
  ghcr.io/neolabhq/sandbox:latest \
  bash
```

The README will note: (1) keep each project in its own sub-directory under `/workspaces/` — agents and LSPs locate project roots by walking up to the nearest `.git`/`pyproject.toml`/`go.mod`/etc., so siblings stay isolated; (2) cross-project refactors work because all projects share one container PATH, `gh` auth, and Claude session; (3) for write isolation use `:ro` on the read-only mounts (e.g., a vendored monorepo dependency).

##### Example: quick devcontainer setup

`.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "NeoLabHQ Sandbox",
  "image": "ghcr.io/neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "remoteUser": "codespace",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "CONTEXT7_API_KEY": "${localEnv:CONTEXT7_API_KEY}"
  },
  "postCreateCommand": "/opt/devcontainer/install-mcps.sh"
}
```

##### Example: devcontainer with Docker MCP

For projects that want MCP servers proxied from the host's [Docker MCP Catalog](https://docs.docker.com/ai/mcp-catalog-and-toolkit/) (managed via Docker Desktop's MCP Toolkit and the [`docker/mcp-gateway`](https://github.com/docker/mcp-gateway) CLI plugin), extend the quick-setup example with an explicit `docker-mcp` runtime hook. The `docker-mcp` plugin is already baked into the image (installed in `Dockerfile.agents`); the devcontainer only needs to mount the host MCP catalog directory and forward the MCP gateway socket:

```jsonc
{
  "name": "NeoLabHQ Sandbox (Docker MCP)",
  "image": "ghcr.io/neolabhq/sandbox:latest",
  "features": {
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {}
  },
  "mounts": [
    "source=${localEnv:HOME}/.docker/mcp,target=/home/codespace/.docker/mcp,type=bind,consistency=cached"
  ],
  "remoteUser": "codespace",
  "remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}",
    "DOCKER_MCP_CATALOG_DIR": "/home/codespace/.docker/mcp"
  },
  "postCreateCommand": "docker mcp gateway run --help >/dev/null && /opt/devcontainer/install-mcps.sh"
}
```

The README will link out to:
- Docker MCP Catalog & Toolkit overview: https://docs.docker.com/ai/mcp-catalog-and-toolkit/
- `docker/mcp-gateway` CLI plugin (source for the `docker mcp` command already baked into the image): https://github.com/docker/mcp-gateway
- Model Context Protocol spec: https://modelcontextprotocol.io/introduction

#### Step 7: Verify and iterate

- Build all three images locally with `docker buildx build` to confirm the chain works.
- Confirm the active user is `codespace` (`id` should show `uid=1000(codespace)`).
- Verify the **`mise`** meta version manager and the global defaults it pins for the four required languages: `mise --version`, `mise current`, `mise list`, `mise ls --global`, plus the resolved-through-mise binaries: `node --version`, `python --version`, `go version`, `java --version`. Confirm the shim path is in `PATH` (`command -v node` should resolve under `/usr/local/share/mise/shims/`). Record the exact resolved versions in the build summary — they become the authoritative reference for the Research Findings table, replacing the sketch values.
- Verify base-image-shipped managers and runtimes are still present and reachable when mise has nothing to shim (coexistence check): `nvm --version`, `nvm list`, `sdk version` (SDKMAN), `sdk list java | head`, `rvm list`, `ruby --version`, and confirm `/usr/local/python/current/bin/python3 --version` and `/usr/local/go/bin/go version` resolve directly. Also run `docker run --rm mcr.microsoft.com/devcontainers/universal:6-noble bash -c 'node --version; python3 --version; go version; java --version; ruby --version; nvm list 2>/dev/null; sdk list java 2>/dev/null | head'` against the upstream image directly so the Research Findings table can be confirmed/updated before merge.
- Verify agents and tooling added by our layers: `claude --version`, `opencode --version`, `gemini --version`, `codex --version`, `codemap --help`, `gopls version`, `pyright --version`, `jdtls --help`, `typescript-language-server --version`, `brew --version`, `docker mcp --help`.
- Confirm `~/.claude/settings.json` is populated under `/home/codespace/.claude/` and statusline runs.
- Run `install-mcps.sh` manually to confirm Context7 MCP registration works.
- Test the ephemeral / single-shot flow: run a container WITHOUT `-v ~/.claude*` mounts and with only `CLAUDE_CODE_OAUTH_TOKEN` set; confirm `claude --version` works and onboarding is skipped.
- Test devcontainer path: rebuild `.devcontainer` and confirm VS Code attach still works with the new `codespace` user.

---

### Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base image | `mcr.microsoft.com/devcontainers/universal:6-noble` | Ships Node/Python/Go/Java/Ruby/PHP/.NET plus their version managers (nvm, SDKMAN, rvm); actively patched by Microsoft on weekly cadence; eliminates per-runtime install logic we would otherwise own. |
| Base-image pin strategy | Floating tag (`6-noble`), NOT `@sha256:` digest | Lets Microsoft's weekly security rebuilds flow in automatically. Reproducibility for layers we own is preserved by digest-pinning our published `:base`/`:agents` downstream and by recording the resolved upstream digest as an OCI annotation per CI build. |
| Version manager (meta) | **`mise`** (https://mise.jdx.dev), installed system-wide; coexists with the base image's per-language managers | Single Rust binary, first-class coverage of all four required languages (Node/Python/Go/Java) — unlike `proto`, where Java is plugin-fallback. Shims-on-PATH mode works in non-interactive shells (Docker `RUN`, `docker exec`, CI) without requiring `eval "$(mise activate ...)"`. Makes the project's default versions explicit via `mise.toml`/`mise current` rather than spread across `nvm alias default`, the `/usr/local/python` symlink, the Go tarball, and SDKMAN's `current` symlink. The base image's `nvm`/SDKMAN/`rvm`/etc. continue to ship their runtimes; mise sits *above* them via PATH ordering and falls through for languages it does not manage. |
| Image-level additions | Homebrew (Linuxbrew) + AI agents + MCP plugins + LSPs | Genuine gaps in `universal:6-noble` for this project. |
| Image layering | 3 separate Dockerfiles (`base` → `agents` → final) | Matches user requirement; enables independent rebuilds; smaller agent-only delta; cacheable. |
| Registry | `ghcr.io/neolabhq/sandbox` | Required by task; lowercase org per GHCR rules. |
| Multi-arch | `linux/amd64` + `linux/arm64` | Apple Silicon parity; matches `dpkg --print-architecture` logic already in existing Dockerfile. |
| Scripts location | Move to repo root | Required by task; allows `Dockerfile` (final) to `COPY` from `.` without `..` paths and keeps `.devcontainer/` clean. |
| Non-root user | `codespace` (UID/GID 1000, default in `universal:6-noble`) | Use the image's existing user rather than renaming it back to `node`. Existing `/home/node/...` references in `configure-claude.sh`, `statusline.sh`, `install-mcps.sh`, and `.devcontainer/devcontainer.json` are rewritten to `/home/codespace/...` (or `$HOME/...`) as part of Step 4. **Alternative considered:** rewrite the user inside the image to `node` (UID 1000) to preserve the existing `/home/node/...` paths. **Rejected** because UID-remapping is brittle (group-membership reshuffling, home-dir ownership gymnastics, divergence from upstream feature assumptions like `docker-outside-of-docker`'s GID mapping), whereas rewriting the three script paths is a one-time edit with a single source of truth. |
| MCP install timing | `postCreateCommand` (runtime), not build time | Needs `CONTEXT7_API_KEY` and other secrets only available at container start. |

---

### File Structure

Files to **create**:
- `/workspaces/sandbox/Dockerfile.base`
- `/workspaces/sandbox/Dockerfile.agents`
- `/workspaces/sandbox/Dockerfile`
- `/workspaces/sandbox/.github/workflows/docker-publish.yml`

Files to **move and edit** (from `.devcontainer/` to repo root, rewriting `/home/node/...` → `/home/codespace/...` or `$HOME/...`):
- `configure-claude.sh`
- `statusline.sh`
- `install-mcps.sh`

Files to **update**:
- `/workspaces/sandbox/README.md` — full usage documentation (persistent + ephemeral + multi-project + devcontainer quick + devcontainer-with-Docker-MCP)
- `/workspaces/sandbox/.devcontainer/Dockerfile` — replace contents with thin `FROM ghcr.io/neolabhq/sandbox:latest` wrapper (committed choice; no alternative path)
- `/workspaces/sandbox/.devcontainer/devcontainer.json` — switch `build.dockerfile` → `image`, drop the `bash-command` docker-mcp feature, update `remoteUser` from `"node"` to `"codespace"`, and verify `postCreateCommand` still resolves to `/opt/devcontainer/install-mcps.sh`

Files to **leave untouched**:
- `/workspaces/sandbox/.claude/`
- `/workspaces/sandbox/claude-helpers.sh`
- `/workspaces/sandbox/justfile`
- `/workspaces/sandbox/LICENSE`
- `/workspaces/sandbox/.specs/`

